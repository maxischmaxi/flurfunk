package shared

// Wire-Protokoll: JSON-Nachrichten über einen Noise-verschlüsselten TCP-Kanal.
// Jede Nachricht ist ein `Wire`-Envelope mit `kind` + den für den Kind
// relevanten Feldern. Requests tragen eine `seq`, Responses echoen sie.
// Server-Events haben seq == 0.

import "core:unicode"

PROTOCOL_VERSION :: 1

// Client -> Server Requests
K_SERVER_INFO    :: "server_info"
K_REGISTER       :: "register"
K_LOGIN          :: "login"
K_RESUME         :: "resume" // Session per Token fortsetzen
K_SETUP          :: "setup"  // Ersteinrichtung durch Admin (Servername)
K_LIST_USERS     :: "list_users"
K_LIST_CHANNELS  :: "list_channels"
K_CREATE_CHANNEL :: "create_channel"
K_DELETE_CHANNEL :: "delete_channel" // nur Admin oder Ersteller
K_INVITE         :: "invite"
K_KICK           :: "kick"
K_LEAVE          :: "leave"
K_OPEN_DM        :: "open_dm"
K_SEND           :: "send"
K_HISTORY        :: "history"

// Server -> Client Events (seq == 0)
EV_MESSAGE         :: "ev_message"         // neue Chat-Nachricht
EV_CHANNEL         :: "ev_channel"         // Channel neu/aktualisiert (Mitgliedschaft)
EV_CHANNEL_REMOVED :: "ev_channel_removed" // aus Channel entfernt / Channel weg (err = "deleted" bei Löschung)
EV_USER            :: "ev_user"            // User neu/aktualisiert (inkl. online)
EV_SERVER          :: "ev_server"          // Server-Konfiguration geändert (Name)

MAX_MESSAGE_TEXT_LEN :: 8 * 1024
MAX_USERNAME_LEN     :: 32
MAX_CHANNEL_NAME_LEN :: 48
MIN_PASSWORD_LEN     :: 6
HISTORY_MAX_LIMIT    :: 100

User :: struct {
	id:           u64    `json:"id"`,
	username:     string `json:"username"`,
	display_name: string `json:"display_name,omitempty"`,
	is_admin:     bool   `json:"is_admin,omitempty"`,
	online:       bool   `json:"online,omitempty"`,
}

Channel :: struct {
	id:         u64    `json:"id"`,
	name:       string `json:"name,omitempty"`,
	is_dm:      bool   `json:"is_dm,omitempty"`,
	creator_id: u64    `json:"creator_id,omitempty"`,
	member_ids: []u64  `json:"member_ids,omitempty"`,
}

Chat_Message :: struct {
	id:         u64    `json:"id"`,
	channel_id: u64    `json:"channel_id"`,
	author_id:  u64    `json:"author_id"`,
	ts_ms:      i64    `json:"ts_ms"`, // Unix-Millisekunden
	text:       string `json:"text"`,
}

// Ein flacher Envelope für alle Nachrichten-Kinds. Nicht gesetzte Felder
// werden dank omitempty nicht serialisiert.
Wire :: struct {
	kind: string `json:"kind"`,
	seq:  u64    `json:"seq,omitempty"`,

	ok:  bool   `json:"ok,omitempty"`,
	err: string `json:"err,omitempty"`,

	// Auth / Setup
	username:     string `json:"username,omitempty"`,
	password:     string `json:"password,omitempty"`,
	display_name: string `json:"display_name,omitempty"`,
	token:        string `json:"token,omitempty"`,

	// Server-Info
	server_name:  string `json:"server_name,omitempty"`,
	initialized:  bool   `json:"initialized,omitempty"`,  // Setup abgeschlossen
	setup_needed: bool   `json:"setup_needed,omitempty"`, // dieser Client muss Setup durchführen

	// Entities
	user:     User         `json:"user,omitempty"`,
	users:    []User       `json:"users,omitempty"`,
	channel:  Channel      `json:"channel,omitempty"`,
	channels: []Channel    `json:"channels,omitempty"`,
	message:  Chat_Message `json:"message,omitempty"`,
	messages: []Chat_Message `json:"messages,omitempty"`,

	// Parameter
	channel_id: u64    `json:"channel_id,omitempty"`,
	user_id:    u64    `json:"user_id,omitempty"`,
	name:       string `json:"name,omitempty"`,
	text:       string `json:"text,omitempty"`,
	before_id:  u64    `json:"before_id,omitempty"`,
	limit:      int    `json:"limit,omitempty"`,
}

// Antwort-Helfer
wire_ok :: proc(kind: string, seq: u64) -> Wire {
	return Wire{kind = kind, seq = seq, ok = true}
}

wire_err :: proc(kind: string, seq: u64, msg: string) -> Wire {
	return Wire{kind = kind, seq = seq, err = msg}
}

valid_username :: proc(s: string) -> bool {
	if len(s) < 2 || len(s) > MAX_USERNAME_LEN {
		return false
	}
	for c in s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', '-', '.':
		case:
			return false
		}
	}
	return true
}

valid_channel_name :: proc(s: string) -> bool {
	if len(s) < 1 || len(s) > MAX_CHANNEL_NAME_LEN {
		return false
	}
	for c in s {
		switch c {
		case 'a' ..= 'z', '0' ..= '9', '_', '-':
		case:
			// Nicht-ASCII-Buchstaben (ä ö ü ß é …) sind erlaubt, solange
			// sie klein sind — Großbuchstaben bleiben wie im ASCII-Fall draußen.
			if c < 0x80 || !unicode.is_letter(c) || unicode.is_upper(c) {
				return false
			}
		}
	}
	return true
}
