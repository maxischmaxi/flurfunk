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
@(private = "file")
draw_fragment :: proc(fonts: ^Fonts, s: Span, text: string, x, y, w, lead, trail: f32) {
	ctext := strings.clone_to_cstring(text, context.temp_allocator)
	font := span_font(fonts, s)
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

// Ein Segment einer Nachricht: Fließtext oder Code-Block.
Msg_Block :: struct {
	is_code: bool,
	lang:    string, // roher Tag hinter ```
	body:    string,
}

@(private = "file")
expand_tabs :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\t", "    ", context.temp_allocator)
	return out
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
		append(blocks, Msg_Block{body = strings.join(cur[:], "\n", context.temp_allocator)})
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
				body := strings.trim_space(tag[:len(tag)-3])
				append(&blocks, Msg_Block{is_code = true, body = expand_tabs(body)})
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
			body := expand_tabs(strings.join(code[:], "\n", context.temp_allocator))
			append(&blocks, Msg_Block{is_code = true, lang = tag, body = body})
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

// Code-Block zeichnen bzw. messen. Gibt die belegte Höhe (inkl. Margins)
// zurück. Harter Zeichenumbruch: Mono-Advance ist konstant, dadurch sind
// Messung und Zeichnung deterministisch identisch.
@(private = "file")
code_block :: proc(fonts: ^Fonts, b: Msg_Block, x, y, w: f32, draw: bool) -> f32 {
	lang := lang_lookup(b.lang)
	adv := rl.MeasureTextEx(fonts.mono15, "M", 15, 0).x
	cols := max(8, int((w - 2*CODE_BLOCK_PAD) / adv))

	lines := strings.split_lines(b.body, context.temp_allocator)
	total := 0
	for l in lines {
		total += code_visual_lines(l, cols)
	}

	label := lang != nil ? lang.label : strings.trim_space(b.lang)
	head := label != "" ? f32(26) : f32(0)
	pad_top := head > 0 ? head + 8 : CODE_BLOCK_PAD
	h := f32(total)*CODE_LINE_H + pad_top + CODE_BLOCK_PAD

	if draw {
		r := rl.Rectangle{x, y + CODE_BLOCK_MARGIN, w, h}
		rrect(r, 8, CODE_BLOCK_BG)
		if head > 0 {
			lw := rl.MeasureTextEx(fonts.regular13, tcstr(label), 13, 0).x
			draw_text(fonts.regular13, tcstr(label), {r.x + r.width - lw - 12, r.y + 7}, 13, 0, SYN_COMMENT)
			rl.DrawLineEx({r.x + 1, r.y + head}, {r.x + r.width - 1, r.y + head}, 1, CODE_BLOCK_HEAD)
		}

		hl := Highlighter{lang = lang}
		x0 := r.x + CODE_BLOCK_PAD
		yy := r.y + pad_top
		for l in lines {
			n := code_visual_lines(l, cols)
			tokens := highlight_line(&hl, l)
			col := 0
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
					draw_text(fonts.mono15, tcstr(seg), {x0 + f32(col)*adv, ty + 2}, 15, 0, color)
					col += count
				}
			}
			yy += f32(n) * CODE_LINE_H
		}
	}
	return h + 2*CODE_BLOCK_MARGIN
}

// Rich-Text mit Wortumbruch zeichnen bzw. nur messen (draw=false).
// Gibt die benötigte Höhe zurück. Zerlegt die Nachricht in Fließtext-
// Segmente und ```-Code-Blöcke.
rich_text :: proc(fonts: ^Fonts, text: string, x, y, max_width: f32, draw: bool) -> f32 {
	cy := y
	for b in split_blocks(text) {
		if b.is_code {
			cy += code_block(fonts, b, x, cy, max_width, draw)
		} else {
			cy += rich_text_spans(fonts, b.body, x, cy, max_width, draw)
		}
	}
	if cy == y {
		cy += RICH_LINE_H // leere Nachricht
	}
	return cy - y
}

// Fließtext-Segment (Slack-Markdown) zeichnen bzw. messen.
@(private = "file")
rich_text_spans :: proc(fonts: ^Fonts, text: string, x, y, max_width: f32, draw: bool) -> f32 {
	cy := y
	it := text
	for line in strings.split_lines_iterator(&it) {
		spans := parse_spans(line)
		cx := x
		if len(spans) == 0 {
			cy += RICH_LINE_H // Leerzeile
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
				if draw {
					draw_fragment(fonts, s, word, cx, cy, ww, lead, trail)
				}
				cx += lead + ww + trail
				first = false
			}
		}
		cy += RICH_LINE_H
	}
	return cy - y
}

rich_text_height :: proc(fonts: ^Fonts, text: string, max_width: f32) -> f32 {
	return rich_text(fonts, text, 0, 0, max_width, false)
}
