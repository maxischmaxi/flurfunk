package main

// OAuth/OIDC login. The server drives the whole flow: the client asks for
// an auth URL (oauth_start), sends the user's browser there, catches the
// loopback redirect (RFC 8252) and hands the code back (oauth_finish).
// Code exchange and userinfo happen HERE — the client_secret never leaves
// the server and clients need no TLS stack. First login with an unknown
// (provider, sub) pair auto-creates an account.
//
// Both handlers run WITHOUT g.mu held — their outbound HTTP requests must
// not stall the whole server. They take g.mu only for short config/user
// work. Pending states and the discovery cache live behind g_oauth.mu
// (lock order: g.mu may be held when taking g_oauth.mu, never the reverse).

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"

import shared "../shared"

OAUTH_STATE_TTL_MS :: 10 * 60 * 1000
OAUTH_MAX_PENDING :: 64

// One outstanding browser login (created by oauth_start, consumed by finish).
OAuth_Pending :: struct {
	state:        string,
	provider:     string,
	verifier:     string, // PKCE code_verifier (base64url)
	redirect_uri: string,
	created_ms:   i64,
}

// Discovered OIDC endpoints, cached per provider id until the config changes.
OAuth_Endpoints :: struct {
	issuer:    string,
	authorize: string,
	token:     string,
	userinfo:  string,
}

g_oauth: struct {
	mu:        sync.Mutex,
	pending:   [dynamic]OAuth_Pending,
	endpoints: map[string]OAuth_Endpoints,
}

// ---------- Config access ----------

// Effective, temp-copied view of one enabled provider — usable without locks.
@(private = "file")
OAuth_Snap :: struct {
	preset:        ^shared.OAuth_Preset,
	client_id:     string,
	client_secret: string,
	issuer:        string,
}

@(private = "file")
oauth_snapshot :: proc(id: string) -> (snap: OAuth_Snap, ok: bool) {
	preset := shared.oauth_preset(id)
	if preset == nil {
		return
	}
	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)
	cfg := find_oauth_cfg(id)
	if cfg == nil || !cfg.enabled || cfg.client_id == "" {
		return
	}
	issuer := cfg.issuer != "" ? cfg.issuer : preset.issuer
	if preset.kind == .OIDC && issuer == "" {
		return
	}
	snap = {
		preset        = preset,
		client_id     = strings.clone(cfg.client_id, context.temp_allocator),
		client_secret = strings.clone(cfg.client_secret, context.temp_allocator),
		issuer        = strings.clone(issuer, context.temp_allocator),
	}
	return snap, true
}

// Enabled providers for server_info (temp; call under g.mu).
oauth_public_list :: proc() -> []shared.OAuth_Provider_Info {
	out := make([dynamic]shared.OAuth_Provider_Info, context.temp_allocator)
	for &p in shared.OAUTH_PRESETS {
		cfg := find_oauth_cfg(p.id)
		if cfg == nil || !cfg.enabled || cfg.client_id == "" {
			continue
		}
		if p.kind == .OIDC && cfg.issuer == "" && p.issuer == "" {
			continue
		}
		label := cfg.label != "" ? cfg.label : p.label
		append(&out, shared.OAuth_Provider_Info{id = p.id, label = label})
	}
	return out[:]
}

// All presets with their stored config for the admin panel (temp; under g.mu).
oauth_admin_list :: proc() -> []shared.OAuth_Provider_Config {
	out := make([]shared.OAuth_Provider_Config, len(shared.OAUTH_PRESETS), context.temp_allocator)
	for &p, i in shared.OAUTH_PRESETS {
		out[i] = {id = p.id}
		if cfg := find_oauth_cfg(p.id); cfg != nil {
			out[i].enabled = cfg.enabled
			out[i].client_id = cfg.client_id
			out[i].client_secret = cfg.client_secret
			out[i].issuer = cfg.issuer
			out[i].label = cfg.label
		}
	}
	return out
}

// Drops the cached discovery result after a config change.
oauth_cache_clear :: proc(id: string) {
	sync.lock(&g_oauth.mu)
	defer sync.unlock(&g_oauth.mu)
	if e, has := g_oauth.endpoints[id]; has {
		oauth_endpoints_free(e)
		delete_key(&g_oauth.endpoints, id)
	}
}

@(private = "file")
oauth_endpoints_free :: proc(e: OAuth_Endpoints) {
	delete(e.issuer)
	delete(e.authorize)
	delete(e.token)
	delete(e.userinfo)
}

@(private = "file")
oauth_url_ok :: proc(u: string) -> bool {
	return strings.has_prefix(u, "https://") || strings.has_prefix(u, "http://")
}

// Endpoints of a provider; OIDC issuers get resolved via the discovery
// document (network!) and cached. Returned strings are temp-allocated.
@(private = "file")
oauth_endpoints :: proc(snap: OAuth_Snap) -> (eps: OAuth_Endpoints, ok: bool) {
	switch snap.preset.kind {
	case .GitHub:
		return {
			authorize = "https://github.com/login/oauth/authorize",
			token     = "https://github.com/login/oauth/access_token",
			userinfo  = "https://api.github.com/user",
		}, true
	case .Discord:
		return {
			authorize = "https://discord.com/oauth2/authorize",
			token     = "https://discord.com/api/oauth2/token",
			userinfo  = "https://discord.com/api/users/@me",
		}, true
	case .OIDC:
		// handled below (keeps the switch exhaustive)
	}

	id := snap.preset.id
	sync.lock(&g_oauth.mu)
	if e, has := g_oauth.endpoints[id]; has && e.issuer == snap.issuer {
		eps = {
			authorize = strings.clone(e.authorize, context.temp_allocator),
			token     = strings.clone(e.token, context.temp_allocator),
			userinfo  = strings.clone(e.userinfo, context.temp_allocator),
		}
		sync.unlock(&g_oauth.mu)
		return eps, true
	}
	sync.unlock(&g_oauth.mu)

	url := fmt.tprintf("%s/.well-known/openid-configuration", strings.trim_suffix(snap.issuer, "/"))
	status, body, hok := http_request(url, "", {"Accept: application/json"}, context.temp_allocator)
	if !hok || status != 200 {
		fmt.printfln("[oauth] %s: Discovery fehlgeschlagen (%s, HTTP %d)", id, url, status)
		return
	}
	doc: struct {
		authorization_endpoint: string `json:"authorization_endpoint"`,
		token_endpoint:         string `json:"token_endpoint"`,
		userinfo_endpoint:      string `json:"userinfo_endpoint"`,
	}
	if json.unmarshal(body, &doc, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil ||
	   !oauth_url_ok(doc.authorization_endpoint) || !oauth_url_ok(doc.token_endpoint) ||
	   !oauth_url_ok(doc.userinfo_endpoint) {
		fmt.printfln("[oauth] %s: Discovery-Dokument unbrauchbar", id)
		return
	}

	sync.lock(&g_oauth.mu)
	if old, has := g_oauth.endpoints[id]; has {
		oauth_endpoints_free(old)
	}
	g_oauth.endpoints[id] = {
		issuer    = strings.clone(snap.issuer),
		authorize = strings.clone(doc.authorization_endpoint),
		token     = strings.clone(doc.token_endpoint),
		userinfo  = strings.clone(doc.userinfo_endpoint),
	}
	sync.unlock(&g_oauth.mu)

	eps = {
		authorize = doc.authorization_endpoint,
		token     = doc.token_endpoint,
		userinfo  = doc.userinfo_endpoint,
	}
	return eps, true
}

// ---------- PKCE / state helpers (temp-allocated) ----------

@(private = "file")
oauth_b64url :: proc(data: []byte) -> string {
	enc := base64.encode(data, base64.ENC_TABLE, context.temp_allocator)
	out := make([dynamic]byte, 0, len(enc), context.temp_allocator)
	for ch in transmute([]byte)enc {
		switch ch {
		case '+':
			append(&out, '-')
		case '/':
			append(&out, '_')
		case '=':
		case:
			append(&out, ch)
		}
	}
	return string(out[:])
}

@(private = "file")
oauth_s256 :: proc(verifier: string) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)verifier)
	digest: [32]byte
	sha2.final(&ctx, digest[:])
	return oauth_b64url(digest[:])
}

// ---------- Pending states ----------

@(private = "file")
oauth_pending_free :: proc(p: OAuth_Pending) {
	delete(p.state)
	delete(p.provider)
	delete(p.verifier)
	delete(p.redirect_uri)
}

@(private = "file")
oauth_pending_purge_locked :: proc(now: i64) {
	for i := len(g_oauth.pending) - 1; i >= 0; i -= 1 {
		if now - g_oauth.pending[i].created_ms > OAUTH_STATE_TTL_MS {
			oauth_pending_free(g_oauth.pending[i])
			ordered_remove(&g_oauth.pending, i)
		}
	}
}

@(private = "file")
oauth_pending_add :: proc(state, provider, verifier, redirect: string) {
	now := now_ms()
	sync.lock(&g_oauth.mu)
	defer sync.unlock(&g_oauth.mu)
	oauth_pending_purge_locked(now)
	if len(g_oauth.pending) >= OAUTH_MAX_PENDING {
		oauth_pending_free(g_oauth.pending[0])
		ordered_remove(&g_oauth.pending, 0)
	}
	append(&g_oauth.pending, OAuth_Pending{
		state        = strings.clone(state),
		provider     = strings.clone(provider),
		verifier     = strings.clone(verifier),
		redirect_uri = strings.clone(redirect),
		created_ms   = now,
	})
}

// Removes and returns the entry — ownership moves to the caller.
@(private = "file")
oauth_pending_take :: proc(state: string) -> (p: OAuth_Pending, ok: bool) {
	if state == "" {
		return
	}
	sync.lock(&g_oauth.mu)
	defer sync.unlock(&g_oauth.mu)
	oauth_pending_purge_locked(now_ms())
	for e, i in g_oauth.pending {
		if e.state == state {
			p = e
			ordered_remove(&g_oauth.pending, i)
			return p, true
		}
	}
	return
}

// ---------- Handlers (run without g.mu, see handle_wire) ----------

// Pre-auth request accounting for the oauth kinds (normally done at the top
// of handle_wire under g.mu).
oauth_budget_ok :: proc(c: ^Client_Conn) -> bool {
	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)
	if !c.authed {
		c.preauth_seen += 1
		if c.preauth_seen > PREAUTH_BUDGET {
			c.drop = true
			return false
		}
	}
	return true
}

handle_oauth_start :: proc(c: ^Client_Conn, w: shared.Wire) {
	if w.redirect_port < 1 || w.redirect_port > 65535 {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	snap, ok := oauth_snapshot(strings.trim_space(w.provider))
	if !ok {
		send_err(c, w.kind, w.seq, "unknown_provider")
		return
	}
	eps, eok := oauth_endpoints(snap)
	if !eok {
		send_err(c, w.kind, w.seq, "oauth_failed")
		return
	}

	raw: [32]byte
	crypto.rand_bytes(raw[:])
	verifier := oauth_b64url(raw[:])
	sraw: [24]byte
	crypto.rand_bytes(sraw[:])
	state := string(hex.encode(sraw[:], context.temp_allocator))
	redirect := fmt.tprintf("http://127.0.0.1:%d/callback", w.redirect_port)
	oauth_pending_add(state, snap.preset.id, verifier, redirect)

	sep := strings.contains(eps.authorize, "?") ? "&" : "?"
	auth_url := fmt.tprintf(
		"%s%sresponse_type=code&client_id=%s&redirect_uri=%s&scope=%s&state=%s&code_challenge=%s&code_challenge_method=S256",
		eps.authorize, sep, url_encode(snap.client_id), url_encode(redirect),
		url_encode(snap.preset.scopes), state, oauth_s256(verifier))

	resp := shared.wire_ok(w.kind, w.seq)
	resp.provider = snap.preset.id
	resp.auth_url = auth_url
	resp.state = state
	send_to(c, resp)
	fmt.printfln("[oauth] %s: Login gestartet (Redirect-Port %d)", snap.preset.id, w.redirect_port)
}

handle_oauth_finish :: proc(c: ^Client_Conn, w: shared.Wire) {
	pend, ok := oauth_pending_take(w.state)
	if !ok {
		// Unknown/expired state — counts towards the fail2ban lockout.
		if security_fail(c.ip) {
			c.drop = true
		}
		send_err(c, w.kind, w.seq, "oauth_expired")
		return
	}
	defer oauth_pending_free(pend)

	code := strings.trim_space(w.code)
	if code == "" || len(code) > 2048 {
		send_err(c, w.kind, w.seq, "invalid_request")
		return
	}
	snap, sok := oauth_snapshot(pend.provider)
	if !sok {
		send_err(c, w.kind, w.seq, "unknown_provider") // disabled mid-flight
		return
	}
	eps, eok := oauth_endpoints(snap)
	if !eok {
		send_err(c, w.kind, w.seq, "oauth_failed")
		return
	}
	ident, iok := oauth_identity(snap, eps, code, pend)
	if !iok {
		send_err(c, w.kind, w.seq, "oauth_failed")
		return
	}

	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)
	u := find_user_by_oauth(pend.provider, ident.sub)
	if u == nil {
		u = oauth_create_user(pend.provider, ident)
		if u == nil {
			send_err(c, w.kind, w.seq, "invalid_request")
			return
		}
	}
	if u.disabled {
		send_err(c, w.kind, w.seq, "user_disabled")
		return
	}

	token := new_token()
	append(&g.sessions, Session{token = token, user_id = u.id, created_ms = now_ms()})
	save_sessions()
	fmt.printfln("[auth] OAuth-Login %q via %s (id=%d)", u.username, pend.provider, u.id)
	auth_success(c, w.kind, w.seq, u, token)
}

// ---------- Provider identity (token exchange + userinfo) ----------

@(private = "file")
OAuth_Identity :: struct {
	sub:      string, // stable unique id at the provider
	username: string, // preferred handle (may be empty)
	display:  string,
	email:    string,
}

@(private = "file")
oauth_identity :: proc(snap: OAuth_Snap, eps: OAuth_Endpoints, code: string, pend: OAuth_Pending) -> (ident: OAuth_Identity, ok: bool) {
	form := fmt.tprintf("grant_type=authorization_code&code=%s&redirect_uri=%s&client_id=%s&code_verifier=%s",
		url_encode(code), url_encode(pend.redirect_uri), url_encode(snap.client_id), pend.verifier)
	if snap.client_secret != "" {
		form = fmt.tprintf("%s&client_secret=%s", form, url_encode(snap.client_secret))
	}
	status, body, hok := http_request(eps.token, form, {"Accept: application/json"}, context.temp_allocator)
	if !hok || status != 200 {
		fmt.printfln("[oauth] %s: Token-Exchange fehlgeschlagen (HTTP %d)", snap.preset.id, status)
		return
	}
	tok: struct {
		access_token: string `json:"access_token"`,
	}
	if json.unmarshal(body, &tok, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil || tok.access_token == "" {
		fmt.printfln("[oauth] %s: Token-Antwort unbrauchbar", snap.preset.id)
		return
	}
	auth_hdr := fmt.tprintf("Authorization: Bearer %s", tok.access_token)

	switch snap.preset.kind {
	case .OIDC:
		ustatus, ubody, uok := http_request(eps.userinfo, "", {auth_hdr, "Accept: application/json"}, context.temp_allocator)
		if !uok || ustatus != 200 {
			fmt.printfln("[oauth] %s: Userinfo fehlgeschlagen (HTTP %d)", snap.preset.id, ustatus)
			return
		}
		info: struct {
			sub:                string `json:"sub"`,
			preferred_username: string `json:"preferred_username"`,
			name:               string `json:"name"`,
			email:              string `json:"email"`,
		}
		if json.unmarshal(ubody, &info, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil {
			return
		}
		ident = {sub = info.sub, username = info.preferred_username, display = info.name, email = info.email}

	case .GitHub:
		ustatus, ubody, uok := http_request(eps.userinfo, "", {auth_hdr, "Accept: application/vnd.github+json"}, context.temp_allocator)
		if !uok || ustatus != 200 {
			fmt.printfln("[oauth] github: Userinfo fehlgeschlagen (HTTP %d)", ustatus)
			return
		}
		gh: struct {
			id:    i64    `json:"id"`,
			login: string `json:"login"`,
			name:  string `json:"name"`,
			email: string `json:"email"`,
		}
		if json.unmarshal(ubody, &gh, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil || gh.id == 0 {
			return
		}
		ident = {sub = fmt.tprintf("%d", gh.id), username = gh.login, display = gh.name, email = gh.email}
		if ident.email == "" {
			// The public profile often hides the email — ask the emails API.
			estatus, ebody, eok := http_request("https://api.github.com/user/emails", "",
				{auth_hdr, "Accept: application/vnd.github+json"}, context.temp_allocator)
			if eok && estatus == 200 {
				emails: []struct {
					email:    string `json:"email"`,
					primary:  bool   `json:"primary"`,
					verified: bool   `json:"verified"`,
				}
				if json.unmarshal(ebody, &emails, json.DEFAULT_SPECIFICATION, context.temp_allocator) == nil {
					for e in emails {
						if e.verified && (ident.email == "" || e.primary) {
							ident.email = e.email
						}
					}
				}
			}
		}

	case .Discord:
		ustatus, ubody, uok := http_request(eps.userinfo, "", {auth_hdr, "Accept: application/json"}, context.temp_allocator)
		if !uok || ustatus != 200 {
			fmt.printfln("[oauth] discord: Userinfo fehlgeschlagen (HTTP %d)", ustatus)
			return
		}
		dc: struct {
			id:          string `json:"id"`,
			username:    string `json:"username"`,
			global_name: string `json:"global_name"`,
			email:       string `json:"email"`,
		}
		if json.unmarshal(ubody, &dc, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil {
			return
		}
		ident = {sub = dc.id, username = dc.username, display = dc.global_name, email = dc.email}
	}

	if ident.sub == "" {
		return
	}
	if ident.display == "" {
		ident.display = ident.username
	}
	return ident, true
}

// ---------- Account creation (under g.mu) ----------

// Turns the provider identity into a valid, free username (temp-allocated).
@(private = "file")
oauth_pick_username :: proc(ident: OAuth_Identity) -> string {
	base := ident.username
	if base == "" && ident.email != "" {
		if at := strings.index_byte(ident.email, '@'); at > 0 {
			base = ident.email[:at]
		} else {
			base = ident.email
		}
	}
	if base == "" {
		base = ident.display
	}

	sb := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(base, context.temp_allocator) {
		switch r {
		case 'a' ..= 'z', '0' ..= '9', '_', '-', '.':
			strings.write_rune(&sb, r)
		case ' ', '\t':
			strings.write_rune(&sb, '.')
		// everything else (umlauts, emoji, …) is dropped — usernames are ASCII
		}
		if strings.builder_len(sb) >= shared.MAX_USERNAME_LEN - 3 {
			break // leave room for the dedupe suffix
		}
	}
	name := strings.trim(strings.to_string(sb), "._-")
	if len(name) < 2 {
		name = "user"
	}
	if find_user_by_name(name) == nil {
		return name
	}
	for n in 2 ..< 1000 {
		cand := fmt.tprintf("%s%d", name, n)
		if find_user_by_name(cand) == nil {
			return cand
		}
	}
	return fmt.tprintf("user%d", g.meta.next_user_id)
}

@(private = "file")
oauth_create_user :: proc(provider: string, ident: OAuth_Identity) -> ^User {
	username := oauth_pick_username(ident)
	if !shared.valid_username(username) {
		return nil
	}
	u := User{
		id             = g.meta.next_user_id,
		username       = strings.clone(username),
		display_name   = strings.clone(strings.trim_space(ident.display)),
		is_admin       = len(g.users) == 0, // first user ever becomes admin
		oauth_provider = strings.clone(provider),
		oauth_sub      = strings.clone(ident.sub),
	}
	// No password: salt/pass_hash stay zero — handle_login rejects those.
	g.meta.next_user_id += 1
	append(&g.users, u)
	save_users()
	save_meta()
	fmt.printfln("[auth] neuer User %q via %s (id=%d, admin=%v)", u.username, provider, u.id, u.is_admin)
	return find_user_by_id(u.id)
}
