package main

// Eingebettete Fonts + Laden in verschiedenen Größen.

import "core:math"

import rl "vendor:raylib"

FONT_SANS_REGULAR := #load("../../assets/fonts/Inter-Regular.ttf")
FONT_SANS_BOLD := #load("../../assets/fonts/Inter-Bold.ttf")
FONT_SANS_ITALIC := #load("../../assets/fonts/Inter-Italic.ttf")
FONT_SANS_BOLD_ITALIC := #load("../../assets/fonts/Inter-BoldItalic.ttf")
FONT_MONO_REGULAR := #load("../../assets/fonts/LiberationMono-Regular.ttf")

Fonts :: struct {
	regular17:     rl.Font, // Nachrichtentext
	bold17:        rl.Font,
	italic17:      rl.Font,
	bold_italic17: rl.Font,
	mono15:        rl.Font, // Inline-Code (kleiner als der Fließtext, ~0.875em)
	regular15:     rl.Font, // Sidebar / Buttons
	bold15:        rl.Font,
	regular13:     rl.Font, // Kleintext (Zeit, Sektions-Header)
	bold13:        rl.Font, // Badges
	bold11:        rl.Font, // Mini-Avatare
	bold18:        rl.Font, // Header
	bold24:        rl.Font, // Empty-States / Panels
	bold36:        rl.Font, // Welcome-Titel
}

// Codepoints, die in den Font-Atlanten landen (Latin + gängige Satzzeichen).
@(private = "file")
build_codepoints :: proc() -> [dynamic]rune {
	cps := make([dynamic]rune, context.temp_allocator)
	for c in rune(32) ..= rune(126) {
		append(&cps, c)
	}
	for c in rune(0xA0) ..= rune(0x17F) {
		append(&cps, c)
	}
	append(&cps, rune(0x2013), rune(0x2014)) // – —
	for c in rune(0x2018) ..= rune(0x201E) { // ‘ ’ ‚ “ ” „
		append(&cps, c)
	}
	append(&cps, rune(0x2022), rune(0x2026), rune(0x20AC)) // • … €
	append(&cps, rune(0x2191), rune(0x2193)) // ↑ ↓ (Jump-Pill, Switcher-Hinweis)
	return cps
}

// Fonts werden in PHYSISCHER Pixelgröße geladen (logische Größe × UI-Zoom).
// Gezeichnet wird mit der logischen Größe — die Camera2D-Matrix skaliert
// zurück auf 1:1-Texel-Mapping, dadurch bleibt Text auf jeder Stufe scharf.
@(private = "file")
load_font :: proc(data: []byte, size: i32, scale: f32, cps: []rune) -> rl.Font {
	px := i32(max(math.round(f32(size) * scale), 6))
	f := rl.LoadFontFromMemory(".ttf", raw_data(data), i32(len(data)), px, raw_data(cps), i32(len(cps)))
	rl.SetTextureFilter(f.texture, .BILINEAR)
	return f
}

fonts_load :: proc(scale: f32) -> Fonts {
	cps := build_codepoints()
	f: Fonts
	f.regular17 = load_font(FONT_SANS_REGULAR, 17, scale, cps[:])
	f.bold17 = load_font(FONT_SANS_BOLD, 17, scale, cps[:])
	f.italic17 = load_font(FONT_SANS_ITALIC, 17, scale, cps[:])
	f.bold_italic17 = load_font(FONT_SANS_BOLD_ITALIC, 17, scale, cps[:])
	f.mono15 = load_font(FONT_MONO_REGULAR, 15, scale, cps[:])
	f.regular15 = load_font(FONT_SANS_REGULAR, 15, scale, cps[:])
	f.bold15 = load_font(FONT_SANS_BOLD, 15, scale, cps[:])
	f.regular13 = load_font(FONT_SANS_REGULAR, 13, scale, cps[:])
	f.bold13 = load_font(FONT_SANS_BOLD, 13, scale, cps[:])
	f.bold11 = load_font(FONT_SANS_BOLD, 11, scale, cps[:])
	f.bold18 = load_font(FONT_SANS_BOLD, 18, scale, cps[:])
	f.bold24 = load_font(FONT_SANS_BOLD, 24, scale, cps[:])
	f.bold36 = load_font(FONT_SANS_BOLD, 36, scale, cps[:])
	return f
}

// Alte Atlanten freigeben (beim Zoom-Wechsel — sonst GPU-Leak).
fonts_unload :: proc(f: ^Fonts) {
	rl.UnloadFont(f.regular17)
	rl.UnloadFont(f.bold17)
	rl.UnloadFont(f.italic17)
	rl.UnloadFont(f.bold_italic17)
	rl.UnloadFont(f.mono15)
	rl.UnloadFont(f.regular15)
	rl.UnloadFont(f.bold15)
	rl.UnloadFont(f.regular13)
	rl.UnloadFont(f.bold13)
	rl.UnloadFont(f.bold11)
	rl.UnloadFont(f.bold18)
	rl.UnloadFont(f.bold24)
	rl.UnloadFont(f.bold36)
}
