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
- Eigene Nachrichten nachträglich bearbeiten: Hover über die Nachricht →
  Aktions-Panel → „⋮“ → „Nachricht bearbeiten“. Möglich innerhalb 1 Minute
  nach dem Senden (bzw. dem letzten Edit — jeder Edit startet die Frist
  neu), maximal 3-mal pro Nachricht; wer rechtzeitig in den
  Bearbeitungsmodus geht, darf darin beliebig lange tippen (✓ speichert,
  ✕ oder Esc bricht ab). Bearbeitete Nachrichten tragen ein
  „(bearbeitet)“-Badge, und „History anzeigen“ öffnet ein von rechts
  hereinfahrendes Sheet mit allen Versionen samt Zeitstempeln
- **Voice-Calls** in jedem Kanal und jeder DM (Kopfhörer-Button im
  Header). Alle Kanal-Mitglieder können beitreten — läuft ein Call, zeigt
  ein Banner im Kanal „Voice-Call · N Teilnehmer · Beitreten“, und wer
  gerade in einem Call ist, trägt überall ein Kopfhörer-Symbol. Das
  Call-Panel sitzt unten in der Seitenleiste (Teilnehmer mit
  Speaking-Glow, eigener Pegel, Mute, Auflegen, Latenz-Anzeige) und lässt
  sich als frei verschiebbares schwebendes Fenster ausgliedern, sodass
  die App parallel nutzbar bleibt. Calls haben bewusst keinen eigenen
  Chat. Technik: Opus 48 kHz (VBR ~32 kbps, in-band FEC, PLC, DTX) über
  verschlüsseltes UDP, RNNoise-Rauschunterdrückung + VAD-Gate (Tastatur,
  Lüfter & Co. werden gar nicht erst gesendet), Speex-Echo-Cancellation,
  adaptiver Jitter-Buffer — bei Stille fließt praktisch kein Byte
- Multi-Server-Client (Server-Rail, Sidebar, Chat, Eingabe) im eigenen
  Design: Zinc-Neutrale + „Sunset“-Akzent aus dem Marken-Logo
- Helles und dunkles Theme, per Voreinstellung dem Desktop folgend
  (Linux/BSD via XDG-Portal bzw. GNOME/KDE, macOS, Windows). Umschaltbar
  oben rechts über das Sonne/Mond-Icon → System / Hell / Dunkel. Der
  Wechsel blendet weich über, auch ein Wechsel am Desktop wird im
  laufenden Betrieb übernommen
- Eingabefeld ist reiner Plaintext — abgeschickte Nachrichten werden aber als
  Rich Text gerendert: `*fett*`, `_kursiv_`, `~durchgestrichen~`, `` `code` ``
- Multiline-Code-Blöcke mit ```` ```sprache ```` und Syntax-Highlighting
  (u. a. TypeScript/JavaScript, Python, Rust, Go, C/C++/C#, Java, Kotlin,
  Swift, PHP, Ruby, Lua, Odin, Zig, SQL, Shell, JSON, YAML, TOML, HTML/XML,
  CSS, Dockerfile, Makefile). Jeder Block hat oben eine Leiste mit dem
  Sprach-Label und einem Copy-Button, der den Code unverändert (inkl. Tabs)
  in die Zwischenablage legt. Einrückung mit Tabs und Spaces übersteht
  Senden, Bearbeiten und Anzeige verlustfrei (Tabs werden spaltenrichtig
  mit Tabstop 4 dargestellt); steht der Cursor im Eingabefeld innerhalb
  eines ```-Blocks, rückt die Tab-Taste ein (Shift+Tab aus, bei
  Mehrzeilen-Auswahl blockweise) statt den Fokus zu wechseln
- Nachrichtentexte inkl. Code lassen sich wie im Browser mit der Maus
  markieren — auch über mehrere Nachrichten hinweg (am Listenrand scrollt
  die Auswahl automatisch weiter). Doppelklick markiert das Wort,
  Dreifachklick die ganze Zeile (auch in den Eingabefeldern), `Strg+C`
  kopiert den sichtbaren Text
- UI-Zoom per `Strg` `+`/`−`/`0` (wird gespeichert; Text bleibt scharf)
- Ungelesen-Badges, Online-Presence, „Neu“-Trennlinie, Tages-Trenner
- Flüssige UI: Smooth Scrolling, animierte Hover-/Fokus-Zustände, Toasts,
  automatisches Nachladen älterer Nachrichten, Auto-Reconnect mit Countdown

### Bedienung & Shortcuts

| Shortcut | Wirkung |
|----------|---------|
| `Tab` / `Shift+Tab` | Tastatur-Navigation durch alle Bedienelemente (wie im Browser); `Enter`/`Leertaste` aktiviert. Steht der Cursor in einem ```-Code-Block, rückt Tab stattdessen ein bzw. aus |
| `Strg` `+` / `−` / `0` | UI vergrößern / verkleinern / zurücksetzen |
| `Strg+K` | Schnellsuche: zu Kanal oder Person springen |
| `Alt+↑ / Alt+↓` | vorheriger / nächster Kanal |
| `Strg+1…9` | Server wechseln |
| `Enter` / `Shift+Enter` | senden / neue Zeile |
| `Esc` | Modal schließen, sonst ans Chat-Ende springen |
| `Bild↑ / Bild↓` | im Verlauf blättern |
| `Strg+A/C/X/V`, Shift+Pfeile, Doppelklick | Textauswahl & Zwischenablage im Eingabefeld |
| Maus-Drag im Chat, `Strg+C` | Nachrichten/Code wie im Browser markieren und kopieren |
| `↑ / ↓` im Eingabefeld | zwischen den Zeilen navigieren; bei viel Inhalt scrollt das Feld (auch per Mausrad/Scrollbar) |

Klick auf Avatar oder Namen einer Nachricht öffnet die Direktnachricht mit
der Person. Eigene Nachrichten zeigen beim Hovern oben rechts ein kleines
Panel mit „⋮“ — darüber lassen sie sich bearbeiten und ihr
Bearbeitungsverlauf anzeigen. Der Zähler im Kanal-Header öffnet die
Mitgliederverwaltung. Der Kopfhörer-Button daneben startet einen
Voice-Call (bzw. tritt dem laufenden bei); im Call-Panel unten links:
Mikro stummschalten, als schwebendes Fenster ausgliedern, auflegen.
Rechtsklick auf einen Kanal in der Sidebar öffnet das Kontextmenü
(als gelesen markieren, Mitglieder, verlassen, löschen). Das Sonne/Mond-Icon
ganz oben rechts schaltet das Theme um.

## Bauen

Voraussetzungen: Odin (getestet mit `dev-2026-07`) im `PATH` sowie für
die Voice-Calls die Systembibliotheken **libopus**, **librnnoise** und
**libspeexdsp** (Arch: `pacman -S opus rnnoise speexdsp`). Die
Audio-Ein-/Ausgabe nutzt das in Odin mitgelieferte miniaudio —
`build.sh` kompiliert dessen `.a` beim ersten Lauf automatisch
(braucht `cc`/`make`).

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
Client-Konfiguration (Server, Sitzungs-Tokens, Geräteschlüssel, UI-Zoom,
Theme) liegt unter `~/.config/ping/client.json`.

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
- **Voice (UDP):** Audio läuft nicht über TCP (Head-of-Line-Blocking),
  sondern über UDP auf demselben Port. Jedes Paket ist einzeln
  XChaCha20-Poly1305-verschlüsselt unter einem zufälligen **Call-Key**,
  den der Server über den Noise-Kanal an die Teilnehmer verteilt
  (Nonce aus ssrc + Sequenznummer, Header als AAD). Der Server arbeitet
  als SFU: er verifiziert nur das Poly1305-Tag jedes Pakets
  (Absender-Authentizität, Anti-Spoofing) und leitet die verschlüsselten
  Bytes unverändert weiter. Calls sind flüchtig — nichts davon berührt
  die Platte.
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
src/shared/   Wire-Protokoll (JSON), Framing, Noise-Secure-Channel, Voice-Pakete
src/server/   Server: Auth, Channels/DMs, verschlüsselte Persistenz, Voice-SFU
src/client/   raylib-Client: Slack-Layout, Multi-Server, Rich-Text, Call-UI
src/audio/    Voice-DSP: Opus/RNNoise/Speex-Bindings, Jitter-Buffer, Engine
tests/smoke/  Headless-Protokolltest inkl. UDP-SFU (gegen frischen Server)
tests/audio/  Headless-DSP-Test (Opus-Roundtrip, FEC/PLC, Jitter, VAD, AEC)
assets/fonts/ Inter + Liberation Mono (werden ins Client-Binary eingebettet)
```

## Protokoll-Smoke-Test

```sh
odin build tests/smoke -out:bin/smoke
bin/ping-server -port 7999 -data /tmp/ping-test &   # frisches Datenverzeichnis!
timeout 30 bin/smoke 127.0.0.1:7999
```
