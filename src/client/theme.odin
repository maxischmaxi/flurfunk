package main

// Design-Tokens: Farben, Radii, Abstände, Schatten. Eine Quelle für alles,
// damit die UI konsistent aussieht.
//
// Stil: neutrale Zinc-Palette (shadcn-artig) + warmer „Sunset"-Akzent aus
// dem Marken-Logo (Pink → Orange → Gelb). Helle Flächen, 1-px-Borders,
// dunkler Primary — bewusst kein Slack-Aubergine.

import "core:math"

import rl "vendor:raylib"

// --- Globaler UI-Zoom (Strg +/-/0). Geometrie wird über eine Camera2D
// skaliert, Fonts werden in physischer Pixelgröße neu geladen — Text
// bleibt dadurch auf jeder Stufe scharf. ---
g_scale := f32(1)

// --- Neutrale (Zinc) ---
COL_CHAT_BG :: rl.Color{255, 255, 255, 255}
COL_PANEL_BG :: rl.Color{250, 250, 250, 255}    // zinc-50 (Auth/Setup-Hintergrund)
COL_RAIL_BG :: rl.Color{244, 244, 245, 255}     // zinc-100
COL_RAIL_ITEM :: rl.Color{228, 228, 231, 255}   // zinc-200 (Ruhefläche „+")
COL_SIDEBAR_BG :: rl.Color{250, 250, 250, 255}  // zinc-50
COL_SIDEBAR_TEXT :: rl.Color{82, 82, 91, 255}   // zinc-600
COL_SIDEBAR_DIM :: rl.Color{161, 161, 170, 255} // zinc-400
COL_SIDEBAR_HOVER :: rl.Color{24, 24, 27, 12}   // dunkles Alpha auf hellem Grund
COL_SIDEBAR_LINE :: rl.Color{228, 228, 231, 255}
COL_TEXT :: rl.Color{24, 24, 27, 255}           // zinc-900
COL_TEXT_DIM :: rl.Color{113, 113, 122, 255}    // zinc-500
COL_TEXT_FAINT :: rl.Color{161, 161, 170, 255}  // zinc-400
COL_BORDER :: rl.Color{228, 228, 231, 255}      // zinc-200
COL_BORDER_SOFT :: rl.Color{244, 244, 245, 255} // zinc-100
COL_HOVER_ROW :: rl.Color{24, 24, 27, 8}        // Nachrichten-Hover
COL_WHITE :: rl.Color{255, 255, 255, 255}

// --- Primary (dunkel, shadcn-Stil) ---
COL_PRIMARY :: rl.Color{24, 24, 27, 255}       // zinc-900 (Buttons, aktive Zeile)
COL_PRIMARY_HOVER :: rl.Color{39, 39, 42, 255} // zinc-800

// --- Brand-Akzent (Sunset aus dem Logo) ---
COL_ACCENT :: rl.Color{242, 88, 47, 255}     // warmes Orange-Rot
COL_ACCENT_SOFT :: rl.Color{242, 88, 47, 36} // Fokus-Glow
LOGO_PINK :: rl.Color{238, 42, 155, 255}     // #ee2a9b
LOGO_ORANGE :: rl.Color{247, 109, 60, 255}   // #f76d3c
LOGO_AMBER :: rl.Color{255, 180, 63, 255}    // #ffb43f

// --- Status / Semantik ---
COL_ONLINE :: rl.Color{16, 185, 129, 255} // emerald-500 (Presence)
COL_RED :: rl.Color{225, 55, 55, 255}     // Danger
COL_BADGE :: rl.Color{240, 71, 47, 255}   // Unread (Logo-Rot)
COL_YELLOW :: rl.Color{234, 179, 8, 255}  // Verbindungsaufbau

// --- Inline-Code (neutral, shadcn-artig) ---
CODE_BG :: rl.Color{244, 244, 245, 255}  // zinc-100
CODE_TEXT :: rl.Color{63, 63, 70, 255}   // zinc-700

// --- Code-Blöcke (dunkles Panel + Syntax-Farben) ---
CODE_BLOCK_BG :: rl.Color{24, 24, 27, 255}      // zinc-900
CODE_BLOCK_HEAD :: rl.Color{255, 255, 255, 14}  // Kopfzeilen-Hairline
SYN_TEXT :: rl.Color{228, 228, 231, 255}        // zinc-200
SYN_KEYWORD :: rl.Color{192, 132, 252, 255}     // violet-400
SYN_TYPE :: rl.Color{103, 232, 249, 255}        // cyan-300
SYN_STRING :: rl.Color{134, 239, 172, 255}      // green-300
SYN_NUMBER :: rl.Color{253, 186, 116, 255}      // orange-300 (Brand-nah)
SYN_COMMENT :: rl.Color{113, 113, 122, 255}     // zinc-500

// --- Metriken ---
RADIUS_CARD :: f32(10)
RADIUS_INPUT :: f32(8)
RADIUS_BTN :: f32(8)

// Rundung als raylib-"roundness" (0..1) für ein Rechteck umrechnen.
roundness :: proc(r: rl.Rectangle, radius: f32) -> f32 {
	m := min(r.width, r.height)
	if m <= 0 {
		return 0
	}
	return clamp(radius * 2 / m, 0, 1)
}

// Gefülltes Rounded-Rect mit Pixel-Radius statt roundness.
rrect :: proc(r: rl.Rectangle, radius: f32, col: rl.Color) {
	rl.DrawRectangleRounded(r, roundness(r, radius), 8, col)
}

rrect_lines :: proc(r: rl.Rectangle, radius: f32, thick: f32, col: rl.Color) {
	rl.DrawRectangleRoundedLinesEx(r, roundness(r, radius), 8, thick, col)
}

// Rounded-Rect mit horizontalem Farbverlauf (für das Marken-Logo).
// Trick: Gradient-Rechteck zeichnen, dann die vier Ecken mit der
// Hintergrundfarbe maskieren und als Viertelkreise neu füllen.
rrect_gradient_h :: proc(r: rl.Rectangle, radius: f32, c0, c1: rl.Color, bg: rl.Color) {
	rl.DrawRectangleGradientEx(r, c0, c0, c1, c1)
	rad := min(radius, min(r.width, r.height)/2)
	corners := [4]struct {
		px, py: f32,      // Eck-Quadrat (oben links)
		cx, cy: f32,      // Kreiszentrum
		a0, a1: f32,      // Sektor-Winkel
		col:    rl.Color,
	}{
		{r.x, r.y, r.x + rad, r.y + rad, 180, 270, c0},
		{r.x + r.width - rad, r.y, r.x + r.width - rad, r.y + rad, 270, 360, c1},
		{r.x, r.y + r.height - rad, r.x + rad, r.y + r.height - rad, 90, 180, c0},
		{r.x + r.width - rad, r.y + r.height - rad, r.x + r.width - rad, r.y + r.height - rad, 0, 90, c1},
	}
	for c in corners {
		rl.DrawRectangleRec({c.px, c.py, rad, rad}, bg)
		rl.DrawCircleSector({c.cx, c.cy}, rad, c.a0, c.a1, 16, c.col)
	}
}

// Weicher Schatten: mehrere wachsende, transparente Schichten.
draw_shadow :: proc(r: rl.Rectangle, radius: f32, strength: f32 = 1) {
	layers := 6
	for i in 1 ..= layers {
		f := f32(i)
		a := u8(clamp(f32(24) * strength * (1 - f/f32(layers+1)) / f, 0, 255))
		grow := f * 2.2
		sr := rl.Rectangle{r.x - grow, r.y - grow + f*0.9, r.width + grow*2, r.height + grow*2}
		rrect(sr, radius + grow, rl.Color{24, 24, 27, a})
	}
}

// DrawTextEx mit auf ganze PHYSISCHE Pixel gerundeter Position. Subpixel-
// Positionen werden vom Bilinear-Filter der Font-Textur verwischt — beim
// UI-Zoom zählt das physische Raster (logisch × g_scale).
draw_text :: proc(font: rl.Font, text: cstring, pos: rl.Vector2, size, spacing: f32, tint: rl.Color) {
	p := rl.Vector2{
		math.round(pos.x * g_scale) / g_scale,
		math.round(pos.y * g_scale) / g_scale,
	}
	rl.DrawTextEx(font, text, p, size, spacing, tint)
}

// Scissor in logischen Koordinaten (rechnet den UI-Zoom ein — raylib-
// Scissor arbeitet in physischen Fenster-Pixeln).
scissor_begin :: proc(x, y, w, h: f32) {
	rl.BeginScissorMode(
		i32(x * g_scale), i32(y * g_scale),
		i32(w * g_scale) + 1, i32(h * g_scale) + 1,
	)
}

scissor_end :: proc() {
	rl.EndScissorMode()
}

// Farbe mit Alpha multiplizieren.
fade :: proc(c: rl.Color, alpha: f32) -> rl.Color {
	out := c
	out.a = u8(clamp(f32(c.a) * alpha, 0, 255))
	return out
}

// Linear zwischen zwei Farben mischen.
mix :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	t := clamp(t, 0, 1)
	return rl.Color{
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * t),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * t),
	}
}
