package main

// Desktop-Farbschema erkennen (für Theme_Mode.System).
//
// Es gibt keine portable API dafür — jedes OS wird über ein Bordmittel
// befragt (gdbus/gsettings, defaults, reg). Findet sich nichts, gilt „hell".
//
// Einmal synchron beim Start (sonst startet die App hell und springt beim
// ersten Poll um), danach in einem Hintergrund-Thread: so folgt die App
// auch einem Wechsel zur Blauen Stunde, ohne Neustart. Gepollt wird nur,
// solange „System" gewählt ist.

import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

@(private = "file")
SYS_POLL_INTERVAL :: 4 * time.Second

@(private = "file")
SYS_POLL_SLICE :: 100 * time.Millisecond

@(private = "file")
g_sys_dark: bool // zuletzt erkannt

@(private = "file")
g_sys_want: bool // pollen? (nur bei Theme_Mode.System)

@(private = "file")
g_sys_stop: bool

sys_theme_is_dark :: proc() -> bool {
	return sync.atomic_load(&g_sys_dark)
}

// Einmal synchron erkennen und den Poll-Thread starten.
sys_theme_start :: proc(follow: bool) {
	sync.atomic_store(&g_sys_dark, sys_theme_detect())
	sync.atomic_store(&g_sys_want, follow)
	thread.run(sys_theme_poll)
}

// Vom Main-Thread bei jedem Moduswechsel: nur „System" muss folgen.
sys_theme_follow :: proc(follow: bool) {
	sync.atomic_store(&g_sys_want, follow)
}

sys_theme_stop :: proc() {
	sync.atomic_store(&g_sys_stop, true)
}

@(private = "file")
sys_theme_poll :: proc() {
	for !sync.atomic_load(&g_sys_stop) {
		// in Scheiben schlafen, damit das Beenden nicht am Intervall hängt
		for slept := time.Duration(0); slept < SYS_POLL_INTERVAL; slept += SYS_POLL_SLICE {
			if sync.atomic_load(&g_sys_stop) {
				return
			}
			time.sleep(SYS_POLL_SLICE)
		}
		if sync.atomic_load(&g_sys_want) {
			sync.atomic_store(&g_sys_dark, sys_theme_detect())
		}
		free_all(context.temp_allocator)
	}
}

// Kommando ausführen und stdout einsammeln. Fehlt das Programm oder endet
// es mit Fehler, ist ok=false — der Aufrufer probiert die nächste Quelle.
@(private = "file")
run_cmd :: proc(cmd: []string) -> (out: string, ok: bool) {
	state, sout, _, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return "", false
	}
	return string(sout), true
}

when ODIN_OS == .Darwin {

	// Im hellen Modus existiert der Schlüssel gar nicht (defaults endet
	// dann mit Exit-Code != 0) — genau das ist das Signal für „hell".
	@(private = "file")
	sys_theme_detect :: proc() -> bool {
		out, ok := run_cmd({"defaults", "read", "-g", "AppleInterfaceStyle"})
		return ok && strings.contains(out, "Dark")
	}

} else when ODIN_OS == .Windows {

	@(private = "file")
	sys_theme_detect :: proc() -> bool {
		// AppsUseLightTheme: 0x0 = dunkel, 0x1 = hell
		out, ok := run_cmd({
			"reg", "query",
			`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`,
			"/v", "AppsUseLightTheme",
		})
		if !ok {
			return false
		}
		if i := strings.index(out, "0x"); i >= 0 && i + 2 < len(out) {
			return out[i + 2] == '0'
		}
		return false
	}

} else {

	// Linux/BSD. Reihenfolge: freedesktop-Portal (desktop-übergreifend),
	// dann GNOME direkt, dann KDE. Fehlt ein Werkzeug, schlägt run_cmd
	// fehl und wir fallen einfach zur nächsten Quelle durch.
	@(private = "file")
	sys_theme_detect :: proc() -> bool {
		// 1. XDG-Desktop-Portal: der Standard, spricht GNOME, KDE und
		//    wlroots-Desktops gleichermaßen an.
		//    Antwort: (<<uint32 1>>,) — 1 = dunkel, 2 = hell, 0 = egal
		if out, ok := run_cmd({
			"gdbus", "call", "--session",
			"--dest", "org.freedesktop.portal.Desktop",
			"--object-path", "/org/freedesktop/portal/desktop",
			"--method", "org.freedesktop.portal.Settings.Read",
			"org.freedesktop.appearance", "color-scheme",
		}); ok {
			if i := strings.index(out, "uint32 "); i >= 0 && i + 7 < len(out) {
				switch out[i + 7] {
				case '1':
					return true
				case '2':
					return false
				}
			}
		}

		// 2. GNOME/GTK direkt
		if out, ok := run_cmd({"gsettings", "get", "org.gnome.desktop.interface", "color-scheme"}); ok {
			v := strings.trim_space(out)
			if strings.contains(v, "dark") {
				return true
			}
			if strings.contains(v, "light") {
				return false
			}
			// 'default' → keine Aussage, weiter beim Theme-Namen
		}
		if out, ok := run_cmd({"gsettings", "get", "org.gnome.desktop.interface", "gtk-theme"}); ok {
			if strings.contains(lower(strings.trim_space(out)), "dark") {
				return true
			}
		}

		// 3. KDE Plasma: Farbschema steht in kdeglobals
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			path := strings.concatenate({home, "/.config/kdeglobals"}, context.temp_allocator)
			if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
				low := lower(string(data))
				if i := strings.index(low, "colorscheme="); i >= 0 {
					line := low[i:]
					if j := strings.index_byte(line, '\n'); j >= 0 {
						line = line[:j]
					}
					return strings.contains(line, "dark")
				}
			}
		}
		return false
	}

	@(private = "file")
	lower :: proc(s: string) -> string {
		return strings.to_lower(s, context.temp_allocator)
	}
}
