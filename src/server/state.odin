package main

// In-Memory-Zustand des Servers. Alles hinter EINEM Mutex (g.mu);
// sämtliche Zugriffe auf g.* passieren nur mit gehaltenem Lock.

import "core:net"
import "core:sync"
import "core:time"

import shared "../shared"

KEY_LEN   :: 32 // Master-/Channel-Keys
SALT_LEN  :: 16 // Argon2id-Salt
HASH_LEN  :: 32 // Argon2id-Hash
NONCE_LEN :: 24 // XChaCha20-Poly1305 Nonce
TAG_LEN   :: 16 // Poly1305-Tag

// Registrierter User inkl. Passwort-Hash.
User :: struct {
	id:           u64,
	username:     string,
	display_name: string,
	is_admin:     bool,
	salt:         [SALT_LEN]byte,
	pass_hash:    [HASH_LEN]byte,
}

// Channel bzw. DM. `key` ist der entpackte Channel-Key —
// er liegt nur im RAM, auf der Platte ausschließlich gewrappt.
Channel :: struct {
	id:         u64,
	name:       string,
	is_dm:      bool,
	creator_id: u64,
	member_ids: [dynamic]u64,
	key:        [KEY_LEN]byte,
}

Session :: struct {
	token:      string,
	user_id:    u64,
	created_ms: i64,
}

// Persistierte Server-Metadaten (server.json).
Server_Meta :: struct {
	server_name:     string `json:"server_name"`,
	initialized:     bool   `json:"initialized"`,
	next_user_id:    u64    `json:"next_user_id"`,
	next_channel_id: u64    `json:"next_channel_id"`,
	next_message_id: u64    `json:"next_message_id"`,
}

// Eine Client-Verbindung; lebt in ihrem eigenen Thread.
Client_Conn :: struct {
	sock:    net.TCP_Socket,
	sc:      shared.Secure_Conn,
	authed:  bool,
	user_id: u64,
	remote:  string, // Gegenstelle, nur fürs Logging
}

Server_State :: struct {
	mu:         sync.Mutex,
	data_dir:   string,
	master_key: [KEY_LEN]byte,
	meta:       Server_Meta,
	users:      [dynamic]User,
	sessions:   [dynamic]Session,
	channels:   [dynamic]Channel,
	conns:      [dynamic]^Client_Conn,
}

g: Server_State

// ---------- Lookup-Helfer (nur unter g.mu aufrufen) ----------

find_user_by_id :: proc(id: u64) -> ^User {
	for &u in g.users {
		if u.id == id {
			return &u
		}
	}
	return nil
}

find_user_by_name :: proc(username: string) -> ^User {
	for &u in g.users {
		if u.username == username {
			return &u
		}
	}
	return nil
}

find_channel :: proc(id: u64) -> ^Channel {
	for &ch in g.channels {
		if ch.id == id {
			return &ch
		}
	}
	return nil
}

find_session :: proc(token: string) -> ^Session {
	for &s in g.sessions {
		if s.token == token {
			return &s
		}
	}
	return nil
}

is_member :: proc(ch: ^Channel, user_id: u64) -> bool {
	for id in ch.member_ids {
		if id == user_id {
			return true
		}
	}
	return false
}

remove_member :: proc(ch: ^Channel, user_id: u64) {
	for id, idx in ch.member_ids {
		if id == user_id {
			ordered_remove(&ch.member_ids, idx)
			return
		}
	}
}

// online = mindestens eine authentifizierte Verbindung dieses Users.
user_online :: proc(user_id: u64) -> bool {
	for conn in g.conns {
		if conn.authed && conn.user_id == user_id {
			return true
		}
	}
	return false
}

// ---------- Wire-Konvertierung ----------

wire_user :: proc(u: ^User) -> shared.User {
	return shared.User{
		id           = u.id,
		username     = u.username,
		display_name = u.display_name,
		is_admin     = u.is_admin,
		online       = user_online(u.id),
	}
}

wire_channel :: proc(ch: ^Channel) -> shared.Channel {
	return shared.Channel{
		id         = ch.id,
		name       = ch.name,
		is_dm      = ch.is_dm,
		creator_id = ch.creator_id,
		member_ids = ch.member_ids[:],
	}
}

// ---------- Senden / Broadcasts (nur unter g.mu aufrufen) ----------

send_to :: proc(c: ^Client_Conn, w: shared.Wire) {
	// Fehler beim Senden werden ignoriert — die Verbindung räumt sich
	// über das recv-Ende ihres eigenen Threads auf.
	_ = shared.send_wire(&c.sc, w)
}

// An alle authentifizierten Verbindungen (optional eine ausnehmen).
broadcast_authed :: proc(w: shared.Wire, exclude: ^Client_Conn) {
	for conn in g.conns {
		if conn == exclude || !conn.authed {
			continue
		}
		send_to(conn, w)
	}
}

// An alle authentifizierten Verbindungen von Channel-Mitgliedern.
broadcast_members :: proc(ch: ^Channel, w: shared.Wire, exclude: ^Client_Conn) {
	for conn in g.conns {
		if conn == exclude || !conn.authed {
			continue
		}
		if !is_member(ch, conn.user_id) {
			continue
		}
		send_to(conn, w)
	}
}

// An alle authentifizierten Verbindungen eines bestimmten Users.
broadcast_user :: proc(user_id: u64, w: shared.Wire, exclude: ^Client_Conn) {
	for conn in g.conns {
		if conn == exclude || !conn.authed || conn.user_id != user_id {
			continue
		}
		send_to(conn, w)
	}
}

// Unix-Millisekunden.
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
