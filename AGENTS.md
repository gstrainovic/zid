# AGENTS.md

## Git Regeln

- **KEINE git-destructive Befehle ohne explizite Erlaubnis**: Kein `git push --force`, `git reset`, `git checkout`, `git restore`, `git clean` ohne vorher zu fragen.

## Logging

- Debug-Zeilen nur mit `VULKAN_ED_DEBUG=1` (`logFn` in main.zig filtert zur Laufzeit). Ohne
  Variable bleiben info/warn/err; vorher waren es tausende Zeilen pro Sitzung.

## Build Commands

```bash
zig build run              # Run vulkan-ed
zig build run -- --headless  # Headless mode (screenshots via RPC port 9999)
zig build run -- --interactive  # Interactive mode (stdin/stdout command interface)
zig build -Doptimize=ReleaseSafe  # Release build
```

## Headless / Interactive Mode

### Interactive Mode (stdin/stdout)
```bash
# Start interactive mode
zig build run -- --interactive

# Commands (line-based):
open <path>           # Open file in new tab
close-tab <n>        # Close tab by index
switch-tab <n>        # Switch to tab by index
click <x> <y>         # Mouse click at coordinates
key <name> [ctrl]     # Send key (enter, backspace, k, etc.)
type <text>           # Type text
screenshot            # Screenshot -> ./tmp/vulkan-screenshot.ppm
split <h|v>           # Split horizontal/vertical
get-state            # Get app state as JSON
shutdown              # Exit

# Example:
echo -e "open ./README.md\nget-state\nshutdown" | zig build run -- --interactive
```

### Headless Screenshots
- Pfad: `./tmp/vulkan-screenshot.ppm`
- RPC: `echo '{"jsonrpc":"2.0","method":"screenshot","id":1}' | nc --send-only localhost 9999`

### E2E-Tests: immer `--headless`, nie ein Fenster
- `--headless --ai=off` führt seit 2026-09-05 denselben Frame-Loop aus wie das Fenster
  (Tab-Wechsel, Explorer-Klicks, Tab-Schließen, gepufferte Eingaben, Screenshots), nur
  ohne Fenster-Events, Cursor und Präsentation. Es gibt keinen Grund mehr, für Tests
  `--e2e` mit Fenster zu starten; das stört den User am Desktop.
- `explorer_open <path>` simuliert einen Klick im File-Explorer (setzt `file_to_open`),
  `open_file` geht nur über die Tab-Leiste.
- `get_active_tab` liefert pro Tab `modified` sowie `editor_modified` und `editor_file`
  (Buffer, den der Editor gerade zeigt).
- RPC-Handler laufen im Server-Thread. `click`, `right_click`, `move_mouse`, `key_press`,
  `type_text` und `screenshot` werden gepuffert und vom Main-Thread pro Frame angewendet
  (`drainInputs` / `serviceScreenshot`); `close_active_tab` geht über `pending_tab_closes`.
  Nur `--interactive` (stdin) wendet Handler direkt an, dort gibt es keinen Loop.
  `open_file`, `split_pane`, `show_context_menu` mutieren noch direkt aus dem Server-Thread.
- Headless-Screenshot ist 1200x800, Tab-Kopf liegt bei y≈105, Inhalt ab y≈130.
- Explorer testen: `explorer_entries` liefert Viewport-Bounds, `row_height`, `scroll` und die
  sichtbaren Zeilen mit Index; Zeilenmitte = `viewport.y + index*row_height + row_height/2 - scroll`.
  Zeilen außerhalb des Viewports vorher mit `scroll x y lines` (negativ = runter) hereinholen.
  Rechtsklick auf Zeile öffnet das Menü (Rename/Delete); F2/Entf wirken auf den markierten
  Eintrag, aber nur wenn der letzte Klick im Explorer war (`ui_state.explorer_focused`).
- `key_press(name, ctrl)` kennt alle Buchstaben a–z sowie enter, backspace, escape, delete, tab,
  grave, up/down/left/right, home/end, page_up/page_down, f1, f2; `key_press_mods(name, ctrl, shift)`
  zusätzlich Shift (Ctrl+Shift+Tab). Modifier werden nach der Taste wieder gelöscht.
- `ui_state` liefert Dialog-Titel, offenes Menü, Explorer-Fokus, Explorer sichtbar, Picker/Shortcut-
  Dialog offen, Tabs (Pfad, Art, geändert) und aktiven Tab. `editor_state` liefert Zeilen, Cursor,
  Suchleiste (offen, Begriff, kein Treffer) und den Text. `element_bounds(id)` /
  `element_bounds_i(id, index)` geben Clay-Bounding-Boxen für Klicks; für "existiert das Element
  gerade?" sind sie unzuverlässig (Clay behält Daten verschwundener Elemente), dafür `ui_state`.
  Fixtures unter `tmp/` anlegen (gitignored, im Explorer sichtbar).

## Projektordner wechseln ("Open Folder…")

- Header-Menü **File → Open Folder…** oder **Ctrl+O** öffnet einen modalen Dialog
  (`src/ui/folder_picker.zig`, Logik ohne Clay in `src/ui/folder_ops.zig` mit Tests):
  editierbarer Pfad (`~` wird expandiert), Liste der sichtbaren Unterordner (Klick steigt ab),
  ↑ für den Elternordner, Enter/Open bestätigt, Escape/Cancel schließt.
- Bestätigt → `UI.pending_open_folder`; `main.zig` holt es per `takePendingOpenFolder` und
  ruft `openProjectFolder` (auch beim Start): Explorer-Root, `current_directory`,
  Git-Branch/-Status und File-Watcher wechseln. Offene Tabs bleiben erhalten.
- Kein nativer Dialog (zenity/kdialog/Portal): der In-App-Dialog ist headless testbar
  und braucht keine Systemabhängigkeit.
- File-Watcher registriert seinen Baum im eigenen Thread (`~/projects` hat tausende
  Ordner, das darf den Frame-Loop nicht blockieren).
- E2E: `python3 scripts/e2e_open_folder.py [ordner]` startet headless, fährt Menü → Dialog →
  Pfad tippen → Enter und prüft den neuen Root; Screenshots in `tmp/e2e_menu.ppm` und
  `tmp/e2e_dialog.ppm`. RPCs dafür: `element_bounds(id)`, `element_bounds_i(id, index)`
  (Clay-Bounding-Box für Klicks auf beliebige Elemente), `folder_picker_state`,
  `get_state.root`, `key_press` kennt zusätzlich `o`, `up`, `down`.
- Headless-Screenshots: der SVG-Atlas rasterisiert max. 4 neue Icons pro Render-Durchgang;
  neue Icons erscheinen daher erst im zweiten Screenshot (das Skript rendert zweimal).
- Logs: `logFn` schreibt per `writerStreaming`; mit `File.writer()` wurde eine umgeleitete
  Log-Datei (`2>log`) laufend ab Offset 0 überschrieben.

## Tastenkürzel und Menüs: eine Quelle

- `src/ui/shortcuts.zig` (Modul `shortcuts`) ist die einzige Tabelle: Command, Taste, Modifier,
  Scope (global / editor / explorer), Label, Anzeige-Text und die Menüstruktur File/Edit/View/Help.
  Unit-Tests prüfen Eindeutigkeit und Labels. Neue Kürzel nur dort eintragen, dann erscheinen sie
  automatisch in Menüleiste, Editor-Kontextmenü und Help → Keyboard Shortcuts (F1).
- Globale und Explorer-Kürzel löst `UI.handleKeyPress` über `shortcuts.lookup` auf und führt sie
  mit `executeCommand` aus; Menüklicks gehen denselben Weg. Editor-Kürzel (Scope `editor`) liegen
  weiterhin in `src/editor/keymap.zig` und müssen zur Tabelle passen (Save, Undo/Redo, Cut/Copy/
  Paste, Select All, Delete Line Ctrl+Shift+K, Find Ctrl+F).
- Globale Kürzel greifen vor Terminal/Chat/TextArea: Ctrl+W, Ctrl+N, Ctrl+O, Ctrl+B, Ctrl+` und
  Ctrl+Tab kommen im Terminal nicht mehr an der Shell an (bewusst, wie in Zed).
- Suchleiste (`CodeEditor.find`, Logik in `src/editor/find_ops.zig`): inkrementell beim Tippen,
  Enter/Shift+Enter weiter/zurück mit Umbruch, Escape schließt, markierter Text wird Suchbegriff.
  Spalten sind Codepoints, Tabs/Breitzeichen sind nicht berücksichtigt.
- Tests in `src/editor/code_editor.zig` laufen nur, weil die Datei eigenes Test-Root ist
  (`code_editor_tests` in build.zig, wio-Symbol-Hack unter `is_test` in der Datei). Tests in
  importierten Modulen führt der Runner nicht aus; `zig build test --summary all` zeigt die
  Zähler pro Modul, ein absichtlich kaputter Test ist der schnellste Beweis.
- E2E: `python3 scripts/e2e_shortcuts.py` fährt headless alle Kürzel und Menüs durch (Explorer
  F2/Entf, Tabs, Ansicht, Menüleiste, Kontextmenü, Shortcut-Dialog, Suchleiste) und legt
  Screenshots unter `tmp/e2e_*.ppm` ab.

## KI-Chat (llama-server / Ollama)

- **Backend-Wahl beim Start** (`UI.init`, sofern nicht `--ai=off`): Standard ist der
  llama.cpp-Vulkan-Build `~/projects/ki/llama.cpp-vulkan/build/bin/llama-server` mit
  `~/projects/ki/BitNet/models/_compare/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`. Fehlt der Build,
  Fallback auf Ollama mit `gemma4:e2b`. `LLAMA_SERVER_PATH` (Pfad oder `ollama`) und
  `LLAMA_MODEL_PATH` überschreiben. Der Init-Block war seit Commit 8a5c7fb auskommentiert.
- **Warum Qwen3-4B:** Messung auf diesem Laptop (i7-8850H, Quadro P1000 4 GB) mit der Frage
  "hallo, was kannst du alles?": gemma4:e2b über Ollama 232 s für 1022 Tokens (4,4 tok/s, das
  5,2-GB-Modell passt nicht in den VRAM); Qwen3-4B Q4 über llama-server auf der P1000 27 s für
  494 Tokens (18,8 tok/s). Deckt sich mit `~/projects/bitnet-colibri-bench` (Testsieger, 10/10
  Werkzeugwahl). Ohne GPU läuft dasselbe Modell auf der CPU mit ~7–10 tok/s; BitNet-b1.58 wäre
  auf reiner CPU ~2× schneller, braucht aber die gepinnte Engine (siehe dort) und ist nur Option.
- **llama-server-Start** (`agent.zig`): prüft Engine- und Modelldatei, fragt
  `--list-devices` ab und wählt per `device_select.zig` (unit-getestet) eine diskrete GPU mit
  ≥ 3 GB, sonst CPU (`-dev none -t N`). iGPUs (Intel UHD …) werden übersprungen: laut Bench ein
  Drittel der CPU. Argumente: `--jinja -c 8192 --log-disable`, GPU `-dev VulkanN -ngl 99`.
  Port 8080 (`default_llama_port`); Ollama bleibt auf 11434. Ohne `-dev` landete das Modell
  womöglich auf der iGPU, ohne `--jinja` stimmt das Qwen3-Chat-Template nicht.
- **Streaming:** `streamChatCompletion` (SSE, `stream: true`) → Worker pusht jedes Delta per
  `Scheduler.pushResult` als `ai_chat_delta`, der Chat zeigt die wachsende Antwort
  (`stream_text`, Markdown wird bei neuem Text neu gebaut). Finale Antwort kommt als
  `ai_chat_reply` mit dem ganzen Text. **Escape** setzt `cancel_flag`, der Worker beendet den
  Stream → `ai_chat_cancelled`, der Teiltext bleibt mit "(abgebrochen)".
- `AgentStatus` (`none`, `model_missing`, `initializing`, `ready`, `failed`) ist der echte
  Verbindungszustand: Statuspunkt, Kopfzeile (`agentTitle`: Modell · Gerät) und `sendMessage`
  (antwortet ohne bereiten Agent sofort mit Erklärung) hängen daran. Warmup schickt "ping" mit
  `max_tokens = 1` (ohne Limit dauerte der Start minutenlang).
- Fehlt das Ollama-Modell, wird nicht synchron gepullt; der Chat zeigt "Pull model with Ollama"
  (`ai_worker.taskOllamaPull`). Lokales GGUF ohne Download registrieren:
  `printf 'FROM /abs/pfad/model.gguf\n' > Modelfile && ollama create NAME -f Modelfile`.
- RPC `chat_state`: Status, Detail, Titel, loading/initializing/downloading, `streaming_len`,
  alle Nachrichten. E2E: `python3 scripts/e2e_ai_chat.py` (Warmup, erstes Delta < 30 s, Escape,
  kurze Antwort; `--only-off` nur den `--ai=off`-Pfad). Messwerte 05.09.2026: Warmup 2,0 s,
  erstes Delta 2,3 s, PONG 0,8 s.
- Keine Unit-Tests für `ai_chat.zig`: die Datei importiert `components/textarea.zig`, das
  `../../editor/actions.zig` zieht, also kein eigenes Test-Root möglich. Logik dort klein halten.

## Explorer: Umbenennen/Löschen und offene Tabs

- Umbenennen zieht Tab-Pfad, Titel, Buffer-Pfad und `open_buffers`-Schlüssel mit, auch für
  alle Tabs unter einem umbenannten Ordner (Preview-Tabs mit `preview://`-Präfix ebenso).
- Klick in den Editor setzt `selection_anchor = cursor`; jede Eingabe hebt den Anker wieder auf
  (`deleteSelection`), sonst ersetzt das zweite getippte Zeichen das erste.
- Löschen schließt Tabs ohne ungespeicherte Änderungen; geänderte Tabs bleiben offen mit
  Stern, Speichern legt die Datei wieder an (Verhalten wie VS Code). Buffer gelöschter
  Dateien wandern nach `orphan_buffers` (bis Programmende), damit ein neu angelegtes File
  mit gleichem Namen nicht den alten Inhalt bekommt.
- Ablauf: Explorer setzt `pending_fs_change`, `UI.update()` holt es per `takeFsChange` ab
  und wendet es vor dem Layout an (`applyFsChange`).

## Bekannte Grenzen (kein Todo, bewusst so)

- **Durchgestrichen in Markdown:** `~~text~~` toggelt zigdown zweimal und bleibt ungestylt,
  `~text~` funktioniert. Upstream-Verhalten in zigdown.
- **Fett/Kursiv nur über Farbe:** Es gibt eine einzige Font-Face (JetBrainsMono-Regular).
  Echte Schnitte bräuchten Font-IDs im Text-Renderer und eine zweite geladene Face.
  MarkdownView zeigt Styles deshalb als Theme-Farben (fett=primary, kursiv=accent,
  Code=warning, Link=blau, durchgestrichen=muted).
