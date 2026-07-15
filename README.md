# ping

Selbst-gehosteter Team-Chat (Slack-Alternative). Server und Client sind
komplett in [Odin](https://odin-lang.org) geschrieben, der Client rendert
mit raylib (`vendor:raylib`). Monorepo: Server, Client und gemeinsames
Protokoll-Package liegen hier zusammen.

## Idee

Ein Unternehmen startet den Server selbst (eigene Hardware, eigene Daten).
Mitarbeiter verbinden ihren Client einfach mit `host:port`. Der Client kann
mit mehreren Servern gleichzeitig verbunden sein — visuell wie die
Workspace-Leiste in Slack.

Wer sich als **erster** Nutzer mit einem frischen Server verbindet, wird im
Registrierungsprozess automatisch **Administrator** und richtet den Server
ein (Servername).

## Features (MVP)

- Channels (invite-only): erstellen (Umlaute erlaubt, z. B. `#büro-küche`),
  Nutzer einladen und entfernen, verlassen; Admin/Ersteller können Kanäle
  löschen (Rechtsklick auf den Kanal → Kontextmenü)
- Direktnachrichten (DMs)
- Multi-Server-Client (Server-Rail, Sidebar, Chat, Eingabe) im eigenen,
  hellen Design: Zinc-Neutrale + „Sunset“-Akzent aus dem Marken-Logo
- Eingabefeld ist reiner Plaintext — abgeschickte Nachrichten werden aber als
  Rich Text gerendert: `*fett*`, `_kursiv_`, `~durchgestrichen~`, `` `code` ``
- Multiline-Code-Blöcke mit ```` ```sprache ```` und Syntax-Highlighting
  (u. a. TypeScript/JavaScript, Python, Rust, Go, C/C++/C#, Java, Kotlin,
  Swift, PHP, Ruby, Lua, Odin, Zig, SQL, Shell, JSON, YAML, TOML, HTML/XML,
  CSS, Dockerfile, Makefile)
- UI-Zoom per `Strg` `+`/`−`/`0` (wird gespeichert; Text bleibt scharf)
- Ungelesen-Badges, Online-Presence, „Neu“-Trennlinie, Tages-Trenner
- Flüssige UI: Smooth Scrolling, animierte Hover-/Fokus-Zustände, Toasts,
  automatisches Nachladen älterer Nachrichten, Auto-Reconnect mit Countdown

### Bedienung & Shortcuts

| Shortcut | Wirkung |
|----------|---------|
| `Tab` / `Shift+Tab` | Tastatur-Navigation durch alle Bedienelemente (wie im Browser); `Enter`/`Leertaste` aktiviert |
| `Strg` `+` / `−` / `0` | UI vergrößern / verkleinern / zurücksetzen |
| `Strg+K` | Schnellsuche: zu Kanal oder Person springen |
| `Alt+↑ / Alt+↓` | vorheriger / nächster Kanal |
| `Strg+1…9` | Server wechseln |
| `Enter` / `Shift+Enter` | senden / neue Zeile |
| `Esc` | Modal schließen, sonst ans Chat-Ende springen |
| `Bild↑ / Bild↓` | im Verlauf blättern |
| `Strg+A/C/X/V`, Shift+Pfeile, Doppelklick | Textauswahl & Zwischenablage im Eingabefeld |
| `↑ / ↓` im Eingabefeld | zwischen den Zeilen navigieren; bei viel Inhalt scrollt das Feld (auch per Mausrad/Scrollbar) |

Klick auf Avatar oder Namen einer Nachricht öffnet die Direktnachricht mit
der Person. Der Zähler im Kanal-Header öffnet die Mitgliederverwaltung.
Rechtsklick auf einen Kanal in der Sidebar öffnet das Kontextmenü
(als gelesen markieren, Mitglieder, verlassen, löschen).

## Bauen

Voraussetzung: Odin (getestet mit `dev-2026-07`) im `PATH`.

```sh
./build.sh          # Release → bin/ping-server, bin/ping
./build.sh debug    # Debug-Build
```

## Starten

```sh
# Server (Unternehmen):
bin/ping-server -port 7788 -data ./ping-data

# Client (Mitarbeiter):
bin/ping
```

Beim ersten Client-Start gibt man `host:port` des Servers an. Weitere Server
lassen sich später über das `+` in der linken Server-Leiste hinzufügen.
Client-Konfiguration (Server, Sitzungs-Tokens, Geräteschlüssel) liegt unter
`~/.config/ping/client.json`.

### Server-Flags

| Flag | Default | Bedeutung |
|------|---------|-----------|
| `-port <n>` | `7788` | TCP-Port |
| `-data <dir>` | `./ping-data` | Datenverzeichnis |
| `-key <pfad>` | `<data>/master.key` | Ort des Master-Keys (z. B. separater Mount/USB-Stick) |

## Sicherheitsmodell

Ziel: Wer den Server-Datenbestand in die Hände bekommt (Backup-Leak,
kompromittierte Platte, neugieriger Hoster), kann **keine einzige Nachricht
lesen** — vergleichbar mit Telegrams Cloud-Chats, bei denen Nachrichten
serverseitig verschlüsselt lagern.

- **Transport:** Noise-Protokoll `XX` (X25519 + ChaCha20-Poly1305 + BLAKE2s,
  `core:crypto/noise`). Der Client pinnt den statischen Server-Schlüssel beim
  ersten Verbinden (TOFU, wie SSH) und schlägt Alarm, wenn er sich ändert.
  Es geht also nie Klartext übers Netz, auch ohne TLS/Zertifikate.
- **Speicherung (at rest):** Jede Nachricht wird mit XChaCha20-Poly1305 unter
  einem zufälligen **Channel-Key** verschlüsselt gespeichert. Channel-Keys
  liegen nur „gewrappt“ (verschlüsselt unter dem **Master-Key**) auf der
  Platte. Der Master-Key (`master.key`, 32 Byte, `0600`) kann per `-key` auf
  ein separates Medium gelegt werden — dann sind Datenverzeichnis und
  Schlüssel physisch getrennt.
- **Passwörter:** Argon2id (64 MiB, 3 Passes) mit zufälligem Salt.
- **Sitzungen:** zufällige 256-Bit-Tokens.

Bewusste MVP-Grenze: Der laufende Server kann Nachrichten entschlüsseln
(nötig für History an neue Channel-Mitglieder) — wie bei Slack/Telegram-
Cloud-Chats. Echtes Ende-zu-Ende (Client-seitige Schlüssel) ist als Ausbau
möglich, weil das Protokoll die Nachrichtentexte bereits als opake Strings
behandelt.

## Aufbau des Repos

```
src/shared/   Wire-Protokoll (JSON), Framing, Noise-Secure-Channel
src/server/   Server: Auth, Channels/DMs, verschlüsselte Persistenz
src/client/   raylib-Client: Slack-Layout, Multi-Server, Rich-Text-Rendering
tests/smoke/  Headless-Protokolltest (läuft gegen einen frischen Server)
assets/fonts/ Inter + Liberation Mono (werden ins Client-Binary eingebettet)
```

## Protokoll-Smoke-Test

```sh
odin build tests/smoke -out:bin/smoke
bin/ping-server -port 7999 -data /tmp/ping-test &   # frisches Datenverzeichnis!
timeout 30 bin/smoke 127.0.0.1:7999
```
