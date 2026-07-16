package main

// Theme-Umschalter oben rechts in der Titelleiste: Icon-Button (Sonne ↔
// Mond) plus Dropdown mit System / Hell / Dunkel.
//
// Das Icon folgt der Überblendung statt dem gewählten Modus: die Sonne
// schrumpft weg, während sie sich dreht, der Mond wächst gedreht nach.
// Weil immer nur eins von beiden sichtbar ist, überlagern sie sich nie —
// wichtig, weil draw_moon die Sichel mit der Hintergrundfarbe ausstanzt.

import "core:fmt"

import rl "vendor:raylib"

THEME_BTN :: f32(30)
THEME_MENU_W :: f32(190)
THEME_ITEM_H :: f32(34)

// Platz, den der Umschalter am rechten Rand der Kopfzeile belegt — der
// Chat-Header rückt seinen Mitglieder-Button darum nach links.
THEME_RESERVE :: f32(46)

// `bg` ist die Fläche unter dem Button (variiert je nach Screen) — sie
// wird zum Ausstanzen der Mondsichel gebraucht.
draw_theme_switch :: proc(app: ^App, sw: f32, bg: rl.Color) {
	// Ein Modal/Kontextmenü/Nachrichten-Menü übernimmt die Eingabe → Dropdown schließen
	if app.modal != .None || app.ctx.open || app.msg_menu.open {
		app.theme_menu = false
	}

	r := rl.Rectangle{sw - 20 - THEME_BTN, (HEADER_H - THEME_BTN)/2, THEME_BTN, THEME_BTN}
	hovered := ui_hover(&app.ui, r, .Base)
	focused := tab_stop(app, anim_id(.Misc, 0x7EE), r, .Base, radius = 7)
	t := anim_to(app, anim_id(.Misc, 0x7EE), (hovered || focused || app.theme_menu) ? 1 : 0)

	// Fläche unter dem Icon — exakt diese Farbe stanzt den Mond aus.
	chip := mix(bg, COL_OVERLAY, t*0.07)
	if t > 0.01 {
		rrect(r, 7, chip)
	}
	if focused {
		draw_focus_ring(r, 7)
	}
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}

	// Sonne (k→0) und Mond (k→1) schrumpfen/wachsen durch die Null,
	// deshalb ist nie mehr als eins gleichzeitig zu sehen.
	cx := r.x + r.width/2
	cy := r.y + r.height/2
	icon := mix(COL_TEXT_DIM, COL_TEXT, t)
	sun_s := clamp(1 - app.theme_k*2, 0, 1)
	moon_s := clamp(app.theme_k*2 - 1, 0, 1)
	if sun_s > 0.02 {
		draw_sun(cx, cy, 7*sun_s, (1 - sun_s)*90, icon)
	}
	if moon_s > 0.02 {
		draw_moon(cx, cy, 7*moon_s, (1 - moon_s)*-90, icon, chip)
	}

	tip := fmt.tprintf("Design: %s", theme_mode_label(app.theme_mode))
	if app.theme_mode == .System {
		// bei „System" auch zeigen, wofür der Desktop sich entschieden hat
		tip = fmt.tprintf("Design: System (%s)", theme_is_dark(app) ? "dunkel" : "hell")
	}
	tooltip(app, anim_id(.Misc, 0x7EF), r, tip, .Base)

	if ui_click(&app.ui, r, .Base) || (focused && app.ui.tab_activate) {
		app.theme_menu = !app.theme_menu
		if app.theme_menu {
			app.anim.vals[anim_id(.Modal_Open, 3)] = 0 // Einblenden neu starten
		}
		// Der öffnende Klick darf das Menü nicht sofort wieder schließen.
		app.ui.clicked = false
	}

	if !app.theme_menu {
		return
	}

	// --- Dropdown ---
	modes := [3]Theme_Mode{.System, .Light, .Dark}
	h := f32(len(modes))*THEME_ITEM_H + 12
	p := rl.Rectangle{
		min(r.x + r.width - THEME_MENU_W, sw - THEME_MENU_W - 8),
		r.y + r.height + 8,
		THEME_MENU_W, h,
	}

	mt := anim_to(app, anim_id(.Modal_Open, 3), 1, 24, initial = 0)
	draw_shadow(p, 10, 0.5*mt)
	rrect(p, 10, fade(COL_SURFACE, mt))
	rrect_lines(p, 10, 1, fade(COL_BORDER, mt))

	iy := p.y + 6
	chosen := Theme_Mode.System
	has_chosen := false
	for m in modes {
		ir := rl.Rectangle{p.x + 6, iy, p.width - 12, THEME_ITEM_H}
		selected := app.theme_mode == m
		item_hover := ui_hover(&app.ui, ir, .Base)
		item_focus := tab_stop(app, anim_id(.Misc, 0x7E0 ~ u64(m)), ir, .Base, radius = 6)
		if item_hover {
			rrect(ir, 6, fade(COL_SIDEBAR_HOVER, mt))
			app.ui.cursor = .POINTING_HAND
		}
		if item_focus {
			draw_focus_ring(ir, 6)
		}
		draw_text(app.fonts.regular15, tcstr(theme_mode_label(m)),
			{ir.x + 10, iy + (THEME_ITEM_H - 15)/2 - 1}, 15, 0, fade(COL_TEXT, mt))
		if selected {
			draw_check(ir.x + ir.width - 18, iy + THEME_ITEM_H/2, 11, 1.8, fade(COL_ACCENT, mt))
		}
		if ui_click(&app.ui, ir, .Base) || (item_focus && app.ui.tab_activate) {
			chosen = m
			has_chosen = true
		}
		iy += THEME_ITEM_H
	}

	// Klick außerhalb schließt
	if app.ui.clicked && !rl.CheckCollisionPointRec(app.ui.mouse, p) {
		app.theme_menu = false
	}

	if has_chosen {
		app.theme_menu = false
		app_set_theme(app, chosen)
	}
}
