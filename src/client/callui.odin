package main

// Call-UI: Header-Button, Channel-Banner, Call-Panel (Sidebar) und das
// ausgliederbare Popout-Panel. Das Panel lebt auf App-Ebene — ein Call
// läuft weiter, egal welcher Channel oder Server gerade angezeigt wird.

import "core:fmt"
import "core:math"

import rl "vendor:raylib"
import shared "../shared"

CALL_PANEL_H :: f32(128)
CALL_POPOUT_W :: f32(320)
CALL_POPOUT_H :: f32(138)

// --- Header-Button (Kopfhörer) im Channel-/DM-Header ---

draw_call_header_button :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, r: rl.Rectangle) {
	here := call_is_here(app, c, cs.ch.id)
	peers := channel_call_peers(c, cs.ch.id)
	live := len(peers) > 0

	hovered := ui_hover(&app.ui, r, .Base)
	focused := tab_stop(app, anim_id(.Call, cs.ch.id ~ 0xCA11), r, .Base, radius = 8)
	t := anim_to(app, anim_id(.Call, cs.ch.id ~ 0xCA11), (hovered || focused) ? 1 : 0)
	rrect(r, 8, fade(COL_OVERLAY, t * 0.07))
	if focused {
		draw_focus_ring(r, 8)
	}
	col := COL_TEXT_DIM
	if here {
		col = COL_ONLINE
	} else if live {
		// laufender Call, dem ich nicht angehöre → Accent mit sanftem Puls
		pulse := f32(math.sin(rl.GetTime() * 4)) * 0.5 + 0.5
		col = mix(COL_ACCENT, COL_TEXT, 0.25 * pulse)
	}
	draw_headphones(r.x + r.width/2, r.y + r.height/2 - 1, 8, 2.4, mix(col, COL_TEXT, t * 0.3))
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	tip := "Voice-Call starten"
	if here {
		tip = "Du bist in diesem Call"
	} else if live {
		tip = fmt.tprintf("Call läuft (%d) — beitreten", len(peers))
	}
	tooltip(app, anim_id(.Call, cs.ch.id ~ 0x71F), r, tip, .Base)
	if (ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate)) && !here {
		call_join(app, c, cs.ch.id)
	}
}

// --- Banner unter dem Header: „Call läuft — beitreten“ ---

// Rückgabe: belegte Höhe (animiert ein/aus).
draw_call_banner :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, chat: rl.Rectangle) -> f32 {
	peers := channel_call_peers(c, cs.ch.id)
	want := len(peers) > 0 && !call_is_here(app, c, cs.ch.id)
	h := anim_to(app, anim_id(.Call, cs.ch.id ~ 0xBA22), want ? 46 : 0, 14, initial = 0)
	if h < 1 {
		return 0
	}
	r := rl.Rectangle{chat.x, chat.y + HEADER_H + 1, chat.width, h}
	scissor_begin(r.x, r.y, r.width, r.height)
	defer scissor_end()
	rl.DrawRectangleRec(r, fade(COL_ACCENT, 0.10))
	rl.DrawLineEx({r.x, r.y + h}, {r.x + r.width, r.y + h}, 1, COL_BORDER_SOFT)

	cy := r.y + h - 23 // Inhalt „fährt“ mit der Unterkante ein
	pulse := f32(math.sin(rl.GetTime() * 4)) * 0.5 + 0.5
	draw_headphones(r.x + 30, cy - 1, 8, 2.4, mix(COL_ACCENT, COL_TEXT, 0.3 * pulse))

	label := len(peers) == 1 ? "Voice-Call · 1 Teilnehmer" : fmt.tprintf("Voice-Call · %d Teilnehmer", len(peers))
	draw_text(app.fonts.bold15, tcstr(label), {r.x + 48, cy - 8}, 15, 0, COL_TEXT)
	lw := rl.MeasureTextEx(app.fonts.bold15, tcstr(label), 15, 0).x

	// Teilnehmer-Avatare, gestapelt
	ax := r.x + 48 + lw + 14
	shown := min(len(peers), 5)
	for i in 0 ..< shown {
		if u := conn_find_user(c, peers[i].user_id); u != nil {
			rl.DrawCircleV({ax + 11, cy}, 13, fade(COL_ACCENT, 0.10))
			draw_avatar(app, u.username, ax, cy - 11, 22)
			ax += 16
		}
	}

	// Beitreten-Button rechts
	bw := f32(104)
	br := rl.Rectangle{r.x + r.width - bw - 16, cy - 15, bw, 30}
	if button(app, br, app.call.joining ? "Verbinde…" : "Beitreten", .Base, style = .Primary) {
		call_join(app, c, cs.ch.id)
	}
	return h
}

// --- Signal-Anzeige (RTT-Balken) ---

@(private = "file")
draw_signal :: proc(app: ^App, x, cy: f32) -> f32 {
	rtt := app.call.link.rtt_ms
	healthy := voice_healthy(&app.call.link)
	bars := 3
	col := COL_ONLINE
	switch {
	case !healthy:
		bars = 0
		col = COL_RED
	case rtt >= 180:
		bars = 1
		col = COL_RED
	case rtt >= 80:
		bars = 2
		col = COL_YELLOW
	}
	for i in 0 ..< 3 {
		bh := f32(4 + i * 3)
		bcol := i < bars ? col : fade(COL_OVERLAY, 0.18)
		rrect({x + f32(i) * 5, cy + 5 - bh, 3, bh}, 1.5, bcol)
	}
	label := healthy ? fmt.tprintf("%d ms", int(rtt)) : "getrennt…"
	draw_text(app.fonts.regular13, tcstr(label), {x + 20, cy - 6}, 13, 0,
		healthy ? COL_TEXT_FAINT : COL_RED)
	return 20 + rl.MeasureTextEx(app.fonts.regular13, tcstr(label), 13, 0).x
}

// --- Gemeinsamer Panel-Körper: Teilnehmer-Reihe + Steuer-Buttons ---

@(private = "file")
call_icon_button :: proc(app: ^App, r: rl.Rectangle, id: u64, bg, bg_hot: rl.Color, tip: string) -> (clicked: bool, t: f32) {
	hovered := ui_hover(&app.ui, r, .Base)
	focused := tab_stop(app, id, r, .Base, radius = 8)
	t = anim_to(app, id, (hovered || focused) ? 1 : 0)
	rrect(r, 8, mix(bg, bg_hot, t))
	if focused {
		draw_focus_ring(r, 8)
	}
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}
	tooltip(app, id ~ 0x717, r, tip, .Base)
	clicked = ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate)
	return
}

@(private = "file")
draw_call_body :: proc(app: ^App, x, y, w: f32, popout: bool) {
	cc := app.call.conn
	peers := channel_call_peers(cc, app.call.channel_id)

	// Teilnehmer-Reihe mit Speaking-Glow
	av := f32(30)
	ax := x + 14
	shown := 0
	max_shown := int((w - 70) / (av + 10))
	for p in peers {
		if shown >= max_shown {
			draw_text(app.fonts.bold13, tcstr(fmt.tprintf("+%d", len(peers) - shown)), {ax + 4, y + 9}, 13, 0, COL_TEXT_DIM)
			break
		}
		u := conn_find_user(cc, p.user_id)
		seed := u != nil ? u.username : fmt.tprintf("%d", p.user_id)

		level := call_peer_level(app, p)
		glow := anim_to(app, anim_id(.Call, u64(p.ssrc) ~ 0x910), level > 0.18 ? 1 : 0, 14, initial = 0)
		if glow > 0.02 {
			rl.DrawRing({ax + av/2, y + av/2}, av/2 + 1.5, av/2 + 3.5, 0, 360, 32, fade(COL_ONLINE, glow))
		}
		draw_avatar(app, seed, ax, y, av)
		if p.muted {
			rl.DrawCircleV({ax + av - 4, y + av - 4}, 7, COL_SURFACE)
			draw_mic(ax + av - 4, y + av - 4, 7, 1.4, COL_RED, COL_SURFACE, true)
		}
		tooltip(app, anim_id(.Call, u64(p.ssrc) ~ 0xA7A), {ax, y, av, av}, user_label(cc, p.user_id), .Base)
		ax += av + 10
		shown += 1
	}

	// Steuer-Buttons
	by := y + av + 12
	bx := x + 14

	// Mute (rot, wenn gemutet)
	mr := rl.Rectangle{bx, by, 40, 30}
	m_bg := app.call.muted ? COL_RED : fade(COL_OVERLAY, 0.07)
	m_hot := app.call.muted ? mix(COL_RED, COL_WHITE, 0.15) : fade(COL_OVERLAY, 0.14)
	mclick, _ := call_icon_button(app, mr, anim_id(.Call, 0x3007E), m_bg, m_hot,
		app.call.muted ? "Mikrofon einschalten" : "Stummschalten")
	draw_mic(mr.x + mr.width/2, mr.y + mr.height/2, 11, 1.8,
		app.call.muted ? COL_WHITE : COL_TEXT, app.call.muted ? COL_RED : COL_RAIL_BG, app.call.muted)
	if mclick {
		call_set_mute(app, !app.call.muted)
	}
	bx += 48

	// Eigener Pegel als Mini-Meter neben dem Mute-Button
	if !app.call.muted {
		lvl := clamp(app.call.engine.mic_level * 7, 0, 1)
		sm := anim_to(app, anim_id(.Call, 0x3E7E5), lvl, 18)
		rrect({bx, by + 8, 4, 14}, 2, fade(COL_OVERLAY, 0.15))
		mh := 14 * sm
		rrect({bx, by + 8 + 14 - mh, 4, mh}, 2, COL_ONLINE)
		bx += 12
	}

	// Popout / Einklappen
	pr := rl.Rectangle{bx, by, 40, 30}
	pclick, _ := call_icon_button(app, pr, anim_id(.Call, 0x707), fade(COL_OVERLAY, 0.07), fade(COL_OVERLAY, 0.14),
		popout ? "Zurück in die Seitenleiste" : "Als schwebendes Fenster ausgliedern")
	draw_popout_icon(pr.x + pr.width/2, pr.y + pr.height/2, 12, 1.8, COL_TEXT)
	if pclick {
		app.call.popout = !popout
		if app.call.popout {
			app.call.popout_pos = {-1, -1} // beim ersten Zeichnen platzieren
		}
	}

	// Auflegen (rechtsbündig, rot)
	hr := rl.Rectangle{x + w - 14 - 52, by, 52, 30}
	hclick, _ := call_icon_button(app, hr, anim_id(.Call, 0xDEAD), fade(COL_RED, 0.88), COL_RED, "Call verlassen")
	draw_hangup(hr.x + hr.width/2, hr.y + hr.height/2 + 4, 10, 3, COL_WHITE)
	if hclick {
		call_hangup(app)
	}
}

@(private = "file")
call_channel_title :: proc(app: ^App) -> string {
	cc := app.call.conn
	if cs := conn_find_channel(cc, app.call.channel_id); cs != nil {
		return channel_title(cc, cs)
	}
	return "Voice-Call"
}

// --- Panel unten in der Sidebar (Standard-Platz) ---

// Rückgabe: belegte Höhe (0, wenn kein Panel).
draw_call_panel :: proc(app: ^App, sh: f32, footer_h: f32) -> f32 {
	if !app.call.active || app.call.popout {
		return 0
	}
	h := CALL_PANEL_H
	y := sh - footer_h - h
	r := rl.Rectangle{RAIL_W, y, SIDEBAR_W, h}
	rl.DrawRectangleRec(r, COL_RAIL_BG)
	rl.DrawLineEx({r.x, r.y}, {r.x + r.width, r.y}, 1, COL_SIDEBAR_LINE)

	// Titelzeile: Kopfhörer + Channel + Dauer/Signal
	draw_headphones(r.x + 22, y + 17, 7, 2.2, COL_ONLINE)
	title := call_channel_title(app)
	if app.call.conn != app_active_conn(app) {
		title = fmt.tprintf("%s · %s", conn_label(app.call.conn), title)
	}
	draw_text(app.fonts.bold13, tcstr(trim_label(app, title, SIDEBAR_W - 110)), {r.x + 36, y + 10}, 13, 0, COL_TEXT)
	draw_text(app.fonts.regular13, tcstr(call_duration_label(app)), {r.x + SIDEBAR_W - 52, y + 10}, 13, 0, COL_TEXT_FAINT)
	draw_signal(app, r.x + 36, y + 32)

	draw_call_body(app, r.x, y + 44, SIDEBAR_W, popout = false)
	return h
}

// Label auf verfügbare Breite kürzen („…“).
@(private = "file")
trim_label :: proc(app: ^App, s: string, max_w: f32) -> string {
	if rl.MeasureTextEx(app.fonts.bold13, tcstr(s), 13, 0).x <= max_w {
		return s
	}
	cut := len(s)
	for cut > 1 {
		cut -= 1
		for cut > 1 && s[cut] & 0xC0 == 0x80 { // nicht mitten im UTF-8-Zeichen
			cut -= 1
		}
		t := fmt.tprintf("%s…", s[:cut])
		if rl.MeasureTextEx(app.fonts.bold13, tcstr(t), 13, 0).x <= max_w {
			return t
		}
	}
	return "…"
}

// --- Ausgegliedertes Popout-Panel (schwebend, draggable) ---

draw_call_popout :: proc(app: ^App, sw, sh: f32) {
	if !app.call.active || !app.call.popout {
		app.ui.overlay_on = false
		return
	}
	w := CALL_POPOUT_W
	h := CALL_POPOUT_H
	if app.call.popout_pos.x < 0 {
		app.call.popout_pos = {sw - w - 20, HEADER_H + 14}
	}

	// Drag über die Titelzone
	title_r := rl.Rectangle{app.call.popout_pos.x, app.call.popout_pos.y, w - 40, 30}
	app.ui.in_overlay = true
	if app.call.popout_drag {
		if app.ui.mouse_down {
			app.call.popout_pos = {app.ui.mouse.x - app.call.drag_off.x, app.ui.mouse.y - app.call.drag_off.y}
		} else {
			app.call.popout_drag = false
		}
	} else if app.ui.clicked && ui_hover(&app.ui, title_r, .Base) {
		app.call.popout_drag = true
		app.call.drag_off = {app.ui.mouse.x - app.call.popout_pos.x, app.ui.mouse.y - app.call.popout_pos.y}
	}
	app.call.popout_pos.x = clamp(app.call.popout_pos.x, 4, sw - w - 4)
	app.call.popout_pos.y = clamp(app.call.popout_pos.y, 4, sh - h - 4)

	p := rl.Rectangle{app.call.popout_pos.x, app.call.popout_pos.y, w, h}
	draw_shadow(p, RADIUS_CARD, 0.8)
	rrect(p, RADIUS_CARD, COL_SURFACE)
	rrect_lines(p, RADIUS_CARD, 1, COL_BORDER)

	// Titelzeile: Griff-Punkte + Name + Dauer
	if ui_hover(&app.ui, title_r, .Base) || app.call.popout_drag {
		app.ui.cursor = app.call.popout_drag ? .RESIZE_ALL : .POINTING_HAND
	}
	draw_headphones(p.x + 22, p.y + 16, 7, 2.2, COL_ONLINE)
	title := call_channel_title(app)
	if app.call.conn != app_active_conn(app) {
		title = fmt.tprintf("%s · %s", conn_label(app.call.conn), title)
	}
	draw_text(app.fonts.bold13, tcstr(trim_label(app, title, w - 150)), {p.x + 36, p.y + 9}, 13, 0, COL_TEXT)
	sig_w := draw_signal(app, p.x + 36, p.y + 32)
	draw_text(app.fonts.regular13, tcstr(call_duration_label(app)),
		{p.x + 36 + sig_w + 12, p.y + 26}, 13, 0, COL_TEXT_FAINT)

	draw_call_body(app, p.x, p.y + 46, w, popout = true)

	app.ui.in_overlay = false
	// Rect fürs Maus-Abfangen im nächsten Frame registrieren
	app.ui.overlay = p
	app.ui.overlay_on = true
}
