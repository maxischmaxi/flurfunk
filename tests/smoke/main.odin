package smoke

// Headless-Protokoll-Smoke-Test gegen einen laufenden ping-Server.
// Nutzung: smoke <host:port>   (Server muss mit frischem Datenverzeichnis laufen)
// Bei Hängern von außen mit `timeout` begrenzen.

import "core:fmt"
import "core:net"
import "core:os"
import "core:crypto/ecdh"
import "core:strings"

import shared "../../src/shared"

Test_Conn :: struct {
	secure:   shared.Secure_Conn,
	priv:     ecdh.Private_Key,
	pending:  [dynamic]shared.Wire,
	next_seq: u64,
	label:    string,
}

fail :: proc(step: string, args: ..any) {
	fmt.eprintf("FEHLGESCHLAGEN: %s ", step)
	fmt.eprintln(..args)
	os.exit(1)
}

step_ok :: proc(step: string) {
	fmt.printfln("ok: %s", step)
}

connect :: proc(addr: string, label: string) -> ^Test_Conn {
	tc := new(Test_Conn)
	tc.label = label
	tc.next_seq = 1
	sock, err := net.dial_tcp(addr)
	if err != nil {
		fail("dial", label, err)
	}
	if !shared.generate_static_key(&tc.priv) {
		fail("keygen", label)
	}
	if !shared.client_handshake(&tc.secure, sock, &tc.priv) {
		fail("handshake", label)
	}
	return tc
}

// Liest Wires, bis die Antwort auf (kind, seq) kommt; Events werden gepuffert.
request :: proc(tc: ^Test_Conn, w: shared.Wire) -> shared.Wire {
	w := w
	w.seq = tc.next_seq
	tc.next_seq += 1
	if !shared.send_wire(&tc.secure, w) {
		fail("send", tc.label, w.kind)
	}
	for {
		r, ok := shared.recv_wire(&tc.secure)
		if !ok {
			fail("recv (Antwort)", tc.label, w.kind)
		}
		if r.seq == w.seq && r.kind == w.kind {
			return r
		}
		append(&tc.pending, r)
	}
}

must :: proc(tc: ^Test_Conn, w: shared.Wire, step: string) -> shared.Wire {
	r := request(tc, w)
	if !r.ok || r.err != "" {
		fail(step, tc.label, "err =", r.err)
	}
	step_ok(step)
	return r
}

must_err :: proc(tc: ^Test_Conn, w: shared.Wire, want_err: string, step: string) {
	r := request(tc, w)
	if r.err != want_err {
		fail(step, tc.label, "erwartet err", want_err, "bekommen:", r.err, r.ok)
	}
	step_ok(step)
}

// Sucht ein Event in Puffer/Stream.
expect_event :: proc(tc: ^Test_Conn, kind: string, step: string) -> shared.Wire {
	for w, i in tc.pending {
		if w.kind == kind {
			ordered_remove(&tc.pending, i)
			step_ok(step)
			return w
		}
	}
	for {
		r, ok := shared.recv_wire(&tc.secure)
		if !ok {
			fail(step, tc.label, "Verbindung zu beim Warten auf", kind)
		}
		if r.kind == kind {
			step_ok(step)
			return r
		}
		append(&tc.pending, r)
	}
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Nutzung: smoke <host:port>")
		os.exit(2)
	}
	addr := os.args[1]

	// 1) Frischer Server: Info + Admin-Registrierung + Setup
	a := connect(addr, "A")
	info := request(a, {kind = shared.K_SERVER_INFO})
	if info.initialized || !info.setup_needed {
		fail("server_info frisch", "initialized =", info.initialized, "setup_needed =", info.setup_needed)
	}
	step_ok("server_info: frischer Server")

	reg := must(a, {kind = shared.K_REGISTER, username = "alice", password = "geheim123", display_name = "Alice"}, "admin-registrierung")
	if !reg.user.is_admin || !reg.setup_needed || reg.token == "" {
		fail("admin-flags", "is_admin =", reg.user.is_admin, "setup_needed =", reg.setup_needed)
	}
	alice_id := reg.user.id
	alice_token := reg.token

	must(a, {kind = shared.K_SETUP, server_name = "ACME Corp"}, "setup servername")

	// 2) Zweiter Client: Info + normale Registrierung
	b := connect(addr, "B")
	info2 := request(b, {kind = shared.K_SERVER_INFO})
	if !info2.initialized || info2.server_name != "ACME Corp" {
		fail("server_info nach setup", "name =", info2.server_name)
	}
	step_ok("server_info: initialisiert mit Namen")

	must_err(b, {kind = shared.K_LIST_USERS}, "not_authenticated", "auth-gate")
	must_err(b, {kind = shared.K_REGISTER, username = "alice", password = "xxxxxxxx"}, "username_taken", "doppelter username")

	regb := must(b, {kind = shared.K_REGISTER, username = "bob", password = "huntert2", display_name = "Bob"}, "registrierung bob")
	if regb.user.is_admin || regb.setup_needed {
		fail("bob-flags", "bob darf kein admin sein")
	}
	bob_id := regb.user.id

	// 3) Channel + Invite + Nachrichten
	ch := must(a, {kind = shared.K_CREATE_CHANNEL, name = "general"}, "channel erstellen").channel
	must_err(a, {kind = shared.K_CREATE_CHANNEL, name = "general"}, "name_taken", "channelname doppelt")
	must_err(b, {kind = shared.K_SEND, channel_id = ch.id, text = "hi"}, "not_a_member", "send ohne mitgliedschaft")

	inv := must(a, {kind = shared.K_INVITE, channel_id = ch.id, user_id = bob_id}, "invite bob")
	if len(inv.channel.member_ids) != 2 {
		fail("invite mitglieder", "erwartet 2, bekommen", len(inv.channel.member_ids))
	}
	evch := expect_event(b, shared.EV_CHANNEL, "bob bekommt ev_channel")
	if evch.channel.id != ch.id {
		fail("ev_channel id", "falscher channel")
	}

	sent := must(a, {kind = shared.K_SEND, channel_id = ch.id, text = "hallo *welt* von _alice_"}, "nachricht senden")
	if sent.message.id == 0 || sent.message.ts_ms == 0 {
		fail("message meta", "id/ts fehlen")
	}
	evmsg := expect_event(b, shared.EV_MESSAGE, "bob bekommt ev_message")
	if evmsg.message.text != "hallo *welt* von _alice_" || evmsg.message.author_id != alice_id {
		fail("ev_message inhalt", "text =", evmsg.message.text)
	}

	must(b, {kind = shared.K_SEND, channel_id = ch.id, text = "hi zurück 🎉"}, "antwort von bob")
	evmsg2 := expect_event(a, shared.EV_MESSAGE, "alice bekommt ev_message")
	if evmsg2.message.author_id != bob_id {
		fail("ev_message autor", "erwartet bob")
	}

	hist := must(b, {kind = shared.K_HISTORY, channel_id = ch.id}, "history")
	if len(hist.messages) != 2 || hist.messages[0].author_id != alice_id || hist.messages[1].author_id != bob_id {
		fail("history inhalt", "anzahl =", len(hist.messages))
	}
	if hist.messages[0].id >= hist.messages[1].id {
		fail("history reihenfolge", "nicht aufsteigend")
	}

	// 4) Listen
	lu := must(b, {kind = shared.K_LIST_USERS}, "list_users")
	if len(lu.users) != 2 {
		fail("list_users anzahl", "erwartet 2, bekommen", len(lu.users))
	}
	lc := must(b, {kind = shared.K_LIST_CHANNELS}, "list_channels")
	if len(lc.channels) != 1 {
		fail("list_channels anzahl", "erwartet 1, bekommen", len(lc.channels))
	}

	// 5) DM
	dm := must(b, {kind = shared.K_OPEN_DM, user_id = alice_id}, "dm öffnen").channel
	if !dm.is_dm || len(dm.member_ids) != 2 {
		fail("dm-channel", "is_dm =", dm.is_dm)
	}
	expect_event(a, shared.EV_CHANNEL, "alice bekommt ev_channel (dm)")
	must(b, {kind = shared.K_SEND, channel_id = dm.id, text = "psst, geheim"}, "dm senden")
	evdm := expect_event(a, shared.EV_MESSAGE, "alice bekommt dm")
	if evdm.message.channel_id != dm.id {
		fail("dm event", "falscher channel")
	}
	dm2 := must(a, {kind = shared.K_OPEN_DM, user_id = bob_id}, "dm nochmal öffnen").channel
	if dm2.id != dm.id {
		fail("dm dedupe", "neuer statt existierender DM")
	}

	// 6) Kick + Auth-Fehler
	must_err(b, {kind = shared.K_KICK, channel_id = ch.id, user_id = alice_id}, "not_allowed", "bob darf nicht kicken")
	must(a, {kind = shared.K_KICK, channel_id = ch.id, user_id = bob_id}, "alice kickt bob")
	evrm := expect_event(b, shared.EV_CHANNEL_REMOVED, "bob bekommt ev_channel_removed")
	if evrm.channel_id != ch.id {
		fail("ev_channel_removed id", "falscher channel")
	}
	must_err(b, {kind = shared.K_SEND, channel_id = ch.id, text = "bin ich noch drin?"}, "not_a_member", "send nach kick")

	// 7) Chunking (>32-KiB-Antworten), Pagination, leave, Validierung
	must_err(a, {kind = shared.K_CREATE_CHANNEL, name = "Große Halle"}, "invalid_request", "ungültiger channelname")
	must_err(a, {kind = shared.K_CREATE_CHANNEL, name = "BÜRO"}, "invalid_request", "großbuchstaben-umlaute abgelehnt")
	uml := must(a, {kind = shared.K_CREATE_CHANNEL, name = "büro-küche"}, "channel mit umlauten erstellen").channel
	if uml.name != "büro-küche" {
		fail("umlaut-channel", "name =", uml.name)
	}
	bulk := must(a, {kind = shared.K_CREATE_CHANNEL, name = "bulk"}, "bulk-channel erstellen").channel

	big := strings.repeat("x", 7000)
	too_big := strings.repeat("x", shared.MAX_MESSAGE_TEXT_LEN + 1)
	must_err(a, {kind = shared.K_SEND, channel_id = bulk.id, text = too_big}, "invalid_request", "nachricht zu lang")

	first_bulk_id: u64
	for i in 0 ..< 12 {
		r := request(a, {kind = shared.K_SEND, channel_id = bulk.id, text = big})
		if !r.ok {
			fail("bulk send", "nachricht", i, "err =", r.err)
		}
		if i == 0 {
			first_bulk_id = r.message.id
		}
	}
	step_ok("12 nachrichten à 7000 zeichen gesendet")

	h5 := must(a, {kind = shared.K_HISTORY, channel_id = bulk.id, limit = 5}, "history limit 5 (chunked, ~35KB)")
	if len(h5.messages) != 5 || len(h5.messages[0].text) != 7000 {
		fail("chunking", "anzahl =", len(h5.messages))
	}
	page2 := must(a, {kind = shared.K_HISTORY, channel_id = bulk.id, before_id = h5.messages[0].id, limit = 5}, "history pagination")
	if len(page2.messages) != 5 {
		fail("pagination anzahl", "erwartet 5, bekommen", len(page2.messages))
	}
	for m in page2.messages {
		if m.id >= h5.messages[0].id {
			fail("pagination filter", "id nicht < before_id")
		}
	}
	_ = first_bulk_id

	must(a, {kind = shared.K_INVITE, channel_id = bulk.id, user_id = bob_id}, "bob in bulk einladen")
	expect_event(b, shared.EV_CHANNEL, "bob bekommt ev_channel (bulk)")
	must(b, {kind = shared.K_LEAVE, channel_id = bulk.id}, "bob verlässt bulk")
	must_err(b, {kind = shared.K_SEND, channel_id = bulk.id, text = "noch da?"}, "not_a_member", "send nach leave")

	// 7b) Kanal löschen (nur Admin oder Ersteller)
	tmp := must(a, {kind = shared.K_CREATE_CHANNEL, name = "temp"}, "temp-channel erstellen").channel
	must(a, {kind = shared.K_INVITE, channel_id = tmp.id, user_id = bob_id}, "bob in temp einladen")
	expect_event(b, shared.EV_CHANNEL, "bob bekommt ev_channel (temp)")
	must_err(b, {kind = shared.K_DELETE_CHANNEL, channel_id = tmp.id}, "not_allowed", "bob darf temp nicht löschen")
	must(a, {kind = shared.K_DELETE_CHANNEL, channel_id = tmp.id}, "alice löscht temp")
	evdel := expect_event(b, shared.EV_CHANNEL_REMOVED, "bob bekommt ev_channel_removed (delete)")
	if evdel.channel_id != tmp.id || evdel.err != "deleted" {
		fail("delete event", "channel =", evdel.channel_id, "reason =", evdel.err)
	}
	must_err(a, {kind = shared.K_SEND, channel_id = tmp.id, text = "noch da?"}, "not_found", "send nach delete")

	// 8) Login/Resume
	c := connect(addr, "C")
	must_err(c, {kind = shared.K_LOGIN, username = "alice", password = "falsch123"}, "invalid_credentials", "login falsches passwort")
	must_err(c, {kind = shared.K_RESUME, token = "deadbeef"}, "invalid_token", "resume kaputter token")
	res := must(c, {kind = shared.K_RESUME, token = alice_token}, "resume mit token")
	if res.user.id != alice_id || res.server_name != "ACME Corp" {
		fail("resume identität", "user =", res.user.username)
	}
	d := connect(addr, "D")
	lg := must(d, {kind = shared.K_LOGIN, username = "bob", password = "huntert2"}, "login bob")
	if lg.user.id != bob_id {
		fail("login identität", "falscher user")
	}

	fmt.println("\nALLE SMOKE-TESTS BESTANDEN ✔")
}
