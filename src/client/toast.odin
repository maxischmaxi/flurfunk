package main

// Toasts: kurze Benachrichtigungen unten mittig, slide+fade.

import "core:strings"

import rl "vendor:raylib"

Toast_Kind :: enum {
	Info,
	Success,
	Error,
}

Toast :: struct {
	text: string, // heap-alloziert
	kind: Toast_Kind,
	age:  f32,
	ttl:  f32,
}

toast :: proc(app: ^App, kind: Toast_Kind, text: string) {
	// identische Meldung nicht stapeln, nur Timer auffrischen
	for &t in app.toasts {
		if t.text == text && t.kind == kind {
			t.age = min(t.age, 0.15)
			return
		}
	}
	ttl := kind == .Error ? f32(5) : f32(3)
	append(&app.toasts, Toast{text = strings.clone(text), kind = kind, ttl = ttl})
	if len(app.toasts) > 4 {
		old := app.toasts[0]
		ordered_remove(&app.toasts, 0)
		delete(old.text)
	}
}

draw_toasts :: proc(app: ^App, sw, sh: f32) {
	font := app.fonts.regular15
	y := sh - 28
	// von unten nach oben stapeln, neueste unten
	for i := len(app.toasts) - 1; i >= 0; i -= 1 {
		t := &app.toasts[i]
		t.age += app.dt
		if t.age >= t.ttl {
			delete(t.text)
			ordered_remove(&app.toasts, i)
			continue
		}

		// Ein-/Ausblenden
		a := f32(1)
		slide := f32(0)
		if t.age < 0.25 {
			a = ease_out_cubic(t.age / 0.25)
			slide = (1 - a) * 14
		} else if t.ttl - t.age < 0.3 {
			a = clamp((t.ttl - t.age) / 0.3, 0, 1)
		}

		tw := rl.MeasureTextEx(font, tcstr(t.text), 15, 0)
		pad_x := f32(16)
		w := tw.x + pad_x*2 + 22
		h := f32(40)
		x := (sw - w) / 2
		ry := y - h + slide

		accent := COL_ACCENT
		icon := "i"
		#partial switch t.kind {
		case .Success:
			accent = COL_ONLINE
			icon = "✓"
		case .Error:
			accent = COL_RED
			icon = "!"
		}
		_ = icon

		r := rl.Rectangle{x, ry, w, h}
		draw_shadow(r, 10, a * 0.7)
		rrect(r, 10, fade(COL_TOAST_BG, a))
		rl.DrawCircleV({x + pad_x + 4, ry + h/2}, 4, fade(accent, a))
		draw_text(font, tcstr(t.text), {x + pad_x + 18, ry + (h - 15)/2 - 1}, 15, 0, fade(COL_TOAST_FG, a))

		y = ry - 8
	}
}
