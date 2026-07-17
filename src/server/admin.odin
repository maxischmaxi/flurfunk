package main

// Admin panel handlers. Every request here requires an admin caller and every
// successful reply carries a fresh Admin_State snapshot — the client simply
// replaces its copy, no incremental sync needed. All handlers run under g.mu.

import "core:crypto"
import "core:fmt"
import "core:net"
import "core:strings"

import shared "../shared"

// Readable, unambiguous alphabet (no I/O/0/1) for invite codes.
@(private = "file")
INVITE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

@(private = "file")
require_admin :: proc(c: ^Client_Conn, w: shared.Wire) -> ^User {
	u := find_user_by_id(c.user_id)
	if u == nil || !u.is_admin {
		send_err(c, w.kind, w.seq, "not_allowed")
		return nil
	}
	return u
}

// Number of admins whose accounts are usable — the last one is protected.
@(private = "file")
active_admins :: proc() -> int {
	n := 0
	for &u in g.users {
		if u.is_admin && !u.disabled {
			n += 1
		}
	}
	return n
}

// Builds the full snapshot (temp-allocated).
@(private = "file")
admin_state_build :: proc() -> shared.Admin_State {
	st: shared.Admin_State
	st.settings = {
		registration_closed = g.meta.registration_closed,
		f2b_disabled        = g.meta.f2b_disabled,
		f2b_max_fails       = g.meta.f2b_max_fails > 0 ? g.meta.f2b_max_fails : F2B_DEFAULT_MAX_FAILS,
		f2b_window_min      = g.meta.f2b_window_min > 0 ? g.meta.f2b_window_min : F2B_DEFAULT_WINDOW_MIN,
		f2b_ban_min         = g.meta.f2b_ban_min > 0 ? g.meta.f2b_ban_min : F2B_DEFAULT_BAN_MIN,
	}

	users := make([]shared.Admin_User, len(g.users), context.temp_allocator)
	for &u, i in g.users {
		users[i] = {id = u.id, disabled = u.disabled, last_ip = u.last_ip, last_seen_ms = u.last_seen_ms}
	}
	st.users = users

	channels := make([dynamic]shared.Admin_Channel, 0, len(g.channels), context.temp_allocator)
	for &ch in g.channels {
		if ch.is_dm {
			st.dm_count += 1
			continue
		}
		append(&channels, shared.Admin_Channel{
			id         = ch.id,
			name       = ch.name,
			creator_id = ch.creator_id,
			members    = len(ch.member_ids),
		})
	}
	st.channels = channels[:]

	invites := make([]shared.Invite_Info, len(g.invites), context.temp_allocator)
	for &inv, i in g.invites {
		invites[i] = {
			code       = inv.code,
			created_ms = inv.created_ms,
			expires_ms = inv.expires_ms,
			created_by = inv.created_by,
			used_by    = inv.used_by,
			used_ms    = inv.used_ms,
		}
	}
	st.invites = invites

	st.bans = bans_snapshot()
	return st
}

// Success reply carrying the fresh snapshot.
@(private = "file")
admin_ok :: proc(w: shared.Wire) -> shared.Wire {
	resp := shared.wire_ok(w.kind, w.seq)
	resp.admin = admin_state_build()
	return resp
}

handle_admin_state :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	send_to(c, admin_ok(w))
}

handle_admin_set :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	s := w.settings
	g.meta.registration_closed = s.registration_closed
	g.meta.f2b_disabled = s.f2b_disabled
	g.meta.f2b_max_fails = clamp(s.f2b_max_fails != 0 ? s.f2b_max_fails : F2B_DEFAULT_MAX_FAILS, 2, 50)
	g.meta.f2b_window_min = clamp(s.f2b_window_min != 0 ? s.f2b_window_min : F2B_DEFAULT_WINDOW_MIN, 1, 24 * 60)
	g.meta.f2b_ban_min = clamp(s.f2b_ban_min != 0 ? s.f2b_ban_min : F2B_DEFAULT_BAN_MIN, 1, 7 * 24 * 60)
	save_meta()
	security_configure(g.meta)

	fmt.printfln("[admin] Einstellungen: Registrierung %s, fail2ban %s (%d Fehler / %d min → %d min Sperre)",
		g.meta.registration_closed ? "geschlossen" : "offen",
		g.meta.f2b_disabled ? "aus" : "an",
		g.meta.f2b_max_fails, g.meta.f2b_window_min, g.meta.f2b_ban_min)
	send_to(c, admin_ok(w))
}

handle_admin_set_role :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	target := find_user_by_id(w.user_id)
	if target == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if target.is_admin && !w.is_admin && active_admins() <= 1 {
		send_err(c, w.kind, w.seq, "last_admin")
		return
	}
	if target.is_admin != w.is_admin {
		target.is_admin = w.is_admin
		save_users()
		broadcast_authed(shared.Wire{kind = shared.EV_USER, user = wire_user(target)}, nil)
		fmt.printfln("[admin] User %q ist jetzt %s (durch User %d)",
			target.username, w.is_admin ? "Admin" : "Mitglied", c.user_id)
	}
	send_to(c, admin_ok(w))
}

handle_admin_set_disabled :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	target := find_user_by_id(w.user_id)
	if target == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if target.id == c.user_id {
		send_err(c, w.kind, w.seq, "not_allowed") // locking yourself out is not allowed
		return
	}
	if w.disabled && target.is_admin && !target.disabled && active_admins() <= 1 {
		send_err(c, w.kind, w.seq, "last_admin")
		return
	}
	if target.disabled != w.disabled {
		target.disabled = w.disabled
		save_users()
		if w.disabled {
			// Sessions die and open connections get cut.
			drop_user_sessions(target.id)
			close_user_conns(target.id, c)
		}
		broadcast_authed(shared.Wire{kind = shared.EV_USER, user = wire_user(target)}, nil)
		fmt.printfln("[admin] User %q %s (durch User %d)",
			target.username, w.disabled ? "deaktiviert" : "aktiviert", c.user_id)
	}
	send_to(c, admin_ok(w))
}

handle_admin_create_user :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	username := strings.trim_space(w.username)
	if !shared.valid_username(username) || len(w.password) < shared.MIN_PASSWORD_LEN {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	if find_user_by_name(username) != nil {
		send_err(c, w.kind, w.seq, "username_taken")
		return
	}

	u := User{
		id           = g.meta.next_user_id,
		username     = strings.clone(username),
		display_name = strings.clone(strings.trim_space(w.display_name)),
	}
	crypto.rand_bytes(u.salt[:])
	if !hash_password(w.password, u.salt[:], u.pass_hash[:]) {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	g.meta.next_user_id += 1
	append(&g.users, u)
	save_users()
	save_meta()

	nu := find_user_by_id(u.id)
	broadcast_authed(shared.Wire{kind = shared.EV_USER, user = wire_user(nu)}, nil)
	fmt.printfln("[admin] Konto %q vorab angelegt (durch User %d)", u.username, c.user_id)

	resp := admin_ok(w)
	resp.user = wire_user(nu)
	send_to(c, resp)
}

handle_admin_reset_password :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	target := find_user_by_id(w.user_id)
	if target == nil {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	if len(w.password) < shared.MIN_PASSWORD_LEN {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	crypto.rand_bytes(target.salt[:])
	if !hash_password(w.password, target.salt[:], target.pass_hash[:]) {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	save_users()
	// All existing sessions die, live connections too — if the account was
	// compromised, the attacker gets kicked immediately.
	drop_user_sessions(target.id)
	close_user_conns(target.id, c)

	fmt.printfln("[admin] Passwort von %q zurückgesetzt (durch User %d)", target.username, c.user_id)
	send_to(c, admin_ok(w))
}

@(private = "file")
invite_code_gen :: proc() -> string {
	raw: [shared.INVITE_CODE_LEN]byte
	crypto.rand_bytes(raw[:])
	buf: [shared.INVITE_CODE_LEN]byte
	for b, i in raw {
		buf[i] = INVITE_ALPHABET[int(b) % len(INVITE_ALPHABET)]
	}
	return strings.clone_from_bytes(buf[:])
}

handle_admin_create_invite :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	now := now_ms()
	minutes := clamp(w.minutes, 0, 365 * 24 * 60)
	inv := Invite{
		code       = invite_code_gen(),
		created_ms = now,
		expires_ms = minutes > 0 ? now + i64(minutes) * 60_000 : 0,
		created_by = c.user_id,
	}
	append(&g.invites, inv)
	save_invites()

	fmt.printfln("[admin] Einladung %s erstellt (durch User %d)", inv.code, c.user_id)
	resp := admin_ok(w)
	resp.invite_code = inv.code
	send_to(c, resp)
}

handle_admin_revoke_invite :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	code := strings.to_upper(strings.trim_space(w.invite_code), context.temp_allocator)
	found := false
	for &inv, i in g.invites {
		if inv.code == code {
			delete(inv.code)
			ordered_remove(&g.invites, i)
			found = true
			break
		}
	}
	if !found {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	save_invites()
	send_to(c, admin_ok(w))
}

handle_admin_ban_ip :: proc(c: ^Client_Conn, w: shared.Wire) {
	caller := require_admin(c, w)
	if caller == nil {
		return
	}
	raw := strings.trim_space(w.ip)
	addr := net.parse_address(raw)
	if addr == nil {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	// Canonical form so the entry matches accept-loop lookups.
	buf: [64]byte
	ip := format_ip(buf[:], addr)
	if ip == c.ip {
		send_err(c, w.kind, w.seq, "own_ip") // locking yourself out is not allowed
		return
	}
	minutes := clamp(w.minutes, 0, 365 * 24 * 60)
	reason := fmt.tprintf("von @%s", caller.username)
	ban_add(ip, reason, c.user_id, minutes)
	close_ip_conns(ip, c)

	fmt.printfln("[admin] IP %s gesperrt (%s, durch User %d)",
		ip, minutes > 0 ? fmt.tprintf("%d min", minutes) : "permanent", c.user_id)
	send_to(c, admin_ok(w))
}

handle_admin_unban_ip :: proc(c: ^Client_Conn, w: shared.Wire) {
	if require_admin(c, w) == nil {
		return
	}
	if !ban_remove(strings.trim_space(w.ip)) {
		send_err(c, w.kind, w.seq, "not_found")
		return
	}
	fmt.printfln("[admin] IP %s entsperrt (durch User %d)", w.ip, c.user_id)
	send_to(c, admin_ok(w))
}
