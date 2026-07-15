package main

// Chat-Bereich: Header, Nachrichtenliste (mit Layout-Cache, Day-Separatoren,
// „Neu"-Divider, Smooth-Scroll, History-Paging) und Eingabefeld.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

import rl "vendor:raylib"
import shared "../shared"

MSG_GUTTER :: f32(76) // Platz links für Avatar / Hover-Zeit
MSG_PAD_RIGHT :: f32(28)

Row_Kind :: enum {
	Message,
	Day_Sep,
	New_Sep,
}

Msg_Row :: struct {
	kind:    Row_Kind,
	msg_idx: int,
	compact: bool,
	h:       f32,
	day_ms:  i64,
}

// --- Layout-Cache ---

@(private = "file")
rows_dirty :: proc(cs: ^Channel_State, text_w: f32) -> bool {
	return cs.rows_n != len(cs.messages) || cs.rows_w != text_w || cs.rows_divider != cs.divider_id
}

@(private = "file")
build_rows :: proc(app: ^App, cs: ^Channel_State, text_w: f32) {
	old_h := cs.content_h
	clear(&cs.rows)

	prev_day: i64 = -1
	divider_placed := false
	msgs := cs.messages[:]

	for m, i in msgs {
		dk := day_key(app, m.ts_ms)
		sep_added := false
		if dk != prev_day {
			append(&cs.rows, Msg_Row{kind = .Day_Sep, h = 40, day_ms = m.ts_ms})
			prev_day = dk
			sep_added = true
		}
		if !divider_placed && cs.divider_id > 0 && m.id > cs.divider_id {
			append(&cs.rows, Msg_Row{kind = .New_Sep, h = 28})
			divider_placed = true
			sep_added = true
		}

		compact := false
		if !sep_added && i > 0 {
			prev := msgs[i-1]
			compact = prev.author_id == m.author_id && m.ts_ms - prev.ts_ms < 3*60*1000
		}
		th := rich_text_height(&app.fonts, m.text, text_w)
		h := compact ? th + 6 : th + 34
		append(&cs.rows, Msg_Row{kind = .Message, msg_idx = i, compact = compact, h = h})
	}

	cs.rows_n = len(msgs)
	cs.rows_w = text_w
	cs.rows_divider = cs.divider_id
	total := f32(10)
	for r in cs.rows {
		total += r.h
	}
	cs.content_h = total + 12

	// History-Prepend: Scroll-Position stabil halten
	if cs.adjust_scroll {
		cs.adjust_scroll = false
		if !cs.stick_bottom {
			delta := cs.content_h - old_h
			cs.scroll.pos += delta
			cs.scroll.target += delta
		}
	}
}

// --- Chat-Hauptfläche ---

draw_chat :: proc(app: ^App, c: ^Server_Conn, chat: rl.Rectangle) {
	cs := conn_find_channel(c, c.active_channel)
	if cs == nil {
		draw_chat_empty_state(app, chat)
		return
	}

	// „Einfach lostippen" → Fokus aufs Eingabefeld.
	// Nicht während Tab-Navigation — die parkt den Fokus bewusst auf Buttons.
	if app.ui.focus == .None && app.modal == .None && !app.ui.tab_nav {
		app.ui.focus = .Message
	}

	draw_chat_header(app, c, cs, chat)

	// Eingabefeld unten (Höhe hängt vom Inhalt ab)
	input_h := draw_message_input(app, c, cs, chat)

	// Nachrichtenliste dazwischen
	list := rl.Rectangle{chat.x, chat.y + HEADER_H + 1, chat.width, chat.height - HEADER_H - 1 - input_h}
	draw_message_list(app, c, cs, list)
}

@(private = "file")
draw_chat_empty_state :: proc(app: ^App, chat: rl.Rectangle) {
	cx := chat.x + chat.width/2
	cy := chat.y + chat.height/2
	rl.DrawCircleV({cx, cy - 60}, 36, COL_PANEL_BG)
	draw_rune_centered(app.fonts.bold24, '#', cx, cy - 60, COL_TEXT_FAINT)
	draw_text_centered(app.fonts.bold18, "Kein Kanal ausgewählt", cx, cy - 4, 18, COL_TEXT)
	draw_text_centered(app.fonts.regular15, "Wähle links einen Kanal oder starte eine Direktnachricht.",
		cx, cy + 24, 15, COL_TEXT_DIM)
	draw_text_centered(app.fonts.regular13, "Tipp: Strg+K öffnet die Schnellsuche", cx, cy + 52, 13, COL_TEXT_FAINT)
}

@(private = "file")
draw_chat_header :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, chat: rl.Rectangle) {
	x := chat.x + 20
	if cs.ch.is_dm {
		// DM: Avatar + Name + Presence
		partner := dm_partner(c, cs)
		seed := partner != nil ? partner.username : "?"
		online := partner != nil && partner.online
		draw_avatar(app, seed, x, chat.y + (HEADER_H - 28)/2, 28, presence = true, online = online)
		title := channel_title(c, cs)
		draw_text(app.fonts.bold18, tcstr(title), {x + 38, chat.y + (HEADER_H - 18)/2}, 18, 0, COL_TEXT)
	} else {
		title := channel_title(c, cs)
		draw_text(app.fonts.bold18, tcstr(title), {x, chat.y + (HEADER_H - 18)/2}, 18, 0, COL_TEXT)

		// Mitglieder-Avatare (gestapelt) + Zähler → öffnet Mitglieder-Modal
		n := len(cs.ch.member_ids)
		shown := min(n, 3)
		aw := f32(26)
		overlap := f32(8)
		stack_w := f32(shown)*aw - f32(max(0, shown-1))*overlap
		count_label := fmt.tprintf("%d", n)
		clw := rl.MeasureTextEx(app.fonts.bold13, tcstr(count_label), 13, 0).x
		total_w := stack_w + clw + 18
		r := rl.Rectangle{chat.x + chat.width - total_w - 24, chat.y + (HEADER_H - 34)/2, total_w + 12, 34}

		hovered := ui_hover(&app.ui, r, .Base)
		focused := tab_stop(app, anim_id(.Misc, cs.ch.id ~ 0xABCD), r, .Base, radius = 7)
		t := anim_to(app, anim_id(.Misc, cs.ch.id ~ 0xABCD), (hovered || focused) ? 1 : 0)
		rrect(r, 7, fade(rl.Color{24, 24, 27, 255}, t*0.06))
		if focused {
			draw_focus_ring(r, 7)
		}
		if hovered {
			app.ui.cursor = .POINTING_HAND
		}
		ax := r.x + 6
		for i in 0 ..< shown {
			mid := cs.ch.member_ids[i]
			seed := fmt.tprintf("%d", mid)
			if u := conn_find_user(c, mid); u != nil {
				seed = u.username
			}
			// weißer Ring, damit sich die gestapelten Avatare abheben
			rl.DrawCircleV({ax + aw/2, r.y + 17}, aw/2 + 2, COL_CHAT_BG)
			draw_avatar(app, seed, ax, r.y + 17 - aw/2, aw)
			ax += aw - overlap
		}
		draw_text(app.fonts.bold13, tcstr(count_label), {ax + 8, r.y + (34-13)/2}, 13, 0, COL_TEXT_DIM)
		tooltip(app, anim_id(.Misc, cs.ch.id ~ 0xEF01), r, "Mitglieder anzeigen & einladen", .Base)
		if ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate) {
			open_modal(app, .Members)
		}
	}
	rl.DrawLineEx({chat.x, chat.y + HEADER_H}, {chat.x + chat.width, chat.y + HEADER_H}, 1, COL_BORDER_SOFT)
}

// --- Nachrichtenliste ---

@(private = "file")
draw_message_list :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, list: rl.Rectangle) {
	if !cs.history_loaded {
		draw_loading_dots(app, list.x + list.width/2, list.y + list.height/2)
		return
	}

	text_x := list.x + MSG_GUTTER
	text_w := list.width - MSG_GUTTER - MSG_PAD_RIGHT

	if rows_dirty(cs, text_w) {
		build_rows(app, cs, text_w)
	}

	if len(cs.messages) == 0 {
		title := channel_title(c, cs)
		cx := list.x + list.width/2
		cy := list.y + list.height/2
		draw_text_centered(app.fonts.bold24, fmt.tprintf("Das ist der Anfang von %s", title), cx, cy - 30, 24, COL_TEXT)
		sub := cs.ch.is_dm ? "Sag hallo — die Nachricht landet direkt bei ihnen." : "Lade Kolleg:innen ein und schreib die erste Nachricht."
		draw_text_centered(app.fonts.regular15, sub, cx, cy + 8, 15, COL_TEXT_DIM)
		return
	}

	max_scroll := max(0, cs.content_h - list.height)

	// Gelesen-Status pflegen, solange der Channel sichtbar & das Fenster fokussiert ist
	if rl.IsWindowFocused() && len(cs.messages) > 0 {
		cs.last_read_id = max(cs.last_read_id, cs.messages[len(cs.messages)-1].id)
		cs.unread = 0
	}

	// Scroll: Wheel + Smoothing; hochscrollen löst den Boden-Anker
	hovered := ui_hover(&app.ui, list, .Base)
	if hovered && app.ui.wheel > 0 {
		cs.stick_bottom = false
	}
	if cs.stick_bottom {
		if max_scroll - cs.scroll.target > 600 {
			scroll_to(&cs.scroll, max_scroll) // weiter Sprung (Channelwechsel) → sofort
		} else {
			cs.scroll.target = max_scroll
		}
	}
	// Seiten-Tasten
	if app.modal == .None {
		if rl.IsKeyPressed(.PAGE_UP) {
			cs.scroll.target -= list.height * 0.85
			cs.stick_bottom = false
			cs.scroll.activity = 1
		}
		if rl.IsKeyPressed(.PAGE_DOWN) {
			cs.scroll.target += list.height * 0.85
			cs.scroll.activity = 1
		}
	}
	scroll_update(app, &cs.scroll, hovered, max_scroll)
	if cs.scroll.target >= max_scroll - 2 && max_scroll > 0 {
		cs.stick_bottom = true
	}

	// Oben angekommen → ältere Nachrichten nachladen
	if cs.scroll.pos < 240 && !cs.history_done {
		app_request_older(c, cs)
	}

	scissor_begin(list.x, list.y, list.width, list.height)

	y := list.y + 10 - cs.scroll.pos

	// Lade-Hinweis oben beim Paging
	if cs.history_loading && !cs.history_done {
		draw_text_centered(app.fonts.regular13, "Lade ältere Nachrichten…", list.x + list.width/2, y - 4, 13, COL_TEXT_FAINT)
	} else if cs.history_done && cs.scroll.pos < 60 && max_scroll > 0 {
		draw_text_centered(app.fonts.regular13, "— Anfang des Verlaufs —", list.x + list.width/2, y - 4, 13, COL_TEXT_FAINT)
	}

	msgs := cs.messages[:]
	for row in cs.rows {
		if y > list.y + list.height {
			break
		}
		if y + row.h < list.y {
			y += row.h
			continue
		}

		switch row.kind {
		case .Day_Sep:
			label := format_day_label(app, row.day_ms)
			tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(label), 13, 0)
			cy := y + row.h/2 + 4
			pill_w := tw.x + 24
			px := list.x + (list.width - pill_w)/2
			rl.DrawLineEx({list.x + 16, cy}, {px - 8, cy}, 1, COL_BORDER_SOFT)
			rl.DrawLineEx({px + pill_w + 8, cy}, {list.x + list.width - 16, cy}, 1, COL_BORDER_SOFT)
			pill := rl.Rectangle{px, cy - 12, pill_w, 24}
			rrect(pill, 12, COL_CHAT_BG)
			rrect_lines(pill, 12, 1, COL_BORDER_SOFT)
			draw_text(app.fonts.bold13, tcstr(label), {px + 12, cy - 6}, 13, 0, COL_TEXT_DIM)

		case .New_Sep:
			cy := y + row.h/2
			label := "Neu"
			tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(label), 13, 0)
			rl.DrawLineEx({list.x + 16, cy}, {list.x + list.width - tw.x - 40, cy}, 1, fade(COL_BADGE, 0.7))
			draw_text(app.fonts.bold13, tcstr(label), {list.x + list.width - tw.x - 28, cy - 6}, 13, 0, COL_BADGE)

		case .Message:
			m := msgs[row.msg_idx]
			row_rect := rl.Rectangle{list.x, y, list.width, row.h}
			row_hover := ui_hover(&app.ui, row_rect, .Base)
			if row_hover {
				rl.DrawRectangleRec(row_rect, COL_HOVER_ROW)
			}

			author_id := m.author_id
			clickable_author := author_id != c.me.id

			if !row.compact {
				author := user_label(c, author_id)
				seed := author
				if u := conn_find_user(c, author_id); u != nil {
					seed = u.username
				}
				av := rl.Rectangle{list.x + 24, y + 8, 36, 36}
				draw_avatar(app, seed, av.x, av.y, 36)

				name_w := rl.MeasureTextEx(app.fonts.bold15, tcstr(author), 15, 0).x
				name_r := rl.Rectangle{text_x, y + 8, name_w, 18}
				draw_text(app.fonts.bold15, tcstr(author), {text_x, y + 8}, 15, 0, COL_TEXT)
				draw_text(app.fonts.regular13, tcstr(format_time_hm(app, m.ts_ms)),
					{text_x + name_w + 8, y + 10}, 13, 0, COL_TEXT_FAINT)

				// Klick auf Avatar/Name → DM öffnen
				if clickable_author {
					if ui_hover(&app.ui, av, .Base) || ui_hover(&app.ui, name_r, .Base) {
						app.ui.cursor = .POINTING_HAND
					}
					if ui_click(&app.ui, av, .Base) || ui_click(&app.ui, name_r, .Base) {
						open_dm_with(app, c, author_id)
					}
				}
				rich_text(&app.fonts, m.text, text_x, y + 28, text_w, true)
			} else {
				// Kompaktzeile: Zeit im Gutter nur bei Hover
				if row_hover {
					ts := format_time_hm(app, m.ts_ms)
					tw := rl.MeasureTextEx(app.fonts.regular13, tcstr(ts), 13, 0).x
					draw_text(app.fonts.regular13, tcstr(ts), {text_x - tw - 10, y + 6}, 13, 0, COL_TEXT_FAINT)
				}
				rich_text(&app.fonts, m.text, text_x, y + 3, text_w, true)
			}
		}
		y += row.h
	}
	scissor_end()

	scrollbar(app, list, cs.content_h, &cs.scroll, .Base)
	draw_jump_pill(app, cs, list, max_scroll)
}

// Ein DM öffnen bzw. aktivieren.
open_dm_with :: proc(app: ^App, c: ^Server_Conn, user_id: u64) {
	if dm := conn_find_dm(c, user_id); dm != nil {
		app_activate_channel(app, c, dm.ch.id)
		return
	}
	conn_request(c, {kind = shared.K_OPEN_DM, user_id = user_id}, {user_id = user_id})
}

// „↓ Zu neuen Nachrichten"-Pille, wenn nicht am Ende.
@(private = "file")
draw_jump_pill :: proc(app: ^App, cs: ^Channel_State, list: rl.Rectangle, max_scroll: f32) {
	show := !cs.stick_bottom && max_scroll > 0 && max_scroll - cs.scroll.pos > 150
	t := anim_to(app, anim_id(.Jump_Pill, cs.ch.id), show ? 1 : 0, 14, initial = 0)
	if t < 0.02 {
		return
	}
	label := "↓  Zu neuen Nachrichten"
	tw := rl.MeasureTextEx(app.fonts.bold13, tcstr(label), 13, 0)
	w := tw.x + 32
	h := f32(32)
	x := list.x + (list.width - w)/2
	y := list.y + list.height - h - 14 + (1 - t)*24

	r := rl.Rectangle{x, y, w, h}
	focused := tab_stop(app, anim_id(.Jump_Pill, cs.ch.id ~ 0x7AB), r, .Base, radius = 16)
	draw_shadow(r, 16, t*0.6)
	rrect(r, 16, fade(COL_PRIMARY, t))
	if focused {
		draw_focus_ring(r, 16)
	}
	draw_text(app.fonts.bold13, tcstr(label), {x + 16, y + (h-13)/2 - 1}, 13, 0, fade(COL_WHITE, t))
	if ui_hover(&app.ui, r, .Base) {
		app.ui.cursor = .POINTING_HAND
	}
	if ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate) {
		cs.stick_bottom = true
		cs.scroll.activity = 1
	}
}

// Drei hüpfende Lade-Punkte.
draw_loading_dots :: proc(app: ^App, cx, cy: f32) {
	t := f32(rl.GetTime())
	for i in 0 ..< 3 {
		phase := t*3.6 - f32(i)*0.55
		dy := math.sin(phase) * 5
		a := 0.35 + 0.65*clamp(math.sin(phase), 0, 1)
		rl.DrawCircleV({cx - 18 + f32(i)*18, cy + dy}, 4.5, fade(COL_TEXT_FAINT, a))
	}
}

// --- Eingabefeld ---

// Zeilen-Layout der Plaintext-Eingabe (Wortumbruch, Runen-Indizes).
Input_Line :: struct {
	start, end: int, // [start, end) in Runen
}

@(private = "file")
g_rune_w: map[rune]f32 // Breiten-Cache (nur Main-Thread)

// Beim Zoom-Wechsel aufrufen — die gemessenen Breiten ändern sich leicht.
rune_widths_clear :: proc() {
	clear(&g_rune_w)
}

@(private = "file")
rune_width :: proc(app: ^App, r: rune) -> f32 {
	if w, ok := g_rune_w[r]; ok {
		return w
	}
	s, _ := utf8.runes_to_string([]rune{r}, context.temp_allocator)
	w := rl.MeasureTextEx(app.fonts.regular17, tcstr(s), 17, 0).x
	g_rune_w[r] = w
	return w
}

@(private = "file")
layout_input :: proc(app: ^App, runes: []rune, width: f32) -> [dynamic]Input_Line {
	lines := make([dynamic]Input_Line, context.temp_allocator)
	start := 0
	x := f32(0)
	last_space := -1
	for i := 0; i < len(runes); i += 1 {
		r := runes[i]
		if r == '\n' {
			append(&lines, Input_Line{start, i})
			start = i + 1
			x = 0
			last_space = -1
			continue
		}
		rw := rune_width(app, r)
		if x + rw > width && i > start {
			brk := last_space > start ? last_space : i
			append(&lines, Input_Line{start, brk})
			start = brk
			last_space = -1
			x = 0
			for j := start; j < i; j += 1 {
				x += rune_width(app, runes[j])
			}
		}
		if r == ' ' {
			last_space = i + 1
		}
		x += rw
	}
	append(&lines, Input_Line{start, len(runes)})
	return lines
}

// Zeichnet das Eingabefeld und gibt die belegte Gesamthöhe (inkl. Ränder) zurück.
@(private = "file")
draw_message_input :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, chat: rl.Rectangle) -> f32 {
	ti := &c.msg_input
	margin := f32(20)
	pad := f32(12)
	send_w := f32(40) // Platz für den Senden-Button rechts
	box_w := chat.width - 2*margin
	inner_w := box_w - 2*pad - send_w

	focused := app.ui.focus == .Message && app.ui.layer == .Base
	submitted := false
	if focused {
		submitted = ti_update(app, ti, true)
	}

	lines := layout_input(app, ti.runes[:], inner_w)
	n_shown := clamp(len(lines), 1, 6)
	target_h := max(f32(46), f32(n_shown)*24 + 20)
	box_h := anim_to(app, anim_id(.Misc, c.active_channel ~ 0x11), target_h, 20, initial = target_h)
	hint_h := f32(20)
	total := box_h + 14 + hint_h + 10

	box := rl.Rectangle{chat.x + margin, chat.y + chat.height - hint_h - 10 - box_h, box_w, box_h}
	text_area := rl.Rectangle{box.x, box.y, box.width - send_w, box.height}
	tab_stop(app, anim_id(.Input_Focus, u64(Focus.Message)), box, .Base, .Message, RADIUS_INPUT)

	if ui_hover(&app.ui, text_area, .Base) {
		app.ui.cursor = .IBEAM
	}

	// Fokus-Ring + Rahmen
	ft := anim_to(app, anim_id(.Input_Focus, u64(Focus.Message)), focused ? 1 : 0, 18)
	rrect(box, RADIUS_INPUT, COL_WHITE)
	if ft > 0.01 {
		glow := rl.Rectangle{box.x - 3, box.y - 3, box.width + 6, box.height + 6}
		rrect_lines(glow, RADIUS_INPUT + 3, 3, fade(COL_ACCENT_SOFT, ft))
	}
	rrect_lines(box, RADIUS_INPUT, focused ? 1.6 : 1, mix(COL_BORDER, COL_ACCENT, ft))

	// Cursor-Zeile bestimmen (Zeilennavigation + Sichtbarkeit beim Scrollen)
	caret_line_of :: proc(lines: []Input_Line, cursor: int) -> int {
		cl := 0
		for l, i in lines {
			if cursor >= l.start && cursor <= l.end {
				cl = i
			}
		}
		return cl
	}
	caret_line := caret_line_of(lines[:], ti.cursor)

	// ↑/↓: zwischen den Zeilen navigieren, Shift erweitert die Selektion.
	// (Alt+↑/↓ bleibt der Channel-Wechsel.)
	if focused && !alt_down() {
		move := 0
		if key_pressed(.UP) {
			move = -1
		}
		if key_pressed(.DOWN) {
			move = +1
		}
		if move != 0 {
			extend := shift_down()
			tgt := caret_line + move
			if tgt < 0 {
				ti_move(ti, 0, extend)
			} else if tgt >= len(lines) {
				ti_move(ti, len(ti.runes), extend)
			} else {
				// x-Position des Cursors in der Zielzeile halten („goal column")
				cx := f32(0)
				for j := lines[caret_line].start; j < ti.cursor; j += 1 {
					cx += rune_width(app, ti.runes[j])
				}
				l := lines[tgt]
				idx := l.end
				x := f32(0)
				for j := l.start; j < l.end; j += 1 {
					w := rune_width(app, ti.runes[j])
					if cx < x + w/2 {
						idx = j
						break
					}
					x += w
				}
				ti_move(ti, idx, extend)
			}
			caret_reset(app)
			caret_line = caret_line_of(lines[:], ti.cursor)
		}
	}

	// Scroll-Zustand: Mausrad über dem Feld scrollt; bewegt sich der
	// Cursor (Tippen, Pfeile, Klick), wird seine Zeile sichtbar gehalten.
	line_h := f32(24)
	content_h := f32(len(lines)) * line_h
	visible_h := box_h - 20
	max_scroll := max(0, content_h - visible_h)
	if ti.cursor != c.input_last_cursor || len(ti.runes) != c.input_last_len {
		c.input_last_cursor = ti.cursor
		c.input_last_len = len(ti.runes)
		cy0 := f32(caret_line) * line_h
		if cy0 < c.input_scroll.target {
			c.input_scroll.target = cy0
		} else if cy0 + line_h > c.input_scroll.target + visible_h {
			c.input_scroll.target = cy0 + line_h - visible_h
		}
	}
	scroll_update(app, &c.input_scroll, ui_hover(&app.ui, text_area, .Base), max_scroll, 48)
	text_y0 := box.y + 10 - c.input_scroll.pos

	// Maus: Cursor setzen / Selektion ziehen / Doppelklick Wort
	if app.ui.layer == .Base {
		mouse_to_index :: proc(app: ^App, lines: []Input_Line, runes: []rune, tx, ty0: f32) -> int {
			li := clamp(int((app.ui.mouse.y - ty0) / 24), 0, len(lines) - 1)
			l := lines[li]
			rel := app.ui.mouse.x - tx
			// Index innerhalb der Zeile suchen
			x := f32(0)
			for j := l.start; j < l.end; j += 1 {
				w := rune_width(app, runes[j])
				if rel < x + w/2 {
					return j
				}
				x += w
			}
			return l.end
		}
		if app.ui.clicked && rl.CheckCollisionPointRec(app.ui.mouse, text_area) {
			app.ui.focus = .Message
			idx := mouse_to_index(app, lines[:], ti.runes[:], box.x + pad, text_y0)
			if app.ui.double_click {
				ti_select_word(ti, idx)
			} else {
				ti_move(ti, idx, shift_down())
				app.ui.drag_focus = .Message
			}
			caret_reset(app)
		}
		if app.ui.drag_focus == .Message && app.ui.mouse_down && !app.ui.clicked {
			idx := mouse_to_index(app, lines[:], ti.runes[:], box.x + pad, text_y0)
			ti_move(ti, idx, true)
		}
	}

	scissor_begin(box.x + 2, box.y + 2, box.width - send_w - 2, box.height - 4)

	if len(ti.runes) == 0 {
		ph: string
		if cs.ch.is_dm {
			ph = fmt.tprintf("Nachricht an %s", channel_title(c, cs))
		} else {
			ph = fmt.tprintf("Nachricht an #%s", cs.ch.name)
		}
		draw_text(app.fonts.regular17, tcstr(ph), {box.x + pad, text_y0 + 3}, 17, 0, COL_TEXT_FAINT)
	}

	lo, hi := ti_sel_range(ti)
	ly := text_y0
	for l, i in lines {
		if ly > box.y + box.height {
			break
		}
		if ly + 24 < box.y {
			ly += 24
			continue
		}
		// Selektion hinterlegen
		if focused && lo < hi {
			seg_lo := max(lo, l.start)
			seg_hi := min(hi, l.end)
			if seg_lo < seg_hi {
				x0 := f32(0)
				for j := l.start; j < seg_lo; j += 1 {
					x0 += rune_width(app, ti.runes[j])
				}
				x1 := x0
				for j := seg_lo; j < seg_hi; j += 1 {
					x1 += rune_width(app, ti.runes[j])
				}
				rl.DrawRectangleRec({box.x + pad + x0, ly + 1, x1 - x0, 22}, fade(COL_ACCENT, 0.28))
			}
		}
		draw_text(app.fonts.regular17, tcstr(runes_str(ti.runes[l.start:l.end])),
			{box.x + pad, ly + 3}, 17, 0, COL_TEXT)
		if focused && caret_visible(app) && i == caret_line {
			cw := f32(0)
			for j := l.start; j < ti.cursor; j += 1 {
				cw += rune_width(app, ti.runes[j])
			}
			rl.DrawLineEx({box.x + pad + cw, ly + 2}, {box.x + pad + cw, ly + 22}, 1.4, COL_TEXT)
		}
		ly += 24
	}
	scissor_end()

	// Scrollbar, sobald der Inhalt höher ist als die Box.
	// content-Parameter so gewählt, dass max_scroll exakt dem des Feldes entspricht.
	sb_area := rl.Rectangle{box.x, box.y + 2, box.width - send_w, box.height - 4}
	scrollbar(app, sb_area, max_scroll + sb_area.height, &c.input_scroll, .Base)

	// Senden-Button
	has_text := len(strings.trim_space(ti_text(ti))) > 0
	btn := rl.Rectangle{box.x + box.width - 38, box.y + box.height - 38, 30, 30}
	btn_focused := tab_stop(app, anim_id(.Misc, 0x5E4D), btn, .Base, radius = 6)
	bt := anim_to(app, anim_id(.Misc, 0x5E4D), has_text ? 1 : 0, 14)
	bcol := mix(rl.Color{225, 225, 225, 255}, COL_ACCENT, bt)
	if ui_hover(&app.ui, btn, .Base) && has_text {
		app.ui.cursor = .POINTING_HAND
		bcol = mix(bcol, rl.Color{0, 0, 0, 255}, 0.08)
	}
	rrect(btn, 6, bcol)
	if btn_focused {
		draw_focus_ring(btn, 6)
	}
	// Senden-Icon (Dreieck nach rechts; DrawPoly umgeht Winding-Fallen).
	// +1 px optischer Ausgleich: rechtsweisende Dreiecke wirken sonst linkslastig.
	rl.DrawPoly({btn.x + btn.width/2 + 1, btn.y + btn.height/2}, 3, 7, 0, COL_WHITE)
	if (ui_click(&app.ui, btn, .Base) || (btn_focused && app.ui.tab_activate)) && has_text {
		submitted = true
	}

	// Hinweiszeile unter dem Feld
	hint_y := box.y + box.height + 6
	over := len(ti_text(ti)) - shared.MAX_MESSAGE_TEXT_LEN
	if over > -500 {
		// Zeichen-Budget anzeigen, wenn es knapp wird
		lbl := over > 0 ? fmt.tprintf("%d Zeichen zu viel", over) : fmt.tprintf("noch %d Zeichen", -over)
		col := over > 0 ? COL_RED : COL_TEXT_FAINT
		tw := rl.MeasureTextEx(app.fonts.regular13, tcstr(lbl), 13, 0).x
		draw_text(app.fonts.regular13, tcstr(lbl), {box.x + box.width - tw, hint_y}, 13, 0, col)
	} else if focused {
		hint := len(ti.runes) == 0 ? "*fett*  _kursiv_  ~durchgestrichen~  `code`  ```sprache … ```" : "Enter senden  ·  Shift+Enter neue Zeile"
		draw_text(app.fonts.regular13, tcstr(hint), {box.x + 2, hint_y}, 13, 0, fade(COL_TEXT_FAINT, ft*0.9))
	}

	if submitted {
		text := strings.trim_space(ti_text(ti))
		if len(text) > shared.MAX_MESSAGE_TEXT_LEN {
			toast(app, .Error, "Nachricht ist zu lang")
		} else if text != "" {
			conn_request(c, {kind = shared.K_SEND, channel_id = cs.ch.id, text = text}, {channel_id = cs.ch.id})
			ti_clear(ti)
			caret_reset(app)
			cs.stick_bottom = true
		}
	}
	return total
}
