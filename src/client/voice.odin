package main

// UDP-Voice-Link des Clients: HELLO/WELCOME-Registrierung beim SFU,
// Audio-Versand (aus dem Engine-Worker), Empfang → Jitter-Buffer,
// PING/PONG als Keepalive + RTT-Messung. Der Main-Thread treibt über
// voice_tick Retries und Keepalives; ein eigener Thread blockiert im recv.

import "core:encoding/endian"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

import audio "../audio"
import shared "../shared"

VOICE_HELLO_RETRY_MS :: 500
VOICE_PING_EVERY_MS :: 2000
VOICE_STALL_MS :: 6000 // so lange kein PONG → „Verbindung gestört“

Voice_Link :: struct {
	sock:         net.UDP_Socket,
	sock_ok:      bool,
	srv:          net.Endpoint,
	key:          [shared.VOICE_KEY_LEN]byte,
	token:        [shared.VOICE_TOKEN_LEN]byte,
	call_id:      u64,
	ssrc:         u32,
	engine:       ^audio.Engine,

	ctl_seq:      u64, // HELLO/PING (nur Main-Thread)
	audio_seq:    u64, // AUDIO (nur Engine-Worker)

	running:      bool, // atomar
	connected:    bool, // atomar: WELCOME gesehen
	recv_t:       ^thread.Thread,

	rtt_ms:       f32, // vom recv-Thread geschrieben (Anzeige)
	last_pong_ms: i64,

	// Main-Thread-Timer
	last_hello_ms: i64,
	last_ping_ms:  i64,
}

// Monotone Millisekunden (threadsicher, unabhängig von raylib).
mono_ms :: proc() -> i64 {
	return time.tick_now()._nsec / 1_000_000
}

// Wird vom Engine-Worker mit fertigen Opus-Paketen gerufen.
voice_on_packet :: proc(user: rawptr, payload: []byte) {
	vl := (^Voice_Link)(user)
	if !vl.sock_ok || !sync.atomic_load(&vl.connected) {
		return
	}
	vl.audio_seq += 1
	buf: [shared.VOICE_MAX_PACKET]byte
	n := shared.voice_pack(buf[:], vl.key[:], shared.VP_AUDIO, 0, vl.ssrc, vl.audio_seq, payload)
	if n > 0 {
		_, _ = net.send_udp(vl.sock, buf[:n], vl.srv)
	}
}

@(private = "file")
voice_send_hello :: proc(vl: ^Voice_Link) {
	vl.ctl_seq += 1
	buf: [shared.VOICE_MAX_PACKET]byte
	n := shared.voice_pack(buf[:], vl.key[:], shared.VP_HELLO, vl.call_id, vl.ssrc, vl.ctl_seq, vl.token[:])
	if n > 0 {
		_, _ = net.send_udp(vl.sock, buf[:n], vl.srv)
	}
	vl.last_hello_ms = mono_ms()
}

@(private = "file")
voice_send_ping :: proc(vl: ^Voice_Link) {
	vl.ctl_seq += 1
	ts: [8]byte
	endian.unchecked_put_u64le(ts[:], u64(mono_ms()))
	buf: [shared.VOICE_MAX_PACKET]byte
	n := shared.voice_pack(buf[:], vl.key[:], shared.VP_PING, 0, vl.ssrc, vl.ctl_seq, ts[:])
	if n > 0 {
		_, _ = net.send_udp(vl.sock, buf[:n], vl.srv)
	}
	vl.last_ping_ms = mono_ms()
}

@(private = "file")
voice_recv_loop :: proc(t: ^thread.Thread) {
	vl := (^Voice_Link)(t.data)
	buf: [shared.VOICE_MAX_PACKET + 64]byte
	plain: [shared.VOICE_MAX_PACKET]byte

	for sync.atomic_load(&vl.running) {
		n, _, err := net.recv_udp(vl.sock, buf[:])
		if err != nil || n <= 0 {
			continue // Stop läuft über running=false + close(sock)
		}
		vp, ok := shared.voice_parse(buf[:n])
		if !ok {
			continue
		}
		pl, opened := shared.voice_open(vp, vl.key[:], plain[:])
		if !opened {
			continue
		}
		switch vp.ptype {
		case shared.VP_WELCOME:
			sync.atomic_store(&vl.connected, true)
			vl.last_pong_ms = mono_ms()
		case shared.VP_PONG:
			if len(pl) == 8 {
				ts := i64(endian.unchecked_get_u64le(pl))
				vl.rtt_ms = f32(mono_ms() - ts)
				vl.last_pong_ms = mono_ms()
			}
		case shared.VP_AUDIO:
			if vp.ssrc != vl.ssrc && vl.engine != nil {
				audio.engine_push_audio(vl.engine, vp.ssrc, vp.seq, pl)
			}
		case shared.VP_HELLO, shared.VP_PING:
		// kommen nur vom Client, nicht vom Server
		}
	}
}

voice_link_start :: proc(vl: ^Voice_Link, engine: ^audio.Engine, srv: net.Endpoint, key: []byte, token: []byte, call_id: u64, ssrc: u32) -> bool {
	vl^ = {}
	sock, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		return false
	}
	// Kurzes Receive-Timeout: close() weckt ein blockierendes recvfrom auf
	// Linux nicht zuverlässig — mit Timeout prüft der recv-Thread periodisch
	// sein running-Flag und thread.join kann nie hängen bleiben.
	_ = net.set_option(sock, .Receive_Timeout, 200 * time.Millisecond)
	vl.sock = sock
	vl.sock_ok = true
	vl.srv = srv
	copy(vl.key[:], key)
	copy(vl.token[:], token)
	vl.call_id = call_id
	vl.ssrc = ssrc
	vl.engine = engine

	sync.atomic_store(&vl.running, true)
	vl.recv_t = thread.create(voice_recv_loop)
	vl.recv_t.data = vl
	thread.start(vl.recv_t)

	voice_send_hello(vl)
	return true
}

voice_link_stop :: proc(vl: ^Voice_Link) {
	if !vl.sock_ok {
		return
	}
	sync.atomic_store(&vl.running, false)
	net.close(vl.sock) // löst das blockierende recv
	if vl.recv_t != nil {
		thread.join(vl.recv_t)
		thread.destroy(vl.recv_t)
	}
	vl^ = {}
}

// Pro Frame vom Main-Thread: HELLO-Retry bis WELCOME, dann Keepalive-PINGs.
voice_tick :: proc(vl: ^Voice_Link) {
	if !vl.sock_ok {
		return
	}
	now := mono_ms()
	if !sync.atomic_load(&vl.connected) {
		if now - vl.last_hello_ms >= VOICE_HELLO_RETRY_MS {
			voice_send_hello(vl)
		}
		return
	}
	if now - vl.last_ping_ms >= VOICE_PING_EVERY_MS {
		voice_send_ping(vl)
	}
	// Länger nichts gehört? NAT-Mapping könnte gekippt sein → neu anmelden.
	if now - vl.last_pong_ms >= VOICE_STALL_MS && now - vl.last_hello_ms >= VOICE_HELLO_RETRY_MS {
		voice_send_hello(vl)
	}
}

// Verbindung gesund? (WELCOME da und PONGs fließen)
voice_healthy :: proc(vl: ^Voice_Link) -> bool {
	return vl.sock_ok && sync.atomic_load(&vl.connected) &&
	       mono_ms() - vl.last_pong_ms < VOICE_STALL_MS
}
