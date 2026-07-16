package main

// Rich-Text-Rendering im Slack-Stil: *fett*, _kursiv_, ~durchgestrichen~,
// `inline-code`. Nur Darstellung — die Eingabe bleibt Plaintext.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

import rl "vendor:raylib"

Span :: struct {
	text:   string,
	bold:   bool,
	italic: bool,
	strike: bool,
	code:   bool,
}

// Kontext für die Chat-Selektion (chatsel.odin). `doc` ist der laufende
// Runen-Index im Render-Dokument der Nachricht — die Zählung läuft in
// Zeichnen-, Mess- und Collect-Modus durch DENSELBEN Code, deshalb sind
// die Indizes garantiert konsistent. Mit gesetztem `collect` wird nur der
// sichtbare Text eingesammelt (Grundlage fürs Kopieren).
Rich_Sel :: struct {
	msg:     u64,
	doc:     int,
	collect: ^strings.Builder,
}

RICH_SIZE :: 17
RICH_LINE_H :: 24
CODE_SIZE :: 15     // Inline-Code etwas kleiner als der Fließtext (~0.875em)
CODE_PAD :: f32(5)  // horizontaler Innenabstand des Code-Chips
CODE_RADIUS :: f32(5)

@(private = "file")
is_delim :: proc(c: rune) -> bool {
	return c == '*' || c == '_' || c == '~' || c == '`'
}

// Gibt es ab Index `from` einen gültigen schließenden Delimiter `d`?
// Regel: schließender Delimiter steht direkt nach Nicht-Leerzeichen.
@(private = "file")
has_closer :: proc(runes: []rune, from: int, d: rune) -> bool {
	for i := from; i < len(runes); i += 1 {
		if runes[i] == d && runes[i-1] != ' ' && runes[i-1] != '\t' {
			return true
		}
	}
	return false
}

// Eine Zeile (ohne \n) in Spans zerlegen. Alloziert im übergebenen Allocator.
parse_spans :: proc(line: string, allocator := context.temp_allocator) -> []Span {
	runes := utf8.string_to_runes(line, context.temp_allocator)
	spans := make([dynamic]Span, allocator)

	bold, italic, strike, code: bool
	sb := strings.builder_make(context.temp_allocator)

	flush :: proc(spans: ^[dynamic]Span, sb: ^strings.Builder, bold, italic, strike, code: bool, allocator: runtime.Allocator) {
		if strings.builder_len(sb^) == 0 {
			return
		}
		append(spans, Span{
			text = strings.clone(strings.to_string(sb^), allocator),
			bold = bold, italic = italic, strike = strike, code = code,
		})
		strings.builder_reset(sb)
	}

	for i := 0; i < len(runes); i += 1 {
		c := runes[i]
		if !is_delim(c) {
			strings.write_rune(&sb, c)
			continue
		}

		// Im Code-Modus schließt nur der Backtick, alles andere ist literal.
		if code {
			if c == '`' && i > 0 && runes[i-1] != ' ' && runes[i-1] != '\t' {
				flush(&spans, &sb, bold, italic, strike, code, allocator)
				code = false
			} else {
				strings.write_rune(&sb, c)
			}
			continue
		}

		active := (c == '*' && bold) || (c == '_' && italic) || (c == '~' && strike)

		if active {
			// Schließer: direkt nach Nicht-Leerzeichen
			if i > 0 && runes[i-1] != ' ' && runes[i-1] != '\t' {
				flush(&spans, &sb, bold, italic, strike, code, allocator)
				switch c {
				case '*': bold = false
				case '_': italic = false
				case '~': strike = false
				}
				continue
			}
			strings.write_rune(&sb, c)
			continue
		}

		// Öffner: am Wortanfang (Anfang / nach Leerzeichen) und direkt vor
		// Nicht-Leerzeichen; außerdem muss ein Schließer existieren.
		at_word_start := i == 0 || runes[i-1] == ' ' || runes[i-1] == '\t' || is_delim(runes[i-1])
		before_nonspace := i + 1 < len(runes) && runes[i+1] != ' ' && runes[i+1] != '\t'
		if at_word_start && before_nonspace && has_closer(runes, i + 2, c) {
			flush(&spans, &sb, bold, italic, strike, code, allocator)
			switch c {
			case '*': bold = true
			case '_': italic = true
			case '~': strike = true
			case '`': code = true
			}
			continue
		}

		// Unabgeschlossen / ungültig → Literaltext
		strings.write_rune(&sb, c)
	}
	flush(&spans, &sb, bold, italic, strike, code, allocator)
	return spans[:]
}

@(private = "file")
span_font :: proc(fonts: ^Fonts, s: Span) -> rl.Font {
	if s.code {
		return fonts.mono15
	}
	if s.bold && s.italic {
		return fonts.bold_italic17
	}
	if s.bold {
		return fonts.bold17
	}
	if s.italic {
		return fonts.italic17
	}
	return fonts.regular17
}

@(private = "file")
span_size :: proc(s: Span) -> f32 {
	return s.code ? CODE_SIZE : RICH_SIZE
}

// Ein Text-Fragment zeichnen (inkl. Code-Hintergrund und Durchstreichung).
// w ist die reine Textbreite; lead/trail sind Chip-Innenabstände am Anfang
// bzw. Ende eines Code-Spans (0 bei Fortsetzungs-Fragmenten).
// hl_lo/hl_hi: markierter Runen-Bereich der Chat-Selektion (-1 = keiner).
@(private = "file")
draw_fragment :: proc(fonts: ^Fonts, s: Span, text: string, x, y, w, lead, trail: f32, hl_lo := -1, hl_hi := -1) {
	ctext := strings.clone_to_cstring(text, context.temp_allocator)
	font := span_font(fonts, s)
	size := span_size(s)
	if s.code {
		bg := rl.Rectangle{x, y + 2, lead + w + trail, RICH_LINE_H - 4}
		rrect(bg, CODE_RADIUS, CODE_BG)
		// Innere Kanten mehrteiliger Spans eckig auffüllen, damit der
		// Hintergrund nahtlos durchläuft statt pro Wort zu „bröckeln".
		edge := min(CODE_RADIUS, bg.width)
		if lead == 0 {
			rl.DrawRectangleRec({bg.x, bg.y, edge, bg.height}, CODE_BG)
		}
		if trail == 0 {
			rl.DrawRectangleRec({bg.x + bg.width - edge, bg.y, edge, bg.height}, CODE_BG)
		}
	}
	if hl_lo >= 0 {
		x0 := rl.MeasureTextEx(font, tcstr(rune_slice(text, 0, hl_lo)), size, 0).x
		x1 := hl_hi >= utf8.rune_count_in_string(text) ? w :
			rl.MeasureTextEx(font, tcstr(rune_slice(text, 0, hl_hi)), size, 0).x
		rl.DrawRectangleRec({x + lead + x0, y + 2, x1 - x0, RICH_LINE_H - 4}, fade(COL_ACCENT, 0.30))
	}
	if s.code {
		draw_text(font, ctext, {x + lead, y + (RICH_LINE_H - CODE_SIZE)/2}, CODE_SIZE, 0, CODE_TEXT)
	} else {
		draw_text(font, ctext, {x, y + 3}, RICH_SIZE, 0, COL_TEXT)
	}
	if s.strike {
		ly := y + RICH_LINE_H*0.52
		rl.DrawLineEx({x + lead, ly}, {x + lead + w, ly}, 1, s.code ? CODE_TEXT : COL_TEXT)
	}
}

// --- Multiline-Code-Blöcke (```lang … ```) ---

CODE_BLOCK_PAD :: f32(12)
CODE_LINE_H :: f32(20)
CODE_BLOCK_MARGIN :: f32(4) // Abstand über/unter dem Block
CODE_HEAD_H :: f32(26)      // Kopfleiste: Sprach-Label + Copy-Button
CODE_BTN :: f32(20)
COPY_FEEDBACK :: f64(1.4)   // so lange zeigt der Button ein Häkchen

// Ein Segment einer Nachricht: Fließtext oder Code-Block.
Msg_Block :: struct {
	is_code: bool,
	lang:    string, // roher Tag hinter ```
	body:    string, // dargestellt (Tabs expandiert)
	raw:     string, // wie getippt — das landet in der Zwischenablage
}

// Tabs spaltenrichtig zu Spaces expandieren (Tabstop 4) — nur fürs
// Rendern; raylib kann \t nicht zeichnen, und nur mit Spaltenbezug
// stimmt gemischte Einrückung („ab\tcd") in Mono-Blöcken überein.
@(private = "file")
expand_tabs :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\t') {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	col := 0
	for r in s {
		switch r {
		case '\n':
			strings.write_rune(&sb, r)
			col = 0
		case '\t':
			n := 4 - col % 4
			for _ in 0 ..< n {
				strings.write_byte(&sb, ' ')
			}
			col += n
		case:
			strings.write_rune(&sb, r)
			col += 1
		}
	}
	return strings.to_string(sb)
}

// Nachricht in Text- und Code-Segmente zerlegen (temp-alloziert).
@(private = "file")
split_blocks :: proc(text: string) -> []Msg_Block {
	blocks := make([dynamic]Msg_Block, context.temp_allocator)
	lines := strings.split_lines(text, context.temp_allocator)
	cur := make([dynamic]string, context.temp_allocator)

	flush_text :: proc(blocks: ^[dynamic]Msg_Block, cur: ^[dynamic]string) {
		if len(cur) == 0 {
			return
		}
		// Auch Fließtext-Tabs expandieren — raylib würde sie als „?" malen.
		body := expand_tabs(strings.join(cur[:], "\n", context.temp_allocator))
		append(blocks, Msg_Block{body = body})
		clear(cur)
	}

	i := 0
	for i < len(lines) {
		trimmed := strings.trim_space(lines[i])
		if strings.has_prefix(trimmed, "```") {
			tag := strings.trim_space(trimmed[3:])
			// Einzeiler ```code``` → Block ohne Sprach-Tag
			if strings.has_suffix(tag, "```") && len(tag) > 3 {
				flush_text(&blocks, &cur)
				raw := strings.trim_space(tag[:len(tag)-3])
				append(&blocks, Msg_Block{is_code = true, body = expand_tabs(raw), raw = raw})
				i += 1
				continue
			}
			flush_text(&blocks, &cur)
			code := make([dynamic]string, context.temp_allocator)
			j := i + 1
			closed := false
			for j < len(lines) {
				if strings.trim_space(lines[j]) == "```" {
					closed = true
					break
				}
				append(&code, lines[j])
				j += 1
			}
			raw := strings.join(code[:], "\n", context.temp_allocator)
			append(&blocks, Msg_Block{is_code = true, lang = tag, body = expand_tabs(raw), raw = raw})
			i = closed ? j + 1 : j
			continue
		}
		append(&cur, lines[i])
		i += 1
	}
	flush_text(&blocks, &cur)
	return blocks[:]
}

// Visuelle Zeilen einer logischen Code-Zeile bei hartem Zeichenumbruch.
@(private = "file")
code_visual_lines :: proc(line: string, cols: int) -> int {
	n := utf8.rune_count_in_string(line)
	if n == 0 {
		return 1
	}
	return (n + cols - 1) / cols
}

// Copy-Button in der Kopfleiste: legt den Code des Blocks in die
// Zwischenablage und zeigt danach kurz ein Häkchen.
@(private = "file")
code_copy_button :: proc(app: ^App, r: rl.Rectangle, code: string, id: u64, layer: UI_Layer) {
	hovered := ui_hover(&app.ui, r, layer)
	focused := tab_stop(app, id, r, layer, radius = 5)
	copied := app.copied_id == id && rl.GetTime() - app.copied_at < COPY_FEEDBACK

	t := anim_to(app, id, (hovered || focused) ? 1 : 0, 18)
	// Fläche unter dem Icon — COL_OVERLAY kippt mit dem Theme, tönt also
	// im Hellen ab und im Dunklen auf. draw_copy_icon stanzt damit aus.
	chip := mix(CODE_BLOCK_BG, COL_OVERLAY, t*0.09)
	if t > 0.01 {
		rrect(r, 5, chip)
	}
	if focused {
		draw_focus_ring(r, 5)
	}
	if hovered {
		app.ui.cursor = .POINTING_HAND
	}

	cx := r.x + r.width/2
	cy := r.y + r.height/2
	if copied {
		draw_check(cx, cy, 10, 1.7, COL_ONLINE)
	} else {
		draw_copy_icon(cx, cy, 11, 1.3, mix(SYN_COMMENT, SYN_TEXT, t), chip)
	}
	tooltip(app, id ~ 0xC0FFEE, r, copied ? "Kopiert!" : "Code kopieren", layer)

	if ui_click(&app.ui, r, layer) || (focused && app.ui.tab_activate) {
		rl.SetClipboardText(tcstr(code))
		app.copied_id = id
		app.copied_at = rl.GetTime()
	}
}

// Code-Block zeichnen bzw. messen. Gibt die belegte Höhe (inkl. Margins)
// zurück. Harter Zeichenumbruch: Mono-Advance ist konstant, dadurch sind
// Messung und Zeichnung deterministisch identisch.
@(private = "file")
code_block :: proc(app: ^App, b: Msg_Block, x, y, w: f32, draw: bool, id: u64, layer: UI_Layer, sel: ^Rich_Sel = nil) -> f32 {
	fonts := &app.fonts
	lang := lang_lookup(b.lang)
	adv := rl.MeasureTextEx(fonts.mono15, "M", 15, 0).x
	cols := max(8, int((w - 2*CODE_BLOCK_PAD) / adv))

	lines := strings.split_lines(b.body, context.temp_allocator)
	total := 0
	for l in lines {
		total += code_visual_lines(l, cols)
	}

	// Die Kopfleiste gibt es jetzt immer — der Copy-Button gehört an jeden
	// Block, auch an einen ohne Sprach-Tag.
	label := lang != nil ? lang.label : strings.trim_space(b.lang)
	head := CODE_HEAD_H
	pad_top := head + 8
	h := f32(total)*CODE_LINE_H + pad_top + CODE_BLOCK_PAD

	if draw {
		r := rl.Rectangle{x, y + CODE_BLOCK_MARGIN, w, h}
		rrect(r, 8, CODE_BLOCK_BG)
		// Im hellen Theme ist die Blockfläche nur leicht getönt — erst der
		// Rahmen grenzt sie sauber vom Chat ab.
		rrect_lines(r, 8, 1, CODE_BLOCK_BORDER)
		// Kopfleiste: Copy-Button ganz rechts, Sprach-Label links davon
		btn := rl.Rectangle{
			r.x + r.width - 6 - CODE_BTN, r.y + (head - CODE_BTN)/2,
			CODE_BTN, CODE_BTN,
		}
		code_copy_button(app, btn, b.raw, id, layer)
		if label != "" {
			lw := rl.MeasureTextEx(fonts.regular13, tcstr(label), 13, 0).x
			draw_text(fonts.regular13, tcstr(label), {btn.x - lw - 8, r.y + 7}, 13, 0, SYN_COMMENT)
		}
		rl.DrawLineEx({r.x + 1, r.y + head}, {r.x + r.width - 1, r.y + head}, 1, CODE_BLOCK_HEAD)

		hl := Highlighter{lang = lang}
		x0 := r.x + CODE_BLOCK_PAD
		yy := r.y + pad_top
		line_doc := sel != nil ? sel.doc : 0 // Doc-Index des Zeilenanfangs
		for l in lines {
			n := code_visual_lines(l, cols)
			tokens := highlight_line(&hl, l)
			col := 0
			lpos := 0 // Runen seit Zeilenanfang (monoton, unabhängig vom Wrap)
			ty := yy
			for tok in tokens {
				color := syn_color(tok.kind)
				rest := tok.text
				for len(rest) > 0 {
					fit := cols - col
					if fit <= 0 {
						ty += CODE_LINE_H
						col = 0
						fit = cols
					}
					// bis zu `fit` Runen abtrennen (count == Runen im Segment)
					count := 0
					end := len(rest)
					for _, bi in rest {
						if count == fit {
							end = bi
							break
						}
						count += 1
					}
					seg := rest[:end]
					rest = rest[end:]
					seg_r := rl.Rectangle{x0 + f32(col)*adv, ty, f32(count)*adv, CODE_LINE_H}
					if sel != nil && sel.collect == nil {
						sel_register(sel.msg, line_doc + lpos, seg, seg_r, fonts.mono15, 15, true)
						if slo, shi := sel_overlap(sel.msg, line_doc + lpos, count); slo >= 0 {
							rl.DrawRectangleRec({seg_r.x + f32(slo)*adv, seg_r.y, f32(shi - slo)*adv, seg_r.height},
								fade(COL_ACCENT, 0.30))
						}
					}
					draw_text(fonts.mono15, tcstr(seg), {seg_r.x, ty + 2}, 15, 0, color)
					col += count
					lpos += count
				}
			}
			yy += f32(n) * CODE_LINE_H
			line_doc += utf8.rune_count_in_string(l) + 1
		}
	}
	// Doc-Zählung/Collect zentral — läuft in JEDEM Modus (zeichnen, messen,
	// einsammeln) identisch, damit die Selektions-Indizes stabil sind.
	if sel != nil {
		for l in lines {
			if sel.collect != nil {
				strings.write_string(sel.collect, l)
				strings.write_byte(sel.collect, '\n')
			}
			sel.doc += utf8.rune_count_in_string(l) + 1
		}
	}
	return h + 2*CODE_BLOCK_MARGIN
}

// Rich-Text mit Wortumbruch zeichnen bzw. nur messen (draw=false).
// Gibt die benötigte Höhe zurück. Zerlegt die Nachricht in Fließtext-
// Segmente und ```-Code-Blöcke.
//
// `id_base` (die Nachrichten-ID) macht die Copy-Buttons pro Code-Block
// eindeutig und über Frames hinweg stabil — nötig, weil die Zeilen beim
// Scrollen wandern. Beim Messen (draw=false) ist sie egal. `layer` ist der
// Eingabe-Layer der Copy-Buttons (im History-Sheet: .Modal).
// `edited` hängt ein kleines „(bearbeitet)"-Badge an — hinter die letzte
// Textzeile, wenn es dort noch passt, sonst auf eine eigene Zeile.
rich_text :: proc(
	app: ^App,
	text: string,
	x, y, max_width: f32,
	draw: bool,
	id_base: u64 = 0,
	layer := UI_Layer.Base,
	edited := false,
	sel: ^Rich_Sel = nil,
) -> f32 {
	cy := y
	block_i := 0
	last_end_x := f32(-1) // Ende der letzten Textzeile (-1 = Code-Block/nichts)
	for b in split_blocks(text) {
		if b.is_code {
			id := anim_id(.Code_Copy, id_base ~ (u64(block_i) << 32))
			cy += code_block(app, b, x, cy, max_width, draw, id, layer, sel)
			block_i += 1
			last_end_x = -1
		} else {
			h, end_x := rich_text_spans(&app.fonts, b.body, x, cy, max_width, draw, sel)
			cy += h
			last_end_x = end_x
		}
	}
	if cy == y {
		cy += RICH_LINE_H // leere Nachricht
	}
	if edited {
		lbl :: "(bearbeitet)"
		bw := rl.MeasureTextEx(app.fonts.regular13, lbl, 13, 0).x
		if last_end_x >= 0 && last_end_x + 6 + bw <= x + max_width {
			if draw {
				draw_text(app.fonts.regular13, lbl, {last_end_x + 6, cy - RICH_LINE_H + 6}, 13, 0, COL_TEXT_FAINT)
			}
		} else {
			// nach einem Code-Block (oder zu voller Zeile): eigene Zeile
			if draw {
				draw_text(app.fonts.regular13, lbl, {x, cy + 2}, 13, 0, COL_TEXT_FAINT)
			}
			cy += 20
		}
	}
	return cy - y
}

// Fließtext-Segment (Slack-Markdown) zeichnen bzw. messen. Gibt neben der
// Höhe auch das x-Ende der letzten Zeile zurück (fürs „bearbeitet"-Badge).
@(private = "file")
rich_text_spans :: proc(fonts: ^Fonts, text: string, x, y, max_width: f32, draw: bool, sel: ^Rich_Sel = nil) -> (f32, f32) {
	cy := y
	end_x := x
	it := text
	for line in strings.split_lines_iterator(&it) {
		spans := parse_spans(line)
		cx := x
		if len(spans) == 0 {
			cy += RICH_LINE_H // Leerzeile
			end_x = x
			if sel != nil {
				if sel.collect != nil {
					strings.write_byte(sel.collect, '\n')
				}
				sel.doc += 1
			}
			continue
		}
		for s in spans {
			font := span_font(fonts, s)
			size := span_size(s)
			// wortweise umbrechen; Whitespace bleibt am Wortende kleben
			rest := s.text
			first := true
			for len(rest) > 0 {
				// nächstes Wort inkl. nachfolgender Leerzeichen abtrennen
				wend := strings.index_byte(rest, ' ')
				word: string
				if wend < 0 {
					word = rest
					rest = ""
				} else {
					j := wend
					for j < len(rest) && rest[j] == ' ' {
						j += 1
					}
					word = rest[:j]
					rest = rest[j:]
				}
				cword := strings.clone_to_cstring(word, context.temp_allocator)
				ww := rl.MeasureTextEx(font, cword, size, 0).x
				// Chip-Innenabstand am Span-Anfang/-Ende zählt zur Breite,
				// damit Code-Chips Luft zu den Nachbarbuchstaben haben.
				lead := s.code && first ? CODE_PAD : 0
				trail := s.code && len(rest) == 0 ? CODE_PAD : 0
				if cx > x && cx + lead + ww + trail > x + max_width {
					cx = x
					cy += RICH_LINE_H
				}
				wn := utf8.rune_count_in_string(word)
				if draw {
					hl_lo, hl_hi := -1, -1
					if sel != nil && sel.collect == nil {
						sel_register(sel.msg, sel.doc, word, {cx + lead, cy, ww, RICH_LINE_H}, font, size, false)
						hl_lo, hl_hi = sel_overlap(sel.msg, sel.doc, wn)
					}
					draw_fragment(fonts, s, word, cx, cy, ww, lead, trail, hl_lo, hl_hi)
				}
				if sel != nil {
					if sel.collect != nil {
						strings.write_string(sel.collect, word)
					}
					sel.doc += wn
				}
				cx += lead + ww + trail
				first = false
			}
		}
		cy += RICH_LINE_H
		end_x = cx
		if sel != nil {
			if sel.collect != nil {
				strings.write_byte(sel.collect, '\n')
			}
			sel.doc += 1
		}
	}
	return cy - y, end_x
}

rich_text_height :: proc(app: ^App, text: string, max_width: f32, edited := false) -> f32 {
	return rich_text(app, text, 0, 0, max_width, false, edited = edited)
}
