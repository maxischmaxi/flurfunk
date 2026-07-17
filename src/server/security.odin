package main

// IP bans and fail2ban-style brute-force lockout.
//
// g_bans owns its own lock so the TCP accept loop and the UDP hot path can
// check bans without touching g.mu. Lock order: g.mu may be held when taking
// g_bans.mu, never the other way around. Banned IPs are rejected before any
// crypto work happens (accept: before the Noise handshake, UDP: before
// parsing) — an attacker costs the server next to nothing.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"

import shared "../shared"

F2B_DEFAULT_MAX_FAILS  :: 5
F2B_DEFAULT_WINDOW_MIN :: 15
F2B_DEFAULT_BAN_MIN    :: 30

Ban :: struct {
	ip:         string,
	reason:     string,
	created_ms: i64,
	expires_ms: i64, // 0 = permanent
	by_user:    u64, // 0 = fail2ban
}

// Failed auth attempts of one IP within the current window.
Fail_Track :: struct {
	count:    int,
	first_ms: i64,
}

g_bans: struct {
	mu:    sync.Mutex,
	bans:  [dynamic]Ban,
	fails: map[string]Fail_Track,

	// Snapshot of the fail2ban config; updated via security_configure so
	// ban checks never need g.mu.
	enabled:   bool,
	max_fails: int,
	window_ms: i64,
	ban_ms:    i64,
}

// Formats an address without heap allocation (UDP hot path). All IP strings
// on the server go through this proc so ban entries always compare equal.
format_ip :: proc(buf: []byte, addr: net.Address) -> string {
	switch a in addr {
	case net.IP4_Address:
		return fmt.bprintf(buf, "%d.%d.%d.%d", a[0], a[1], a[2], a[3])
	case net.IP6_Address:
		return fmt.bprintf(buf, "%x:%x:%x:%x:%x:%x:%x:%x",
			u16(a[0]), u16(a[1]), u16(a[2]), u16(a[3]),
			u16(a[4]), u16(a[5]), u16(a[6]), u16(a[7]))
	}
	return ""
}

// Applies the fail2ban settings from g.meta (call at startup and on change).
security_configure :: proc(meta: Server_Meta) {
	sync.lock(&g_bans.mu)
	defer sync.unlock(&g_bans.mu)
	g_bans.enabled = !meta.f2b_disabled
	g_bans.max_fails = meta.f2b_max_fails > 0 ? meta.f2b_max_fails : F2B_DEFAULT_MAX_FAILS
	window := meta.f2b_window_min > 0 ? meta.f2b_window_min : F2B_DEFAULT_WINDOW_MIN
	ban := meta.f2b_ban_min > 0 ? meta.f2b_ban_min : F2B_DEFAULT_BAN_MIN
	g_bans.window_ms = i64(window) * 60_000
	g_bans.ban_ms = i64(ban) * 60_000
}

// Drops expired bans; call with g_bans.mu held.
@(private = "file")
purge_expired_locked :: proc(now: i64) {
	for i := len(g_bans.bans) - 1; i >= 0; i -= 1 {
		b := g_bans.bans[i]
		if b.expires_ms > 0 && b.expires_ms <= now {
			delete(b.ip)
			delete(b.reason)
			ordered_remove(&g_bans.bans, i)
		}
	}
}

@(private = "file")
ban_idx_locked :: proc(ip: string) -> int {
	for b, i in g_bans.bans {
		if b.ip == ip {
			return i
		}
	}
	return -1
}

ip_banned :: proc(ip: string) -> bool {
	sync.lock(&g_bans.mu)
	defer sync.unlock(&g_bans.mu)
	purge_expired_locked(now_ms())
	return ban_idx_locked(ip) >= 0
}

// Cheap gate for the UDP loop: stringify only while bans exist at all.
udp_banned :: proc(addr: net.Address) -> bool {
	sync.lock(&g_bans.mu)
	empty := len(g_bans.bans) == 0
	sync.unlock(&g_bans.mu)
	if empty {
		return false
	}
	buf: [64]byte
	return ip_banned(format_ip(buf[:], addr))
}

// Adds (or replaces) a ban. minutes == 0 → permanent. Strings are cloned.
ban_add :: proc(ip, reason: string, by_user: u64, minutes: int) {
	now := now_ms()
	b := Ban{
		ip         = strings.clone(ip),
		reason     = strings.clone(reason),
		created_ms = now,
		expires_ms = minutes > 0 ? now + i64(minutes) * 60_000 : 0,
		by_user    = by_user,
	}
	sync.lock(&g_bans.mu)
	if idx := ban_idx_locked(ip); idx >= 0 {
		delete(g_bans.bans[idx].ip)
		delete(g_bans.bans[idx].reason)
		g_bans.bans[idx] = b
	} else {
		append(&g_bans.bans, b)
	}
	delete_key(&g_bans.fails, ip)
	save_bans_locked()
	sync.unlock(&g_bans.mu)
}

ban_remove :: proc(ip: string) -> bool {
	sync.lock(&g_bans.mu)
	defer sync.unlock(&g_bans.mu)
	idx := ban_idx_locked(ip)
	if idx < 0 {
		return false
	}
	delete(g_bans.bans[idx].ip)
	delete(g_bans.bans[idx].reason)
	ordered_remove(&g_bans.bans, idx)
	delete_key(&g_bans.fails, ip)
	save_bans_locked()
	return true
}

// Records a failed auth attempt. Returns true if the IP just got banned —
// the caller should then drop the connection.
security_fail :: proc(ip: string) -> bool {
	if ip == "" {
		return false
	}
	now := now_ms()
	sync.lock(&g_bans.mu)
	defer sync.unlock(&g_bans.mu)
	if !g_bans.enabled {
		return false
	}
	tr := g_bans.fails[ip]
	if now - tr.first_ms > g_bans.window_ms {
		tr = Fail_Track{first_ms = now}
	}
	tr.count += 1
	if tr.count < g_bans.max_fails {
		if _, has := g_bans.fails[ip]; !has {
			key := strings.clone(ip)
			g_bans.fails[key] = tr
		} else {
			g_bans.fails[ip] = tr
		}
		return false
	}
	delete_key(&g_bans.fails, ip)
	b := Ban{
		ip         = strings.clone(ip),
		reason     = strings.clone("fail2ban"), // ban_remove/purge delete() it
		created_ms = now,
		expires_ms = now + g_bans.ban_ms,
	}
	if idx := ban_idx_locked(ip); idx >= 0 {
		delete(g_bans.bans[idx].ip)
		delete(g_bans.bans[idx].reason)
		g_bans.bans[idx] = b
	} else {
		append(&g_bans.bans, b)
	}
	save_bans_locked()
	fmt.printfln("[security] fail2ban: %s für %d min gesperrt (%d Fehlversuche)",
		ip, g_bans.ban_ms / 60_000, tr.count)
	return true
}

// Clears the fail counter after a successful auth.
security_success :: proc(ip: string) {
	sync.lock(&g_bans.mu)
	defer sync.unlock(&g_bans.mu)
	delete_key(&g_bans.fails, ip)
}

// Snapshot for the admin panel (temp-allocated).
bans_snapshot :: proc() -> []shared.Ban_Info {
	sync.lock(&g_bans.mu)
	defer sync.unlock(&g_bans.mu)
	purge_expired_locked(now_ms())
	out := make([]shared.Ban_Info, len(g_bans.bans), context.temp_allocator)
	for b, i in g_bans.bans {
		out[i] = {
			ip         = b.ip,
			reason     = b.reason,
			created_ms = b.created_ms,
			expires_ms = b.expires_ms,
			by_user    = b.by_user,
		}
	}
	return out
}
