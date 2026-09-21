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
zig build test-text        # nur Textsystem (Glyph-Cache, Atlas; Root src/text_tests.zig)
```

## Themen in Skills (`.claude/skills/`, laden bei Bedarf)

Hier stehen nur Regeln, die überall gelten. Wissen zu einzelnen Bereichen liegt in Skills;
vor Arbeit an einem Bereich die passende laden. Neue Befunde gehören in die Skill ihres
Bereichs, nicht hierher.

- `markdown-preview`: Vorschau (Tabellen, Umbruch, Word Wrap, Balken, Auswahl, Suche, E2E-IDs)
- `clay-layout`: Clay-Fallstricke (Elementgrenze, Mindestbreite, Clipping, IDs in Schleifen)
- `git-views`: Diff-Editor, Timeline, Source Control Graph, Changes mit Commit
- `llm-local`: KI-Chat, Selbsteinrichtung, Engines/Modelle, Agent-Werkzeuge
- `packaging`: eingebettete Daten, MuPDF, Windows-CI, Release-Tarball, Binärgröße
- `marp`: Folien und PDF-Export; `pdf-view`: PDF-Vorschau; `lsp`: zls; `emoji`: Farb-Emoji
- Laufzeitdaten (Schrift, Icons, Shader) ins Binary einbetten, nie relativ zum Arbeitsverzeichnis
  lesen — Details in `packaging`.

## Fenster-Backends: Wayland und X11

- `build.zig` baut wio mit `unix_backends = "x11,wayland"`. wio wählt beim Start selbst:
  `XDG_SESSION_TYPE` entscheidet, sonst probiert es beide (`libs/wio/src/unix.zig`).
- Die WGPU-Surface braucht je Backend andere Handles. `Platform.nativeWindow` liefert sie als
  `NativeWindow` (`src/platform/native_window.zig`), `Renderer.setWindow` baut daraus den
  Deskriptor: Wayland-Surface, Xlib-Window oder HWND.
- wio lädt libX11, libXcursor und die Wayland-Libs per `dlopen`; `build.zig` linkt sie trotzdem,
  weil die extern-Deklarationen der Import-Tabellen im Debug-Info stehen und der Linker sie
  sonst als undefiniert meldet. Dasselbe gilt für `code_editor_tests`.
- Der vendorte wio-Patch `fix(x11): GLX-Importe nur mit enable_opengl deklarieren` hält libGL
  aus einem reinen Vulkan-Build heraus.
- X11 von einer Wayland-Sitzung aus prüfen: `env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11
  DISPLAY=:0 ./zig-out/bin/zid --e2e --ai=off <datei>`, dann Screenshot per RPC. Xwayland
  reicht dafür. Headless berührt kein Backend, deckt das also nicht ab.

## Lesende RPCs gehören in den Hauptthread

`onMain` ist Pflicht für jeden RPC, der veränderlichen UI-Zustand liest. `explorer_entries`
tat das nicht und las, während der Hauptthread den Baum neu baute: der Test sah einen
eingeklappten Baum, Einträge fehlten sporadisch (`Explorer-Eintrag 'beta.txt' nicht
sichtbar`), und die Namen zeigten in gerade freigegebenen Speicher. Wer einen neuen
Lese-RPC ergänzt, nimmt `onMain` wie `editorState` und `chatState`.

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
- Die UI-Uhr (`ui_time_ms`, Tooltips nach 700 ms, Toasts, Hover) läuft seit 18.09.2026 mit der
  echten Zeit zwischen zwei Frames (Deckel 250 ms), vorher pauschal 16 ms je Frame. Headless
  dauert ein Frame mit Layout und RPC ~35 ms, die Uhr lief also halb so schnell und ein Tooltip
  kam erst nach ~1,5 s; `e2e_scm_changes.py` (1 s Hover) scheiterte deshalb unter Windows,
  `e2e_timeline.py` flatterte. Tests, die auf Zeit warten, rechnen in Echtzeit. Nebenbefund
  derselben Umstellung: der Explorer-Tooltip (`fx_tooltip`, unter der Zeile) fing ohne
  `pointer_capture_mode = .passthrough` den Klick auf die nächste Zeile ab — jedes Hover-Element,
  das nicht selbst klickbar ist, braucht passthrough (wie `tooltip.attach`, Cursorstriche,
  Platzhalter). `open_folder` läuft seit 18.09.2026 gepuffert im Main-Thread wie `open_file`:
  synchron im Server-Thread leerte `loadDirectory` die Knoten unter einem laufenden Render.
- `explorer_open <path>` simuliert einen Klick im File-Explorer (setzt `file_to_open`),
  `open_file` geht nur über die Tab-Leiste.
- `get_active_tab` liefert pro Tab `modified` sowie `editor_modified` und `editor_file`
  (Buffer, den der Editor gerade zeigt).
- RPC-Handler laufen im Server-Thread. `click`, `right_click`, `move_mouse`, `key_press`,
  `type_text` und `screenshot` werden gepuffert und vom Main-Thread pro Frame angewendet
  (`drainInputs` / `serviceScreenshot`); `close_active_tab` geht über `pending_tab_closes`.
  Nur `--interactive` (stdin) wendet Handler direkt an, dort gibt es keinen Loop.
  `open_file` prüft nur IsDir synchron und legt den Tab gepuffert an (ein `tabs.append` aus dem
  Server-Thread traf `renderTabBar` mitten in der Iteration: General protection exception in
  `tabLabel`); nach `open_file` also `settle`, bevor Tabs abgefragt werden. `split_pane` und
  `show_context_menu` mutieren noch direkt aus dem Server-Thread.
- **Lesende RPCs laufen im Server-Thread, außer sie durchlaufen Buffer.** `editor_state`,
  `file_text` und `get_chat_input` gehen über `onMain`: der Server-Thread legt den Aufruf ab,
  `drainInputs` führt ihn im nächsten Frame aus, der Server wartet (5 s Zeitlimit). Im
  Server-Thread lasen sie Buffer, die der Main-Thread per `setText` ersetzte: „switch on corrupt
  value“ in `Buffer.walk_const` (Stresstest `python3 scripts/e2e_rpc_race.py`). Neue RPCs, die
  Buffer, Editoren oder Listen der UI lesen, ebenfalls über `onMain`.
  Übrige Lesezugriffe auf gemeinsame Daten brauchen eine Sperre: `file_explorer.git_status`
  hängt an `git_status_mutex`, weil der Main-Thread die Map in `updateGitStatus` ersetzt (Keys
  werden freigegeben) und `explorer_entries` sie gleichzeitig liest — das war ein Segfault in
  `isIgnored`. Zugriff nur über `statusFor`, `isIgnored`, `folderStatus`, nie direkt auf die Map.
- Headless-Screenshot ist 1200x800, Tab-Kopf liegt bei y≈105, Inhalt ab y≈130.
- Explorer testen: `explorer_entries` liefert Viewport-Bounds, `row_height`, `scroll` und die
  sichtbaren Zeilen mit Index; Zeilenmitte = `viewport.y + index*row_height + row_height/2 - scroll`.
  Zeilen außerhalb des Viewports vorher mit `scroll x y lines` (negativ = runter) hereinholen.
  Das ist die UI-Konvention aller `scrollLines` (positiv = hoch). Im Fenster spiegelt
  `platform/wheel.zig` das wio-Delta (positiv = Rad nach unten, auf jeder Plattform gleich)
  ohne OS-Sonderfall; der RPC umgeht diese Stelle, das Vorzeichen deckt nur der Unit-Test ab.
  Achtung beim Prüfen von Hand: das Touchpad hat unter GNOME Natural Scrolling, die Maus nicht.
  Rechtsklick auf Zeile öffnet das Menü (Rename/Delete); F2/Entf wirken auf den markierten
  Eintrag, aber nur wenn der letzte Klick im Explorer war (`ui_state.explorer_focused`).
- `key_press(name, ctrl)` kennt alle Buchstaben a–z sowie enter, backspace, escape, delete, tab,
  grave, up/down/left/right, home/end, page_up/page_down, f1, f2; `key_press_mods(name, ctrl, shift)`
  zusätzlich Shift (Ctrl+Shift+Tab). Modifier werden nach der Taste wieder gelöscht.
- `ui_state` liefert Dialog-Titel, offenes Menü, Explorer-Fokus, Explorer sichtbar, Picker/Shortcut-
  Dialog offen, Tabs (Pfad, Art, geändert) und aktiven Tab, dazu `last_frame_ms`/`max_frame_ms`
  (Layout-Zeit; headless rendert nur beim Screenshot) und die Glyph-Cache-Diagnose
  `glyph_rasterized`, `glyph_cache_clears`, `glyph_cache_entries`, dazu `text_runs_dropped` (nicht
  gezeichnete Textstücke) und `clay_errors` (Clay-Fehler seit Start). E2E können damit prüfen, dass
  nichts still verloren ging (`scripts/e2e_long_runs.py`). `editor_state` liefert Zeilen,
  Cursor, Suchleiste (offen, Begriff, kein Treffer), den Text sowie `height`/`visible_rows`
  (Bounding-Box des Editors aus dem Vorframe, muss über Frames konstant bleiben). `element_bounds(id)` /
  `element_bounds_i(id, index)` geben Clay-Bounding-Boxen für Klicks; für "existiert das Element
  gerade?" sind sie unzuverlässig (Clay behält Daten verschwundener Elemente), dafür `ui_state`.
  Fixtures unter `tmp/` anlegen (gitignored, im Explorer sichtbar). Keine Suite liest aus
  `test_data/`, und zid öffnet beim Start nur eine Datei von der Kommandozeile (früher
  automatisch `test_data/syntax_test.md`): eingecheckte Vorlagen
  liegen unter `scripts/fixtures/`, PDF und PNG erzeugt `scripts/e2e_fixtures.py` ohne
  Fremdbibliothek (`write_pdf`, `write_png`; Selbsttest per Direktaufruf).

## Projektordner wechseln ("Open Folder…")

- Header-Menü **File → Open Folder…** oder **Ctrl+O** öffnet einen modalen Dialog
  (`src/ui/folder_picker.zig`, Logik ohne Clay in `src/ui/folder_ops.zig` mit Tests):
  editierbarer Pfad (`~` wird expandiert), Liste der sichtbaren Unterordner (Klick steigt ab),
  ↑ für den Elternordner, Enter/Open bestätigt, Escape/Cancel schließt.
- Bestätigt → `UI.pending_open_folder`; `main.zig` holt es per `takePendingOpenFolder` und
  ruft `openProjectFolder` (auch beim Start): Explorer-Root, `current_directory`,
  Git-Branch/-Status und File-Watcher wechseln. Offene Tabs bleiben erhalten.
- **Ordner ohne Repo bekommen keine git-Tasks.** `git_worker.isInsideRepo` (unit-getestet) sucht
  `.git` aufwärts; schlägt das fehl, bleibt `git_repo_path` null und weder Branch noch Status
  werden eingereiht. `runGitCwd` loggt bei Fehlern Befehl, Ordner und stderr — „git exited 128"
  allein sagte nicht, woran es lag.
- Kein nativer Dialog (zenity/kdialog/Portal): der In-App-Dialog ist headless testbar
  und braucht keine Systemabhängigkeit.
- File-Watcher registriert seinen Baum im eigenen Thread (`~/projects` hat tausende
  Ordner, das darf den Frame-Loop nicht blockieren).
- **Jedes Async-Result weckt den Frame-Loop:** `Scheduler.on_result` ist im Fenster-Modus
  `wio.cancelWait` (Worker und Watcher rufen es nach jedem `push`). Ohne Hook schläft der Loop
  in `wio.wait(.{})`, die Result-Queue (256) läuft bei ruhigem Fenster voll und der Watcher
  loggt pro Ereignis „result queue full". Headless braucht keinen Hook (Polling).
- E2E: `python3 scripts/e2e_open_folder.py [ordner]` startet headless, fährt Menü → Dialog →
  Pfad tippen → Enter und prüft den neuen Root; Screenshots in `tmp/e2e_menu.ppm` und
  `tmp/e2e_dialog.ppm`. RPCs dafür: `element_bounds(id)`, `element_bounds_i(id, index)`
  (Clay-Bounding-Box für Klicks auf beliebige Elemente), `folder_picker_state`,
  `get_state.root`, `key_press` kennt zusätzlich `o`, `up`, `down`.
- **Lucide-Icons sind Strichpfade.** `svg.Svg` füllt den Pfad (Explorer-Chevrons und
  Datei-Icons so gewollt); reine Linienpfade wie `plus`, `minus`, `check`, Pfeile bleiben
  gefüllt aber unsichtbar, Bögen (`undo_2`, `refresh_cw`) werden zu Klecksen. Dafür
  `svg.SvgStroke` (Strichbreite 2 auf viewbox 24, `SvgRenderInfo.stroke_width`, Atlas-Key
  unterscheidet Füllung/Strich). `tooltip.iconButton`, die SCM-Zeilenaktionen, der Commit-Knopf
  und die Graph-Kopfzeile zeichnen seit 18.09.2026 als Kontur. Der Rasterizer schreibt im
  Strich-Modus den Alpha auch nach R, weil `text_atlas.wgsl` mit R maskiert.
- Headless-Screenshots: der SVG-Atlas rasterisiert max. 4 neue Icons pro Render-Durchgang;
  neue Icons erscheinen daher erst im zweiten Screenshot (das Skript rendert zweimal).
- Logs: `logFn` schreibt per `writerStreaming`; mit `File.writer()` wurde eine umgeleitete
  Log-Datei (`2>log`) laufend ab Offset 0 überschrieben.

## Clay-Layout

**UI-Bausteine nie parallel nachbauen.** Scrollbalken, Tooltips, Kontextmenüs und
Eingabezeilen gibt es je einmal (`scrollbar.zig`, `tooltip.zig`, `context_menu.zig`,
`line_edit.zig`). Vor einem neuen Bedienelement dort suchen und das Modul verwenden oder
erweitern. Kopien bekommen Fixes nur an einer Stelle: der I-Beam über dem waagrechten
Balken war im Editor behoben und kam am 18.09.2026 in der Markdown-Vorschau wieder, weil
die einen eigenen Balken samt Zieh-Logik hatte.

Regeln und Fallstricke stehen in der Skill `.claude/skills/clay-layout/SKILL.md`
(Elementgrenze, Mindestbreite von Text ohne Umbruch, verschachteltes Clipping, IDs in
Schleifen, Fehlerhandler, Virtualisierung). `UI.MAX_CLAY_ELEMENTS` und `UI.clayError`
liegen in `src/ui/mod.zig`, das Virtualisierungsmuster in
`MarkdownView.renderDocumentVirtualized`. E2E: `python3 scripts/e2e_md_preview.py`.

- **Scrollbalken kommen aus `src/ui/scrollbar.zig`** (Modul `scrollbar`, eigenes Modul, weil
  code_editor.zig ein eigenes Test-Root ist). Clay hat keinen Balken, nur Clip-Container; die
  virtualisierten Ansichten scrollen über eigene Offsets. `Model` (Achse, Track, total, visible,
  offset, max_offset) → `geometry`, `hitTest` (Thumb greifen oder Seite blättern), `dragOffset`,
  `render`. Editor senkrecht und waagrecht nutzen es (`vscrollModel`/`hscrollModel`,
  `vscroll_drag`/`hscroll_drag`). Explorer: `FileExplorerState.scrollModel` in Pixeln, der
  Balken hängt an der Hülle `file_tree_area` und beginnt so unter der Filterzeile. Terminal:
  `TerminalInstance.scrollModel` in Zeilen, Track über die volle Höhe von `terminal_outer`
  (Lage aus dem Vorframe). E2E: `e2e_explorer.step_scrollbar`, `scripts/e2e_terminal.py`
  (RPC `terminal_state`: `view_row`, `total_rows`, `visible_rows`, `pane_index` für
  `element_bounds_i("terminal_scrollbar_track", pane_index)`). Die waagrechte Editor-Leiste misst die längste Zeile der
  ganzen Datei (`maxLineWidth`, gecacht, nach einem Edit nur der betroffene Bereich), damit sie
  beim senkrechten Scrollen stabil bleibt, und deckt auch den Gutter ab. E2E: `step_hscrollbar`
  in `scripts/e2e_editor.py`.

## Tastenkürzel und Menüs: eine Quelle

- `src/ui/shortcuts.zig` (Modul `shortcuts`) ist die einzige Tabelle: Command, Taste, Modifier,
  Scope (global / editor / explorer), Label, Anzeige-Text und die Menüstruktur File/Edit/View/Help.
  Unit-Tests prüfen Eindeutigkeit und Labels. Neue Kürzel nur dort eintragen, dann erscheinen sie
  automatisch in Menüleiste, Kontextmenüs und Help → Keyboard Shortcuts (F1).
- **Umschalt-Befehle zeigen ihren Zustand:** `toggleState(cmd)` in `src/ui/mod.zig` liefert für
  jeden `toggle_*`-Befehl den aktuellen Wert; das Dropdown zeichnet davor ein Häkchen
  (Clay-ID `menu_check_<command>`, E2E über `element_bounds`). Neuer Toggle: dort eintragen.
  Autosave steht zusätzlich als Feld `status_autosave` in der Statusleiste.
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
  (`requestMarkdownPreview`), aus dem Editor die des aktiven Buffers. Speichern (Ctrl+S oder
  Autosave) baut eine offene Vorschau derselben Datei neu auf (`UI.reloadMarkdownPreview`, liest
  die Datei, behält Scroll-Position, Folie und Schriftgröße); Split „Editor links, Vorschau
  rechts“ zieht damit nach. E2E: `python3 scripts/e2e_md_preview_reload.py`.
- **Breite der Aufklappmenüs ist dynamisch:** der Rahmen `menu_dropdown` ist `.w = .fit`, die
  Einträge sind `.w = .grow` mit `child_gap = 32`. Clay misst den breitesten Eintrag und zieht alle
  anderen darauf; die Kürzel stehen dadurch rechtsbündig, ohne dass jemand selbst misst. Vorher war
  der Eintrag fest 380 breit und lange Labels stießen an ihr Kürzel („Toggle Line Comment"
  überlappte „Ctrl+/"). Gemessene Breiten: File 523, Edit 687, View 475, Help 507.
- **Wann `fit`/`grow` reicht und wann nicht:** beim Menü darf der Rahmen mitwachsen, die Einträge
  sind eine kurze bekannte Liste. Im Picker ist der Kasten bewusst fest (720) und der Inhalt
  unbegrenzt lang (Pfade) — dort braucht es die Obergrenze `growMinMax` plus Kürzen. Erst prüfen,
  ob der Rahmen mitwachsen darf; nur wenn nicht, selbst messen.
- Globale und Explorer-Kürzel löst `UI.handleKeyPress` über `shortcuts.lookup` auf und führt sie
  mit `executeCommand` aus; Menüklicks gehen denselben Weg. Editor-Kürzel (Scope `editor`) liegen
  weiterhin in `src/editor/keymap.zig` und müssen zur Tabelle passen (Save, Undo/Redo, Cut/Copy/
  Paste, Select All, Delete Line Ctrl+Shift+K, Find Ctrl+F).
- Globale Kürzel greifen vor Terminal/Chat: Ctrl+W, Ctrl+N, Ctrl+O, Ctrl+B, Ctrl+` und
  Ctrl+Tab kommen im Terminal nicht mehr an der Shell an (bewusst, wie in Zed).
- Suchleiste (`CodeEditor.find` = `find_bar.FindState`, Leiste `find_bar.render`, gemeinsam mit
  der Markdown-Vorschau; Logik in `src/editor/find_ops.zig`): inkrementell beim Tippen,
  Enter/Shift+Enter weiter/zurück mit Umbruch, Escape schließt, markierter Text wird Suchbegriff.
  Ctrl+F bei offener Leiste markiert den Begriff neu (Tippen ersetzt ihn), Ctrl+H schaltet
  Ersetzen dazu. Die Widget-IDs (`find_widget`, `find_input`, `replace_*`, `goto_*`) tragen das
  Editor-Salz (`idi`), zwei Panes mit offener Leiste meldeten sonst duplicate_id.
  E2E: `python3 scripts/e2e_find_preview.py` (Vorschau, Editor-Tab, Split).
  Spalten sind Codepoints, Tabs/Breitzeichen sind nicht berücksichtigt.
- Tests in `src/editor/code_editor.zig` laufen nur, weil die Datei eigenes Test-Root ist
  (`code_editor_tests` in build.zig, wio-Symbol-Hack unter `is_test` in der Datei). Tests in
  importierten Modulen führt der Runner nicht aus; `zig build test --summary all` zeigt die
  Zähler pro Modul, ein absichtlich kaputter Test ist der schnellste Beweis.
- E2E: `python3 scripts/e2e_shortcuts.py` fährt headless alle Kürzel und Menüs durch (Explorer
  F2/Entf, Tabs, Ansicht, Menüleiste, Kontextmenü, Shortcut-Dialog, Suchleiste) und legt
  Screenshots unter `tmp/e2e_*.ppm` ab.

## Textfelder: zwei Sorten, klar getrennt

- **Mehrzeilig → `CodeEditor`**: Haupteditor, KI-Chat-Eingabe und das Commit-Feld der
  Source-Control-Ansicht. Damit gibt es dort Umbruch, Rückgängig, Mausauswahl,
  Kontextmenü und unbegrenzte Länge. Das Commit-Feld war vorher ein eigener Puffer mit
  2048 Bytes ohne Ctrl+Z; `scm_changes_view` zeichnete Zeilen, Auswahl und Schreibmarke
  von Hand.
- **Einzeilig → `line_edit` + `explorer_ops.EditBuffer`**: Umbenennen und Filter im
  Explorer, Schnellöffner, Ordner-Dialog. Klein gehalten, kein Umbruch
  (`wrap_mode = .none`). Rückgängig gibt es dort seit Kurzem, aber nur **einen** Schritt
  (`undoEdit`/`redoEdit`): zusammenhängendes Tippen ist eine Gruppe, eine Cursorbewegung
  schliesst sie. Doppelklick markiert das Wort (`selectWordAtCursor`); die Zeit dafür kommt
  aus `std.time.milliTimestamp`, damit die Aufrufer keine Uhr durchreichen müssen.
- Jeder eingebettete `CodeEditor` braucht die Modifier: `UI.setCtrlState`/`setAltState`/
  `setShiftState` reichen sie an Chat **und** Commit-Feld weiter. Ohne das greift die
  Keymap des Editors nicht und Ctrl+Z tut nichts.

## KI-Chat (llama-server)

Details in der Skill `.claude/skills/llm-local/SKILL.md`: Backend- und Gerätewahl,
llama-server-Argumente, Streaming und `AgentStatus`, Chat-Eingabe als CodeEditor,
gepinnte Engines unter `engines/`, Modellablage und die Messregeln aus `llm-bench/`.

Kurz: zid spricht ausschliesslich mit llama-server. Quellen in dieser Reihenfolge:
`engines/llama.cpp-vulkan/build/bin/llama-server` samt `models/gemma-4-E2B-it-Q4_0.gguf`
im Quellbaum (`src/ai/paths.zig`), sonst das Datenverzeichnis, das zid sich selbst
einrichtet (`src/ai/selfsetup.zig`). Fehlt beides, zeigt der Chat einen Knopf, der
Engine und Modell lädt. `LLAMA_SERVER_PATH` und `LLAMA_MODEL_PATH` überschreiben. zid nutzt nur lokale Backends; Cloud-
Anbieter (Claude, OpenAI) sind eine Entscheidung des Projektinhabers dagegen. RPC `chat_state`,
E2E `python3 scripts/e2e_ai_chat.py` und `scripts/e2e_ai_tools.py`.

Drei Regeln aus der Messreihe vom 17.09.2026
(`llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md`, Laptop-Gegenprobe
`linux-p1000-gemma4-vs-qwen3.md`):

- **Thinking aus.** llama-server bekommt `--chat-template-kwargs {"enable_thinking":false}`.
  Denkende Modelle (gemma4) streamen sonst
  20–30 s `reasoning`, bevor das erste `content`-Delta kommt. `--reasoning-budget 0` und
  `think: false` wirken nicht.
- **Werkzeug-Prompt klein halten.** Das `command`-Werkzeug trägt die Kommandos nur als
  Enum im Schema, keine Liste mit Label oder Kürzel im Text. Die Liste kostete 1000 Token,
  auf CPU 20 s vor dem ersten Delta, und brachte gemma4 dazu, `open_folder` statt
  `command` zu wählen. Jeder Stream endet mit einer `usage:`-Logzeile (Prompt-Token,
  `prompt_ms`) — vor Prompt-Änderungen vorher/nachher ablesen.
- **Enum-Wert als Werkzeugname** (`toggle_explorer` statt `command{name}`) führt
  `agent_actions` als Kommando aus (`ai_tools.commandFromToolName`), statt „unknown tool"
  zu melden; kleine Modelle tun das.

## Schaltflächen: `components/button.zig`

- Einheitliches Aussehen über `button(id, text, theme, mouse_x, mouse_y, mouse_pressed, opts)`
  mit den Rollen `primary` (Hauptaktion), `secondary` (Nebenaktion) und `ghost` (unauffällig,
  Fläche erst beim Überfahren). `disabled` dämpft und schluckt Klicks.
- Der Treffer wird gegen die Box aus dem letzten Layout gerechnet, **nicht** über
  `clay.pointerOver`: im Frame eines RPC-Klicks kennt Clay die neue Zeigerposition noch
  nicht, der Klick ginge verloren.
- Die alte Fassung war unbenutzt, hatte Schriftgröße 24 fest verdrahtet und nutzte
  `pointerOver`. Wer eine Schaltfläche braucht, nimmt diese Komponente statt selbst zu
  zeichnen — sonst fehlen Hover und Rahmen, wie beim ersten „Verlauf kopieren".
- Eine Aktion ohne sichtbare Folge bestätigt sich per `UI.showToast`.

## Explorer: Fokus, Tastatur, Auswahl, Papierkorb

- **Symlink auf einen Ordner ist ein Ordner** (`explorer_ops.isDirectory` folgt dem Link, z. B.
  `wartungsheft/business-plan -> ../business/auto-service`). `TabBar.appendFileTab` lehnt
  Verzeichnisse mit `error.IsDir` ab, egal ob Explorer, Ctrl+P, Agent oder RPC `open_file`.
  Scheitert der Buffer-Load beim Tab-Wechsel trotzdem (z. B. AccessDenied), meldet `main.zig`
  den Fehler einmal, schließt den Tab und nullt `pending_switch_path`; sonst wiederholt sich
  der Fehler in jedem Frame. E2E: `python3 scripts/e2e_symlink_dir.py`.

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
  Taste `.` oder „Toggle Hidden Files" im View-Menü (`show_hidden`, gedämpft, mit Häkchen); die
  Taste allein war nicht auffindbar. Das Filterfeld öffnet `/` (Name enthält Text, Elternordner
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
- **Kleine Editierfelder** (Umbenennen, Anlegen, Filter, Picker-Suche, Pfad im Ordner-Dialog,
  Commit-Nachricht) teilen `explorer_ops.EditBuffer` und `line_edit.zig`. Seit 18.09.2026 mit
  Auswahl: `anchor` im Puffer, Shift+Pfeile/Pos1/Ende/↑↓ erweitern, Ctrl+←/→ wortweise
  (`moveWordLeft/Right`, Klassen Wort/Satzzeichen/Leerraum), Ctrl+A/C/X/V über
  `line_edit.Clipboard` (`UI.editClipboard`: Fenster oder headless `last_clipboard_text`),
  Shift+Klick und Ziehen (`handleClick(extend)`, `handleDrag`, `handleRelease`; `mouse_selecting`
  im Puffer). Tippen/Backspace/Entf/Einfügen ersetzen die Auswahl im `EditBuffer`, einzeilige
  Felder machen beim Einfügen aus Umbrüchen Leerzeichen (`insertText(multiline)`). Markierung:
  Element `<feld-id>_sel` (Commit-Feld `sc_input_sel` je Zeile). Die Feld-Handler bekommen
  `line_edit.Mods` und `?Clipboard` von `mod.zig` (`editMods`). Unit-Tests in `explorer_ops.zig`,
  E2E `python3 scripts/e2e_line_edit.py`.
  Anlegen zeigt eine Eingabezeile unter dem Zielordner (`startCreate`, `targetFolder`: markierter
  Ordner, sonst Elternordner, sonst Root); Enter legt an (Dateien werden geöffnet), Escape bricht ab.
- **Löschen = Papierkorb** (`explorer_ops.trashPath`: `$XDG_DATA_HOME/Trash` bzw. `~/.local/share/Trash`,
  `files/` + `info/*.trashinfo`, DeletionDate in UTC), Fallback `gio trash`, nie endgültig.
  E2E-Skripte setzen `XDG_DATA_HOME=tmp/xdg`, damit der echte Papierkorb leer bleibt. Fehler von
  Explorer-Aktionen landen in `takeError` → Dialog „Error“ statt nur im Log.
- **Dialoge per Tastatur** (`dialog_ops.zig`, unit-getestet): Enter wählt den fokussierten Button
  (Start: erster = primär), Escape Cancel, Tab/Shift+Tab wandern, Anfangsbuchstabe wählt (`d` Delete,
  `s` Save, `n` Don't Save). Bei offenem Dialog erreicht keine Taste und kein Zeichen den Editor.
  In `renderExample` wird `ad.key_result` erst nach dem Übernehmen in `pending_dialog_result`
  geleert: `res = render(...) orelse ad.key_result` verwies unter Windows noch auf das Feld, das
  vorherige Nullen kam als null an und keine Taste schloss einen Dialog.
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
- **Ctrl+X ohne Auswahl schneidet die ganze Zeile aus** (VS Code, Zed): Zeile plus Umbruch in
  die Zwischenablage, dann `DeleteLine`. Mit Auswahl bleibt Cut wie gehabt.
- **Metrik-Fix:** `egc_chunk_width` lieferte für jeden Chunk 1; `insert_chars` addiert die Chunk-
  Breite zur Cursor-Spalte, der Cursor stand nach Einfügen/Autoclose eine Spalte zu weit links.
- **Undo-Schritte und Undo-Cursor:** `snapshotForUndo` legt die Cursor-Position (`zeile:spalte`)
  als Metadaten in den flow-core-Undo-Stand; `afterUndoRedo` setzt den Cursor dorthin (begrenzt)
  statt an den Dateianfang und nimmt den Geändert-Status aus `Buffer.is_dirty()`. Eine Tipp-Gruppe
  endet, wenn der Cursor nicht mehr hinter dem zuletzt getippten Zeichen steht (`typing_end`), und
  beim Speichern (`markSaved`): nur dann ist der root des nächsten Undo-Stands `last_save`, und
  Undo zurück dorthin macht den Tab sauber. Vorher lief eine Gruppe über Cursorsprünge hinweg, ein
  Undo nahm auch weit entfernte Eingaben zurück.
- **Cursor-Spalte nach Tippen kommt aus `insert_chars`** (`result[1]`), nie aus der Byte-Länge: ein
  Umlaut ist 2 Bytes, aber 1 Spalte. Mit Byte-Länge stand der Cursor danach im Chat-Eingabefeld
  hinter dem Zeilenende und jede weitere Eingabe scheiterte still (`INSERT FAILED`).
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
- Datei außerhalb geändert: Watcher-`file_changed` oder `file_created` (atomares Ersetzen per
  rename meldet IN_MOVED_TO) → `UI.handleExternalChange`: gleicher Inhalt (eigener Save)
  ignoriert, ungeänderter Buffer wird still neu geladen, geänderter fragt („File Changed“:
  Reload / Keep Mine). Symlink-Ordner: der Linux-Watcher steigt auch in Link-Ordner ab (inotify
  folgt dem Link; schon bekannter Watch-Deskriptor = kein zweiter Abstieg), und
  `bufferKeyForPath` findet den Buffer notfalls über realpath, weil Ereignis- und Öffnungspfad
  verschiedene Schreibweisen derselben Datei sein können. E2E:
  `python3 scripts/e2e_external_change.py` (in-place, atomic, Symlink im und außerhalb des
  Projekts). Unter Windows nimmt die Suite ohne Symlink-Recht Junctions und schreibt LF
  (`newline="\n"`; im Textmodus käme CRLF und schon der Ausgangsvergleich schlüge fehl).
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
  (VS Code bewegt sich reihenweise); horizontale Scrollbar und Shift+Mausrad sind aus. Die
  Obergrenze fürs Scrollen ist `maxViewRow`: sie summiert bei Wrap die Reihen von hinten, bis der
  Schirm voll ist; Zeilen minus sichtbare Zeilen ließe das Dateiende unerreichbar. Rad, Leiste
  (Daumen über `totalVisualRows`) und Ziehen benutzen sie.
  RPC `editor_state.word_wrap`, `editor_state.visual_rows` (Reihen der Cursor-Zeile).
- **Neue Editoren erben Optionen:** `splitActivePane` kopiert Minimap/Whitespace/Guides/Wrap,
  Schriftgröße und Theme vom Ausgangs-Editor (`copyEditorOptions`); vorher hatte der zweite Pane
  Standardwerte, und `loadUserState` erreichte nur die beim Start vorhandenen Leaves.
- **Clay `getElementData` vergisst nichts:** IDs, die nicht mehr gerendert werden, bleiben `found`
  mit alter Geometrie. E2E-Prüfungen auf „Element ist weg“ sind wertlos; Zustand per RPC prüfen.
  Für ausgeblendete Kontextmenü-Einträge geht es trotzdem: der Eintrag muss innerhalb des frisch
  gezeichneten `<prefix>_container` liegen (`menu_entry_visible` in `scripts/e2e_marp_pdf.py`).
- **E2E nie mit der echten Konfiguration:** `start_zid` in `scripts/e2e_open_folder.py` setzt ohne
  eigenes `env` frische `XDG_CONFIG_HOME`/`XDG_DATA_HOME` unter `tmp/e2e_env/<log-name>`. Mit
  `~/.config/zid/state` (Word-Wrap, Schriftgröße, Sidebar-Breite) messen Suiten Fremdzustand und
  überschreiben ihn. Neue Suiten starten zid deshalb über `start_zid`, nie per `Popen`.
- **Split behält Chat und Terminal:** `splitActivePane` gibt die bisherige Tab-Leiste an die
  erste Hälfte weiter, nur die neue Hälfte bekommt `cloneFrom` (ohne Chat und Terminal). Zwei
  Kopien ließen Chat-Tabs und Terminal-Instanzen verschwinden. E2E: `e2e_tabs.py`.
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
  **jedem Frame** auf Dark, deshalb griff kein Umschalter.
- **Zoom:** Ctrl+=/Ctrl+-/Ctrl+0 (`zoom_in/out/reset`, 10–48, `setFontSizeAll` für alle Panes).
  Klein gezoomt zeichnet der Editor mehr Reihen; das Layout selbst darf dabei nie wachsen
  (Minimap-Rückkopplung, siehe Skill `clay-layout`; `python3 scripts/e2e_layout_stable.py`).
  Der Glyph-Cache (4096 Einträge, je Größe × 4 Subpixel-Varianten) leert sich komplett, wenn er
  voll ist (`GlyphCache.ensureFreeSlot`), statt neue Glyphen jeden Frame neu zu rastern.
- **Fenster schließen fragt nach:** wio `.close` beendet nicht selbst (`platform/mod.zig`), sondern
  ruft `UI.requestQuit`. Ohne ungespeicherte Buffer (`Buffer.is_dirty()` über `open_buffers`)
  setzt es `quit_confirmed`, sonst Dialog „Unsaved Changes“ (Save All / Don't Save / Cancel);
  Save All legt wie `save()` eine Sicherung an und bricht beim ersten Speicherfehler ab, ohne zu
  beenden. Der Main-Loop endet über `quit_confirmed`. RPC `request_quit` stellt den
  Schließen-Knopf nach, E2E `python3 scripts/e2e_quit_unsaved.py`.
  **Nach dem Laden `UI.markLoaded`, nie nur `last_save = root`:** `is_dirty` vergleicht auch
  `last_save_eol_mode` (Vorgabe LF) mit dem erkannten `file_eol_mode`. Bis 21.09.2026 galt so
  jede CRLF-Datei ab dem Öffnen als geändert (unter Windows jede aus Git ausgecheckte), dazu der
  namenlose Scratch-Buffer ohne Startdatei; Beenden fragte nach „todo.md, .“.
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
- **Zeilenlayout bei Dateien** (`src/ui/path_display.zig`, unit-getestet): Dateiname zuerst in
  Textfarbe, Ordner gedimmt dahinter und mittig gekürzt (`truncateMiddle`, Auslassungszeichen,
  zählt Zeichen statt Bytes). Vorher stand der ganze Pfad von links in der Zeile und wurde rechts
  abgeschnitten; in tiefen Bäumen sahen dadurch alle Treffer gleich aus, weil genau der
  unterscheidende Teil wegfiel. VS Code und Zed stellen den Namen ebenfalls nach vorn, snacks.picker
  kürzt standardmäßig in der Mitte. `ROW_CHARS` rechnet das Zeichenbudget aus `BOX_WIDTH` — zulässig,
  weil die einzige Schrift eine Monospace ist. `commonPrefix` liegt bereit für Zeds Ansatz
  (gemeinsame Segmente aller Treffer wegkürzen), ist aber noch nicht verdrahtet.
- **Clay: Text ohne Umbruch ist eine Mindestbreite.** `wrap_mode = .none` meldet die volle
  Textbreite als Mindestmaß, und Clay zieht Zeile und Liste darauf auf — gemessen 1236 px in einem
  720 px breiten Kasten, worauf der rechtsbündige Ordner ins Leere geschoben wurde. Abhilfe ist
  `SizingAxis.growMinMax(.{ .min = 0, .max = … })` auf der Zeile, das Gegenstück zu `max-width`;
  in CSS entspricht das `min-width: 0` an einem Flex-Element. **Kein verschachteltes `.clip`** als
  Ersatz: der innere Clip ersetzt im Renderer den äußeren statt sich mit ihm zu schneiden, dann
  läuft die Liste unten aus dem Kasten.
- Breiten werden gemessen, nicht aus Zeichen geschätzt: Name (18 px) und Ordner (14 px) stehen in
  verschiedenen Größen, ein gemeinsames Zeichenbudget lag daneben. `truncateToWidth` sucht die
  Zeichenzahl binär über `ui.measureTextWidth`.
- `Picker.dirShown` ist die eine Quelle für Render und RPC, damit der E2E prüft, was gezeichnet wird.
  `e2e_picker.py` prüft zusätzlich die Geometrie (Zeile ⊆ Kasten) — die reinen Textprüfungen waren
  grün, während die Zeile 1236 px breit war.
- RPC `picker_state` (open, scanning, mode, query, matches, items, selected, selected_label,
  selected_dir_shown); `python3 scripts/e2e_picker.py`.

## Tab-Leiste

- **„+“ (Neu-Menü) sitzt ganz links** vor dem scrollenden Tab-Streifen. Der Streifen hat `.w = .grow`
  mit Clip; stand der Knopf dahinter, wanderte er an den Fensterrand und sein Dropdown wurde
  abgeschnitten.
- **Beschriftung** (`tabLabel`): Markdown-Vorschauen heißen „Preview: name“; gleicher Dateiname in
  zwei Tabs derselben Art bekommt den Elternordner davor. Split (`cloneFrom`) kopiert Text-,
  Bild- und Vorschau-Tabs, aber nicht Chat und Terminal (ein Zustand, eine Zeichnung je Frame,
  siehe Skill `clay-layout`).
- **Keine Vorschau-Tabs** (auf Wunsch des Projektinhabers; VS Code und Zed haben
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
- **Leiste** scrollt den aktiven Tab per `scroll_x` in den Sichtbereich (`tab_strip` mit Clip).
  Klicks auf Tabs zählen nur innerhalb von `tab_strip`: weggescrollte Tabs liegen mit ihrer
  Bounding-Box unter „+“, der Sidebar oder rechts außerhalb des Fensters. E2E aktiviert Tabs
  außerhalb des 1200-px-Fensters per Ctrl+1…9 statt per Klick;
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

Details in der Skill `.claude/skills/marp/SKILL.md`. Kurz: Parser `src/ui/marp.zig`
(Modul `marp`), HTML `src/ui/marp_html.zig`, PDF `src/rendering/marp_pdf.zig` über
MuPDFs Story-Engine. Folienvorschau in `MarkdownView` (`deck`-Feld), Command
`md_export_pdf`. E2E: `python3 scripts/e2e_marp_pdf.py`, Fixture
`scripts/fixtures/marp_test.md`.

## Tooltips für Icon-Schaltflächen

- `src/ui/components/tooltip.zig`: `iconButton(arena, theme, id, icon_id, icon, label, opts)` ist der
  gemeinsame Knopf (Hintergrund beim Überfahren, `toggled` in Primärfarbe), `attach(theme, id,
  label)` hängt einen Tooltip an ein selbst gezeichnetes Element. Tooltip erscheint nach 700 ms über
  demselben Element unter dem Element (`hover_delay.Hover`, Modul `hover_delay`, unit-getestet);
  `beginFrame`/`endFrame` rahmen `renderExample` ein. Zustand ist modulweit, der Text muss den
  Frame überleben (Literal oder Frame-Arena).
- Beschriftungen wie VS Code: Timeline (Pin the Current Timeline / Unpin …, Refresh), Graph
  (Refresh, Open Changes), Changes (Commit, Sync Changes / Publish Branch, Refresh, Open File, Stage/Unstage/Discard
  Changes, Stage/Unstage/Discard All Changes), Diff-Editor (Previous/Next Change, Toggle Collapse
  Unchanged Regions, Switch to Inline/Side by Side View), Multi-File-Diff (Collapse/Expand All
  Diffs), Ordner-Dialog (Parent Folder), Statusleiste (Current Git Branch, Toggle Autosave).
  Neue Icon-Knöpfe immer über `tooltip.iconButton` anlegen.
- E2E: `ui_state.tooltip` = Text des Tooltips im letzten Frame (null ohne), geprüft in
  `e2e_scm_changes.py` und `e2e_timeline.py` (Maus 1 s über dem Knopf halten).

## Clay: gepatchte clay.h unter libs/clay-zig/vendor

Das Submodul zeigt auf den eigenen Fork `gstrainovic/clay-zig-bindings`, Branch `zid`
(Upstream johan0A als Remote `upstream`); dort liegen beide Fixes als Commits `598a5c7`
(Scroll-Container), `27407cd` (Hash-Map) und `7c66140` (Messcache). Für eine neuere clay.h den Branch `zid` auf
upstream rebasen. `libs/clay-zig/build.zig` legt `vendor/clay.h` vor die Abhängigkeit. Gegenüber v0.14 (upstream
unverändert) sind dort drei Stellen in `Clay_UpdateScrollContainers` korrigiert, alle mit „zid:“
markiert: Swap-Remove ohne `i--` übersprang Einträge, `Clay__GetHashMapItem` liefert nie `NULL`
(sondern `&Clay_LayoutElementHashMapItem_DEFAULT`), und der Zeiger auf das Clip-Element wird vor
dem Zugriff geprüft. Ohne den letzten Punkt stürzte zid mit „member access within null pointer of
type Clay_ClipElementConfig“ ab, sobald nach einem Diff-Tab ein Multi-File-Diff im selben Pane
stand. Clays Scroll-Positionen benutzt zid nicht, aber jedes `.clip`-Element legt dort einen
Eintrag an, und nur `UI.updateScroll` räumt die (10 Einträge große) Liste auf.

Zweiter Fix (`27407cd`): **Clays Hash-Map der
Element-IDs liegt im persistenten Speicher und wurde nie geleert.** Jede je gesehene ID
(auch anonyme Textstücke: Hash aus Eltern-ID und Kindindex) belegt einen Eintrag, bis die
Kapazität `maxElementCount` (16384) erreicht ist; danach liefert `Clay__AddHashMapItem` still
`NULL`, neue Elemente haben keine Bounds (`getElementData` „nicht gefunden“), kein Hover, kein
Klick. Die Markdown-Vorschau ohne Zeilenumbruch (hunderte Stücke je Reihe, beim Scrollen immer
andere Reihen-Slots × Kindindizes) füllte die Map in Sekunden; Symptom in der E2E: nach der
Vorschau hatte ein neuer Tab keine `tab_bounds`, obwohl er sichtbar war. Im Alltag träfe es
jede lange Sitzung mit vielen Vorschauen oder Chat-Bubbles (je `MarkdownView` neue IDs).
`Clay__CompactLayoutElementsHashMap` läuft in `Clay_BeginLayout`, sobald die Map zu drei
Vierteln voll ist: behält Einträge der letzten drei Frames, verdichtet `debugElementData`
im Gleichschritt (Zeiger je Eintrag) und baut die Buckets neu. Für die E2E heißt das:
`element_bounds` verschwundener Elemente bleiben nur, solange die Map nicht verdichtet wurde —
darauf nie bauen (siehe `visible_blocks` in `e2e_md_preview.py`). Bei „Element X nicht im
Layout“, obwohl X sichtbar ist: zuerst an diese Map denken.

Dritter Fix (`7c66140`): **Der Messcache der Texte lief beim Streamen voll.** Clay gibt Einträge
und ihre Wörter nur frei, wenn ein Nachschlagen zufällig über einen veralteten Eintrag im selben
Bucket läuft. Die gestreamte Chat-Antwort ist ein einziger wachsender Absatz: jedes Delta ein
neuer Eintrag mit allen Wörtern, die alten trifft kaum ein Nachschlagen; nach ~1500 Zeichen war
die Wortgrenze (16384) voll („run out of space in it's internal text measurement cache“), danach
blieb Text ungemessen. `Clay__ResetMeasureTextCacheWhenFull` leert den Cache in
`Clay_BeginLayout`, sobald Wort- oder Eintragsliste zu drei Vierteln voll ist. Unit-Test
`src/ui/clay_cache_tests.zig` (eigenes Test-Root mit Clay, ohne UI).

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
  bekanntes Verhalten (Tastatur-Fokus pro Tab-Art ist nicht umgesetzt).
- Textstücke über `ShapedRunCache.MAX_TEXT_LEN` (2048 Bytes) passen nicht in den Shape-Cache und
  gehen ungecacht über den Heap (`shapeTextInto` → `shapeText`); erst über `max_draw_run_bytes`
  (256 KiB, Schutz gegen kaputte Zeiger) werden sie verworfen, gezählt (`ui_state.text_runs_dropped`)
  und einmal geloggt. Der Editor gibt pro Zeile trotzdem nur den sichtbaren Spaltenausschnitt an Clay (`CodeEditor.visibleSliceOf`: ab
  `view.col`, `view.cols + 2` Spalten; `view.cols` kommt aus `visibleColCount` = Editor-Breite minus
  Gutter durch Zeichenbreite). Highlight-Tags, Auswahl und Cursor rechnen mit dem Byte-Offset des
  Ausschnitts. `View.clamp` (flow-core) zieht `view.col` dem Cursor nach; Shift+Mausrad bzw.
  `scroll_horizontal` scrollt Spalten (`scrollColumns`). RPC `editor_state` liefert `view_col`/`view_cols`.
- **Spalten sind Codepoints** (Tab = 4). `CodeEditor.metrics.egc_length` liefert die Länge der
  UTF-8-Sequenz bei einer Spalte; `cursor.col`, `view.col`, `find_ops`, `wrap_ops`,
  `renderRowOverlays` und die LSP-Positionen rechnen alle so. Bytes bekommt man nur über
  `get_line_width_to_pos` (Spalte → Byte) und `pos_to_width` (Byte → Spalte); tree-sitter-Edits
  (`pushEditForChange`) und die Highlight-Tags sind Byte-Offsets. Bis 18.09.2026 zählte
  `egc_length` jedes Byte als Spalte (Rest eines Qwen-Fixes vom April): ←/→ liefen in zwei
  Schritten durch ein „ü“, Tippen dazwischen zerschnitt die Sequenz (`a\xc3x\xbcb` im Buffer,
  so gespeichert), und `visibleSliceOf` schnitt in schmalen Panes mitten im Gedankenstrich
  (`warning(shaper): invalid UTF-8 text … "> **Tab 1 \xe2\x80"`). Wer Metriken schreibt, muss
  `reparseFromBuffer` (flow-core) im Blick behalten: tree-sitter meldet Byte-Spalten, der
  Wrapper dort liest byteweise, unabhängig von der Spaltendefinition.
- `python3 scripts/e2e_odd_files.py` legt unter `tmp/` eine 3-KB-Binärdatei ohne Zeilenumbruch,
  eine 5000-Zeichen-Zeile und eine 5-MB-Datei an, öffnet sie headless, tippt und misst die Latenz
  bis das Zeichen in `editor_state` steht (gemessen 0,06 s bei der langen Zeile,
  1,2–2,4 s bei der 5-MB-Datei); die Binärdatei muss als Tab-Art `binary` ohne Buffer erscheinen. Logs mit Binärinhalt nur mit `grep -a` lesen, sonst schweigt grep.
- Der RPC-Socket bindet nur mit SO_REUSEADDR, nie mit SO_REUSEPORT (`Address.listen` mit
  `reuse_address` setzt beides). Sonst lauscht eine verwaiste Instanz weiter, der Kernel
  verteilt die Verbindungen, und ein Teil der RPC-Antworten kommt aus dem alten Prozess mit
  altem Zustand. Ein zweiter Start meldet jetzt `Port 9999 ist belegt`.
- E2E-Skripte starten zid nie über `zig build run`, sondern über `start_zid` aus
  `scripts/e2e_open_folder.py`: erst `zig build`, dann das Binary als direktes Kind. Bei `zig build
  run` ist zid ein Enkel, ein `kill` auf zig lässt zid auf dem Port zurück; Prozessgruppen
  (`start_new_session`/`killpg`) als Ausweg gibt es unter Windows nicht. `stop_zid` beendet per RPC,
  notfalls hart.
- **Nicht alle Suiten bauen selbst.** Nur wer `start_zid` nimmt, ruft vorher `zig build` auf.
  `e2e_scm_changes.py`, `e2e_scm_graph.py`, `e2e_timeline.py`, `e2e_git_diff.py`, `e2e_lsp.py`,
  `e2e_editor.py`, `e2e_picker.py` u. a. starten `zig-out/bin/zid` direkt: vor dem Lauf `zig build`,
  sonst testet die Suite still das alte Binary (18.09.2026 so passiert, der Knopf zeigte noch
  „Push 1↑").
- **Suiten nacheinander, nie parallel** — auch nicht als zwei Hintergrund-Tasks. Alle nutzen
  Port 9999; ein zweiter Lauf redet mit der Instanz des ersten, und beide scheitern ohne
  erkennbaren Grund.
- **Zeitfehler erst messen, dann erklären.** Kommt ein Tooltip oder Toast zu spät, zuerst mit
  einem 100-ms-Polling-Probe die echte Dauer bestimmen (beim Tooltip-Fehler 1,5 s statt 0,7 s,
  Ursache war die Frame-Uhr), nicht am Timeout des Tests schrauben.
- **Fenster nur nach Rückfrage.** Auch Reproduktionen und Messungen laufen `--headless`. Braucht
  ein Befund zwingend ein Fenster (Present, Swapchain, DPI, Maximieren), das begründen und den
  User fragen oder ihn selbst starten lassen und das Log auswerten. Frame-Vergleiche per
  Screenshot-RPC zeigen kein Present-Flackern, das nur am Monitor sichtbar ist.
- **Meldungen aus dem Fenster am echten Dokument nachstellen.** „Funktioniert nicht" hat oft eine
  andere Ursache als vermutet (18.09.2026: „Word Wrap geht nicht" war Text in Listen, der an der
  vollen statt der eingerückten Breite umbrach). Die Datei des Users aus dem Log holen (die
  Ausgabe von `zig build run` zeigt geöffnete Pfade), headless öffnen, Zustand per RPC messen,
  notfalls in Zeilenbereiche schneiden, bevor eine Theorie entsteht. Ein Test muss den Effekt an
  dem prüfen, was der User sieht (Fliesstext), nicht nur an einem Sonderfall (Codeblock).
- Verwaiste Headless-Prozesse: Linux `pkill -f '[v]ulkan-ed --headless'` — ohne die Klammer trifft
  das Muster die eigene Shell, die den Befehl enthält. Windows: **nie** `taskkill /IM zid.exe` —
  das beendet auch die Fenster des Users samt ungespeicherter Änderungen (21.09.2026 so passiert).
  Nur Headless-Instanzen gezielt per PID:
  `Get-CimInstance Win32_Process -Filter "Name='zid.exe'" | ? CommandLine -match '--headless' |
  % { Stop-Process -Id $_.ProcessId -Force }`.
- **Windows:** Die Suiten laufen headless genauso (`python scripts/e2e_*.py`, kein Fenster).
  RPC-Antworten mit Pfaden immer über `std.json.fmt`/`Stringify` bauen, nie `"{s}"`: Backslashes
  ergeben sonst ungültiges JSON und jede Suite scheitert beim ersten `ui_state`. Die Text-Probe
  (memfd) und der Test auf unlesbare Dateien (`chmod 0`) greifen nur unter Linux; `e2e_symlink_dir.py`
  nimmt ohne Symlink-Recht eine Junction (`mklink /J`).
- **Explorer sortiert nicht:** Reihenfolge ist die des Dateisystems (ext4 Hash-Reihenfolge, NTFS
  alphabetisch). Tests navigieren deshalb per berechneter Anzahl ↑/↓ (`cursor_to` in
  `e2e_explorer.py`), nie mit fest angenommenen Nachbarn.
- **File-Watcher Windows** (`src/async/file_watcher_win.zig`): `ReadDirectoryChangesW` auf die
  Wurzel mit ganzem Baum, überlappende I/O mit Event (Stop-Flag alle 100 ms). Gleiche Ergebnisse
  und Filter wie Linux (versteckte Pfadteile, `zig-out`, `node_modules`, `.gguf`, 100-ms-Dedupe).
  Atomares Speichern (Rename) meldet `file_created`, nur Überschreiben `file_changed` — wie
  inotify. `src/async/file_watcher.zig` ist ein alter, nicht eingebundener Stub.
  `bWatchSubtree` folgt keinen Reparse-Points: der Watcher-Thread sucht deshalb nach dem Start
  Symlink-/Junction-Ordner mit Ziel außerhalb der Wurzel (`GetFileAttributesW`, denn
  `Dir.iterate` meldet sie als `.directory`) und öffnet je Ziel ein eigenes Handle (höchstens 63),
  Ereignisse kommen unter dem Link-Pfad; gewartet wird mit `WaitForMultipleObjects`. Ziele
  innerhalb braucht es nicht (realpath in `bufferKeyForPath`). Nicht abgedeckt: Links, die nach
  dem Start entstehen, und Links innerhalb eines Link-Ziels. E2E `e2e_external_change.py`.
- Testdaten der Suiten kommen aus `scripts/fixtures/` und `scripts/e2e_fixtures.py` (PDF, PNG
  werden erzeugt), nicht aus dem ignorierten `test_data/`. Git-Fixtures löscht
  `e2e_open_folder.rmtree` (setzt Rechte auf `.git/objects`, sonst bleibt das Fixture unter
  Windows still stehen); die Suiten stellen stdout auf UTF-8 (Pfeile in Meldungen).
- **Zeilenenden:** Git for Windows setzt systemweit `core.autocrlf=true`. Neue Git-Fixtures in
  Zig-Tests und Suiten setzen `core.autocrlf false` (daran scheiterte
  `git_worker.test.taskGitAction` bis 21.09.2026), Python-Suiten schreiben Dateien mit
  `newline="\n"`.
- Umgebungsvariablen nur über `src/platform/env.zig` lesen, nie `std.posix.getenv` — das gibt
  es unter Windows nicht, und der Windows-Build bricht still, weil hauptsächlich unter Linux
  entwickelt wird. Bei neuen Windows-Buildfehlern zuerst `zig version` (muss 0.15.x sein) und
  die MuPDF-Archive prüfen, bevor Code angefasst wird (README, Abschnitt Windows).
- Ein langsamer Test lässt sich unter Windows nicht mit `timeout` aus Git Bash begrenzen (dort
  teils gesperrt, `Permission denied`); Runner in Python mit `subprocess.run(timeout=)`.
- Windows-Build der Engine: clang + ninja, `-DGGML_VULKAN=OFF`, dazu
  `-D_WIN32_WINNT=0x0A00` in C- und CXX-Flags (cpp-httplib verlangt Windows 10).
- Pfade in Git-Status (`/`) und LSP-URIs (`file:///C:/…`) werden auf Windows-Trenner umgesetzt
  (`updateGitStatus`, `lsp_proto.pathToUri`/`uriToPath`). Dasselbe gilt für die Repo-Wurzel aus
  `git rev-parse --show-toplevel`: `git_worker.repoRoot` setzt sie um, bevor sie in Timeline- und
  Graph-Antworten geht — sonst stimmt kein Vergleich gegen einen Editor-Pfad.

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
  gezeichnet wurde → `Segmentation fault` in `text_system.hashText` (Symptom:
  Bilder per Drag & Drop in einen Ordner verschoben, Absturz beim nächsten Zeichnen).
- Kein `clay.text(&.{byte}, …)`: Zeiger auf ein Stack-Temporary, beim Zeichnen längst
  überschrieben. Statische Literale nehmen (Git-Status-Buchstaben in `renderTreeEntry`).
- Dasselbe für `var buf: [N]u8 = undefined` in einer `render`-Funktion mit `bufPrint` → `clay.text`:
  der Puffer gehört in die Frame-Arena (`arena.alloc(u8, N)`) oder das Ergebnis wird `arena.dupe`d.
  Symptom im Fenster (Debug-Build): der Text besteht aus 0xAA-Bytes (Zigs `undefined`-Muster,
  ein späterer Stack-Frame hat den Puffer neu initialisiert), im Log `warning(shaper): invalid
  UTF-8 text … hex=aaaa…`, gezeichnet als lauter U+FFFD. Vor dem 18.09.2026 fiel dadurch der ganze
  Frame aus (`renderClayLayout` brach ab, `endFrame` präsentierte trotzdem das alte Bild aus der
  Swap-Chain): Source Control „zitterte“ beim Verbreitern des Explorers zwischen zwei Ständen,
  weil `fitText` den Platzhalter des Commit-Felds erst ab ~360 px ungekürzt (= Stack-Zeiger)
  durchreichte. Headless zeigt das nicht (kein GPU-Text; der memfd-Probe prüft nur Mapping, nicht
  Inhalt). Seitdem dekodiert `SimpleShaper.shape` verlustbehaftet und `renderClayLayout`-Fehler
  werden als `warning(rendering)` gemeldet.
- `Platform.setCursor` meldet nur Formwechsel an wio: unter Windows macht wio je Aufruf
  `GetCursorPos`+`SetCursorPos`, und bei gedrückter Maustaste erzeugt das ein `WM_MOUSEMOVE`, das
  den nächsten Frame weckt — beim Splitter-Ziehen lief der Loop ohne Pause (`ZID_DEBUG=1`:
  `mouse: … dx=0` in jedem Frame). Die Debug-Zeilen `mouse:` (main.zig, nur beim Ziehen),
  `splitter:` (Breite vorher/nachher) und `cursor:` (Formwechsel) bleiben für solche Diagnosen.
- **Werkzeug:** Headless fasst jeden Text-Command per `pwrite` in ein memfd an
  (`src/debug/text_probe.zig`; `/dev/null` liest den Puffer nicht, EFAULT bleibt aus). Zeigt ein
  Command auf unmapped Speicher, panict der Loop mit Command-Index, Bounding-Box und dem
  vorigen Text. Mit `--page-alloc` oder `ZID_PAGE_ALLOC=1` läuft alles über
  `src/debug/free_log.zig` (page_allocator: jede Freigabe = munmap, kein In-Place-Remap) und
  die Meldung enthält den Stack-Trace der Freigabe. So laufen lassen:
  `ZID_PAGE_ALLOC=1 python3 scripts/e2e_explorer.py` (jede E2E-Suite geht) oder
  `python3 scripts/e2e_repro_text_uaf.py --page-alloc` (Ordnerwechsel in einen erzeugten Baum
  unter `tmp/e2e_uaf`, Bilder, Tooltip, Picker-Klicks, Tab-Schließen). Der GPA unmappt kleine Buckets erst, wenn sie ganz leer sind,
  darum fällt der Fehler im Fenster nur sporadisch auf.

## Bekannte Grenzen (kein Todo, bewusst so)

- **Durchgestrichen in Markdown:** `~~text~~` toggelt zigdown zweimal und bleibt ungestylt,
  `~text~` funktioniert. Upstream-Verhalten in zigdown.
- **Fett/Kursiv nur über Farbe:** Es gibt eine einzige Font-Face (JetBrainsMono-Regular).
  Echte Schnitte bräuchten Font-IDs im Text-Renderer und eine zweite geladene Face.
  MarkdownView zeigt Styles deshalb als Theme-Farben (fett=primary, kursiv=accent,
  Code=warning, Link=blau, durchgestrichen=muted).
