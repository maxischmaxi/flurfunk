package audio_test

// Headless-Test der Voice-DSP-Pipeline (keine Audio-Geräte, kein Netz):
//   1. Opus-Roundtrip durch den Processor (Encode) und Decoder
//   2. FEC- und PLC-Rekonstruktion
//   3. Jitter-Buffer: Verlust, Reordering, Lücken, Resync
//   4. VAD-Gate: Rauschen wird nicht gesendet, AEC dämpft Echo
// Nutzung: einfach starten, Exit-Code 0 = bestanden.

import "core:fmt"
import "core:math"
import "core:os"

import audio "../../src/audio"

fail :: proc(step: string, args: ..any) {
	fmt.eprintf("FEHLGESCHLAGEN: %s ", step)
	fmt.eprintln(..args)
	os.exit(1)
}

rms :: proc(samples: []f32) -> f32 {
	sum: f32
	for s in samples {
		sum += s * s
	}
	return math.sqrt(sum / f32(len(samples)))
}

// Deterministisches weißes Rauschen (LCG), Amplitude ±amp.
Noise :: struct {
	state: u64,
}
noise_next :: proc(n: ^Noise, amp: f32) -> f32 {
	n.state = n.state * 6364136223846793005 + 1442695040888963407
	return (f32(n.state >> 33) / f32(1 << 31) - 1) * amp
}

sine_frame :: proc(buf: []f32, phase: ^f32, freq: f32, amp: f32) {
	for &s in buf {
		s = math.sin(phase^) * amp
		phase^ += 2 * math.PI * freq / audio.SAMPLE_RATE
	}
}

main :: proc() {
	// ---------- 1. Encode/Decode-Roundtrip ----------
	p: audio.Processor
	if !audio.processor_init(&p) {
		fail("processor_init")
	}
	p.denoise_on = false // Sinus ist keine Sprache — Gate offen halten

	d: audio.Decoder
	if !audio.decoder_init(&d) {
		fail("decoder_init")
	}

	phase: f32
	mic: [audio.FRAME_10MS]f32
	pkt: [audio.MAX_PAYLOAD]byte
	out: [audio.FRAME_20MS]f32

	packets: [dynamic][]byte
	total_bytes := 0
	for _ in 0 ..< 200 { // 2 s Sinus
		sine_frame(mic[:], &phase, 440, 0.5)
		n := audio.processor_push_capture(&p, mic[:], pkt[:])
		if n > 0 {
			total_bytes += n
			cp := make([]byte, n)
			copy(cp, pkt[:n])
			append(&packets, cp)
		}
	}
	if len(packets) < 90 {
		fail("encode", "zu wenige Pakete:", len(packets))
	}
	kbps := f32(total_bytes) * 8 / 2000
	if kbps > 60 {
		fail("bitrate", "unerwartet hoch:", kbps, "kbps")
	}

	got_energy := false
	for pl in packets {
		if !audio.decode_packet(&d, pl, out[:]) {
			fail("decode")
		}
		if rms(out[:]) > 0.05 {
			got_energy = true
		}
	}
	if !got_energy {
		fail("roundtrip", "kein Signal nach Decode")
	}
	fmt.printfln("ok: opus-roundtrip (%d pakete, %.0f kbps inkl. gate-anlauf)", len(packets), kbps)

	// ---------- 2. FEC und PLC ----------
	d2: audio.Decoder
	if !audio.decoder_init(&d2) {
		fail("decoder_init 2")
	}
	for pl in packets[:20] { // Decoder-Kontext aufbauen
		audio.decode_packet(&d2, pl, out[:])
	}
	if !audio.decode_fec(&d2, packets[21], out[:]) {
		fail("fec-decode")
	}
	if rms(out[:]) < 0.01 {
		fail("fec-energie", rms(out[:]))
	}
	if !audio.decode_plc(&d2, out[:]) {
		fail("plc-decode")
	}
	fmt.println("ok: fec-rekonstruktion und plc")

	// ---------- 3. Jitter-Buffer ----------
	d3: audio.Decoder
	if !audio.decoder_init(&d3) {
		fail("decoder_init 3")
	}
	jb: audio.Jitter
	audio.jitter_init(&jb)

	// Takttreue Simulation über 60 Sende-Slots: jedes 7. Paket geht
	// verloren (FEC-Fall), das Paar 20/21 kommt vertauscht an (Reorder),
	// während 40..45 sendet die Gegenseite nichts (DTX-Pause → PLC-Ausklang
	// + Neuansatz). Ein Verlust-Slot ist ein Tick OHNE Ankunft — Pakete
	// kommen in Echtzeit, nicht als Burst.
	sched: [60]int
	for i in 0 ..< 60 {
		sched[i] = i % 7 == 3 || (i >= 40 && i <= 45) ? -1 : i
	}
	sched[20], sched[21] = sched[21], sched[20]

	oks, fecs, plcs := 0, 0, 0
	for tick in 0 ..< 90 {
		if tick < 60 && sched[tick] >= 0 {
			audio.jitter_push(&jb, u64(sched[tick]), packets[sched[tick]])
		}
		switch audio.jitter_pull(&jb, &d3, out[:]) {
		case .Ok:
			oks += 1
		case .Fec:
			fecs += 1
		case .Plc:
			plcs += 1
		case .Silence:
		}
	}
	if oks < 40 {
		fail("jitter ok-frames", oks)
	}
	if fecs == 0 {
		fail("jitter fec nie benutzt", fecs)
	}
	if plcs == 0 {
		fail("jitter plc nie benutzt", plcs)
	}
	if jb.n_ok != u64(oks) || jb.n_fec != u64(fecs) || jb.n_plc != u64(plcs) {
		fail("jitter statistik inkonsistent")
	}
	fmt.printfln("ok: jitter-buffer (ok=%d fec=%d plc=%d, tiefe=%d)", oks, fecs, plcs, jb.target)

	// Später ankommende Pakete erhöhen die Zieltiefe.
	late_before := jb.target
	audio.jitter_push(&jb, jb.next - 3, packets[0])
	if jb.target <= late_before {
		fail("jitter adaptivität", jb.target, late_before)
	}
	fmt.println("ok: jitter-buffer adaptiert bei zu späten paketen")

	// ---------- 4. VAD-Gate: Rauschen wird nicht übertragen ----------
	p2: audio.Processor
	if !audio.processor_init(&p2) {
		fail("processor_init 4")
	}
	nz := Noise{state = 0x9E3779B97F4A7C15}
	noise_pkts_tail := 0
	for i in 0 ..< 200 { // 2 s reines Rauschen
		for &s in mic {
			s = noise_next(&nz, 0.08)
		}
		n := audio.processor_push_capture(&p2, mic[:], pkt[:])
		if n > 0 && i >= 100 {
			noise_pkts_tail += 1 // nach Einschwingen darf nichts mehr kommen
		}
	}
	if noise_pkts_tail > 3 {
		fail("vad-gate", "rauschen erzeugte", noise_pkts_tail, "pakete")
	}
	fmt.printfln("ok: vad-gate hält rauschen zurück (%d pakete nach einschwingen)", noise_pkts_tail)

	// ---------- 5. AEC: Lautsprecher-Echo wird gedämpft ----------
	p3: audio.Processor
	if !audio.processor_init(&p3) {
		fail("processor_init 5")
	}
	p3.denoise_on = false // Echo-Dämpfung isoliert messen
	phase2: f32
	spk: [audio.FRAME_10MS]f32
	early, late_lvl: f32
	for i in 0 ..< 300 { // 3 s: Mikro hört exakt den Lautsprecher
		sine_frame(spk[:], &phase2, 350, 0.4)
		audio.processor_feed_playback(&p3, spk[:])
		audio.processor_push_capture(&p3, spk[:], pkt[:])
		if i < 20 {
			early = max(early, p3.level)
		}
		if i >= 250 {
			late_lvl = max(late_lvl, p3.level)
		}
	}
	if late_lvl > early * 0.5 {
		fail("aec", "kaum dämpfung: früh =", early, "spät =", late_lvl)
	}
	fmt.printfln("ok: aec dämpft echo (pegel %.3f → %.3f)", early, late_lvl)

	fmt.println("\nALLE AUDIO-TESTS BESTANDEN ✔")
}
