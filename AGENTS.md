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

## Agent-Werkzeuge: der Agent kann, was der Editor kann

- **Natives Tool-Calling** (OpenAI `tools`-Feld, `tool_calls` in der Antwort, `role: tool` zurück).
  Geprüft 05.09.2026 mit llama-server b10524 + Qwen3-4B + `--jinja`: funktioniert nicht-streamend
  und streamend (`delta.tool_calls` je Index zusammensetzen), das Modell nutzt Tool-Ergebnisse.
  Das alte JSON-im-Text-Verfahren (`tryExecuteToolCall`) ist entfernt. Kein MCP, kein RPC:
  Agent und Editor sind derselbe Prozess; MCP wäre nur für externe Agenten interessant.
- **Definitionen** in `src/ai/tools.zig` (Modul `ai_tools`, unit-getestet): `command` (Enum aus
  `shortcuts.Command`, Beschreibung mit Label + Kürzel jedes Kommandos → jedes Menü/Kürzel ist
  automatisch Agent-Werkzeug), `open_file`, `read_file` (≤ 200 KB), `write_file`, `replace_text`,
  `list_files` (≤ 200 Einträge), `open_folder`, `find_in_editor`. `toolsJson` liefert das Schema,
  `parseEnvelope` die Aufrufe aus dem Worker-Ergebnis `{"content","tool_calls"}`.
- **Ausführung** auf dem Main-Thread in `src/ui/agent_actions.zig` (`UI.driveAgentTools` in
  `update()`): `command` → `executeCommand`; Dateien nur innerhalb von `current_directory`
  (`ai_tools.resolveInProject`, `..` und fremde absolute Pfade → `{"error": "outside the project"}`).
  Ergebnisse gehen als JSON in `tool`-Nachrichten.
- **Regeln in Code, nicht im Prompt** (Qwen3-4B hält Prompt-Regeln unzuverlässig ein, siehe
  replace_text-Umweg). Der Systemprompt nennt nur Rolle und "Pfade relativ zum Projekt".
  `ai_tools.choosePaneForFile` (unit-getestet) entscheidet für `open_file`: Chat nicht im
  aktiven Pane → dort öffnen; Chat aktiv und zweites Pane vorhanden → dort; sonst vertikal
  splitten (Chat oben, Datei unten). Danach geht der Fokus zurück zum Chat-Pane, man kann
  weiterschreiben. Dafür lädt main.zig Tab-Wechsel jetzt für **alle** Leaves
  (`UI.leavesWithPendingSwitch`; der Block biegt `active_pane` pro Leaf kurz um), vorher nur
  für das aktive Pane.
- `write_file`/`replace_text` auf eine offene Datei laden den Buffer und alle Editoren darauf
  neu (`UI.reloadFileFromDisk`: `setText`, `setLanguageFromPath`, `last_save = root`, Tabs
  gelten als gespeichert). Zed/VS Code lösen das Sichtbarkeitsproblem mit einem Chat-Dock
  neben den Editor-Panes; das bleibt eine Option, der Split reicht vorerst.
- **Bestätigung** über den normalen Dialog ("AI agent", Allow/Deny): `write_file` auf bestehende
  Datei; `replace_text`, wenn `old` ≥ halbe Datei ist (`replaceCountsAsRewrite`; Qwen umging so
  die write_file-Regel). Antwort wird in `update()` verarbeitet, nie im Dialog-Callback. Deny →
  `{"error":"the user denied this action"}` ans Modell. `close_tab`/`delete_entry` fragen über
  ihre bestehenden Dialoge. Max. 8 Werkzeugrunden pro Frage (`max_tool_rounds`).
- Anzeige: Assistant-Aufrufe als `🔧 name(args)`, Ergebnisse als `✅/⚠️ name → JSON…`.
- Kein `run_shell` (bewusst, erst mit Sandbox). Kein Diff-Review vor dem Schreiben (Zed zeigt
  Agent-Änderungen erst als Vorschlag); wäre der nächste Schritt nach dem Dock.
- RPCs: `focus_chat` (Chat-Tab in irgendeinem Pane aktivieren), `file_text(path)` (Inhalt des
  offenen Buffers), `ui_state.pane_count`,
  `ui_state.all_tabs`, `ui_state.agent_confirm_pending`, `chat_state.tool_rounds/pending_tools`,
  Nachrichten mit `tool_calls`/`tool_call_id`.
- E2E `python3 scripts/e2e_ai_tools.py`: Explorer per Chat aus/ein, Datei anlegen+öffnen ohne
  zweites Pane → Split, Fokus bleibt im Chat, Buffer im Nachbar-Pane geladen; lesen; kleine
  replace_text-Änderung ohne Dialog mit Tab-Reload; Überschreiben → Dialog → Deny → unverändert;
  `/etc/hostname` abgelehnt. Messung: erste Runde nach Warmup 13–14 s, danach 3–9 s je Frage.

## Explorer: Fokus, Tastatur, Auswahl, Papierkorb

- **Fokus** (`ui_state.explorer_focused`) setzt jeder Klick in die Sidebar, Escape gibt ihn ab; die
  Sidebar zeigt ihn als linken Rahmen in `border_focus`. Mit Fokus erreicht keine Taste den Editor:
  Explorer-Kürzel aus `shortcuts.zig` (Scope `explorer`, auch ohne markierten Eintrag) → sonst
  `FileExplorerState.handleNavKey` (↑↓ mit Shift-Bereich, ←→ zu-/aufklappen bzw. Eltern/Kind,
  Enter/Space öffnet, Home/End, PageUp/PageDown) → Rest wird geschluckt. Buchstaben wie in
  nvim-tree/yazi: `d` Papierkorb, `r` umbenennen, `a`/`Shift+A` anlegen, `y`/`x`/`p` kopieren/
  ausschneiden/einfügen, `Ctrl+D` duplizieren, `c`/`Shift+C` Pfad, `Shift+R`/F5 neu laden,
  `w` alles zuklappen, `Ctrl+A` alles markieren. Kein Type-ahead: Buchstaben sind Kürzel.
- **Auswahl** ist eine Menge (`selected_nodes`, Ctrl+Klick toggelt, Shift+Klick/Shift+↑↓ Bereich ab
  `anchor_index`), `selected_index` ist der Cursor. Ordner-Klick markiert und toggelt. `selectedPaths`
  lässt Kinder markierter Ordner weg. Ctrl+Klick lässt sich per RPC nicht auslösen (Modifier gelten
  nur für `key_press_mods`), der E2E nimmt Shift+↓.
- **Kontextmenü** ist datengetrieben (`context_menu_items`, Labels/Kürzel aus der Tabelle, IDs
  `fx_menu_<command>`); der Klick landet in `pending_command`, die UI führt `executeCommand` aus.
  Anlegen zeigt eine Eingabezeile unter dem Zielordner (`startCreate`, `targetFolder`: markierter
  Ordner, sonst Elternordner, sonst Root); Enter legt an (Dateien werden geöffnet), Escape bricht ab.
- **Löschen = Papierkorb** (`explorer_ops.trashPath`: `$XDG_DATA_HOME/Trash` bzw. `~/.local/share/Trash`,
  `files/` + `info/*.trashinfo`, DeletionDate in UTC), Fallback `gio trash`, nie endgültig.
  E2E-Skripte setzen `XDG_DATA_HOME=tmp/xdg`, damit der echte Papierkorb leer bleibt. Fehler von
  Explorer-Aktionen landen in `takeError` → Dialog „Error“ statt nur im Log.
- **Dialoge per Tastatur** (`dialog_ops.zig`, unit-getestet): Enter wählt den fokussierten Button
  (Start: erster = primär), Escape Cancel, Tab/Shift+Tab wandern, Anfangsbuchstabe wählt (`d` Delete,
  `s` Save, `n` Don't Save). Bei offenem Dialog erreicht keine Taste und kein Zeichen den Editor.
- `python3 scripts/e2e_explorer.py` fährt Fokus, Kürzel, Dialog-Tastatur, Papierkorb, Navigation,
  Anlegen/Umbenennen, Zwischenablage, Mehrfachauswahl und Kontextmenü headless durch.

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

## Große und merkwürdige Dateien (Binärdateien, Riesenzeilen)

- `gpu_renderer.renderText` arbeitet mit Stack-Puffern von `glyph_layout.max_batch_glyphs` (256)
  Glyphen. `shapeTextInto` liefert für Runs über 256 Glyphen einen owned Heap-Slice beliebiger
  Länge; die Glyphen werden deshalb blockweise verarbeitet, die Stiftposition läuft über
  Blockgrenzen weiter (`glyph_layout.computeGlyphDevicePositions` gibt sie zurück, unit-getestet).
  Vorher: `index out of bounds: index 463, len 256` beim Öffnen einer `.traineddata`-Datei.
- Headless rendert keinen GPU-Text (`renderFrameWithText` läuft nur mit Fenster), ein Absturz im
  Text-Renderer ist per E2E nicht reproduzierbar — reine Logik nach `src/text/glyph_layout.zig`
  ziehen und dort testen. `types.zig` importiert `platform/mod.zig` (wio), deshalb nimmt das Modul
  die Glyphen als `anytype`.
- **Binärdateien** öffnen keinen Buffer: `file_types.detectFileKind` (Endung zuerst, dann die ersten
  1024 Bytes durch `looksBinary`, Heuristik wie Zeds `analyze_byte_content`: bekannte Header,
  NUL-Anteil ≥ 1/16, sonst ≥ 8 % nicht textartige Bytes; unit-getestet) liefert `.binary`, der Tab
  zeigt nur `binary_view.zig` (Name, Größe). Bewusst ohne „Trotzdem öffnen“ (VS Code hat das, Zed
  nicht). UTF-16 gilt als binär, es gibt keinen Decoder. Bild/PDF entscheidet weiter die Endung.
  Eingaben auf einem Binär-Tab gehen wie bei Bild-Tabs an den Editor des vorherigen Buffers —
  bekanntes Verhalten, Tastatur-Fokus pro Tab-Art steht in todo.md.
- Runs über `ShapedRunCache.MAX_TEXT_LEN` (2048 Bytes) liefert der Shaper stumm leer: solche Zeilen
  sind unsichtbar, kein Fehler im Log. Offen in todo.md (Editor soll nur den sichtbaren
  Spaltenausschnitt an Clay geben).
- `python3 scripts/e2e_odd_files.py` legt unter `tmp/` eine 3-KB-Binärdatei ohne Zeilenumbruch,
  eine 5000-Zeichen-Zeile und eine 5-MB-Datei an, öffnet sie headless, tippt und misst die Latenz
  bis das Zeichen in `editor_state` steht (Messung 06.09.2026: 0,06 s bei der langen Zeile,
  1,2–2,4 s bei der 5-MB-Datei); die Binärdatei muss als Tab-Art `binary` ohne Buffer erscheinen. Logs mit Binärinhalt nur mit `grep -a` lesen, sonst schweigt grep.
- Verwaiste Headless-Prozesse: `pkill -f '[v]ulkan-ed --headless'` — ohne die Klammer trifft das
  Muster die eigene Shell, die den Befehl enthält.

## Bekannte Grenzen (kein Todo, bewusst so)

- **Durchgestrichen in Markdown:** `~~text~~` toggelt zigdown zweimal und bleibt ungestylt,
  `~text~` funktioniert. Upstream-Verhalten in zigdown.
- **Fett/Kursiv nur über Farbe:** Es gibt eine einzige Font-Face (JetBrainsMono-Regular).
  Echte Schnitte bräuchten Font-IDs im Text-Renderer und eine zweite geladene Face.
  MarkdownView zeigt Styles deshalb als Theme-Farben (fett=primary, kursiv=accent,
  Code=warning, Link=blau, durchgestrichen=muted).
