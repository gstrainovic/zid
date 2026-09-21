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
- `explorer`: Fokus, Tastatur, Auswahl, Papierkorb, Anlegen/Umbenennen, .gitignore, Tab-Nachführung
- `editor`: Bearbeiten, Maus, Mehrfach-Cursor, Word-Wrap, Suche, Panes, externe Änderungen, Textfelder
- `schnelloeffner`: Ctrl+P und Command Palette (Fuzzy, Datei-Scan, Zeilenlayout)
- `tableiste`: Neu-Menü, Ctrl+Tab (MRU), Tab-Picker, Scrollen, Drag & Drop, Pinnen
- `theme-zoom`: Theme, Zoom, Autosave/Backup, Toasts, Beenden-Dialog, Menü-Tastatur
- `grosse-dateien`: Binärdateien, Riesenzeilen, E2E-Betrieb/Windows, Use-after-free in Render-Commands
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
- **Veraltete git-status-Ergebnisse verwirft `UI.updateGitStatus`:** der Status trägt
  `root:<toplevel>`, angenommen wird er nur, wenn das zur Repo-Wurzel des aktuellen Projekts
  passt (`git_worker.repoTopLevel`, `samePath`). Sonst überschrieb der Status des Start-Projekts,
  der erst nach `open_project` ankam, den des neuen (Fixture unter dem zid-Repo: leere Changes).
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

## Bekannte Grenzen (kein Todo, bewusst so)

- **Durchgestrichen in Markdown:** `~~text~~` toggelt zigdown zweimal und bleibt ungestylt,
  `~text~` funktioniert. Upstream-Verhalten in zigdown.
- **Fett/Kursiv nur über Farbe:** Es gibt eine einzige Font-Face (JetBrainsMono-Regular).
  Echte Schnitte bräuchten Font-IDs im Text-Renderer und eine zweite geladene Face.
  MarkdownView zeigt Styles deshalb als Theme-Farben (fett=primary, kursiv=accent,
  Code=warning, Link=blau, durchgestrichen=muted).
