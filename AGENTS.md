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
- **Kontextgrenze:** llama-server (`-c 8192`) kürzt nicht still, sondern antwortet HTTP 400
  `exceed_context_size_error` (gemessen 06.09.2026: 24 017 Tokens abgelehnt; ein 8014-Token-Prompt
  brauchte auf der P1000 123 s). `agent.zig` macht daraus `error.ContextTooLong`, der Chat zeigt
  einen verständlichen Hinweis. Vorbeugend schickt `submitCompletion` nur das jüngste Stück der
  Historie, das in `history_budget_chars` (12 000 Zeichen ≈ 3–4 k Tokens; Tools-Schema 6 501 Zeichen
  und Systemprompt kosten ~2 k Tokens) passt: `src/ai/history.zig` (`keepFrom`, unit-getestet)
  behält die aktuelle Frage immer und beginnt nie mit einem verwaisten `tool`-Ergebnis. Die
  Anzeige im Chat bleibt vollständig. `read_file` liefert weiter bis 200 KB; eine so große Datei
  sprengt das Fenster trotzdem, dann kommt der Hinweis.
- **Gemessene Grenzen (Bench `~/projects/bitnet-colibri-bench`, Engine b10524 Commit 9ee9fc0,
  Qwen3-4B-Instruct-2507-Q4_K_M sha256 3605803b982cb64a…):** Ein-Datei-Fix gelingt; Ursachen über
  einen Import hinweg scheitern (Qwen3 bricht gefahrlos ab, Llama-3.2-3B schrieb destruktiv). Der
  Agent soll nur in Git-Repos ändern: nur die Bestätigungsdialoge sichern, eine Warnung außerhalb
  eines Repos ist eine offene Produktentscheidung. Prompt-Verarbeitung auf der P1000 ~96 tok/s.
- **Temperatur bleibt 0.7, auch mit Tools** (negatives Ergebnis 06.09.2026): `bench/agent_eval.py`
  Werkzeugwahl bei 0.7 dreimal 10/10, bei 0.0 ebenfalls 10/10 — kein Unterschied, keine Sonderregel.
- **CPU ohne `-tb`** (negatives Ergebnis 06.09.2026, `-dev none -ngl 0`, Prompt 6×-Absatz):
  `-t 8` prompt 52,9 tok/s / gen 10,8 tok/s; `-t 8 -tb 12` prompt 50,6 / gen 11,5 — im Rauschen,
  `agent.zig` bleibt bei `-t min(Kerne, 8)`.
- Nach jeder Änderung an `agent.zig` muss `python3 scripts/e2e_ai_tools.py` grün bleiben; Messzahlen
  immer mit Engine-Commit und Modell-sha256 notieren, Referenz
  `bitnet-colibri-bench/results/linux-i7-8850H-gpu-und-neue-modelle.md`.
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
- **Anzeige:** Namen werden auf die Sidebar-Breite gekürzt („…“, `ellipsize` misst per
  `measureTextWidth`), ein Tooltip mit dem vollen Pfad erscheint nach 700 ms über einer Zeile
  (`hover_index`/`hover_since_ms`, Element `fx_tooltip`). Ordner erben die Git-Farbe ihrer Nachfahren
  (`folderStatus`, C > M > A > ?), Icons nach Endung (`fileIcon`-Tabelle). Versteckte Einträge zeigt
  Taste `.` (`show_hidden`, gedämpft), das Filterfeld öffnet `/` (Name enthält Text, Elternordner
  bleiben, Ordner mit Treffern gelten als aufgeklappt; nur geladene Knoten werden durchsucht; Enter
  behält den Filter, Escape leert ihn). Drag & Drop: Ziehen eines Eintrags auf einen Ordner (oder eine
  Datei darin) fragt „Move 'a' into 'b'?“ und ruft `performMove` (`drag`/`pending_move`).
- **Gemerkter Zustand** (`src/ui/user_state.zig`, unit-getestet): `$XDG_CONFIG_HOME/vulkan-ed/state`
  bzw. `~/.config/vulkan-ed/state` mit `sidebar_width` und `show_hidden`; geschrieben nach dem
  Splitter-Ziehen und beim Umschalten, gelesen in `UI.loadUserState` nach `setupClay`. E2E setzt
  `XDG_CONFIG_HOME=tmp/xdg-config`.
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

## Editor: Bearbeiten, Maus, Statusleiste, Panes

- Reine Textlogik in `src/editor/edit_ops.zig` (unit-getestet): Auto-Indent (`newlineInsertion`:
  Einrückung übernehmen, nach `{([` eine Stufe mehr, `{}`-Paar aufspannen), Autoclose-Regeln
  (`autoclosePolicy`: Paar, drüberspringen, neben Wortzeichen normal; `deletesPair` für Backspace),
  Ein-/Ausrücken, Kommentar umschalten (`commentPrefixForPath` je Endung, Markdown/HTML keins),
  `languageNameForPath`, `wordAt`, `looksLikeDefinition`. Der Editor wendet sie in `dispatchAction`
  an (Actions IndentLines/OutdentLines/ToggleComment/MoveLineUp/Down/DuplicateLine/GotoLine/Replace/
  GotoDefinition; Keymap Shift+Tab, Ctrl+/, Alt+↑/↓, Ctrl+Shift+D, Ctrl+G, Ctrl+H, F12; Tab mit
  mehrzeiliger Auswahl rückt ein). Zeilenoperationen laufen über `replaceLineSpan`.
- **Metrik-Fix:** `egc_chunk_width` lieferte für jeden Chunk 1; `insert_chars` addiert die Chunk-
  Breite zur Cursor-Spalte, der Cursor stand nach Einfügen/Autoclose eine Spalte zu weit links.
- **Anzeige im Editor** (`renderRowOverlays`, schwebende Elemente über dem Zeilentext, x = Spalte ×
  `charWidth`): Einrück-Guides je 4 Spalten führenden Whitespace, Whitespace-Punkte/Tab-Striche
  (`show_whitespace`, Standard aus), Klammerpaar am Cursor (`findBracketPair`, max. 2000 Zeilen,
  pro Frame; Rahmen um beide Klammern; RPC `editor_state.bracket_pair`). Minimap rechts
  (`renderMinimap`, 2 px je Zeile, Fenster um den Viewport, Klick springt) und horizontale Scrollbar
  unten (`renderHScrollbar`, nur wenn eine sichtbare Zeile breiter als der Ausschnitt ist). View →
  Toggle Minimap / Render Whitespace / Indent Guides (gemerkt in `user_state`).
- **Backup vor dem Speichern** löst relative Pfade per `realpathAlloc` auf (`accessAbsolute` hat bei
  der relativen Standarddatei einen `unreachable`-Panic ausgelöst).
- Suchleiste: Ctrl+H zeigt die Ersetzen-Zeile, Tab wechselt das Feld, Enter ersetzt den Treffer,
  Alt+Enter alle (`replaceAll`, ein Undo-Schritt). Ctrl+G öffnet „Go to line“ (nur Ziffern).
- **Suche:** Optionen Alt+C (Groß/Klein), Alt+W (Ganzwort), Alt+R (Regex) in der Suchleiste, Badges
  „Aa W .*“. Regex-Engine `src/editor/tiny_regex.zig` (Backtracking: Literale, `.`, `* + ?`, Klassen,
  `^ $`, `\d \w \s \b`, Gruppen, `|`; keine Rückverweise/Captures, keine lazy Quantoren; unit-getestet).
  `find_ops.findOpts` rechnet Spalten als Anzeigespalten (Tab = 4) und nimmt das Trefferende aus dem
  Treffer, nicht aus der Musterlänge. Der erste Tastendruck nach Ctrl+F ersetzt den alten Begriff
  (`replace_on_type`), sonst hing er an. Watcher: identische Ereignisse werden nur innerhalb von 100 ms
  zusammengefasst; ohne Zeitfenster ging eine zweite externe Änderung derselben Datei verloren.
- Maus: Dreifachklick markiert die Zeile (`click_count`), Shift+Klick erweitert vom Anker, Ctrl+Klick/
  F12 springen zur ersten Definitionszeile des Worts im selben Buffer (kein LSP: der Client in
  `src/lsp` wird nirgends gestartet), Ziehen über den Rand scrollt (`autoScrollWhileDragging` im Render).
- Statusleiste (oben, neben dem Branch): `UI.statusText` — Ln/Col, Auswahl, LF/CRLF, UTF-8,
  Sprache, „Spaces: 4“; RPC `ui_state.status_text`.
- Datei außerhalb geändert: Watcher-`file_changed` → `UI.handleExternalChange`: gleicher Inhalt
  (eigener Save) ignoriert, ungeänderter Buffer wird still neu geladen, geänderter fragt („File
  Changed“: Reload / Keep Mine).
- Panes: Ctrl+\ splittet, Ctrl+Alt+Pfeil oder Chord Ctrl+K dann Pfeil wechselt geometrisch
  (`focusPane` über die Pane-Bounds des letzten Frames), Ctrl+Shift+E fokussiert den Explorer,
  Ctrl+J wechselt zum Terminal-Tab und zurück (`terminal_return_index`). Ctrl+K erreicht die Shell
  im Terminal nicht mehr.
- RPCs: `key_press_alt(name, ctrl, shift, alt)`, `click_mods(x, y, ctrl, shift)`, `editor_state.selection`,
  `ui_state.active_pane_index`. `python3 scripts/e2e_editor.py` deckt alles ab.
- **Mehrfach-Cursor:** Ctrl+D markiert das Wort unter dem Cursor, jedes weitere Ctrl+D fügt das
  nächste Vorkommen als `ExtraCursor` (Cursor + Anker) hinzu (`selectNextOccurrence`); Ctrl+Alt+↑/↓
  setzt Cursor in der Nachbarzeile (`addCursorVertical`). `dispatchAction`/`handleChar` sind Wrapper:
  mit Extra-Cursorn läuft `forEachCursor` über alle Cursor von unten nach oben (`dispatchSingle`/
  `handleCharSingle` je Cursor, `in_multi` verhindert Snapshots pro Cursor, ein Undo-Schritt für
  alle). Schon bearbeitete Cursor derselben Zeile werden um die Breitenänderung verschoben, tiefere
  um die Zeilenänderung; sonst zeigte `prevCharBoundary` hinter das Zeilenende. Escape/Klick/Enter
  lösen auf (`multiSafe` listet, was mit mehreren Cursorn erlaubt ist). RPC `editor_state.cursors`.
- **Word-Wrap (Alt+Z, View → Toggle Word Wrap, gemerkt in `user_state`):** Soft-Wrap in
  `src/editor/wrap_ops.zig` (unit-getestet): Segmente von `wrapCols()` Anzeigespalten (sichtbare
  Spalten minus Minimap minus 1; Codepoint = 1, Tab = 4), Bruch hinter dem letzten Whitespace,
  sonst hart. Der Renderer zeichnet je Buffer-Zeile ein Segment pro Reihe (`renderLine` bekommt
  Segment, Startspalte und `is_last`; Cursor/Auswahl/Overlays werden auf das Segment geklemmt),
  Fortsetzungsreihen ohne Zeilennummer und mit eigenen Clay-IDs (`roww/gutterw/codew` je sichtbarer
  Reihe; das erste Segment behält `row/gutter/code` je Buffer-Zeile für `element_bounds_i`).
  Maus: `hitRow` findet Zeile + Segmentanfang, `colFromX` misst ab dort. `ensureCursorVisible`
  setzt `view.col = 0`, `view.cols` riesig und rückt `view.row` vor, bis die Reihen bis zum Cursor
  passen. Bewusst einfach: Cursor ↑/↓ und Scrollen arbeiten in Buffer-Zeilen, nicht in Reihen
  (VS Code bewegt sich reihenweise); horizontale Scrollbar und Shift+Mausrad sind aus.
  RPC `editor_state.word_wrap`, `editor_state.visual_rows` (Reihen der Cursor-Zeile).
- **Neue Editoren erben Optionen:** `splitActivePane` kopiert Minimap/Whitespace/Guides/Wrap,
  Schriftgröße und Theme vom Ausgangs-Editor (`copyEditorOptions`); vorher hatte der zweite Pane
  Standardwerte, und `loadUserState` erreichte nur die beim Start vorhandenen Leaves.
- **Clay `getElementData` vergisst nichts:** IDs, die nicht mehr gerendert werden, bleiben `found`
  mit alter Geometrie. E2E-Prüfungen auf „Element ist weg“ sind wertlos; Zustand per RPC prüfen.
- **E2E immer mit `XDG_CONFIG_HOME=tmp/xdg-config`:** `e2e_editor.py` lief ohne und hat
  `~/.config/vulkan-ed/state` mit Testwerten (Word-Wrap an) überschrieben; jetzt setzen alle
  Skripte beide XDG-Variablen.
- **setText verwirft den Undo-Verlauf.** `libs/flow-core` gibt in `Buffer.load` die Leaf-Puffer des
  vorherigen Ladevorgangs frei (Leak-Fix gegenüber upstream flow). Alle Undo-/Redo-Knoten zeigen aber
  auf Bäume in genau diesen Puffern: Undo nach einem externen Reload endete in „switch on corrupt
  value“ in `walk_from_line_begin_const_internal` (aufgefallen erst im vollen `e2e_editor.py`, weil
  `typing_in_progress` über den Reload hinweg true blieb und der nächste Tastendruck deshalb keinen
  frischen Snapshot legte). `CodeEditor.setText` setzt jetzt `undo_head`/`redo_head` auf null, beendet
  die Tipp-Gruppe und löscht Extra-Cursor; Undo über einen Reload hinweg gibt es damit bewusst nicht.

## Theme, Zoom, Autosave, Toasts, Menü-Tastatur

- **Theme:** `toggle_theme` (View, Palette) schaltet `UI.theme` zwischen `Theme.light()`/`dark()`;
  Editor-Farben kommen aus `CodeEditor.applyTheme` (bg, gutter, Zeilennummern, Cursor, Auswahl,
  `text_color`). `--theme light|dark` gilt einmalig beim Start; vorher setzte main.zig das Theme in
  **jedem Frame** auf Dark, deshalb griff kein Umschalter (Ursache, Datum 06.09.2026).
- **Zoom:** Ctrl+=/Ctrl+-/Ctrl+0 (`zoom_in/out/reset`, 10–48, `setFontSizeAll` für alle Panes).
- **Autosave:** File → Toggle Autosave (`UI.autosave`), speichert 1 s nach der letzten Änderung
  (`CodeEditor.last_edit_ms`) nur Text-Tabs mit Pfad. Jedes Speichern legt vorher eine Sicherung
  unter `$XDG_DATA_HOME/vulkan-ed/backup/<name>.<hash>.bak` ab (`src/editor/backup.zig`, eine je
  Datei, wird ersetzt). CRLF-Dateien bleiben CRLF (`file_eol_mode`, Test im Editor).
- **Gemerkt** (`user_state`): `theme`, `font_size`, `autosave` zusätzlich zu Breite/Hidden.
- **Toasts:** `UI.showToast` (3 s, unten rechts, max. 4): „Saved x“ (`CodeEditor.takeSaved`),
  „Moved to trash: x“ (`FileExplorerState.takeInfo`), „Font size n“, „Autosave on/off“.
  RPC `ui_state.toast` liefert den jüngsten Text.
- **Menü per Tastatur:** Alt+F/E/V/H öffnet, ←/→ wechselt, ↑/↓ markiert (`menu_highlight`),
  Enter führt aus, Escape schließt. **Kürzel-Dialog** scrollt (Mausrad, ↑/↓; `shortcuts_scroll_y`,
  Inhalt `sc_content` in einem 520-px-Clip).
- **503 beim Warmup:** `agent.zig` liefert `error.ServerLoading` (debug-Log) statt `Llama Server
  Error: 503` im Fehler-Log; die Warmup-Schleife wiederholt, der Chat zeigt „initializing“.
- `python3 scripts/e2e_ui_misc.py` deckt Theme, Zoom, Autosave, Toast, Backup, Menü-Tastatur und
  Dialog-Scroll ab.

## Schnellöffner (Ctrl+P) und Command Palette (Ctrl+Shift+P)

- `src/ui/picker.zig`: ein modaler Picker für beide Modi, Matching in `src/ui/fuzzy.zig` (unit-getestet:
  Teilfolge in Reihenfolge, Bonus für zusammenhängende Treffer, Wortanfänge, Dateinamen). Die Palette
  listet alle `shortcuts.Command` mit Label und Kürzel; Enter läuft über `executeCommand`.
- Dateiliste: Hintergrund-Thread (`scanWorker`, Breitensuche, versteckte und `zig-out`/`node_modules`/…
  übersprungen, max. 100 000), Ergebnis kommt per Mutex in `poll()` (jeden Frame aus `update`). Labels
  liegen in einer Arena: 30 000 einzelne `free()` mit dem Debug-Allocator dauerten Sekunden und
  blockierten den Main-Thread. Cache 10 s je Root. Der Picker erscheint sofort, „Scanning…“ im Hinweis.
- `filter()` tauscht die Trefferliste erst nach dem Ranking (der RPC-Thread liest nebenläufig).
- RPC `picker_state` (open, scanning, mode, query, matches, items, selected, selected_label);
  `python3 scripts/e2e_picker.py`.

## Tab-Leiste

- **Vorschau-Tabs** (`Tab.preview`): Einfachklick oder Space im Explorer öffnet als Vorschau (Text in
  `subtext`-Farbe), der nächste Vorschau-Klick ersetzt sie an derselben Stelle; Doppelklick (< 400 ms,
  `FileExplorerState.now_ms`), Enter, Änderung oder festes Öffnen macht sie fest. `openFileAs(path,
  preview)`; `openFile` bleibt fest (Agent, RPC). Fest öffnen ersetzt keine Vorschau (wie VS Code).
- **Leiste** scrollt den aktiven Tab per `scroll_x` in den Sichtbereich (`tab_strip` mit Clip);
  Namensgleichheit zeigt den Elternordner (`a/mod.zig`), ungespeichert = „• name“. Mittelklick
  schließt, Rechtsklick öffnet das Menü aus `shortcuts.tab_menu_items` (`tab_menu_<command>`),
  Kommandos laufen mit `tab_cmd_target` durch `executeCommand`. Drag & Drop: `TabBarState.drag`
  (Start beim Klick, ab 6 px Bewegung, Drop auf `tabIndexAt`). Angepinnte Tabs haben kein ×
  und bleiben bei Close Others/All/Saved; geänderte Tabs ebenso (kein Dialog pro Tab).
- Ctrl+Shift+T öffnet aus `UI.closed_tabs` (max. 20, nur noch existierende Dateien), Ctrl+1…9,
  Ctrl+PgUp/PgDn, Ctrl+S ist global. „Don't Save“ lädt den Buffer von der Platte neu, weil Buffer
  das Schließen überleben. Auto-Reveal: Tab-Wechsel auf eine Textdatei markiert sie im Explorer.
- RPCs: `tab_bounds(index)`, `middle_click`, `mouse_down`/`mouse_up` (Drag), `move_mouse` hält die
  gedrückte Taste; Tab-JSON hat `preview`/`pinned`. `python3 scripts/e2e_tabs.py` deckt alles ab.
- Frame-Zeit: `ui_state.last_frame_ms`/`max_frame_ms` (Maximum seit dem letzten Abholen). Die
  frühere „1–2 s Tipp-Latenz“ bei der 5-MB-Datei war der `editor_state`-RPC (5 MB JSON je Abfrage);
  echte Frames liegen bei 1–4 ms. Fehler beim Laden/Speichern zeigt `UI.reportError` als Dialog.
- Markdown-Preview hält je Sprache einen Highlighter (`code_highlighters`-Map); vorher wurde bei
  jedem Sprachwechsel ein neuer Tree-sitter-Parser gebaut, viermal pro Frame bei vier Sprachen.

## LSP (zls): Sprung zur Definition

- **Aufbau:** `src/lsp/lsp_proto.zig` (reine Logik, unit-getestet: `Content-Length`-Rahmen,
  Request/Notification, `file://`-URIs, `firstLocation` für Location | Location[] | LocationLink[],
  `parseMessage`) und `src/lsp/lsp_client.zig` (Prozess über stdio, Reader-Thread, `id → Methode`,
  Antworten als `TaskResult` `lsp_definition` mit dem Ergebnis-JSON; Server-Requests werden sofort
  mit `result: null` beantwortet). Der alte Client nutzte die std.json-API von 0.13 und gab Payloads
  vor dem Lesen frei; er wurde ersetzt.
- **Start:** lazy beim ersten F12/Ctrl+Klick in einer `.zig`-Datei (`UI.ensureLsp`): `ZLS_PATH`,
  sonst `~/.local/bin/zls`, sonst `zls` im PATH; `VULKAN_ED_LSP=off` schaltet ab. Root ist
  `current_directory`. Solange `initialize` nicht beantwortet ist, springt der Editor per Textmuster
  (`gotoDefinitionLocal`). RPC `ui_state.lsp` = off/starting/ready/failed.
- **Ablauf:** `CodeEditor.definition_hook` (vom UI in `ensureEditorHooks` jedem Editor gesetzt, weil
  der UI-Zeiger erst nach `init` stabil ist) → `lspGotoDefinition`: Dokument per didOpen/didChange
  (Full Sync, nur vor Anfragen, nicht pro Tastendruck) synchronisieren, `textDocument/definition`
  mit Zeichenindex (`charIndexAt`, Codepoints statt Anzeigespalten). Antwort in
  `handleLspDefinition`: gleiche Datei → `jumpTo`; andere Datei → `openFileAs` + `lsp_goto`, das
  `applyLspGoto` in `update()` ausführt, sobald der Tab aktiv und der Buffer geladen ist (max. 240
  Frames); leeres Ergebnis → lokale Suche.
- **Gemessen (zls 0.15.1, Zig 0.15.2):** erste Definition im frischen Projekt ~12 s (zls analysiert
  std), danach sofort. Hover/Completion sind im Client nicht angebunden (Methoden vorgesehen).
- E2E `python3 scripts/e2e_lsp.py` (braucht zls): F12 auf `a.helper()` öffnet `a.zig` mit Cursor auf
  `helper`. Hinweis: der RPC `open_folder` lädt nur den Explorer neu, `current_directory` bleibt das
  Startverzeichnis; zls bekommt im E2E deshalb das Projekt als Root.

## Explorer: .gitignore-Einträge

- `taskGitStatus` ruft `git status --porcelain=v2 --branch --null --ignored` (im Projekt ~50 ms
  mehr) und schreibt zusätzlich `root:<toplevel>` (aus `rev-parse --show-toplevel`): porcelain-Pfade
  sind relativ zur Repo-Wurzel, nicht zum Projektordner. Das Parsing steckt in
  `git_worker.parseStatusOutput` (unit-getestet); ignorierte Einträge kommen als `I:<pfad>`, Ordner
  ohne den abschließenden Schrägstrich von `! pfad/`.
- `FileExplorer.isIgnored(path)`: Eintrag selbst oder ein Vorfahr mit `I` → Name in `theme.muted`,
  kein Badge; `folderStatus` überspringt `I`, damit ein ignorierter Ordner keinen Status nach oben
  vererbt. RPC `explorer_entries[].ignored`; E2E-Schritt `step_gitignore` nutzt, dass `tmp/` im
  Projekt ignoriert ist.

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
- Runs über `ShapedRunCache.MAX_TEXT_LEN` (2048 Bytes) liefert der Shaper stumm leer. Deshalb gibt der
  Editor pro Zeile nur den sichtbaren Spaltenausschnitt an Clay (`CodeEditor.visibleSliceOf`: ab
  `view.col`, `view.cols + 2` Spalten; `view.cols` kommt aus `visibleColCount` = Editor-Breite minus
  Gutter durch Zeichenbreite). Highlight-Tags, Auswahl und Cursor rechnen mit dem Byte-Offset des
  Ausschnitts. `View.clamp` (flow-core) zieht `view.col` dem Cursor nach; Shift+Mausrad bzw.
  `scroll_horizontal` scrollt Spalten (`scrollColumns`). RPC `editor_state` liefert `view_col`/`view_cols`.
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
