package main

// Browser-artige Maus-Selektion über die Chat-Nachrichten (inkl. Code-
// Blöcke): ziehen zum Markieren, Doppelklick fürs Wort, Strg+C kopiert.
//
// Funktionsweise (Immediate-Mode): Während rich_text die Nachrichten des
// aktiven Channels zeichnet, registriert es jedes Text-Fragment als
// „Run" (Screen-Rect + Position im Render-Dokument der Nachricht). Die
// Selektion selbst ist layout-stabil als (message_id, Runen-Index) im
// Render-Dokument verankert — das ist der sichtbare Text der Nachricht
// (Markdown-Marker entfernt, Code-Tabs expandiert), dessen Indizes sich
// beim Umbruch/Scrollen/Zoomen nicht verschieben. Kopiert wird, was man
// sieht — exakt wie im Browser.

import "core:strings"
import "core:unicode/utf8"

import rl "vendor:raylib"

// Ein gezeichnetes Text-Fragment (gültig nur für den aktuellen Frame).
Chat_Run :: struct {
	msg:   u64, // Nachrichten-ID (monoton → Dokumentordnung)
	start: int, // Runen-Index im Render-Dokument der Nachricht
	n:     int,
	text:  string, // temp-alloziert (Frame-Lebensdauer)
	rect:  rl.Rectangle,
	font:  rl.Font,
	size:  f32,
	mono:  bool, // konstanter Advance → Hit/Highlight ohne Messungen
}

g_runs: [dynamic]Chat_Run

g_sel: struct {
	active:   bool, // Selektion existiert (a != b)
	dragging: bool,
	conn:     ^Server_Conn,
	channel:  u64,
	a_msg:    u64, // Anker
	a_ch:     int,
	b_msg:    u64, // bewegliches Ende
	b_ch:     int,
	// Zonen, in denen kein Drag starten darf (Hover-Panel über dem Text)
	block:    rl.Rectangle,
	block_on: bool,
}

// Pro Frame (ui_begin_frame): Run-Liste und Block-Zone zurücksetzen.
chat_sel_frame :: proc() {
	clear(&g_runs)
	g_sel.block_on = false
}

sel_clear :: proc() {
	g_sel.active = false
	g_sel.dragging = false
	g_sel.conn = nil
	g_sel.channel = 0
}

// Panel-Zone anmelden — dort startet kein Text-Drag (der ⋮-Button liegt
// über dem Text der vorigen Zeile).
sel_block :: proc(r: rl.Rectangle) {
	g_sel.block = r
	g_sel.block_on = true
}

sel_register :: proc(msg: u64, start: int, text: string, rect: rl.Rectangle, font: rl.Font, size: f32, mono: bool) {
	n := utf8.rune_count_in_string(text)
	if n == 0 {
		return
	}
	append(&g_runs, Chat_Run{msg, start, n, text, rect, font, size, mono})
}

// --- Ordnung & Überlappung ---

@(private = "file")
sel_pos_less :: proc(m1: u64, c1: int, m2: u64, c2: int) -> bool {
	return m1 < m2 || (m1 == m2 && c1 < c2)
}

// Normalisierte Selektion (lo vor hi).
@(private = "file")
sel_norm :: proc() -> (lm: u64, lc: int, hm: u64, hc: int) {
	if sel_pos_less(g_sel.a_msg, g_sel.a_ch, g_sel.b_msg, g_sel.b_ch) {
		return g_sel.a_msg, g_sel.a_ch, g_sel.b_msg, g_sel.b_ch
	}
	return g_sel.b_msg, g_sel.b_ch, g_sel.a_msg, g_sel.a_ch
}

// Überlappung der aktiven Selektion mit einem Fragment [start, start+n)
// einer Nachricht — als relative Runen-Range (-1 = keine).
sel_overlap :: proc(msg: u64, start, n: int) -> (rel_lo, rel_hi: int) {
	if !g_sel.active {
		return -1, -1
	}
	lm, lc, hm, hc := sel_norm()
	if msg < lm || msg > hm {
		return -1, -1
	}
	lo := msg == lm ? lc : 0
	hi := msg == hm ? hc : start + n // Nachricht liegt ganz innen → alles
	a := max(lo - start, 0)
	b := min(hi - start, n)
	if a >= b {
		return -1, -1
	}
	return a, b
}

// Runen-korrekt einen Substring [from, to) (Runen-Indizes) schneiden.
rune_slice :: proc(s: string, from, to: int) -> string {
	if from >= to {
		return ""
	}
	b0 := -1
	b1 := len(s)
	i := 0
	for _, bi in s {
		if i == from {
			b0 = bi
		}
		if i == to {
			b1 = bi
			break
		}
		i += 1
	}
	if b0 < 0 {
		return "" // from liegt hinter dem letzten Zeichen
	}
	return s[b0:b1]
}

// Breite der ersten `n` Runen eines Fragments.
sel_prefix_w :: proc(run: Chat_Run, n: int) -> f32 {
	if run.mono {
		return f32(n) * (run.rect.width / f32(run.n))
	}
	if n <= 0 {
		return 0
	}
	if n >= run.n {
		return run.rect.width
	}
	return rl.MeasureTextEx(run.font, tcstr(rune_slice(run.text, 0, n)), run.size, 0).x
}

// --- Hit-Testing ---

@(private = "file")
Sel_Hit :: struct {
	ok:  bool,
	msg: u64,
	ch:  int,
}

// Wie streng ein Punkt einem Text-Fragment zugeordnet wird:
//   Exact  — praktisch auf dem Text (I-Beam-Anzeige)
//   Start  — Drag-Beginn: im y-Band einer Zeile; rechts vom Zeilenende
//            zählt der Klick wie im Browser als „am Zeilenende“
//   Extend — laufender Drag: nächstgelegene Zeile, egal wo
@(private = "file")
Sel_Hit_Mode :: enum {
	Exact,
	Start,
	Extend,
}

@(private = "file")
sel_hit :: proc(m: rl.Vector2, mode: Sel_Hit_Mode) -> Sel_Hit {
	best := -1
	best_score := f32(1e30)
	for run, i in g_runs {
		dy := f32(0)
		if m.y < run.rect.y {
			dy = run.rect.y - m.y
		} else if m.y > run.rect.y + run.rect.height {
			dy = m.y - (run.rect.y + run.rect.height)
		}
		left := m.x < run.rect.x // Maus links vom Fragment?
		dx := f32(0)
		if left {
			dx = run.rect.x - m.x
		} else if m.x > run.rect.x + run.rect.width {
			dx = m.x - (run.rect.x + run.rect.width)
		}
		switch mode {
		case .Exact:
			if dy > 0 || dx > 4 {
				continue
			}
		case .Start:
			// im Zeilen-Band; links nur knapp daneben (im Gutter liegen
			// klickbare Avatare/Namen), rechts beliebig weit
			if dy > 2 || (left && dx > 4) {
				continue
			}
		case .Extend:
		}
		score := dy*4096 + dx
		if score < best_score {
			best_score = score
			best = i
		}
	}
	if best < 0 {
		return {}
	}
	run := g_runs[best]

	// Runen-Index innerhalb des Fragments
	rel := m.x - run.rect.x
	idx := run.n
	if rel <= 0 {
		idx = 0
	} else if rel < run.rect.width {
		if run.mono {
			adv := run.rect.width / f32(run.n)
			idx = clamp(int(rel/adv + 0.5), 0, run.n)
		} else {
			x := f32(0)
			idx = run.n
			ri := 0
			for r in run.text {
				s, _ := utf8.runes_to_string([]rune{r}, context.temp_allocator)
				w := rl.MeasureTextEx(run.font, tcstr(s), run.size, 0).x
				if rel < x + w/2 {
					idx = ri
					break
				}
				x += w
				ri += 1
			}
		}
	}
	return {true, run.msg, run.start + idx}
}

// --- Interaktion (pro Frame nach dem Zeichnen der Liste) ---

chat_sel_update :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, list: rl.Rectangle) {
	// Kontextwechsel (anderer Channel/Server) → Selektion verfällt
	if (g_sel.active || g_sel.dragging) && (g_sel.conn != c || g_sel.channel != cs.ch.id) {
		sel_clear()
	}
	if app.ui.layer != .Base {
		g_sel.dragging = false
		return
	}
	blocked := g_sel.block_on && rl.CheckCollisionPointRec(app.ui.mouse, g_sel.block)
	over_list := rl.CheckCollisionPointRec(app.ui.mouse, list)

	exact := sel_hit(app.ui.mouse, .Exact)
	if exact.ok && !blocked && !g_sel.dragging {
		app.ui.cursor = .IBEAM
	}

	if app.ui.clicked && !blocked {
		start := sel_hit(app.ui.mouse, .Start)
		if start.ok && over_list {
			if app.ui.triple_click {
				sel_select_line(app, c, cs, start)
			} else if app.ui.double_click {
				sel_select_word(app, c, cs, start)
			} else {
				g_sel.dragging = true
				g_sel.conn = c
				g_sel.channel = cs.ch.id
				g_sel.a_msg, g_sel.a_ch = start.msg, start.ch
				g_sel.b_msg, g_sel.b_ch = start.msg, start.ch
				g_sel.active = false
			}
		} else if g_sel.active {
			sel_clear() // Klick ins Leere/anderswohin hebt die Markierung auf
		}
	}

	if g_sel.dragging {
		if app.ui.mouse_down {
			if h := sel_hit(app.ui.mouse, .Extend); h.ok {
				g_sel.b_msg, g_sel.b_ch = h.msg, h.ch
			}
			g_sel.active = g_sel.a_msg != g_sel.b_msg || g_sel.a_ch != g_sel.b_ch
			app.ui.cursor = .IBEAM

			// Am Listenrand weiterziehen → automatisch scrollen
			if app.ui.mouse.y > list.y + list.height - 12 {
				cs.scroll.target += 900 * app.dt
				cs.scroll.activity = 1
			} else if app.ui.mouse.y < list.y + 12 {
				cs.scroll.target -= 900 * app.dt
				cs.scroll.activity = 1
				cs.stick_bottom = false
			}
		} else {
			g_sel.dragging = false
			if !g_sel.active {
				sel_clear()
			}
		}
	}
}

// Doppelklick: Wort unter dem Cursor markieren.
@(private = "file")
sel_select_word :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, h: Sel_Hit) {
	for &m in cs.messages {
		if m.id != h.msg {
			continue
		}
		plain := msg_render_text(app, m.text)
		runes := utf8.string_to_runes(plain, context.temp_allocator)
		if len(runes) == 0 {
			return
		}
		i := clamp(h.ch, 0, len(runes) - 1)
		// Klick direkt HINTER einem Wort (Zeilenende, vor Leerzeichen)
		// gehört zum Wort davor — wie im Browser.
		if !is_word_rune(runes[i]) && i > 0 && is_word_rune(runes[i-1]) {
			i -= 1
		}
		lo, hi := i, i + 1
		if is_word_rune(runes[i]) {
			for lo > 0 && is_word_rune(runes[lo-1]) {
				lo -= 1
			}
			for hi < len(runes) && is_word_rune(runes[hi]) {
				hi += 1
			}
		}
		g_sel.conn = c
		g_sel.channel = cs.ch.id
		g_sel.a_msg, g_sel.a_ch = h.msg, lo
		g_sel.b_msg, g_sel.b_ch = h.msg, hi
		g_sel.active = true
		g_sel.dragging = false
		return
	}
}

// Dreifachklick: die ganze logische Zeile markieren (zwischen \n im
// Render-Dokument — bei umgebrochenem Text also den kompletten Absatz,
// wie im Browser).
@(private = "file")
sel_select_line :: proc(app: ^App, c: ^Server_Conn, cs: ^Channel_State, h: Sel_Hit) {
	for &m in cs.messages {
		if m.id != h.msg {
			continue
		}
		plain := msg_render_text(app, m.text)
		runes := utf8.string_to_runes(plain, context.temp_allocator)
		if len(runes) == 0 {
			return
		}
		i := clamp(h.ch, 0, len(runes) - 1)
		lo, hi := i, i
		for lo > 0 && runes[lo-1] != '\n' {
			lo -= 1
		}
		for hi < len(runes) && runes[hi] != '\n' {
			hi += 1
		}
		if lo >= hi {
			return // leere Zeile
		}
		g_sel.conn = c
		g_sel.channel = cs.ch.id
		g_sel.a_msg, g_sel.a_ch = h.msg, lo
		g_sel.b_msg, g_sel.b_ch = h.msg, hi
		g_sel.active = true
		g_sel.dragging = false
		return
	}
}

// --- Kopieren ---

// Render-Dokument einer Nachricht: derselbe Code-Pfad wie das Zeichnen
// (rich_text im Collect-Modus) — Indizes stimmen daher garantiert überein.
msg_render_text :: proc(app: ^App, text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	rs := Rich_Sel{collect = &sb}
	rich_text(app, text, 0, 0, 100_000, false, sel = &rs)
	return strings.to_string(sb)
}

// Strg+C: markierten Chat-Text in die Zwischenablage. false, wenn es
// nichts zu kopieren gab (Aufrufer kann anderweitig reagieren).
sel_copy :: proc(app: ^App) -> bool {
	if !g_sel.active || g_sel.conn == nil {
		return false
	}
	cs := conn_find_channel(g_sel.conn, g_sel.channel)
	if cs == nil {
		return false
	}
	lm, lc, hm, hc := sel_norm()
	sb := strings.builder_make(context.temp_allocator)
	first := true
	for &m in cs.messages {
		if m.id < lm || m.id > hm {
			continue
		}
		plain := msg_render_text(app, m.text)
		n := utf8.rune_count_in_string(plain)
		from := m.id == lm ? clamp(lc, 0, n) : 0
		to := m.id == hm ? clamp(hc, 0, n) : n
		if !first {
			strings.write_byte(&sb, '\n')
		}
		part := rune_slice(plain, from, to)
		// Render-Dokumente enden mit \n — am Schnittende nicht mitkopieren
		strings.write_string(&sb, strings.trim_suffix(part, "\n"))
		first = false
	}
	rl.SetClipboardText(tcstr(strings.to_string(sb)))
	return true
}

// Strg+C-Weiche: Eingabefeld-Selektionen kopieren sich selbst (ti_update);
// nur wenn dort nichts markiert ist, gehört das C der Chat-Selektion.
sel_try_copy :: proc(app: ^App, c: ^Server_Conn) {
	if !g_sel.active || app.modal != .None {
		return
	}
	#partial switch app.ui.focus {
	case .Message:
		if ti_has_sel(&c.msg_input) {
			return
		}
	case .Edit:
		if ti_has_sel(&c.edit_input) {
			return
		}
	}
	sel_copy(app)
}
