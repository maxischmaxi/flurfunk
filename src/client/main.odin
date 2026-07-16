package main

// Einstiegspunkt: Fenster, Main-Loop (Netzwerk pollen → UI zeichnen).

import "core:fmt"

import rl "vendor:raylib"

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.InitWindow(1360, 850, "ping")
	defer rl.CloseWindow()
	rl.SetWindowMinSize(960, 600)
	rl.SetTargetFPS(240) // Obergrenze; VSync taktet real
	rl.SetExitKey(.KEY_NULL)

	app: App
	app_init(&app)
	defer sys_theme_stop()

	title_unread := -1

	for !rl.WindowShouldClose() {
		app.dt = min(rl.GetFrameTime(), 1.0/20.0) // Ruckler nicht überspringen lassen
		app_poll(&app)
		theme_frame(&app) // Farben für diesen Frame festlegen (vor ClearBackground)

		// Fenstertitel mit Unread-Zähler
		unread := app_total_unread(&app)
		if unread != title_unread {
			title_unread = unread
			if unread > 0 {
				rl.SetWindowTitle(fmt.ctprintf("(%d) ping", unread))
			} else {
				rl.SetWindowTitle("ping")
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(COL_CHAT_BG)
		// UI-Zoom: Geometrie über die Kamera skalieren; die Fonts sind in
		// physischer Größe geladen → Text bleibt 1:1 scharf.
		rl.BeginMode2D(rl.Camera2D{zoom = g_scale})
		ui_draw(&app)
		rl.EndMode2D()
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}
