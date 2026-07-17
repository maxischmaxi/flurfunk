package smoke

// Minimal fake OIDC provider for the OAuth smoke tests: discovery, token
// and userinfo endpoints on a loopback port, plain HTTP. The authorization
// code encodes the test identity as "<sub>|<username>|<email>" — the token
// endpoint wraps it into the access token, userinfo unpacks it. The
// authorize endpoint is never hit (no browser in the test).

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:thread"

FAKE_OIDC_PORT :: 43117

fake_oidc_issuer :: proc() -> string {
	return fmt.tprintf("http://127.0.0.1:%d", FAKE_OIDC_PORT)
}

fake_oidc_start :: proc() {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = FAKE_OIDC_PORT})
	if err != nil {
		fail("fake-oidc listen", err)
	}
	thread.create_and_start_with_poly_data(listener, fake_oidc_loop, nil, .Normal, true)
	step_ok("fake-oidc provider gestartet")
}

@(private = "file")
fake_oidc_loop :: proc(listener: net.TCP_Socket) {
	for {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			return
		}
		fake_oidc_handle(client)
		net.close(client)
	}
}

@(private = "file")
respond :: proc(client: net.TCP_Socket, status, ctype, body: string) {
	head := fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status, ctype, len(body), body)
	_, _ = net.send_tcp(client, transmute([]byte)head)
}

@(private = "file")
url_decode :: proc(s: string) -> string {
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

@(private = "file")
form_value :: proc(form, key: string) -> string {
	for pair in strings.split(form, "&", context.temp_allocator) {
		eq := strings.index_byte(pair, '=')
		if eq <= 0 {
			continue
		}
		if pair[:eq] == key {
			return url_decode(pair[eq + 1:])
		}
	}
	return ""
}

@(private = "file")
fake_oidc_handle :: proc(client: net.TCP_Socket) {
	buf: [16384]byte
	total := 0
	head_end := -1
	for total < len(buf) {
		n, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || n <= 0 {
			break
		}
		total += n
		if idx := strings.index(string(buf[:total]), "\r\n\r\n"); idx >= 0 {
			head_end = idx
			break
		}
	}
	if head_end < 0 {
		return
	}
	head := string(buf[:head_end])
	body_start := head_end + 4

	clen := 0
	lines := strings.split(head, "\r\n", context.temp_allocator)
	for line in lines {
		l := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(l, "content-length:") {
			clen, _ = strconv.parse_int(strings.trim_space(line[len("content-length:"):]), 10)
		}
	}
	for total < body_start + clen && total < len(buf) {
		n, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || n <= 0 {
			break
		}
		total += n
	}
	body := string(buf[body_start:min(body_start + clen, total)])

	req := strings.split(lines[0], " ", context.temp_allocator)
	if len(req) < 3 {
		return
	}
	method := req[0]
	path := req[1]

	switch {
	case method == "GET" && strings.has_prefix(path, "/.well-known/openid-configuration"):
		// Odin fmt treats { } in format strings as placeholders → {{ }}.
		iss := fake_oidc_issuer()
		respond(client, "200 OK", "application/json", fmt.tprintf(
			"{{\"issuer\":\"%s\",\"authorization_endpoint\":\"%s/authorize\"," +
			"\"token_endpoint\":\"%s/token\",\"userinfo_endpoint\":\"%s/userinfo\"}}",
			iss, iss, iss, iss))

	case method == "POST" && strings.has_prefix(path, "/token"):
		code := form_value(body, "code")
		if form_value(body, "grant_type") != "authorization_code" ||
		   form_value(body, "client_id") != "test-client" ||
		   form_value(body, "client_secret") != "test-secret" ||
		   form_value(body, "code_verifier") == "" ||
		   !strings.has_prefix(form_value(body, "redirect_uri"), "http://127.0.0.1:") ||
		   code == "" {
			respond(client, "400 Bad Request", "application/json", "{\"error\":\"invalid_request\"}")
			return
		}
		respond(client, "200 OK", "application/json",
			fmt.tprintf("{{\"access_token\":\"tok.%s\",\"token_type\":\"Bearer\"}}", code))

	case method == "GET" && strings.has_prefix(path, "/userinfo"):
		tok := ""
		for line in lines {
			if strings.has_prefix(strings.to_lower(line, context.temp_allocator), "authorization:") {
				tok = strings.trim_space(line[len("authorization:"):])
			}
		}
		if !strings.has_prefix(tok, "Bearer tok.") {
			respond(client, "401 Unauthorized", "application/json", "{\"error\":\"invalid_token\"}")
			return
		}
		parts := strings.split(tok[len("Bearer tok."):], "|", context.temp_allocator)
		if len(parts) != 3 {
			respond(client, "401 Unauthorized", "application/json", "{\"error\":\"invalid_token\"}")
			return
		}
		respond(client, "200 OK", "application/json", fmt.tprintf(
			"{{\"sub\":\"%s\",\"preferred_username\":\"%s\",\"email\":\"%s\",\"name\":\"Test User\"}}",
			parts[0], parts[1], parts[2]))

	case:
		respond(client, "404 Not Found", "text/plain", "not found")
	}
}
