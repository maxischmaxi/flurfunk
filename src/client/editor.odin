package main

// Mehrzeiliger Plaintext-Editor: Zeilen-Layout mit Wortumbruch, Pfeiltasten-
// Navigation, Maus-Selektion, Scrolling und Caret. Wird vom Eingabefeld
// unten (chat.odin) und vom Inline-Edit einer Nachricht geteilt.

import "core:strings"
import "core:unicode/utf8"

import rl "vendor:raylib"
import shared "../shared"

EDITOR_LINE_H :: f32(24)
EDITOR_PAD :: f32(12)

// Scroll-/Caret-Zustand eines Editors (pro Instanz, lebt im Server_Conn).
Editor_State :: struct {
	scroll:      Scroll,
	last_cursor: int, // Cursor-Bewegung erkennen → Caret sichtbar halten
	last_len:    int,
}

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
	if r == '\t' {
		// Tab = feste 4 Leerzeichen — vor dem Cache behandelt, denn raylib
		// kann \t weder messen noch zeichnen.
		return 4 * rune_width(app, ' ')
	}
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
		if r == ' ' || r == '\t' {
			last_space = i + 1
		}
		x += rw
	}
	append(&lines, Input_Line{start, len(runes)})
	return lines
}

// Eine Editor-Zeile zeichnen. Tabs werden segmentweise übersprungen —
// raylib würde \t als „?" rendern; der x-Vorschub kommt aus rune_width,
// damit Zeichnung, Caret, Selektion und Maus-Hit identisch rechnen.
@(private = "file")
draw_editor_line :: proc(app: ^App, runes: []rune, x, y: f32) {
	seg := 0
	cx := x
	for i := 0; i <= len(runes); i += 1 {
		if i < len(runes) && runes[i] != '\t' {
			continue
		}
		if i > seg {
			draw_text(app.fonts.regular17, tcstr(runes_str(runes[seg:i])), {cx, y}, 17, 0, COL_TEXT)
			for j in seg ..< i {
				cx += rune_width(app, runes[j])
			}
		}
		if i < len(runes) {
			cx += rune_width(app, '\t')
		}
		seg = i + 1
	}
}

// --- Code-Block-Erkennung für die Tab-Taste ---

// Ist `line` eine öffnende/schließende ```-Fence-Zeile? Einzeiler wie
// ```code``` sind in sich geschlossen und zählen nicht.
@(private = "file")
line_is_fence :: proc(line: []rune) -> bool {
	a, b := 0, len(line)
	for a < b && (line[a] == ' ' || line[a] == '\t') {
		a += 1
	}
	for b > a && (line[b-1] == ' ' || line[b-1] == '\t') {
		b -= 1
	}
	if b - a < 3 || line[a] != '`' || line[a+1] != '`' || line[a+2] != '`' {
		return false
	}
	if b - a > 5 && line[b-1] == '`' && line[b-2] == '`' && line[b-3] == '`' {
		return false // ```einzeiler``` — öffnet und schließt zugleich
	}
	return true
}

// Steht die Caret-Position in einem offenen ```-Code-Block? (Ungerade Zahl
// von Fence-Zeilen oberhalb der Caret-Zeile.)
editor_in_code :: proc(runes: []rune, cursor: int) -> bool {
	fences := 0
	line_start := 0
	for i := 0; i < len(runes) && i < cursor; i += 1 {
		if runes[i] == '\n' {
			if line_is_fence(runes[line_start:i]) {
				fences += 1
			}
			line_start = i + 1
		}
	}
	return fences % 2 == 1
}

// Für ui_begin_frame: Tab gehört dem fokussierten Editor (Einrückung),
// wenn dessen Caret gerade in einem Code-Block steht.
editor_wants_tab :: proc(app: ^App) -> bool {
	if app.modal != .None {
		return false
	}
	c := app_active_conn(app)
	if c == nil {
		return false
	}
	#partial switch app.ui.focus {
	case .Message:
		return editor_in_code(c.msg_input.runes[:], c.msg_input.cursor)
	case .Edit:
		return editor_in_code(c.edit_input.runes[:], c.edit_input.cursor)
	}
	return false
}

// Tab/Shift+Tab im Code-Block: ohne Selektion fügt Tab ein \t am Caret ein;
// mit Selektion (oder bei Shift+Tab) werden ganze Zeilen ein-/ausgerückt.
@(private = "file")
editor_indent :: proc(ti: ^Text_Input, outdent: bool) {
	lo, hi := ti_sel_range(ti)
	if !outdent && lo == hi {
		ti_insert(ti, '\t')
		return
	}
	forward := ti.cursor >= ti.sel

	// Anfang der ersten betroffenen Zeile
	i := lo
	for i > 0 && ti.runes[i-1] != '\n' {
		i -= 1
	}
	for i <= hi {
		if outdent {
			// führendes \t oder bis zu 4 Spaces entfernen
			removed := 0
			if i < len(ti.runes) && ti.runes[i] == '\t' {
				ordered_remove(&ti.runes, i)
				removed = 1
			} else {
				for removed < 4 && i < len(ti.runes) && ti.runes[i] == ' ' {
					ordered_remove(&ti.runes, i)
					removed += 1
				}
			}
			if removed > 0 {
				if lo > i {lo = max(lo - removed, i)}
				hi = max(hi - removed, i)
			}
		} else {
			inject_at(&ti.runes, i, '\t')
			if lo > i {lo += 1}
			hi += 1
		}
		// nächster Zeilenanfang
		for i < len(ti.runes) && ti.runes[i] != '\n' {
			i += 1
		}
		i += 1
	}
	if forward {
		ti.sel, ti.cursor = lo, hi
	} else {
		ti.sel, ti.cursor = hi, lo
	}
}

// Box-Höhe für den aktuellen Inhalt (bis max_lines Zeilen, danach scrollt
// der Editor intern). Muss die gleiche Innenbreite bekommen wie der Editor.
editor_box_height :: proc(app: ^App, ti: ^Text_Input, inner_w: f32, max_lines: int) -> f32 {
	lines := layout_input(app, ti.runes[:], inner_w)
	n := clamp(len(lines), 1, max_lines)
	return max(f32(46), f32(n)*EDITOR_LINE_H + 20)
}

// Editor zeichnen und Eingaben verarbeiten. `right_reserve` hält rechts in
// der Box Platz für Buttons frei. Gibt submitted zurück (Enter ohne Shift,
// nur wenn fokussiert).
multiline_editor :: proc(
	app: ^App,
	box: rl.Rectangle,
	ti: ^Text_Input,
	ed: ^Editor_State,
	focus: Focus,
	placeholder: string,
	right_reserve: f32,
) -> (submitted: bool) {
	pad := EDITOR_PAD
	inner_w := box.width - 2*pad - right_reserve

	focused := app.ui.focus == focus && app.ui.layer == .Base
	if focused {
		submitted = ti_update(app, ti, true)
		// Tab im Code-Block rückt ein statt zu navigieren (ui_begin_frame
		// überspringt die Fokus-Navigation in genau diesem Fall).
		if key_pressed(.TAB) && !ctrl_down() && !alt_down() &&
		   editor_in_code(ti.runes[:], ti.cursor) {
			editor_indent(ti, shift_down())
			caret_reset(app)
		}
	}

	lines := layout_input(app, ti.runes[:], inner_w)
	text_area := rl.Rectangle{box.x, box.y, box.width - right_reserve, box.height}
	tab_stop(app, anim_id(.Input_Focus, u64(focus)), box, .Base, focus, RADIUS_INPUT)

	if ui_hover(&app.ui, text_area, .Base) {
		app.ui.cursor = .IBEAM
	}

	// Fokus-Ring + Rahmen
	ft := anim_to(app, anim_id(.Input_Focus, u64(focus)), focused ? 1 : 0, 18)
	rrect(box, RADIUS_INPUT, COL_SURFACE)
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
	content_h := f32(len(lines)) * EDITOR_LINE_H
	visible_h := box.height - 20
	max_scroll := max(0, content_h - visible_h)
	if ti.cursor != ed.last_cursor || len(ti.runes) != ed.last_len {
		ed.last_cursor = ti.cursor
		ed.last_len = len(ti.runes)
		cy0 := f32(caret_line) * EDITOR_LINE_H
		if cy0 < ed.scroll.target {
			ed.scroll.target = cy0
		} else if cy0 + EDITOR_LINE_H > ed.scroll.target + visible_h {
			ed.scroll.target = cy0 + EDITOR_LINE_H - visible_h
		}
	}
	scroll_update(app, &ed.scroll, ui_hover(&app.ui, text_area, .Base), max_scroll, 48)
	text_y0 := box.y + 10 - ed.scroll.pos

	// Maus: Cursor setzen / Selektion ziehen / Doppelklick Wort
	mouse_to_index :: proc(app: ^App, lines: []Input_Line, runes: []rune, tx, ty0: f32) -> int {
		li := clamp(int((app.ui.mouse.y - ty0) / EDITOR_LINE_H), 0, len(lines) - 1)
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
	if app.ui.clicked && ui_hover(&app.ui, text_area, .Base) {
		app.ui.focus = focus
		idx := mouse_to_index(app, lines[:], ti.runes[:], box.x + pad, text_y0)
		if app.ui.triple_click {
			ti_select_line(ti, idx)
		} else if app.ui.double_click {
			ti_select_word(ti, idx)
		} else {
			ti_move(ti, idx, shift_down())
			app.ui.drag_focus = focus
		}
		caret_reset(app)
	}
	if app.ui.drag_focus == focus && app.ui.mouse_down && !app.ui.clicked {
		idx := mouse_to_index(app, lines[:], ti.runes[:], box.x + pad, text_y0)
		ti_move(ti, idx, true)
	}

	scissor_begin(box.x + 2, box.y + 2, box.width - right_reserve - 2, box.height - 4)

	if len(ti.runes) == 0 && placeholder != "" {
		draw_text(app.fonts.regular17, tcstr(placeholder), {box.x + pad, text_y0 + 3}, 17, 0, COL_TEXT_FAINT)
	}

	lo, hi := ti_sel_range(ti)
	ly := text_y0
	for l, i in lines {
		if ly > box.y + box.height {
			break
		}
		if ly + EDITOR_LINE_H < box.y {
			ly += EDITOR_LINE_H
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
		draw_editor_line(app, ti.runes[l.start:l.end], box.x + pad, ly + 3)
		if focused && caret_visible(app) && i == caret_line {
			cw := f32(0)
			for j := l.start; j < ti.cursor; j += 1 {
				cw += rune_width(app, ti.runes[j])
			}
			rl.DrawLineEx({box.x + pad + cw, ly + 2}, {box.x + pad + cw, ly + 22}, 1.4, COL_TEXT)
		}
		ly += EDITOR_LINE_H
	}
	scissor_end()

	// Scrollbar, sobald der Inhalt höher ist als die Box.
	// content-Parameter so gewählt, dass max_scroll exakt dem des Feldes entspricht.
	sb_area := rl.Rectangle{box.x, box.y + 2, box.width - right_reserve, box.height - 4}
	scrollbar(app, sb_area, max_scroll + sb_area.height, &ed.scroll, .Base)
	return
}

// --- Inline-Edit einer Nachricht ---

EDIT_BTNS :: f32(70)     // Platz für ✕/✓ rechts unten in der Box
EDIT_MAX_LINES :: 8      // danach scrollt der Editor intern

// Box-Höhe des Inline-Editors bei gegebener Textbreite der Nachricht.
edit_box_height :: proc(app: ^App, c: ^Server_Conn, text_w: f32) -> f32 {
	return editor_box_height(app, &c.edit_input, text_w - 2*EDITOR_PAD - EDIT_BTNS, EDIT_MAX_LINES)
}

// Bearbeiten beginnen (aus dem „Mehr"-Menü). Optimistisch: der Server prüft
// die Frist parallel über edit_start — lehnt er ab, räumt die Antwort den
// Editor wieder weg (app_apply_reply).
start_edit :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, m: shared.Chat_Message) {
	if c.edit_msg_id == m.id {
		return
	}
	if c.edit_msg_id != 0 {
		// nur ein Edit gleichzeitig — den alten serverseitig freigeben
		conn_request(c, {kind = shared.K_EDIT_CANCEL, channel_id = c.edit_channel, message_id = c.edit_msg_id})
	}
	c.edit_msg_id = m.id
	c.edit_channel = cs.ch.id
	c.edit_busy = false
	ti_set_text(&c.edit_input, m.text)
	c.edit_ed = {}
	app.ui.focus = .Edit
	caret_reset(app)
	conn_request(c, {kind = shared.K_EDIT_START, channel_id = cs.ch.id, message_id = m.id},
		{channel_id = cs.ch.id, message_id = m.id})
}

// Edit-Zustand lokal aufräumen (nach Speichern, Abbrechen oder Fehler).
// Die Zeilenhöhen richten sich über den Layout-Cache von selbst wieder ein
// (edit_msg_id ist Teil seines Schlüssels).
stop_edit :: proc(app: ^App, c: ^Server_Conn) {
	c.edit_msg_id = 0
	c.edit_channel = 0
	c.edit_busy = false
	ti_clear(&c.edit_input)
	if app.ui.focus == .Edit {
		app.ui.focus = .Message
	}
}

cancel_edit :: proc(app: ^App, c: ^Server_Conn) {
	if c.edit_msg_id == 0 {
		return
	}
	conn_request(c, {kind = shared.K_EDIT_CANCEL, channel_id = c.edit_channel, message_id = c.edit_msg_id})
	stop_edit(app, c)
}

commit_edit :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, m: shared.Chat_Message) {
	text := strings.trim_space(ti_text(&c.edit_input))
	if text == "" || c.edit_busy {
		return
	}
	if text == m.text {
		cancel_edit(app, c) // nichts geändert → keinen der 3 Edits verbrauchen
		return
	}
	if len(text) > shared.MAX_MESSAGE_TEXT_LEN {
		toast(app, .Error, "Nachricht ist zu lang")
		return
	}
	c.edit_busy = true
	conn_request(c, {kind = shared.K_EDIT_MESSAGE, channel_id = cs.ch.id, message_id = m.id, text = text},
		{channel_id = cs.ch.id, message_id = m.id})
}

// Inline-Editor einer Nachricht: ersetzt den Nachrichtentext der Zeile.
// ✓ speichert (auch Enter), ✕ bricht ab (auch Esc).
draw_edit_row :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, m: shared.Chat_Message, x, y, w: f32) {
	box := rl.Rectangle{x, y, w, edit_box_height(app, c, w)}
	submitted := multiline_editor(app, box, &c.edit_input, &c.edit_ed, .Edit, "", EDIT_BTNS)

	text := strings.trim_space(ti_text(&c.edit_input))
	can_save := len(text) > 0 && !c.edit_busy

	save := rl.Rectangle{box.x + box.width - 32, box.y + box.height - 32, 26, 26}
	cancel := rl.Rectangle{save.x - 30, save.y, 26, 26}

	// ✕ Abbrechen
	cancel_id := anim_id(.Msg_Action, m.id ~ 0xCA)
	cfocused := tab_stop(app, cancel_id, cancel, .Base, radius = 6)
	chovered := ui_hover(&app.ui, cancel, .Base)
	ct := anim_to(app, cancel_id, (chovered || cfocused) ? 1 : 0, 18)
	if ct > 0.01 {
		rrect(cancel, 6, fade(COL_OVERLAY, ct*0.08))
	}
	if cfocused {
		draw_focus_ring(cancel, 6)
	}
	if chovered {
		app.ui.cursor = .POINTING_HAND
	}
	draw_cross(cancel.x + 13, cancel.y + 13, 9, 1.6, mix(COL_TEXT_DIM, COL_TEXT, ct))
	tooltip(app, cancel_id ~ 0x71C, cancel, "Abbrechen — Esc", .Base)
	if ui_click(&app.ui, cancel, .Base) || (cfocused && app.ui.tab_activate) {
		cancel_edit(app, c)
		return
	}

	// ✓ Speichern
	save_id := anim_id(.Msg_Action, m.id ~ 0x5A)
	sfocused := tab_stop(app, save_id, save, .Base, radius = 6)
	st := anim_to(app, save_id, can_save ? 1 : 0, 14)
	scol := mix(COL_SEND_IDLE, COL_ACCENT, st)
	if ui_hover(&app.ui, save, .Base) && can_save {
		app.ui.cursor = .POINTING_HAND
		scol = mix(scol, COL_PRESS, 0.08)
	}
	rrect(save, 6, scol)
	if sfocused {
		draw_focus_ring(save, 6)
	}
	if c.edit_busy {
		draw_spinner(save.x + 13, save.y + 13, 7, COL_WHITE)
	} else {
		draw_check(save.x + 13, save.y + 13, 11, 1.8, mix(COL_TEXT_FAINT, COL_WHITE, st))
	}
	tooltip(app, save_id ~ 0x71C, save, "Speichern — Enter", .Base)
	if (ui_click(&app.ui, save, .Base) || (sfocused && app.ui.tab_activate) || submitted) && can_save {
		commit_edit(app, c, cs, m)
	}
}
