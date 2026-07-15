package main

// Kontextmenü für Kanäle und DMs (Rechtsklick in der Sidebar):
// kompaktes Panel mit Items, Separator und Danger-Aktion.

import rl "vendor:raylib"
import shared "../shared"

CTX_W :: f32(224)
CTX_ITEM_H :: f32(34)

ctx_open :: proc(app: ^App, channel_id: u64) {
	app.ctx = Ctx_Menu{open = true, channel_id = channel_id, pos = app.ui.mouse}
	app.anim.vals[anim_id(.Modal_Open, 2)] = 0 // Einblend-Animation neu starten
	// Der öffnende Klick darf das Menü nicht sofort wieder schließen.
	app.ui.clicked = false
	app.ui.rclicked = false
}

@(private = "file")
Ctx_Action :: enum {
	Mark_Read,
	Members,
	Leave,
	Delete,
}

@(private = "file")
Ctx_Item :: struct {
	label:  string,
	danger: bool,
	sep:    bool, // Trennlinie über dem Item
	action: Ctx_Action,
}

draw_ctx_menu :: proc(app: ^App, c: ^Server_Conn, sw, sh: f32) {
	if !app.ctx.open {
		return
	}
	if app.modal != .None {
		app.ctx.open = false
		return
	}
	cs := conn_find_channel(c, app.ctx.channel_id)
	if cs == nil {
		app.ctx.open = false
		return
	}

	items := make([dynamic]Ctx_Item, context.temp_allocator)
	append(&items, Ctx_Item{label = "Als gelesen markieren", action = .Mark_Read})
	if !cs.ch.is_dm {
		append(&items, Ctx_Item{label = "Mitglieder anzeigen", action = .Members})
		append(&items, Ctx_Item{label = "Kanal verlassen", action = .Leave})
		if c.me.is_admin || cs.ch.creator_id == c.me.id {
			append(&items, Ctx_Item{label = "Kanal löschen…", danger = true, sep = true, action = .Delete})
		}
	}

	h := f32(len(items))*CTX_ITEM_H + 12
	for it in items {
		if it.sep {
			h += 9
		}
	}
	x := clamp(app.ctx.pos.x, 8, sw - CTX_W - 8)
	y := clamp(app.ctx.pos.y, 8, sh - h - 8)
	p := rl.Rectangle{x, y, CTX_W, h}

	t := anim_to(app, anim_id(.Modal_Open, 2), 1, 24, initial = 0)
	draw_shadow(p, 10, 0.5*t)
	rrect(p, 10, fade(COL_WHITE, t))
	rrect_lines(p, 10, 1, fade(COL_BORDER, t))

	iy := y + 6
	chosen := Ctx_Action.Mark_Read
	has_chosen := false
	for it in items {
		if it.sep {
			rl.DrawLineEx({x + 8, iy + 4}, {x + CTX_W - 8, iy + 4}, 1, COL_BORDER)
			iy += 9
		}
		r := rl.Rectangle{x + 6, iy, CTX_W - 12, CTX_ITEM_H}
		hovered := ui_hover(&app.ui, r, .Modal)
		if hovered {
			rrect(r, 6, it.danger ? fade(COL_RED, 0.08) : COL_RAIL_BG)
			app.ui.cursor = .POINTING_HAND
		}
		col := it.danger ? COL_RED : COL_TEXT
		draw_text(app.fonts.regular15, tcstr(it.label), {r.x + 10, iy + (CTX_ITEM_H - 15)/2 - 1}, 15, 0, fade(col, t))
		if ui_click(&app.ui, r, .Modal) {
			chosen = it.action
			has_chosen = true
		}
		iy += CTX_ITEM_H
	}

	// Klick außerhalb (links wie rechts) schließt
	if (app.ui.clicked || app.ui.rclicked) && !rl.CheckCollisionPointRec(app.ui.mouse, p) {
		app.ctx.open = false
	}

	if has_chosen {
		app.ctx.open = false
		switch chosen {
		case .Mark_Read:
			cs.unread = 0
			cs.divider_id = 0
			if len(cs.messages) > 0 {
				cs.last_read_id = max(cs.last_read_id, cs.messages[len(cs.messages)-1].id)
			}
		case .Members:
			app_activate_channel(app, c, cs.ch.id)
			open_modal(app, .Members)
		case .Leave:
			conn_request(c, {kind = shared.K_LEAVE, channel_id = cs.ch.id}, {channel_id = cs.ch.id})
		case .Delete:
			app.confirm_channel = cs.ch.id
			open_modal(app, .Confirm_Delete)
		}
	}
}
