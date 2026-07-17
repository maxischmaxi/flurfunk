package main

// Client side of the OAuth login flow: open a loopback HTTP listener
// (RFC 8252), ask the server for the auth URL (oauth_start), send the
// user's browser there, catch the redirect with ?code=…&state=… and hand
// the code back to the server (oauth_finish) — which answers like a
// normal login. The client never talks to the provider itself, so it
// needs no TLS stack.

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import rl "vendor:raylib"
import shared "../shared"

// Seconds until a dangling browser flow gives up.
OAUTH_FLOW_TIMEOUT :: 180.0

// App-wide at most one flow. The listener thread owns its socket and
// closes it on exit; the main thread only bumps `gen` to invalidate it.
OAuth_Flow :: struct {
	active:   bool,
	provider: string, // preset id (heap)
	label:    string, // for toasts/buttons (heap)
	conn:     ^Server_Conn,
	port:     int,
	state:    string, // expected CSRF state (heap; set by the oauth_start reply)
	started:  f64,    // rl.GetTime() at start

	// listener thread → main (mu guards everything below)
	mu:     sync.Mutex,
	gen:    int,
	got:    bool,
	code:   string, // heap clones made by the listener thread
	rstate: string,
	errmsg: string, // provider error param ("" = none)
}

// ---------- Flow control (main thread) ----------

oauth_begin :: proc(app: ^App, c: ^Server_Conn, provider_id, label: string) {
	if app.oauth.active {
		oauth_flow_stop(app)
	}
	sock, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil {
		toast(app, .Error, "Konnte keinen lokalen Port öffnen")
		return
	}
	ep, eerr := net.bound_endpoint(sock)
	if eerr != nil || ep.port == 0 {
		net.close(sock)
		toast(app, .Error, "Konnte keinen lokalen Port öffnen")
		return
	}
	// Timeout so the accept loop can notice a stale generation and exit.
	_ = net.set_option(sock, .Receive_Timeout, 200 * time.Millisecond)

	if conn_request(c, {kind = shared.K_OAUTH_START, provider = provider_id, redirect_port = ep.port}) == 0 {
		net.close(sock)
		toast(app, .Error, "Verbindung zum Server verloren")
		return
	}

	f := &app.oauth
	sync.lock(&f.mu)
	f.gen += 1
	gen := f.gen
	f.got = false
	f.code = ""
	f.rstate = ""
	f.errmsg = ""
	sync.unlock(&f.mu)

	f.active = true
	f.provider = strings.clone(provider_id)
	f.label = strings.clone(label)
	f.conn = c
	f.port = ep.port
	f.state = ""
	f.started = rl.GetTime()
	thread.run_with_poly_data3(f, gen, sock, oauth_listener)
}

// Invalidates the listener thread and frees the flow state.
oauth_flow_stop :: proc(app: ^App) {
	f := &app.oauth
	if !f.active {
		return
	}
	sync.lock(&f.mu)
	f.gen += 1
	f.got = false
	delete(f.code)
	delete(f.rstate)
	delete(f.errmsg)
	f.code = ""
	f.rstate = ""
	f.errmsg = ""
	sync.unlock(&f.mu)

	f.active = false
	delete(f.provider)
	delete(f.label)
	delete(f.state)
	f.provider = ""
	f.label = ""
	f.state = ""
	f.conn = nil
}

// The oauth_start reply arrived: remember the state, open the browser.
oauth_url_ready :: proc(app: ^App, c: ^Server_Conn, w: shared.Wire) {
	f := &app.oauth
	if !w.ok {
		if f.active && f.conn == c {
			oauth_flow_stop(app)
		}
		toast(app, .Error, translate_err(w.err))
		return
	}
	if !f.active || f.conn != c {
		return // stale reply (flow was cancelled meanwhile)
	}
	delete(f.state)
	f.state = strings.clone(w.state)
	oauth_open_browser(w.auth_url)
	toast(app, .Info, "Browser geöffnet — bitte dort anmelden")
}

// Per-frame poll (app_poll): timeout + results from the listener thread.
oauth_tick :: proc(app: ^App) {
	f := &app.oauth
	if !f.active {
		return
	}
	alive := false
	for c in app.conns {
		if c == f.conn {
			alive = true
			break
		}
	}
	if !alive {
		oauth_flow_stop(app)
		return
	}
	if rl.GetTime() - f.started > OAUTH_FLOW_TIMEOUT {
		toast(app, .Error, "Anmeldung abgelaufen — bitte erneut versuchen")
		oauth_flow_stop(app)
		return
	}

	sync.lock(&f.mu)
	got := f.got
	code := f.code
	rstate := f.rstate
	errmsg := f.errmsg
	f.got = false
	f.code = ""
	f.rstate = ""
	f.errmsg = ""
	sync.unlock(&f.mu)
	if !got {
		return
	}
	defer {
		delete(code)
		delete(rstate)
		delete(errmsg)
	}

	if errmsg != "" {
		msg := errmsg == "access_denied" ? "Anmeldung im Browser abgelehnt" : "Anmeldung fehlgeschlagen"
		toast(app, .Error, fmt.tprintf("%s: %s", f.label, msg))
		oauth_flow_stop(app)
		return
	}
	if code == "" || f.state == "" || rstate != f.state {
		toast(app, .Error, "Anmeldung fehlgeschlagen (ungültige Antwort)")
		oauth_flow_stop(app)
		return
	}

	c := f.conn
	conn_request(c, {kind = shared.K_OAUTH_FINISH, state = f.state, code = code})
	c.auth_busy = true
	c.auth_error = ""
	oauth_flow_stop(app)
}

// ---------- Browser ----------

// Fire-and-forget in a small thread: process_exec waits for the opener to
// exit (xdg-open can take a moment) and reaps it — no zombies.
@(private = "file")
oauth_open_browser :: proc(url: string) {
	u := strings.clone(url)
	thread.run_with_poly_data(u, proc(u: string) {
		defer runtime.default_temp_allocator_destroy(nil)
		when ODIN_OS == .Darwin {
			cmd := []string{"open", u}
		} else when ODIN_OS == .Windows {
			cmd := []string{"cmd", "/c", "start", "", u}
		} else {
			cmd := []string{"xdg-open", u}
		}
		_, _, _, _ = os.process_exec({command = cmd}, context.temp_allocator)
		delete(u)
	})
}

// ---------- Loopback listener (own thread) ----------

@(private = "file")
OAUTH_HTML_OK :: "<!doctype html><meta charset=\"utf-8\"><title>Flurfunk</title>" +
	"<body style=\"font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#fafafa;color:#18181b\">" +
	"<div style=\"text-align:center\"><div style=\"font-size:40px\">✅</div><h2>Anmeldung erfolgreich</h2>" +
	"<p>Du kannst diesen Tab schließen und zu Flurfunk zurückkehren.</p></div>"

@(private = "file")
OAUTH_HTML_ERR :: "<!doctype html><meta charset=\"utf-8\"><title>Flurfunk</title>" +
	"<body style=\"font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#fafafa;color:#18181b\">" +
	"<div style=\"text-align:center\"><div style=\"font-size:40px\">❌</div><h2>Anmeldung nicht abgeschlossen</h2>" +
	"<p>Du kannst diesen Tab schließen und es in Flurfunk erneut versuchen.</p></div>"

@(private = "file")
oauth_listener :: proc(f: ^OAuth_Flow, gen: int, sock: net.TCP_Socket) {
	defer runtime.default_temp_allocator_destroy(nil)
	defer net.close(sock)

	for {
		sync.lock(&f.mu)
		stale := f.gen != gen
		sync.unlock(&f.mu)
		if stale {
			return
		}

		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			// Mostly the 200 ms receive timeout — loop and re-check gen.
			time.sleep(50 * time.Millisecond)
			continue
		}
		_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)

		path, pok := oauth_read_request(client)
		if !pok {
			net.close(client)
			continue
		}
		if !strings.has_prefix(path, "/callback") {
			// Browsers also ask for /favicon.ico — answer and keep waiting.
			oauth_respond(client, "404 Not Found", "")
			net.close(client)
			continue
		}

		code, state, errparam := oauth_parse_query(path)
		oauth_respond(client, "200 OK", errparam == "" && code != "" ? OAUTH_HTML_OK : OAUTH_HTML_ERR)
		net.close(client)

		sync.lock(&f.mu)
		if f.gen == gen && !f.got {
			f.got = true
			f.code = strings.clone(code)
			f.rstate = strings.clone(state)
			f.errmsg = strings.clone(errparam)
		}
		sync.unlock(&f.mu)
		return
	}
}

// Reads until the end of the request head and returns the path of the
// request line ("GET <path> HTTP/1.1").
@(private = "file")
oauth_read_request :: proc(client: net.TCP_Socket) -> (path: string, ok: bool) {
	buf: [8192]byte
	total := 0
	for total < len(buf) {
		n, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || n <= 0 {
			return
		}
		total += n
		if strings.contains(string(buf[:total]), "\r\n") {
			break
		}
	}
	line := string(buf[:total])
	if nl := strings.index(line, "\r\n"); nl >= 0 {
		line = line[:nl]
	}
	parts := strings.split(line, " ", context.temp_allocator)
	if len(parts) < 3 || parts[0] != "GET" {
		return
	}
	return strings.clone(parts[1], context.temp_allocator), true
}

@(private = "file")
oauth_respond :: proc(client: net.TCP_Socket, status: string, body: string) {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status, len(body), body)
	_, _ = net.send_tcp(client, transmute([]byte)head)
}

// Extracts code/state/error from "/callback?a=b&c=d" (temp-allocated).
@(private = "file")
oauth_parse_query :: proc(path: string) -> (code, state, errparam: string) {
	qi := strings.index_byte(path, '?')
	if qi < 0 {
		return
	}
	query := path[qi + 1:]
	for pair in strings.split(query, "&", context.temp_allocator) {
		eq := strings.index_byte(pair, '=')
		if eq <= 0 {
			continue
		}
		key := pair[:eq]
		val := oauth_url_decode(pair[eq + 1:])
		switch key {
		case "code":
			code = val
		case "state":
			state = val
		case "error":
			errparam = val
		}
	}
	return
}

@(private = "file")
oauth_url_decode :: proc(s: string) -> string {
	hexval :: proc(c: byte) -> int {
		switch c {
		case '0' ..= '9':
			return int(c - '0')
		case 'a' ..= 'f':
			return int(c - 'a') + 10
		case 'A' ..= 'F':
			return int(c - 'A') + 10
		}
		return -1
	}
	out := make([dynamic]byte, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '+':
			append(&out, ' ')
		case c == '%' && i + 2 < len(s) && hexval(s[i + 1]) >= 0 && hexval(s[i + 2]) >= 0:
			append(&out, byte(hexval(s[i + 1]) << 4 | hexval(s[i + 2])))
			i += 2
		case:
			append(&out, c)
		}
	}
	return string(out[:])
}
