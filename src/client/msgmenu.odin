package main

// „Mehr"-Menü einer Nachricht (⋮ im Hover-Panel): Popover mit
// „Nachricht bearbeiten" (solange die 1-Minuten-Frist läuft und noch
// Edits übrig sind) und „History anzeigen" (sobald einmal bearbeitet).

import rl "vendor:raylib"
import shared "../shared"

MSG_MENU_W :: f32(224)
MSG_MENU_ITEM_H :: f32(34)

// Zustand des Popovers (in App).
Msg_Menu :: struct {
	open:       bool,
	channel_id: u64,
	msg_id:     u64,
	pos:        rl.Vector2, // Ankerpunkt (unter dem ⋮-Button), logisch
}

// Läuft die 1-Minuten-Bearbeitungsfrist dieser Nachricht noch? Nach jedem
// Edit beginnt sie neu (ab edited_ms). Der Server prüft mit seiner eigenen
// Uhr nochmal — das hier steuert nur die Sichtbarkeit des Menüpunkts.
edit_window_open :: proc(m: shared.Chat_Message) -> bool {
	base := m.edited_ms > 0 ? m.edited_ms : m.ts_ms
	return unix_now_ms() - base <= shared.EDIT_WINDOW_MS
}

msg_menu_open :: proc(app: ^App, channel_id, msg_id: u64, pos: rl.Vector2) {
	app.msg_menu = Msg_Menu{open = true, channel_id = channel_id, msg_id = msg_id, pos = pos}
	app.anim.vals[anim_id(.Modal_Open, 4)] = 0 // Einblend-Animation neu starten
	// Der öffnende Klick darf das Menü nicht sofort wieder schließen.
	app.ui.clicked = false
	app.ui.rclicked = false
}

@(private = "file")
Menu_Action :: enum {
	None,
	Edit,
	History,
}

draw_msg_menu :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	if !app.msg_menu.open {
		return
	}
	if app.modal != .None || app.ctx.open {
		app.msg_menu.open = false
		return
	}
	cs := conn_find_channel(c, app.msg_menu.channel_id)
	if cs == nil {
		app.msg_menu.open = false
		return
	}
	m: ^shared.Chat_Message
	for &mm in cs.messages {
		if mm.id == app.msg_menu.msg_id {
			m = &mm
			break
		}
	}
	if m == nil {
		app.msg_menu.open = false
		return
	}

	// Verfügbarkeit pro Frame neu bewerten — läuft die Frist während das
	// Menü offen ist ab, verschwindet der Punkt live.
	can_edit := m.author_id == c.me.id && m.edit_count < shared.MAX_MESSAGE_EDITS && edit_window_open(m^)
	has_history := m.edit_count > 0

	Item :: struct {
		label:  string,
		action: Menu_Action,
	}
	items := make([dynamic]Item, context.temp_allocator)
	if can_edit {
		append(&items, Item{"Nachricht bearbeiten", .Edit})
	}
	if has_history {
		append(&items, Item{"History anzeigen", .History})
	}
	empty := len(items) == 0
	rows := empty ? 1 : len(items)

	h := f32(rows)*MSG_MENU_ITEM_H + 12
	x := clamp(app.msg_menu.pos.x - MSG_MENU_W/2, 8, sw - MSG_MENU_W - 8)
	y := clamp(app.msg_menu.pos.y, 8, sh - h - 8)
	p := rl.Rectangle{x, y, MSG_MENU_W, h}

	t := anim_to(app, anim_id(.Modal_Open, 4), 1, 24, initial = 0)
	draw_shadow(p, 10, 0.5*t)
	rrect(p, 10, fade(COL_SURFACE, t))
	rrect_lines(p, 10, 1, fade(COL_BORDER, t))

	chosen := Menu_Action.None
	iy := y + 6
	if empty {
		draw_text(app.fonts.regular15, "Keine Aktionen verfügbar",
			{x + 16, iy + (MSG_MENU_ITEM_H - 15)/2 - 1}, 15, 0, fade(COL_TEXT_FAINT, t))
	}
	for it in items {
		r := rl.Rectangle{x + 6, iy, MSG_MENU_W - 12, MSG_MENU_ITEM_H}
		if ui_hover(&app.ui, r, .Modal) {
			rrect(r, 6, COL_SIDEBAR_HOVER)
			app.ui.cursor = .POINTING_HAND
		}
		draw_text(app.fonts.regular15, tcstr(it.label),
			{r.x + 10, iy + (MSG_MENU_ITEM_H - 15)/2 - 1}, 15, 0, fade(COL_TEXT, t))
		if ui_click(&app.ui, r, .Modal) {
			chosen = it.action
		}
		iy += MSG_MENU_ITEM_H
	}

	// Klick außerhalb (links wie rechts) schließt
	if (app.ui.clicked || app.ui.rclicked) && !rl.CheckCollisionPointRec(app.ui.mouse, p) {
		app.msg_menu.open = false
	}

	if chosen != .None {
		app.msg_menu.open = false
		switch chosen {
		case .None:
		case .Edit:
			start_edit(app, c, cs, m^)
		case .History:
			open_message_history(app, c, cs.ch.id, m.id)
		}
	}
}
