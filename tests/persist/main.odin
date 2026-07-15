package persist

// Persistenz-Test: läuft gegen einen NEU GESTARTETEN Server mit dem
// Datenbestand aus dem Smoke-Test (alice/general/DM müssen existieren).
// Nutzung: persist <host:port>

import "core:fmt"
import "core:net"
import "core:os"
import "core:crypto/ecdh"

import shared "../../src/shared"

fail :: proc(step: string, args: ..any) {
	fmt.eprintf("FEHLGESCHLAGEN: %s ", step)
	fmt.eprintln(..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Nutzung: persist <host:port>")
		os.exit(2)
	}

	sock, derr := net.dial_tcp(os.args[1])
	if derr != nil {
		fail("dial", derr)
	}
	priv: ecdh.Private_Key
	if !shared.generate_static_key(&priv) {
		fail("keygen")
	}
	conn: shared.Secure_Conn
	if !shared.client_handshake(&conn, sock, &priv) {
		fail("handshake")
	}

	seq: u64 = 1
	request :: proc(conn: ^shared.Secure_Conn, seq: ^u64, w: shared.Wire) -> shared.Wire {
		w := w
		w.seq = seq^
		seq^ += 1
		if !shared.send_wire(conn, w) {
			fail("send", w.kind)
		}
		for {
			r, ok := shared.recv_wire(conn)
			if !ok {
				fail("recv", w.kind)
			}
			if r.seq == w.seq && r.kind == w.kind {
				return r
			}
			// Events ignorieren
		}
	}

	lg := request(&conn, &seq, {kind = shared.K_LOGIN, username = "alice", password = "geheim123"})
	if !lg.ok || lg.server_name != "ACME Corp" || !lg.user.is_admin || lg.setup_needed {
		fail("login nach neustart", "ok =", lg.ok, "name =", lg.server_name)
	}
	fmt.println("ok: login nach neustart, servername erhalten")

	lc := request(&conn, &seq, {kind = shared.K_LIST_CHANNELS})
	if len(lc.channels) != 4 { // general + DM + büro-küche + bulk (aus dem Smoke-Test)
		fail("channels nach neustart", "erwartet 4, bekommen", len(lc.channels))
	}
	fmt.println("ok: channels nach neustart vorhanden")

	h := request(&conn, &seq, {kind = shared.K_HISTORY, channel_id = 1})
	if len(h.messages) != 2 {
		fail("history nach neustart", "erwartet 2, bekommen", len(h.messages))
	}
	if h.messages[0].text != "hallo *welt* von _alice_" || h.messages[1].text != "hi zurück 🎉" {
		fail("history texte", "entschlüsselte texte falsch:", h.messages[0].text, "/", h.messages[1].text)
	}
	fmt.println("ok: history nach neustart korrekt entschlüsselt (inkl. emoji)")

	s := request(&conn, &seq, {kind = shared.K_SEND, channel_id = 1, text = "nach dem neustart"})
	if !s.ok {
		fail("send nach neustart", s.err)
	}
	h2 := request(&conn, &seq, {kind = shared.K_HISTORY, channel_id = 1})
	if len(h2.messages) != 3 || h2.messages[2].text != "nach dem neustart" {
		fail("history nach send", "anzahl =", len(h2.messages))
	}
	if h2.messages[2].id <= h2.messages[1].id {
		fail("message-id monotonie", "id nicht größer als vorherige")
	}
	fmt.println("ok: message-ids nach neustart monoton, senden funktioniert")

	fmt.println("\nPERSISTENZ-TEST BESTANDEN ✔")
}
