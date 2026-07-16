package shared

// UDP-Voice-Paketformat. Audio läuft NICHT über den Noise-TCP-Kanal
// (Head-of-Line-Blocking wäre Gift für Echtzeit), sondern über UDP auf
// demselben Port. Jedes Paket ist einzeln mit dem per TCP verteilten
// Call-Key XChaCha20-Poly1305-verschlüsselt und authentifiziert — es geht
// also auch hier nie Klartext-Audio übers Netz, und der Server forwarded
// nur Pakete, deren Tag er verifizieren konnte.
//
// Layout (alles little-endian):
//   HELLO           : type(1) call_id(8) ssrc(4) seq(8) | ct(token 16) tag(16)
//   AUDIO/PING      : type(1)           ssrc(4) seq(8) | ct(…) tag(16)
//   WELCOME/PONG    : type(1)           ssrc(4) seq(8) | ct(…) tag(16)
// Der Klartext-Header ist als AAD mitauthentifiziert. Nonce (24 Byte):
//   [0]=type  [1..5]=ssrc  [5..13]=seq  Rest 0
// type als Domain-Trenner + ssrc einmalig pro Call + seq monoton pro
// Sender ⇒ (Key, Nonce) wiederholt sich nie.

import "core:crypto/aead"
import "core:encoding/endian"

VP_HELLO :: u8(1) // Client → Server: Adresse registrieren (Payload: udp_token)
VP_WELCOME :: u8(2) // Server → Client: Registrierung bestätigt
VP_AUDIO :: u8(3) // beide Richtungen: ein Opus-Frame (20 ms)
VP_PING :: u8(4) // Client → Server: Keepalive + RTT (Payload: 8B Zeitstempel)
VP_PONG :: u8(5) // Server → Client: Echo des Zeitstempels

VOICE_KEY_LEN :: 32
VOICE_TOKEN_LEN :: 16
VOICE_TAG_LEN :: 16
VOICE_HDR_LEN :: 13 // type + ssrc + seq
VOICE_HELLO_HDR_LEN :: 21 // type + call_id + ssrc + seq
VOICE_MAX_PACKET :: 512

// Geparster Klartext-Header; `sealed` zeigt in den Originalpuffer.
Voice_Packet :: struct {
	ptype:   u8,
	call_id: u64, // nur HELLO, sonst 0
	ssrc:    u32,
	seq:     u64,
	hdr:     []byte, // Header-Bytes (AAD)
	sealed:  []byte, // ciphertext || tag
}

voice_nonce :: proc(ptype: u8, ssrc: u32, seq: u64) -> (n: [24]byte) {
	n[0] = ptype
	endian.unchecked_put_u32le(n[1:5], ssrc)
	endian.unchecked_put_u64le(n[5:13], seq)
	return
}

// Baut ein komplettes Paket nach dst; Rückgabe = Gesamtlänge (0 = dst zu klein).
voice_pack :: proc(dst: []byte, key: []byte, ptype: u8, call_id: u64, ssrc: u32, seq: u64, plain: []byte) -> int {
	hdr_len := ptype == VP_HELLO ? VOICE_HELLO_HDR_LEN : VOICE_HDR_LEN
	total := hdr_len + len(plain) + VOICE_TAG_LEN
	if len(dst) < total {
		return 0
	}
	dst[0] = ptype
	off := 1
	if ptype == VP_HELLO {
		endian.unchecked_put_u64le(dst[off:], call_id)
		off += 8
	}
	endian.unchecked_put_u32le(dst[off:], ssrc)
	endian.unchecked_put_u64le(dst[off + 4:], seq)

	nonce := voice_nonce(ptype, ssrc, seq)
	ct := dst[hdr_len : hdr_len + len(plain)]
	tag := dst[hdr_len + len(plain) : total]
	aead.seal_oneshot(.XCHACHA20POLY1305, ct, tag, key, nonce[:], dst[:hdr_len], plain)
	return total
}

// Zerlegt nur den Klartext-Header (kein Key nötig — fürs Routing).
voice_parse :: proc(pkt: []byte) -> (vp: Voice_Packet, ok: bool) {
	if len(pkt) < VOICE_HDR_LEN + VOICE_TAG_LEN || len(pkt) > VOICE_MAX_PACKET {
		return
	}
	vp.ptype = pkt[0]
	off := 1
	if vp.ptype == VP_HELLO {
		if len(pkt) < VOICE_HELLO_HDR_LEN + VOICE_TAG_LEN {
			return
		}
		vp.call_id = endian.unchecked_get_u64le(pkt[off:])
		off += 8
	}
	vp.ssrc = endian.unchecked_get_u32le(pkt[off:])
	vp.seq = endian.unchecked_get_u64le(pkt[off + 4:])
	vp.hdr = pkt[:off + 12]
	vp.sealed = pkt[off + 12:]
	ok = vp.ptype >= VP_HELLO && vp.ptype <= VP_PONG
	return
}

// Entschlüsselt und authentifiziert die Payload eines geparsten Pakets.
// dst braucht len(vp.sealed) - VOICE_TAG_LEN Bytes.
voice_open :: proc(vp: Voice_Packet, key: []byte, dst: []byte) -> (plain: []byte, ok: bool) {
	n := len(vp.sealed) - VOICE_TAG_LEN
	if n < 0 || len(dst) < n {
		return
	}
	nonce := voice_nonce(vp.ptype, vp.ssrc, vp.seq)
	if !aead.open_oneshot(.XCHACHA20POLY1305, dst[:n], key, nonce[:], vp.hdr, vp.sealed[:n], vp.sealed[n:]) {
		return
	}
	return dst[:n], true
}
