package audio

// Adaptiver Jitter-Buffer, ein Exemplar pro Remote-Stream (ssrc).
//
// Pakete landen per jitter_push (Netzwerk-Thread-Seite des Workers) in
// festen Slots (seq mod JB_CAP — keine Allokationen im Hot-Path). Der
// Mixer zieht per jitter_pull alle 20 ms genau einen Frame:
//   Paket da        → normal dekodieren
//   fehlt, next+1 da → in-band-FEC des Folgepakets rekonstruiert ihn
//   beides weg      → Opus-PLC extrapoliert (max. JB_MAX_PLC Frames)
//
// Die Zieltiefe `target` atmet mit dem Netz: kommen Pakete zu spät
// (seq < next), wächst sie; bleibt es lange sauber, schrumpft sie.
// Sende-Pausen (Gate zu → 0 Pakete) sind KEIN Verlust: nach kurzem
// PLC-Ausklang liefert der Buffer Stille und prebuffert beim nächsten
// Sprech-Einsatz neu.

JB_CAP :: 64 // Slots à 20 ms = 1,28 s Fenster
JB_TARGET_MIN :: 2 // 40 ms
JB_TARGET_MAX :: 12 // 240 ms
JB_MAX_PLC :: 5 // 100 ms Extrapolation, danach Stille
JB_GOOD_SHRINK :: 250 // 5 s sauber → target um 1 senken

Pull_Result :: enum {
	Silence, // nichts zu spielen (Prebuffer/Leerlauf)
	Ok,
	Fec,
	Plc,
}

Jitter :: struct {
	pkts:    [JB_CAP][MAX_PAYLOAD]byte,
	lens:    [JB_CAP]int, // 0 = Slot leer
	seqs:    [JB_CAP]u64,
	next:    u64, // nächste abzuspielende seq
	highest: u64, // höchste gesehene seq
	started: bool,
	prebuf:  int, // Frames warten, bevor gezogen wird
	target:  int, // Ziel-Tiefe in Paketen
	misses:  int, // Pulls ohne Daten in Folge
	good:    int, // saubere Pulls seit letzter Anpassung
	// Statistik fürs UI (seit Join)
	n_ok:    u64,
	n_fec:   u64,
	n_plc:   u64,
	n_late:  u64,
}

jitter_init :: proc(jb: ^Jitter) {
	jb^ = {}
	jb.target = 3 // 60 ms Start-Tiefe
}

jitter_depth :: proc(jb: ^Jitter) -> int {
	if !jb.started || jb.highest + 1 < jb.next {
		return 0
	}
	return int(jb.highest + 1 - jb.next)
}

jitter_push :: proc(jb: ^Jitter, seq: u64, payload: []byte) {
	if len(payload) == 0 || len(payload) > MAX_PAYLOAD {
		return
	}
	if !jb.started || seq >= jb.next + JB_CAP || (jb.next > seq && jb.next - seq >= JB_CAP) {
		// Erststart oder Riesen-Sprung → Resync auf diese seq.
		jb.lens = {}
		jb.next = seq
		jb.highest = seq
		jb.started = true
		jb.prebuf = jb.target
	}
	if seq < jb.next {
		// Zu spät — Frame ist schon vorbei. Netz jittert stärker als
		// gepuffert wird → Tiefe erhöhen.
		jb.n_late += 1
		jb.good = 0
		jb.target = min(jb.target + 2, JB_TARGET_MAX)
		return
	}
	if jb.misses > JB_MAX_PLC && jitter_depth(jb) == 0 {
		// Wiedereinsatz nach Sende-Pause: direkt hier aufsetzen
		// und kurz neu ansparen.
		jb.next = seq
		jb.prebuf = max(jb.target - 1, 0)
		jb.misses = 0
	}
	slot := seq % JB_CAP
	copy(jb.pkts[slot][:], payload)
	jb.lens[slot] = len(payload)
	jb.seqs[slot] = seq
	jb.highest = max(jb.highest, seq)

	// Stark übervoll (Burst nach Netz-Hänger) → nach vorn springen.
	if jitter_depth(jb) > jb.target + 8 {
		jb.next = jb.highest - u64(jb.target) + 1
	}
}

// Zieht genau einen 20-ms-Frame nach `out`. Bei .Silence ist out genullt.
jitter_pull :: proc(jb: ^Jitter, d: ^Decoder, out: []f32) -> Pull_Result {
	assert(len(out) >= FRAME_20MS)
	silence :: proc(out: []f32) {
		for &s in out {s = 0}
	}

	if !jb.started {
		silence(out)
		return .Silence
	}
	if jb.prebuf > 0 {
		jb.prebuf -= 1
		silence(out)
		return .Silence
	}

	slot := jb.next % JB_CAP
	if jb.lens[slot] > 0 && jb.seqs[slot] == jb.next {
		ok := decode_packet(d, jb.pkts[slot][:jb.lens[slot]], out)
		jb.lens[slot] = 0
		jb.next += 1
		jb.misses = 0
		jb.n_ok += 1
		jb.good += 1
		if jb.good >= JB_GOOD_SHRINK {
			jb.good = 0
			jb.target = max(jb.target - 1, JB_TARGET_MIN)
		}
		if !ok {
			silence(out)
			return .Silence
		}
		return .Ok
	}

	// Frame fehlt. Liegt der Folgeframe vor, trägt er FEC-Daten für uns.
	nslot := (jb.next + 1) % JB_CAP
	if jb.lens[nslot] > 0 && jb.seqs[nslot] == jb.next + 1 {
		ok := decode_fec(d, jb.pkts[nslot][:jb.lens[nslot]], out)
		jb.next += 1 // Folgeframe bleibt liegen und ist als Nächstes dran
		jb.misses = 0
		jb.n_fec += 1
		jb.good = 0
		if !ok {
			silence(out)
			return .Silence
		}
		return .Fec
	}

	// Gar nichts da: kurz extrapolieren, dann Ruhe (Sende-Pause/Leitung tot).
	jb.misses += 1
	if jb.misses <= JB_MAX_PLC {
		if jitter_depth(jb) > 0 {
			// Es liegen neuere Pakete: der Frame ist wirklich verloren.
			jb.next += 1
		}
		jb.n_plc += 1
		jb.good = 0
		if decode_plc(d, out) {
			return .Plc
		}
	} else if jitter_depth(jb) > 0 {
		// Ruhe-Modus, aber neuere Pakete liegen bereit (großes Loch nach
		// Netz-Aussetzer) → direkt zur ältesten liegenden seq springen,
		// statt auf den Überlauf-Sprung in jitter_push zu warten.
		lo := jb.highest
		for l, i in jb.lens {
			if l > 0 && jb.seqs[i] >= jb.next && jb.seqs[i] < lo {
				lo = jb.seqs[i]
			}
		}
		jb.next = lo
		jb.misses = 0
	}
	silence(out)
	return .Silence
}
