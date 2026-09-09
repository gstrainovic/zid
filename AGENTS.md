# AGENTS.md

## Git Regeln

- **KEINE git-destructive Befehle ohne explizite Erlaubnis**: Kein `git push --force`, `git reset`, `git checkout`, `git restore`, `git clean` ohne vorher zu fragen.

## Logging

- Debug-Zeilen nur mit `ZID_DEBUG=1` (`logFn` in main.zig filtert zur Laufzeit). Ohne
  Variable bleiben info/warn/err; vorher waren es tausende Zeilen pro Sitzung.

## Build Commands

```bash
zig build run              # Run zid
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
  automatisch in Menüleiste, Kontextmenüs und Help → Keyboard Shortcuts (F1).
- **Ein Kontextmenü für alles:** `src/ui/context_menu.zig` (Modul `context_menu`, eigenes Modul wie
  `shortcuts`, weil code_editor.zig ein eigenes Test-Root ist) zeichnet Tab-Kopf, Editor-Text,
  Markdown-Vorschau, Terminal und Explorer im selben Theme-Stil (`Colors.fromTheme`, Zeile 30 px,
  Label 18 px links, Kürzel 14 px rechts). Einträge sind Listen in `shortcuts.zig`
  (`tab_menu_items`, `editor_menu_items`, `markdown_menu_items`, `terminal_menu_items`,
  `file_explorer.context_menu_items`), IDs `<prefix>_<command>` mit den Präfixen `tab_menu`,
  `editor_menu`, `md_menu`, `term_menu`, `fx_menu`; `hit(prefix, items, hidden)` liefert den
  angeklickten Eintrag. `Hidden` (EnumSet) blendet Einträge zustandsabhängig aus: Markdown Preview
  nur bei `.md` (Editor und Tab-Kopf), im Chat-Eingabefeld (`compact_menu`) weder Preview noch
  Split. Der Editor hält die Farben in `menu_colors` (gesetzt in `applyTheme`). Terminal-Copy/Paste
  sind eigene Commands `terminal_copy`/`terminal_paste` ohne Kürzel (Ctrl+C/V gehen an die Shell).
  `md_preview` aus dem Tab-Menü öffnet die Vorschau des angeklickten Tabs
  (`requestMarkdownPreview`), aus dem Editor die des aktiven Buffers.
- Globale und Explorer-Kürzel löst `UI.handleKeyPress` über `shortcuts.lookup` auf und führt sie
  mit `executeCommand` aus; Menüklicks gehen denselben Weg. Editor-Kürzel (Scope `editor`) liegen
  weiterhin in `src/editor/keymap.zig` und müssen zur Tabelle passen (Save, Undo/Redo, Cut/Copy/
  Paste, Select All, Delete Line Ctrl+Shift+K, Find Ctrl+F).
- Globale Kürzel greifen vor Terminal/Chat: Ctrl+W, Ctrl+N, Ctrl+O, Ctrl+B, Ctrl+` und
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
  llama.cpp-Vulkan-Build `engines/llama.cpp-vulkan/build/bin/llama-server` mit
  `models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`, beides relativ zur Repo-Wurzel (`src/ai/paths.zig`,
  unit-getestet: Wurzel aus `<repo>/zig-out/bin` der ausführbaren Datei, sonst das
  Arbeitsverzeichnis; nichts mehr über `$HOME`). Fehlt der Build, Fallback auf Ollama mit
  `gemma4:e2b`. `LLAMA_SERVER_PATH` (Pfad oder `ollama`) und
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
- **Codeblock-Antworten brachten zigdown zum Absturz** (06.09.2026): endet der Text genau mit
  ``` ohne Zeilenumbruch (Antwort nur aus einem Codeblock, oder ein Streaming-Stand), erzeugt
  `handleLineCode` einen leeren Tag und greift auf `tag[0]` zu (`libs/zigdown`, Submodul, nicht
  gepatcht). `chat_markdown.finishForParser` hängt deshalb immer einen Zeilenumbruch an und
  schließt einen offenen Zaun; `toDisplayMarkdown`/`wrapToolResult` laufen darüber. Test mit
  echtem zigdown-Parse in `chat_markdown.zig`, E2E `code_only_answer` in `e2e_ai_chat.py`.
- **Chat-Eingabe ist der CodeEditor** (seit 06.09.2026; vorher `components/textarea.zig`, eine
  2140-Zeilen-Kopie des Editors vom April, gelöscht): `AIChatState.input_editor` mit
  `show_gutter = false`, `show_minimap = false`, `compact_menu = true` (Kontextmenü nur
  Cut/Copy/Paste) und `word_wrap = true`. Enter sendet, Shift+Enter fügt eine Zeile ein
  (`dispatchAction(.InsertNewline)`, die Keymap kennt Enter nur ohne Modifier). Das UI reicht
  Shift/Ctrl/Alt auch an den Chat-Editor weiter, `applyThemeToEditors` färbt ihn mit. Editor-
  Neuerungen gelten damit automatisch auch im Chat. E2E `input_newline_and_send` in
  `e2e_ai_chat.py` (läuft im `--ai=off`-Teil).
- Keine Unit-Tests für `ai_chat.zig`: die Datei importiert den CodeEditor und die UI, also kein
  eigenes Test-Root möglich. Logik dort klein halten.

## Engines und Modelle (`engines/`, `models/`, `llm-bench/`)

Seit 06.09.2026 liegt alles im Repo; `~/projects/ki` und das separate Bench-Repo gibt es nicht mehr.

- **Layout:** `engines/BitNet` (Submodul, gepinnt `01eb415`, Submodul `3rdparty/llama.cpp`
  `1f86f05` = b3962, `.gitmodules` mit `ignore = dirty`, weil `src/ggml-bitnet-mad.cpp` den
  lokalen Patch `llm-bench/patches/bitnet-mad-const-y_col.patch` trägt) und
  `engines/llama.cpp-vulkan` (Submodul, `9ee9fc0` = b10524, Build mit `GGML_VULKAN=ON`). Die Builds
  liegen unbeobachtet in `engines/*/build/`. `models/` hält alle GGUFs flach (per `*.gguf`
  ignoriert, nie committen), das BitNet-Referenzmodell unter
  `models/bitnet-b1.58-2B-4T/ggml-model-i2_s.gguf`. In `engines/BitNet/models/` zeigen zwei
  Symlinks (`_compare`, `BitNet-b1.58-2B-4T`) auf `models/`, damit BitNets eigene Skripte laufen.
- **cmake brennt absolute Pfade ein:** nach dem Umzug fanden `llama-server` und `llama-bench`
  ihre `libllama.so` nicht (RUNPATH zeigte auf `~/projects/ki/...`). `llm-bench/setup/fix-rpath.sh`
  schreibt die RUNPATHs aller Programme und Bibliotheken beider Builds per patchelf auf
  `$ORIGIN`-relative Pfade um (Kopie patchen und darüberschieben, weil ein laufender llama-server
  die Datei gemappt hält: „Text file busy“). Nach jedem Neubau bzw. Verschieben erneut ausführen;
  die Build-Verzeichnisse selbst kann cmake nach einem Umzug nicht mehr neu konfigurieren
  (`CMAKE_HOME_DIRECTORY`), ein Neubau muss von vorn beginnen.
- **`llm-bench/`** ist das frühere Repo `bitnet-colibri-bench` als `git subtree` (Historie
  erhalten, Rohlogs unter `results/logs/`). `results/*.md` sind historische Protokolle und werden
  nicht angefasst; `bench/olmoe_*.py` bleiben als Messprotokoll (colibri ist gelöscht).
  `llm-bench/setup/serve-coding-agent.sh` und `setup/linux.sh` rechnen mit den Repo-Pfaden.
- **Die Engine ist gepinnt, und das ist keine Vorsicht.** Der aktuelle Stand von
  microsoft/BitNet zeigt mit seinem Submodul auf einen Fork-Branch, mit dem BitNet-b1.58-2B-4T
  unbrauchbar ist (Endlosschleife, Perplexity ×3,7, Werkzeugwahl 0/10) — bei unauffälligem
  Durchsatz. Vor jeder Messung `./engines/BitNet/build/bin/llama-bench -m <i2_s.gguf> -p 8 -n 8
  -r 1`: `I2_S - 2 bpw ternary` in der Modellspalte heißt brauchbar, `Q1_0` heißt nicht messen.
- **BitNet braucht `--override-kv tokenizer.ggml.pre=str:llama-bpe`** (dem GGUF fehlt das
  Feld; ohne Override zerfallen Werkzeugnamen, 8–9/10 → 4/10). Nur für BitNet.
- **Feste Engine-Zuordnung:** BitNet i2_s nur auf der gepinnten BitNet-Engine (auf b10524 ist
  i2_s kaputt); Qwen3/Phi-4/Gemma-3 nur auf b10524 (b3962 kennt die Architekturen nicht und hat
  kein taugliches Vulkan); Llama-3.2-3B läuft auf beiden und ist die Brücke (tg64 13,64 gegen
  12,22, pp128 36,73 gegen 49,30) — Zahlen nie ohne diese Verschiebung über die Engine-Grenze
  vergleichen.
- **Jede Zahl braucht drei Kennungen:** Engine-Commit, Submodul-Commit, Modell-sha256
  (Referenz BitNet `4221b252…`, 1 187 801 280 Bytes; Perplexity nur mit `llm-bench/bench/ppl-corpus.txt`
  bei `-c 512`). Entscheidungen des Projektinhabers (keine Fehlerberichte an fremde Projekte, keine
  weiteren Läufe) und die Liste „nicht erneut aufrollen“ stehen in `llm-bench/CLAUDE.md`.
- **Nachweis nach dem Umzug (06.09.2026):** `scripts/e2e_ai_chat.py` grün (llama-server aus
  `engines/`), BitNet `llama-bench` zeigt `I2_S - 2 bpw ternary` (pp8 97,6, tg8 21,9 tok/s, 6 Threads),
  `serve-coding-agent.sh llama gpu 8081` + `agent_eval.py` 9/10 wie in `results/`. Das GitHub-Repo
  `gstrainovic/bitnet-colibri-bench` ist archiviert.
- **Standardmodell des Chats** ist Qwen3-4B-Instruct-2507 (Pflicht); Llama-3.2-3B und das
  BitNet-Referenzmodell sind sinnvoll; die fünf reinen Bench-Modelle (Qwen3.5-4B/2B, xLAM,
  Gemma-3, Phi-4-mini, ~10 GB) bleiben, bis der Projektinhaber entscheidet.

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
- **Gemerkter Zustand** (`src/ui/user_state.zig`, unit-getestet): `$XDG_CONFIG_HOME/zid/state`
  bzw. `~/.config/zid/state` mit `sidebar_width` und `show_hidden`; geschrieben nach dem
  Splitter-Ziehen und beim Umschalten, gelesen in `UI.loadUserState` nach `setupClay`. E2E setzt
  `XDG_CONFIG_HOME=tmp/xdg-config`.
- **Kontextmenü** ist datengetrieben (`context_menu_items`, Labels/Kürzel aus der Tabelle, IDs
  `fx_menu_<command>`, gezeichnet über `context_menu.zig`); der Klick landet in `pending_command`,
  die UI führt `executeCommand` aus.
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
  `~/.config/zid/state` mit Testwerten (Word-Wrap an) überschrieben; jetzt setzen alle
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
  unter `$XDG_DATA_HOME/zid/backup/<name>.<hash>.bak` ab (`src/editor/backup.zig`, eine je
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

- **„+“ (Neu-Menü) sitzt ganz links** vor dem scrollenden Tab-Streifen. Der Streifen hat `.w = .grow`
  mit Clip; stand der Knopf dahinter, wanderte er an den Fensterrand und sein Dropdown wurde
  abgeschnitten (aufgefallen 06.09.2026).
- **Keine Vorschau-Tabs** (entfernt 06.09.2026 auf Wunsch des Projektinhabers; VS Code und Zed haben
  sie standardmäßig an): Einfachklick, Space und Enter im Explorer öffnen jede Datei in einem
  eigenen Tab, ein Klick auf eine schon offene Datei wechselt nur dorthin (`TabBarState.openFile`).
- **Ctrl+Tab = zuletzt benutzt** (`recent_tab_next`/`recent_tab_prev`, wie VS Code/Zed): Tabs
  tragen eine Seriennummer, `TabBarState.mru` (`src/ui/tab_mru.zig`, unit-getestet) hält die
  Reihenfolge, `setActive` holt nach vorn, `closeTab` entfernt, Split kopiert sie. Der Umschalter
  (`UI.tab_switcher`, Overlay unter der Leiste) wandert bei gehaltenem Ctrl je Tab eine Position
  (`cyclePos`), Loslassen von Ctrl wählt (`commitTabSwitcher` in `setCtrlState(false)`). Ein
  einzelnes Ctrl+Tab springt damit zwischen den zwei jüngsten Tabs. Ctrl+PgUp/PgDn bleiben die
  Reihenfolge der Leiste (`next_tab`/`prev_tab`).
- **Ctrl+E = Tab-Picker** (`open_tab_picker`): der Picker im Modus `tabs` listet die offenen Tabs
  der aktiven Leiste, jüngster zuerst, mit Ordner als Detail; Enter wechselt (`Picker.takeTab`).
- E2E: `key_press_hold(name, ctrl, shift, alt)` lässt die Modifier gedrückt, `mods_release` löst sie;
  `ui_state.tab_switcher` ist die Position (−1 = zu). `key_press_mods` löst Ctrl nach der Taste,
  deshalb wählt dort jedes Ctrl+Tab sofort.
- **Leiste** scrollt den aktiven Tab per `scroll_x` in den Sichtbereich (`tab_strip` mit Clip);
  Namensgleichheit zeigt den Elternordner (`a/mod.zig`), ungespeichert = „• name“. Mittelklick
  schließt, Rechtsklick öffnet das Menü aus `shortcuts.tab_menu_items` (`tab_menu_<command>`,
  gezeichnet über `context_menu.zig`; Markdown Preview nur bei `.md`-Text-Tabs), Kommandos laufen
  mit `tab_cmd_target` durch `executeCommand`. Drag & Drop: `TabBarState.drag`
  (Start beim Klick, ab 6 px Bewegung, Drop auf `tabIndexAt`). Angepinnte Tabs haben kein ×
  und bleiben bei Close Others/All/Saved; geänderte Tabs ebenso (kein Dialog pro Tab).
- Ctrl+Shift+T öffnet aus `UI.closed_tabs` (max. 20, nur noch existierende Dateien), Ctrl+1…9,
  Ctrl+PgUp/PgDn, Ctrl+S ist global. „Don't Save“ lädt den Buffer von der Platte neu, weil Buffer
  das Schließen überleben. Auto-Reveal: Tab-Wechsel auf eine Textdatei markiert sie im Explorer.
- RPCs: `tab_bounds(index)`, `middle_click`, `mouse_down`/`mouse_up` (Drag), `move_mouse` hält die
  gedrückte Taste; Tab-JSON hat `pinned`. `python3 scripts/e2e_tabs.py` deckt alles ab.
- Frame-Zeit: `ui_state.last_frame_ms`/`max_frame_ms` (Maximum seit dem letzten Abholen). Die
  frühere „1–2 s Tipp-Latenz“ bei der 5-MB-Datei war der `editor_state`-RPC (5 MB JSON je Abfrage);
  echte Frames liegen bei 1–4 ms. Fehler beim Laden/Speichern zeigt `UI.reportError` als Dialog.
- Markdown-Preview hält je Sprache einen Highlighter (`code_highlighters`-Map); vorher wurde bei
  jedem Sprachwechsel ein neuer Tree-sitter-Parser gebaut, viermal pro Frame bei vier Sprachen.

## Marp: Folien aus Markdown, Export nach PDF

- **Parser** `src/ui/marp.zig` (Modul `marp`, rein, 15 Tests): Front-Matter mit `marp: true`,
  Folientrennung an `---` (nicht im Code-Zaun, nicht bei Setext-Überschriften), `headingDivider`,
  globale Direktiven (`theme`, `style`, `size`, `headingDivider`) und lokale mit Vererbung
  (`_`-Präfix = nur diese Folie). Kommentare ohne Direktiven werden Notizen. Das `Deck` hält eine
  eigene Arena, die Quelle darf danach weg.
- **HTML** `src/ui/marp_html.zig` (Modul `marp_html`): Folie → HTML-Fragment über zigdowns
  `HtmlRenderer` (`body_only`) plus CSS. Bewusst CSS 2.1, MuPDFs Story-Engine kennt weder
  Flexbox noch Grid noch Custom Properties.
- **PDF** `src/rendering/marp_pdf.zig`: eine Seite je Folie in Foliengröße über `fz_story` und
  `fz_new_document_writer`. Hintergrund, Kopf-/Fußzeile und Seitenzahl zeichnet das Modul selbst,
  weil MuPDFs CSS kein `position` kennt. Die Wrapper dafür stehen in `mupdf_wrapper/fitz-z.c`
  (setjmp-Kapselung wie beim Lesen).
- **Folienvorschau:** `MarkdownView` parst ihren Text beim Anlegen als Deck (`deck`-Feld).
  Gelingt das, zeigt sie statt des Fließtexts eine Folie im Seitenverhältnis des Decks
  (`md_slide`) plus Blätterleiste (`md_slide_prev`, `md_slide_counter`, `md_slide_next`).
  Geblättert wird per Pfeil links/rechts, Bild auf/ab, Pos1/Ende, Mausrad und den beiden
  Schaltflächen. Es ist immer nur eine Folie geparst (`slide_arena`/`slide_parsed`), der
  Folienwechsel wirft sie weg. `UI.activeSlideDeckView` liefert die Vorschau des aktiven Tabs,
  wenn sie ein Deck zeigt; darüber laufen Tasten und der RPC `slide_state`
  (`deck`, `slides`, `current`, `scale`, `font_size`, `overflow`).
- **Rahmengröße von Hand:** `renderDeck` rechnet Breite und Höhe der Folie selbst aus der Fläche
  des Wurzelelements (`markdown_view_root`, letzter Frame) und setzt sie als `.fixed`. Mit Clays
  `.aspect_ratio` plus `.w = .grow` blieb der Rahmen auf Inhaltsgröße stehen und war im Fenster
  winzig; im Headless-Test fiel das nicht auf, weil dort nur Verhältnisse geprüft wurden. Der
  E2E prüft deshalb jetzt auch, dass der Rahmen die Breite ausfüllt.
- **Maßstab:** Der Rahmen wird im Verhältnis `Rahmenbreite / Deckbreite` gezeichnet, Ränder und
  Grundschrift stammen aus denselben Konstanten wie der Export (`pdf_margin_x`, `pdf_margin_y`,
  `pdf_content_em`, gespiegelt aus `marp_pdf.zig`); die Überschriftenfaktoren in `renderBlock`
  (2.0 / 1.5 / 1.2) entsprechen dem Export-CSS. Untergrenze 6 px, sonst wird die Vorschau in
  kleinen Panes unleserlich.
- **Überlauf:** `marp_pdf.slideFits` legt die Folie mit `fz_place_story` aus und zeichnet nichts;
  bleibt Inhalt übrig, meldet die Vorschau „Inhalt passt nicht auf die Folie" (`md_slide_overflow`).
  Clay kann das nicht beantworten: der Rahmen clippt, die gemessene Höhe geht darum nie über die
  Innenhöhe hinaus.
- **Bedienung:** Command `md_export_pdf` („Export to PDF") in `shortcuts.zig`, sichtbar im
  Tab-Kontextmenü, im Editor-Kontextmenü, im Kontextmenü der Vorschau und im View-Menü; wie
  `md_preview` bei Nicht-`.md`-Tabs ausgeblendet. Das Ergebnis landet neben der Quelle
  (`deck.md` → `deck.pdf`) und wird sofort als PDF-Tab geöffnet, die Vorschau ist damit das,
  was rauskommt. Fehlt `marp: true`, kommt ein Fehlerdialog statt einer Datei.
- **E2E:** `python3 scripts/e2e_marp_pdf.py` (headless) deckt Sichtbarkeit des Menüeintrags,
  Export, Seitenzahl, PDF-Tab, den Nicht-Deck-Fall und die Folienvorschau samt Blättern ab. Fixture: `test_data/marp_test.md`.
  Einzelne Seiten prüfen: `mutool draw -F txt -o - DATEI.pdf SEITE`.
- **Grenzen:** Der Streifen für Kopf-/Fußzeile muss eine Zeile samt Abstand fassen, sonst
  platziert `fz_place_story` gar nichts (deshalb `chrome_h = 40` und `p { margin: 0 }`).
  Inhalt, der nicht auf die Folie passt, wird abgeschnitten statt verkleinert. zigdown maskiert
  nur Textstücke mit spitzer Klammer, ein alleinstehendes `&` bleibt roh. Mehrzeiliges YAML im
  Front-Matter (`style: |`) wird nicht zusammengefasst. `![bg]`-Hintergrundbilder bleiben im
  Markdown stehen. Die Vorschau bildet den Umbruch nach, ist aber keine Pixelkopie: sie zeichnet
  mit der Editor-Schrift (JetBrainsMono), das PDF mit MuPDFs Serifenlosen. Die Grenze meldet
  deshalb `slideFits`, nicht das Auge.

## LSP (zls): Sprung zur Definition

- **Aufbau:** `src/lsp/lsp_proto.zig` (reine Logik, unit-getestet: `Content-Length`-Rahmen,
  Request/Notification, `file://`-URIs, `firstLocation` für Location | Location[] | LocationLink[],
  `parseMessage`) und `src/lsp/lsp_client.zig` (Prozess über stdio, Reader-Thread, `id → Methode`,
  Antworten als `TaskResult` `lsp_definition` mit dem Ergebnis-JSON; Server-Requests werden sofort
  mit `result: null` beantwortet). Der alte Client nutzte die std.json-API von 0.13 und gab Payloads
  vor dem Lesen frei; er wurde ersetzt.
- **Start:** lazy beim ersten F12/Ctrl+Klick in einer `.zig`-Datei (`UI.ensureLsp`): `ZLS_PATH`,
  sonst `~/.local/bin/zls`, sonst `zls` im PATH; `ZID_LSP=off` schaltet ab. Root ist
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
- Headless rendert keinen GPU-Text (`renderFrameWithText` läuft nur mit Fenster). Glyph-Logik
  nach `src/text/glyph_layout.zig` ziehen und dort unit-testen (`types.zig` importiert
  `platform/mod.zig` (wio), deshalb nimmt das Modul die Glyphen als `anytype`). Ob die
  Text-Strings der Render-Commands überhaupt noch gültig sind, prüft headless die Text-Probe
  (siehe „Use-after-free in Render-Commands“).
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

## Use-after-free in Render-Commands (Segfault in `hashText`/`renderText`)

- **Frame-Regel:** Die Render-Commands aus `renderExample` zeigen auf fremden Speicher
  (Explorer-Knotennamen, Tab-Namen, Dialog-Nachricht, Frame-Arena). Der GPU-Renderer liest sie
  erst *nach* `renderExample`. Nichts, worauf sie zeigen, darf zwischen `endLayout` und dem
  nächsten `renderExample` freigegeben werden — „nach endLayout“ ist **nicht** sicher.
  Aufräumen gehört vor das nächste Layout: `UI.update`, `processPending`, oder der Anfang
  von `renderExample` (`applyPendingDialogResult`).
- `applyDeferredLayoutActions` läuft am Anfang von `renderExample` und wendet an, was das
  vorige Layout angefordert hat: Dialog-Klick/Enter (`pending_dialog_result`),
  `pending_split`, `pending_tab_closes`, leere Panes. Vorher lief das direkt nach `endLayout`:
  die Dialog-Nachricht wurde freigegeben, `performMove` → `refresh` → `loadDirectory` gab alle
  Knotennamen frei, `closeTab`/`TabBarState.deinit` die Tab-Namen, während der Frame noch
  gezeichnet wurde → `Segmentation fault` in `text_system.hashText` (Symptom vom 06.09.2026:
  Bilder per Drag & Drop in einen Ordner verschoben, Absturz beim nächsten Zeichnen).
- Kein `clay.text(&.{byte}, …)`: Zeiger auf ein Stack-Temporary, beim Zeichnen längst
  überschrieben. Statische Literale nehmen (Git-Status-Buchstaben in `renderTreeEntry`).
- **Werkzeug:** Headless fasst jeden Text-Command per `pwrite` in ein memfd an
  (`src/debug/text_probe.zig`; `/dev/null` liest den Puffer nicht, EFAULT bleibt aus). Zeigt ein
  Command auf unmapped Speicher, panict der Loop mit Command-Index, Bounding-Box und dem
  vorigen Text. Mit `--page-alloc` oder `ZID_PAGE_ALLOC=1` läuft alles über
  `src/debug/free_log.zig` (page_allocator: jede Freigabe = munmap, kein In-Place-Remap) und
  die Meldung enthält den Stack-Trace der Freigabe. So laufen lassen:
  `ZID_PAGE_ALLOC=1 python3 scripts/e2e_explorer.py` (jede E2E-Suite geht) oder
  `python3 scripts/e2e_repro_text_uaf.py --page-alloc` (Ordnerwechsel, Bilder, Tooltip,
  Picker-Klicks, Tab-Schließen). Der GPA unmappt kleine Buckets erst, wenn sie ganz leer sind,
  darum fällt der Fehler im Fenster nur sporadisch auf.

## Bekannte Grenzen (kein Todo, bewusst so)

- **Durchgestrichen in Markdown:** `~~text~~` toggelt zigdown zweimal und bleibt ungestylt,
  `~text~` funktioniert. Upstream-Verhalten in zigdown.
- **Fett/Kursiv nur über Farbe:** Es gibt eine einzige Font-Face (JetBrainsMono-Regular).
  Echte Schnitte bräuchten Font-IDs im Text-Renderer und eine zweite geladene Face.
  MarkdownView zeigt Styles deshalb als Theme-Farben (fett=primary, kursiv=accent,
  Code=warning, Link=blau, durchgestrichen=muted).
