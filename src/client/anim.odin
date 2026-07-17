package main

// Animations-Grundlagen: framerate-unabhängiges Smoothing, Per-ID-Zustände
// für Hover-/Pop-Effekte, Caret-Blink mit Reset beim Tippen.

import "core:math"

import rl "vendor:raylib"

// Framerate-unabhängige exponentielle Annäherung an ein Ziel.
// speed ~ 10..20 fühlt sich "snappy" an, ~6 weich.
exp_smooth :: proc(current, target, dt, speed: f32) -> f32 {
	return target + (current - target) * math.exp(-speed * dt)
}

ease_out_cubic :: proc(t: f32) -> f32 {
	u := 1 - clamp(t, 0, 1)
	return 1 - u * u * u
}

// Leichter Überschwinger (für Badge-Pops u. ä.).
ease_out_back :: proc(t: f32) -> f32 {
	c1 :: 1.70158
	c3 :: c1 + 1
	u := clamp(t, 0, 1) - 1
	return 1 + c3 * u * u * u + c1 * u * u
}

// Namensräume für Animations-IDs, damit sich Widgets nicht in die Quere kommen.
Anim_Kind :: enum u8 {
	Rail_Hover,
	Rail_Active,
	Sidebar_Row,
	Button,
	Input_Focus,
	Badge_Pop,
	Jump_Pill,
	Scrollbar,
	Modal_Open,
	Msg_Row,
	Tab_Slider,
	Switcher_Row,
	Toast,
	Code_Copy,
	Msg_Action, // Hover-Panel, „Mehr"-Menü, Inline-Editor-Buttons
	Call,       // Banner, Panel-Buttons, Speaking-Ringe
	Misc,
}

anim_id :: proc(kind: Anim_Kind, v: u64) -> u64 {
	id := (u64(kind) << 56) ~ (v * 0x9E3779B97F4A7C15)
	// 0 is the "no tab focus" sentinel — no widget id may ever be 0
	// (.Rail_Hover with v == 0 used to produce exactly that).
	return id != 0 ? id : 1
}

Anim_Store :: struct {
	vals: map[u64]f32,
	pops: map[u64]f32, // laufende Pop-Timer (Sekunden seit Auslösung)
}

// Per-ID gesmoothter Wert Richtung `target`. Neu auftauchende IDs starten
// bei `initial` (Default: sofort am Ziel, kein Aufplopp-Effekt).
anim_to :: proc(app: ^App, id: u64, target: f32, speed: f32 = 16, initial: f32 = -1) -> f32 {
	v, ok := app.anim.vals[id]
	if !ok {
		v = initial >= 0 ? initial : target
	}
	v = exp_smooth(v, target, app.dt, speed)
	if abs(v - target) < 0.0005 {
		v = target
	}
	app.anim.vals[id] = v
	return v
}

// Pop-Animation auslösen (z. B. Badge zählt hoch).
anim_pop :: proc(app: ^App, id: u64) {
	app.anim.pops[id] = 0
}

// Aktueller Skalierungsfaktor einer Pop-Animation (1 = Ruhe).
anim_pop_scale :: proc(app: ^App, id: u64, dur: f32 = 0.28, amount: f32 = 0.45) -> f32 {
	t, ok := app.anim.pops[id]
	if !ok {
		return 1
	}
	t += app.dt
	if t >= dur {
		delete_key(&app.anim.pops, id)
		return 1
	}
	app.anim.pops[id] = t
	// hochschnellen, dann zurückfedern
	return 1 + amount * (1 - ease_out_back(t / dur))
}

// --- Caret-Blink (setzt beim Tippen zurück, damit der Cursor beim
// Schreiben durchgehend sichtbar ist) ---

caret_reset :: proc(app: ^App) {
	app.caret_t = rl.GetTime()
}

caret_visible :: proc(app: ^App) -> bool {
	t := rl.GetTime() - app.caret_t
	return math.mod(t, 1.1) < 0.6
}

// --- Smooth-Scroll-Zustand ---

Scroll :: struct {
	pos:      f32, // dargestellte Position
	target:   f32, // Ziel (Wheel/Drag schreiben hierhin)
	activity: f32, // >0 kurz nach Scroll-Aktivität (Scrollbar-Fade)
	dragging: bool,
	drag_off: f32, // Offset Maus→Thumb beim Drag
}

// Wheel-Input + Smoothing + Clamping. Gibt die aktuelle Position zurück.
scroll_update :: proc(app: ^App, s: ^Scroll, hovered: bool, max_scroll: f32, wheel_step: f32 = 60) -> f32 {
	if hovered && app.ui.wheel != 0 {
		s.target -= app.ui.wheel * wheel_step
		s.activity = 1
	}
	s.target = clamp(s.target, 0, max_scroll)
	s.pos = exp_smooth(s.pos, s.target, app.dt, 18)
	if abs(s.pos - s.target) < 0.2 {
		s.pos = s.target
	} else {
		s.activity = max(s.activity, 0.7)
	}
	s.pos = clamp(s.pos, 0, max_scroll)
	s.activity = max(0, s.activity - app.dt*1.2)
	return s.pos
}

scroll_to :: proc(s: ^Scroll, pos: f32) {
	s.target = pos
	s.pos = pos
}
