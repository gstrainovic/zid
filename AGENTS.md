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
  `glyph_rasterized`, `glyph_cache_clears`, `glyph_cache_entries`. `editor_state` liefert Zeilen,
  Cursor, Suchleiste (offen, Begriff, kein Treffer), den Text sowie `height`/`visible_rows`
  (Bounding-Box des Editors aus dem Vorframe, muss über Frames konstant bleiben). `element_bounds(id)` /
  `element_bounds_i(id, index)` geben Clay-Bounding-Boxen für Klicks; für "existiert das Element
  gerade?" sind sie unzuverlässig (Clay behält Daten verschwundener Elemente), dafür `ui_state`.
  Fixtures unter `tmp/` anlegen (gitignored, im Explorer sichtbar). Keine Suite liest aus
  `test_data/` außer der dort getrackten `syntax_test.md` (Startdatei): eingecheckte Vorlagen
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

- **Tabellen in der Vorschau:** zigdown liefert eine Tabelle als Container mit flacher
  Zellliste (je `ncol` Paragraphen eine Zeile, erste Zeile = Kopf). `MarkdownView.renderTable`
  baut daraus das Raster; ohne das lagen alle Zellen untereinander. Die Spaltenbreiten kommen
  wie im Browser aus dem Inhalt: `measureCell` liefert je Zelle die Wunschbreite (eine Zeile)
  und die Mindestbreite (breitestes unteilbares Stück), die Tabelle verteilt proportional und
  staucht notfalls die jeweils breiteste Spalte. `relative_width` aus der Trennzeile bleibt
  ungenutzt, die Zahl der Striche sagt nichts über den Inhalt. Die Tabelle steht in zwei
  `grow`-Hüllen (`md_table_row` mit Frame-Nummer für die E2E, darin `md_table_box` mit je Block
  stabiler Nummer zum Messen) und ist selbst `fit` — gemessen wird die Hülle, sonst
  schrumpfte die Tabelle Frame für Frame an ihrer eigenen Breite. Die Hüllenbreite ist nach
  oben durch `wrap_width_hint` gedeckelt: `grow` wird nie schmaler als das Kind und hielte
  sonst eine Überbreite aus dem ersten Frame (noch ohne Hint, 800 px) für immer fest.
  **Kein `clip` je Zelle:** Clay hält nur zehn Clip-Container, eine Tabelle sprengt das sofort
  („out of bounds array access"). Zu lange Wörter zerlegt stattdessen `splitWide`; Fließtext und
  Tabellen scrollen nie waagrecht, nur Codeblöcke (siehe unten). Fixture: `libs/zigdown/test/table.md`,
  geprüft in `scripts/e2e_md_preview.py`. Spaltenausrichtung (`alignment`) wird nicht umgesetzt.

- **Abfragbare IDs der Vorschau (E2E):** `md_tcell` mit Index Tabelle × 100000 + Zeile × ncol
  + Spalte (Tabellen ab 1), `md_quote`, `md_li`/`md_bullet` und `md_code` mit laufender
  Nummer ab 1. Alle Zähler setzt `resetCounters` zu Beginn jedes Frames zurück.
  **IDs, an denen die Vorschau im nächsten Frame eine Breite abliest** (`md_run_…` in
  `flushPieces`, `md_table_box`), tragen dagegen den Block-Index und einen je Block gezählten
  Lauf (`beginBlock` setzt zurück): frameweite Nummern verrutschten, sobald das virtualisierte
  Fenster oben einen Block verlor, jeder Lauf las die Breite eines anderen (Listenpunkt,
  Zitat) und brach einen Frame lang falsch um — die Vorschau zappelte beim Rad-Scrollen.
  Zweite Ursache für Springen: Blöcke im Vorlauf über der Oberkante wechseln von Schätzung auf
  Messung, `syncBlockHeights` gleicht das über `scrollbar.anchorShift` im Offset aus.
  `e2e_md_preview.py` prüft, dass ein Rad-Schritt sichtbare Blöcke um genau 60 px bewegt.
  `e2e_md_preview.py` öffnet jede `libs/zigdown/test/*.md` (Glob), legt je Datei
  `tmp/e2e_md_example_<name>.ppm` ab und prüft Zitatrand, Aufzählungszeichen und
  Codeblock-Hintergrund an Pixeln des Screenshots.

- **Umbruchbreite = Hint minus Einrückung, plus Clays Viertelpixel.** `MarkdownView.indent`
  summiert die Einrückungen um den gezeichneten Block (Liste 24 px plus Punkt und Abstand,
  Zitat 16 px, Alert 32 px); `availWidth` zieht sie vom `wrap_width_hint` ab, und `flushPieces`,
  `renderTable`, `renderCodeBlock` brechen daran um. Vorher brach Text in Listen an der vollen
  Breite, ragte um die Einrückung über den Rand und wurde vom Viewport stumm abgeschnitten
  (Business-Plan-Listen, 18.09.2026). Zweiter Anteil: Clay schlägt je Textelement 0.25 px auf
  (`measureText` in mod.zig), jedes Wort ist ein eigenes Element — `flushPieces` rechnet den
  Zuschlag wie `measureCell` mit, sonst ist eine Zeile aus 40 Wörtern 10 px zu breit.
  Symptom für beides: `md_content` breiter als `md_viewport` ohne breiten Code. Bei Verdacht
  die Datei in Zeilenbereiche schneiden und je Scheibe headless die Breite messen (Probe im
  Stil von `e2e_md_preview.step_wide_code`), statt am Fenster zu raten.

- **Balken der Vorschau** kommen beide aus `scrollbar.zig` (`vModel`/`hModel`, Pixel als
  Einheiten, `md_scrollbar_*`/`md_hscroll_*`): Klick blättert, Thumb zieht (`vdrag`/`hdrag`),
  `render` meldet Hover → `scrollbar_hovered`, und `UI.getDesiredCursor` fragt zuerst
  `MarkdownView.cursorAt` (Pfeil über Balken und Menü, I-Beam über `md_viewport`). Vorher
  hatte die Vorschau einen eigenen Balken mit eigener Zieh-Logik und keinen Cursor-Code; der
  Editor-Bounds-Test der Pane meldete über der Vorschau immer I-Beam, auch über den Balken.
  **Keine zweite Balken-Implementierung anlegen**, alle Balken laufen über `scrollbar.zig`.
  `ui_state.cursor` (E2E) liefert die Cursorform an der Mausposition;
  `e2e_editor.step_hscrollbar`, `e2e_md_preview.step_wide_code`, `e2e_explorer.step_scrollbar`
  und `e2e_terminal.py` prüfen Pfeil über Balken (Editor und Vorschau auch I-Beam über Text)
  — bei jedem neuen Balken den Test ergänzen. Explorer und Terminal werten den Hover nicht aus (dort gilt ohnehin der
  Pfeil); nur das Ziehen des Explorer-Thumbs hält den Pfeil auch über dem Editor. Zeilen unter
  einem Balken bekommen keinen Klick: Clay-Floating-Elemente fangen den Zeiger (`capture`).

- **Word Wrap in der Vorschau: Alt+Z, ein Schalter für Editor und Vorschau — bewusst anders
  als VS Code.** VS Code bricht in der Vorschau Fließtext immer um, Code nie (`pre { overflow:
  auto }`), und `editor.wordWrap` wirkt dort nicht. Der Projektinhaber will stattdessen den
  Editor-Schalter (18.09.2026, nach zwei Fehlversuchen: erst wirkte Alt+Z nur auf Code, dann
  gar nicht — beide Male sah er am Fließtext „Word Wrap geht nicht“). `render` liest
  `getActiveEditor().word_wrap` in `MarkdownView.wrap`. **Ein:** `flushPieces` bricht mit
  `splitWide`/`wrapLines` an `availWidth`, `renderCodeBlock` bricht Codezeilen mit `codeRowEnd`
  an jeder Stelle in Reihen (`Join.none`, kopiert ohne Trenner). **Aus:** `flushPieces` gibt
  jedem Lauf eine Reihe (Limit `floatMax`), Codezeilen laufen hinaus, `md_content` wächst mit
  der längsten Zeile (`grow` wird nie schmaler als das Kind), `md_viewport` verschiebt per
  `child_offset.x`, unten liegt der waagrechte Balken aus `scrollbar.zig`
  (`md_hscroll_track`/`_thumb`; Klick blättert, Thumb zieht, Shift+Rad bzw. Touchpad über
  `UI.handleScrollHorizontal` → `scrollColumns`, 60 px je Schritt). Tabellen passen in beiden
  Fällen in die Breite. Es scrollt der ganze Inhalt, nicht nur der Block: ein Clip je Block
  geht nicht, der Renderer schneidet verschachtelte Clips nicht (siehe oben) und Clay hält nur
  zehn. Der Nutzerzustand (`~/.config/zid/state`, `word_wrap=`) gilt beim Start auch für die
  Vorschau. E2E `step_wide_code`: aus → breit mit Balken, ein → Listen, Zitat und 400-Zeichen-
  Code passen; Screenshots `e2e_md_preview_{list_wrapped,wrapped,wide,wide_scrolled}.ppm`.

- **Umbruch nur an Leerzeichen:** `word_wrap.wrapLines` trennt zwischen Wörtern, nie zwischen
  zwei Stücken ohne Leerzeichen dazwischen — zigdown liefert `code`, Satzzeichen und Wortteile
  einzeln, „Nr." kommt als „Nr" und „.". `measureCell` rechnet genauso und schlägt je
  Textelement 0.25 px auf, den Zuschlag aus `measureText` in `mod.zig`.

- **Textauswahl in der Vorschau** (Logik in `src/ui/md_select.zig`, unit-getestet): Ziehen mit
  der Maus markiert wie im Browser, Ctrl+C und Kontextmenü „Copy“ kopieren, Escape oder ein Klick
  ohne Ziehen heben auf. Position = (Block auf oberster Ebene, Zeile im Block, Byte-Offset), damit
  die Auswahl gültig bleibt, während die Virtualisierung andere Blöcke zeichnet. Jede Textreihe
  aus `flushPieces` und jede Codeblock-Zeile trägt die ID `md_line` (laufend je Frame) und landet
  mit Text in `line_texts` (bleibt über Frames, damit ein herausgescrolltes Ende kopierbar ist;
  `endBlock` wirft Zeilen weg, die es nach neuem Umbruch nicht mehr gibt). Hit-Test nimmt die
  Clay-Box der Reihe aus dem Vorframe und misst Codepoints (`offsetAtX`). Hervorhebung: `textSel`
  teilt ein Stück an den Auswahlgrenzen, der markierte Teil steht in einem `md_sel`-Element mit
  Hintergrund — kein Floating, keine Alpha-Überlagerung, Elemente nur für markierte Stücke.
  Kopiertext: weiche Umbrüche werden wieder Leerzeichen, harte Zeilen `\n`, Blockwechsel `\n\n`
  (zigdown macht aus Leerzeilen `Break`-Blöcke, die bleiben stumm), Absatzenden verlieren ihr
  Leerzeichen-Stück; ein nie gezeichneter Block dazwischen kommt als Fließtext aus dem Baum.
  Ändern sich Umbruchbreite oder Schriftgröße, wird die Auswahl aufgehoben (Zeilennummern
  stimmen dann nicht mehr). Tasten in der Vorschau erreichen sonst weiter den unsichtbaren
  Editor dahinter. RPC `md_selection` (`open`, `lines`, `text`), E2E in
  `scripts/e2e_md_preview.py` (`step_selection`).
  **Deck (Marp):** dieselbe Auswahl auf der Folie (`beginSelection("md_slide", …)`, Block 0);
  ein Folienwechsel hebt sie auf. E2E in `e2e_marp_pdf.py`.
  **Chat-Bubbles:** jede Nachricht hat ihre eigene `MarkdownView`, `AIChatState.handleMouseDown`
  trifft die Bubble (`ai_msg_<idx>`) und startet dort die Auswahl (`sel_msg`, unter `mutex`, weil
  der Worker Nachrichten anhängt); Ctrl+C kopiert markierten Bubble-Text vor dem Eingabefeld,
  Escape hebt auf. Ein Klick ohne Ziehen kopiert wie bisher die ganze Nachricht — jetzt beim
  Loslassen (`pending_copy_msg`, im Render, dort ist das Fenster), nicht mehr beim Drücken.
  Die wachsende Stream-Bubble ist nicht auswählbar (wird je Token neu gebaut). RPC
  `chat_line_bounds(msg, line)`; E2E `select_in_bubble` in `e2e_ai_chat.py`.

- **Schriftgröße der Vorschau:** `UI.previewFontSize` (Editor minus 4, Standard 24 → 20).
  `setFontSizeAll` setzt sie bei jedem Zoom auf alle offenen `open_markdown_views`, und beide
  Stellen, die eine Vorschau anlegen (`src/main.zig` und der Render-Zweig in `mod.zig`),
  übernehmen sie — sonst blieb die Vorschau auf ihrer Startgröße stehen.

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

Details in der Skill `.claude/skills/llm-local/SKILL.md`: Backend- und Gerätewahl,
llama-server-Argumente, Streaming und `AgentStatus`, Chat-Eingabe als CodeEditor,
gepinnte Engines unter `engines/`, Modellablage und die Messregeln aus `llm-bench/`.

Kurz: Standard ist `engines/llama.cpp-vulkan/build/bin/llama-server` (unter Windows
`.exe`, sonst fällt zid still auf Ollama zurück) mit
`models/gemma-4-E2B-it-Q4_0.gguf` auf allen Plattformen (`src/ai/paths.zig`). Fallback Ollama.
`LLAMA_SERVER_PATH` und `LLAMA_MODEL_PATH` überschreiben. zid nutzt nur lokale Backends; Cloud-
Anbieter (Claude, OpenAI) sind eine Entscheidung des Projektinhabers dagegen. RPC `chat_state`,
E2E `python3 scripts/e2e_ai_chat.py` und `scripts/e2e_ai_tools.py`.

Drei Regeln aus der Messreihe vom 17.09.2026
(`llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md`, Laptop-Gegenprobe
`linux-p1000-gemma4-vs-qwen3.md`):

- **Thinking aus.** llama-server bekommt `--chat-template-kwargs {"enable_thinking":false}`,
  Ollama-Requests `reasoning_effort: "none"`. Denkende Modelle (gemma4) streamen sonst
  20–30 s `reasoning`, bevor das erste `content`-Delta kommt. `--reasoning-budget 0` und
  `think: false` wirken nicht.
- **Werkzeug-Prompt klein halten.** Das `command`-Werkzeug trägt die Kommandos nur als
  Enum im Schema, keine Liste mit Label oder Kürzel im Text. Die Liste kostete 1000 Token,
  auf CPU 20 s vor dem ersten Delta, und brachte gemma4 dazu, `open_folder` statt
  `command` zu wählen. Jeder Stream endet mit einer `usage:`-Logzeile (Prompt-Token,
  `prompt_ms`) — vor Prompt-Änderungen vorher/nachher ablesen.
- **Enum-Wert als Werkzeugname** (`toggle_explorer` statt `command{name}`) führt
  `agent_actions` als Kommando aus (`ai_tools.commandFromToolName`), statt „unknown tool"
  zu melden; kleine Modelle über Ollama tun das.

## Engines und Modelle (`engines/`, `models/`, `llm-bench/`)

Alles liegt im Repo. Layout, gepinnte Submodule, `fix-rpath.sh` und die Messregeln stehen in
`.claude/skills/llm-local/SKILL.md`. Kurz: `engines/llama.cpp-vulkan` ist die einzige Engine
(gepinnt, CPU und GPU in einem Build), `models/` hält GGUFs flach und ignoriert (nie committen),
`llm-bench/` ist ein `git subtree` mit historischen Protokollen, die nicht angefasst werden. Die
BitNet-Engine und ihr Modell liegen nicht im Repo; `llm-bench/setup/linux.sh` holt und baut sie
für Nachmessungen.

## Agent-Werkzeuge: der Agent kann, was der Editor kann

- **Natives Tool-Calling** (OpenAI `tools`-Feld, `tool_calls` in der Antwort, `role: tool` zurück).
  Geprüft mit llama-server b10524 + Qwen3-4B + `--jinja`: funktioniert nicht-streamend
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
  `exceed_context_size_error` (gemessen: 24 017 Tokens abgelehnt; ein 8014-Token-Prompt
  brauchte auf der P1000 123 s). `agent.zig` macht daraus `error.ContextTooLong`, der Chat zeigt
  einen verständlichen Hinweis. Vorbeugend schickt `submitCompletion` nur das jüngste Stück der
  Historie, das in `history_budget_chars` (12 000 Zeichen) passt: `src/ai/history.zig` (`keepFrom`,
  unit-getestet) behält die laufende Runde (letzte Frage, Aufrufe, Ergebnisse) immer ganz, auch über
  dem Budget, und beginnt nie mit einem verwaisten `tool`-Ergebnis. Ein Ergebnis ohne Frage und
  Aufruf verwirft das Chat-Template, das Modell antwortet dann ohne jeden Kontext („What would you
  like to do?"). Die Anzeige im Chat bleibt vollständig.
- **`read_file` liefert den rohen Dateiinhalt, ohne JSON und ohne Kopf.** Als JSON-String sah das
  Modell `\n` und `\"` statt echter Zeilen (das gemma4-Template reicht den String unverändert
  durch); ein Kopf wie `path: …` galt ihm als erste Dateizeile (erste Zeile 0/3 statt 3/3). Roh
  spart 6–7 % Prompt-Token beim Ergebnis. Fehler bleiben `{"error":…}`, daran erkennt
  `pushToolResult` sie (Präfix, nicht Teilstring: Dateien dürfen `"error"` enthalten).
- **Zu große Werkzeugergebnisse werden erst nach der Ablehnung gekürzt:** `handleError` kürzt bei
  `ContextTooLong` das größte `tool`-Ergebnis der Runde (`ai_tools.shrinkToolResult`: Anfang auf
  zwei Drittel, höchstens 24 000 Bytes, an einer Zeilengrenze; am Ende die Zeile
  `[zid: file truncated: N bytes total, first M shown]`; JSON mit `content`-Feld wird im Feld
  gekürzt) und sendet neu, bis es passt. Was passt, geht ungekürzt raus; eine feste Grenze in
  `read_file` hätte Dateien gekappt, die ganz ins Fenster passen. Die Ablehnung kostet kaum Zeit.
  Messwerte P1000 (`python3 scripts/e2e_ai_read_limits.py`, erste/letzte Zeile aus N Bytes Zig-Code):
  Grundlast 1 366 Prompt-Token, 4 KB 2 628 Token und 20 s, 12 KB 4 974 Token und 47 s, 28 KB nach
  dem Kürzen 75 s (20 KB passte noch ungekürzt: 7 511 Token, 87 s, gemessen mit JSON-Ergebnis). Die „letzte Zeile" streut ab 12 KB bei gleichem
  Prompt (Temperatur 0.7); Fälle wiederholen.
- **Gemessene Grenzen (Bench `~/projects/bitnet-colibri-bench`, Engine b10524 Commit 9ee9fc0,
  Qwen3-4B-Instruct-2507-Q4_K_M sha256 3605803b982cb64a…):** Ein-Datei-Fix gelingt; Ursachen über
  einen Import hinweg scheitern (Qwen3 bricht gefahrlos ab, Llama-3.2-3B schrieb destruktiv). Der
  Agent soll nur in Git-Repos ändern: nur die Bestätigungsdialoge sichern, eine Warnung außerhalb
  eines Repos ist eine offene Produktentscheidung. Prompt-Verarbeitung auf der P1000 ~96 tok/s.
- **Temperatur bleibt 0.7, auch mit Tools** (negatives Ergebnis): `bench/agent_eval.py`
  Werkzeugwahl bei 0.7 dreimal 10/10, bei 0.0 ebenfalls 10/10 — kein Unterschied, keine Sonderregel.
- **CPU ohne `-tb`** (negatives Ergebnis, `-dev none -ngl 0`, Prompt 6×-Absatz):
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
  Projekts). Der Windows-Watcher folgt Symlink-Ordnern nicht (ungetestet, offen in `todo.md`).
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

## PDF-Vorschau: Blättern und Neuladen

- **Neu laden bei Dateiänderung:** `handleExternalChange` erkennt offene PDFs (`keyForPath` über
  `open_pdfs`, auch per realpath) und reiht sie in `pending_pdf_reloads` ein; `exportMarpPdf` tut
  das direkt. Der Main-Loop lädt erst, wenn die Datei 150 ms ruht (`takeDuePdfReload`, mtime):
  Das System-mupdf 1.27.2 (Linux linkt `/lib64/libmupdf.so`, nicht fancy-cats mupdf) stürzt beim
  Reparieren mancher halb geschriebener PDFs ab („double free“, `mutool draw` segfaultet auf
  derselben Datei), und der Watcher meldet je Datei nur ein Ereignis pro 100 ms. Neuer Handler,
  Seite geklemmt, Textur ersetzt; scheitert etwas, bleibt der alte Stand. `wantsFrameSoon` hält
  den Loop wach, solange ein Reload wartet. E2E `python3 scripts/e2e_pdf_reload.py`, Marp-Weg in
  `e2e_marp_pdf.py` (letzter Schritt).

- Blätter-Logik als reines Modul `src/ui/pdf_nav.zig` (Tasten, Mausrad, Sättigung an den
  Rändern, Beschriftung). Die Ansicht `src/ui/pdf_view.zig` liefert nur ein Seiten-Delta,
  angewendet wird es in der Hauptschleife, die auch die Textur neu rendert.
- Bild ab/auf und Pfeil links/rechts blättern; hoch und runter bleiben der Navigation
  zwischen Panes und im Explorer. Mausrad: negative Zeilen heißen nach unten, also vorwärts.
- `clay.pointerOver` meldet in dieser Ansicht nichts, deshalb hat die Leiste eine eigene
  Schaltfläche statt `components.Button`: Hover und Klick rechnen gegen die Bounding-Box aus
  dem letzten Layout (`pdf_nav.hits`, Aufhellung über `pdf_nav.brighten`).
- Die Beschriftung liegt in einem Puffer der UI (`pdf_label_buf`), nicht in der Frame-Arena:
  `beginLayout` setzt die Arena zurück, Clay liest den Text erst beim Zeichnen.
- Zustand für E2E: `pdf_state` liest Felder im `E2EContext`, die der Main-Thread pro Frame
  setzt. Über Tabs und `open_pdfs` im Server-Thread zu laufen lieferte springende Werte.
- E2E: `python3 scripts/e2e_pdf_pager.py`, das siebenseitige PDF erzeugt `write_pdf` nach
  `tmp/e2e_pdf/pager.pdf`. Der Test startet
  mit eigenem, frischem `XDG_CONFIG_HOME` und übergibt das PDF als Startdatei: über eine
  wiederhergestellte Sitzung wechselt der aktive Tab und die Messung trifft Fremdzustand.
  `open_file` öffnet keinen PDF-Tab, das Laden hängt am Explorer-Pfad.

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

## Git-Ansichten: gemeinsame Bausteine

- Repo-Verlauf zeigt der Source Control Graph, Datei-Verlauf die Timeline im Explorer; es gibt
  keinen eigenen History-Tab.
- `git_worker.frame`/`unframe`/`splitKey`: Worker-Ergebnisse als `<schlüssel>\n<text>`, bei
  Commit-Anfragen `\x1f<hash>` im Schlüssel, damit veraltete Antworten erkannt werden. Fehler von
  git kommen als `*_error`-Tag mit stderr als Text, nie als Task-Fehler (`framedResult`).
- `src/git/git_list.zig` (Modul `git_list`, unit-getestet): `visibleRange`, `scrollToShow`,
  `clampScroll` für virtualisierte Listen mit fester Zeilenhöhe (Timeline, Graph).
- Alle git-Aufrufe laufen mit `core.quotepath=off`.
- E2E: RPC `git_diff_state` liefert den Diff-Editor des aktiven Tabs (`view: "diff"`), JSON vom
  Main-Thread pro Frame gespiegelt (`snapshotGitViews`, mit `timeline_state` und `scm_state`).

## Diff-Editor im VS-Code-Stil (Tab `git-diff://…`)

- Vorbild ist VS Codes Diff-Editor, Standardwerte aus `src/vs/editor/common/config/diffEditor.ts`:
  Automatic-Layout (nebeneinander ab 900 px, sonst untereinander), `+`/`−`-Markierung, unveränderte
  Bereiche standardmäßig sichtbar, eingeklappt mit Kontext 3 / Minimum 3. Titel wie
  `resolveTimelineOpenDiffCommand`: `name (eltern) ↔ name (commit)`, Wurzel-Commit gegen den leeren
  Baum `4b825dc`. Kürzel wie VS Code: Alt+F5 / Shift+Alt+F5 (`diff_next_change`/`diff_prev_change`),
  Umschalter „Toggle Collapse Unchanged Regions“ und „Toggle Inline View“ in der Werkzeugleiste.
- Aufbau: `src/git/git_diff.zig` (Modul `git_diff`, unit-getestet: Tab-Pfad mit 0x1f-Feldern
  Commit/Eltern/Repo/Pfad/alter Pfad, Hunks aus `git show -U0 -M`, Ausrichtung je Layout,
  `collapse`, `innerChange`, `columnSlice`, `DiffState`), Worker `taskGitFileDiff` (alter Inhalt
  `<eltern>:<alter pfad>`, neuer `<commit>:<pfad>`, fehlende Seite leer), Ansicht
  `src/ui/git_diff_view.zig`. Die Zeilen-Ausrichtung übernimmt git (Hunks), zid berechnet keinen Diff.
- Beide Seiten nutzen den Tree-sitter-Highlighter wie die Markdown-Codeblöcke; Hälften sind
  `.percent(0.5)`: feste Breiten aus dem Vorframe zogen im neuen Pane den Container auf 1200 px.
- Tab-Pfade enthalten 0x1f: RPC-JSON immer über `std.json.Stringify` schreiben (`ui_state.tabs`).
- E2E `python3 scripts/e2e_git_diff.py` (öffnet den Tab per `open_file` mit gebautem Pfad), Zustand
  über `git_diff_state`.

## Timeline im Explorer (VS-Code-Stil)

- Abschnitt „TIMELINE“ unter dem Dateibaum (`sidebar` = Explorer + `timeline_view.zig`), anfangs
  eingeklappt wie VS Code, Auf-Zustand in `user_state` (`timeline_expanded`). Quellen:
  `timelinePane.ts` (Zeitspalte, ausgeblendete gleiche Zeit, Meldungen, Pin/Refresh nur beim
  Überfahren), `timelineProvider.ts` (Label = erste Nachrichtenzeile, Autor als Beschreibung,
  `previousRef` = nächstälterer Commit **der Datei**, beim ältesten der leere Baum), `hover.ts`,
  `base/common/date.ts` (`fromNow`-Kurzformen), `git.timeline.date` = committed.
- Logik in `src/git/git_timeline.zig` (Modul `git_timeline`, unit-getestet), Worker `taskGitTimeline`
  (`git log --follow --numstat`; `--shortstat` mit `--name-only` liefert keine Zahlen, `%p` ist in
  deutscher Locale leer → 24 h). Klick öffnet den Diff-Editor (`openGitDiff`), Rechtsklick
  `timeline_menu_items`. Die Hunks kommen dafür aus `git diff <voriger Datei-Commit> <commit>`.
- Folgt dem aktiven Tab (Text, Bild, PDF, Binär, Vorschau-Quelle); Diff-Tabs lassen die Timeline
  stehen, weil ihr Pfad der historische Name ist (sonst sprang sie nach einer Umbenennung auf die
  alte Datei). Geladen wird nur aufgeklappt; Dateiereignisse (git-status-Debounce) laden neu.
- „File History“ im Explorer-, Tab- und Editor-Kontextmenü (`file_history`, `file_history_entry`)
  stellt die Timeline wie VS Code `files.openTimeline` auf diese Datei: aufgeklappt, angepinnt,
  ohne Tab zu öffnen (`Timeline.show`). Aus dem Editor-Menü läuft das über `pending_file_history`
  in `update()`, nie im Render-Pfad: `show` gibt den Log frei, auf den Clay-Texte des Frames zeigen.
  Pin lösen folgt sofort dem aktiven Tab (`resetTimelineFollow`).
- Tastatur nach Klick in Kopf oder Liste (`sidebar_focus = .timeline`): ↑↓/PgUp/PgDn/Home/End
  wählen, Enter öffnet den Diff wie ein Klick, F5 lädt neu, Escape gibt den Fokus ab.
- E2E `python3 scripts/e2e_timeline.py` (Fixture-Repo mit festen Commit-Zeiten), RPC `timeline_state`.

## Source Control Graph und Multi-File-Diff (VS-Code-Stil)

- Ctrl+Shift+G schaltet die Sidebar auf Source Control (`UI.sidebar_mode`), Ctrl+Shift+E zurück.
  Kopf „SOURCE CONTROL GRAPH“ mit Filter „Auto“ und Refresh; Commit-Zeile = Graph, Betreff, Autor,
  Badges der gefilterten Referenzen; Klick klappt die Dateien auf, Klick auf eine Datei öffnet den
  Diff-Editor, Rechtsklick `graph_menu_items`, Inline-Aktion und Menü „Open Changes“ öffnen den
  Multi-File-Diff (`git-commit://…`, Titel „kurz - betreff“ wie `git.viewCommit`). Am Listenende
  lädt die nächste Seite automatisch (`scm.graph.pageOnScroll`, 50 je Seite).
- **Tastatur:** Klick in die Sidebar oder Ctrl+Shift+G setzt `UI.sidebar_focus = .scm`; dann wählen
  ↑↓/PgUp/PgDn/Home/End Zeilen (`View.moveSelection`), Enter/Leertaste klappt Commits auf bzw.
  öffnet die Datei im Diff-Editor (`activateSelected`), ←/→ klappen zu/auf, F5 lädt neu. Keine
  Taste und kein Zeichen erreicht den Editor; Escape, Klick anderswo, Tab-Öffnen oder Pane-Wechsel
  geben den Fokus ab. Gleiches Modell für die Timeline (`.timeline`, `Timeline.moveSelection`).
- Quellen: `scmHistory.ts` (Bahnen und Zeichnen, 1:1 portiert in `src/git/git_graph.zig`),
  `scmHistoryViewPane.ts` (Zeilen, Badges `scm.graph.badges = filter`), `historyProvider.ts`
  (Referenzen, Filter Auto = Branch + Upstream + Basis), `git.ts` (`--topo-order --decorate=full
  --shortstat --diff-merges=first-parent`), `diffEditorItemTemplate.ts` (Multi-Diff: unveränderte
  Bereiche eingeklappt, Status R/D/A, Klappknopf je Datei).
- Daten in `src/git/git_scm.zig` (Modul `git_scm`, unit-getestet: Referenzen, Filter, Log, Dateien,
  Zeilen, Load More), Worker `taskGitGraphLog`/`taskGitCommitChanges`, Ansichten
  `src/ui/scm_graph_view.zig` und `src/ui/git_commit_view.zig` (jede Datei ein `GitDiffView`,
  Inhalt lädt erst, wenn der Abschnitt sichtbar wird).
- **Graph zeichnen ohne Rundungen im Renderer:** gerade Linien sind Rechtecke, Bögen und Kreise je
  ein kleines SVG mit eigenem Pfad. Das ist Absicht: Der Rasterizer füllt nach Even-Odd (mehrere
  Formen in einem Pfad schneiden Löcher) und der Atlas rastert höchstens vier neue Formen pro
  Durchgang — als eigene Formen je Radius und Quadrant werden sie wiederverwendet.
- `git_worker.FieldsParam` trennt Felder mit 0x1e, weil Schlüssel selbst 0x1f enthalten
  (`graph<generation>\x1f<hash>`); `generation` verwirft Ergebnisse von vor einem Refresh.
- E2E `python3 scripts/e2e_scm_graph.py` (Fixture mit Remote, Merge, Tag und 55 Commits Vorlauf),
  RPC `scm_state`.

### Changes-Bereich mit Commit (über dem Graphen)

- Kopf „SOURCE CONTROL“ (Commit, Sync Changes bzw. Publish Branch, Refresh beim Überfahren;
  VS Code hat statt Sync ein „…“-Menü mit Pull/Push/Fetch/Sync), mehrzeiliges Eingabefeld
  (`EditBuffer` mit Zeilenfunktionen `moveUp/moveDown/moveLineHome/moveLineEnd/setCursorAtLine`,
  Enter = neue Zeile, Ctrl+Enter = Commit, wächst bis `INPUT_MAX_LINES` = 6 wie
  `scm.inputMaxLineCount`, danach scrollt es zur Cursorzeile; Platzhalter `Message (Ctrl+Enter to
  commit on "<branch>")`), großer Knopf wie `scm.showActionButton`: „Commit“ solange Änderungen da
  sind, sauber ohne Upstream „Publish Branch“ (`push -u origin <branch>`), sauber und voraus oder
  zurück „Sync Changes M↓ N↑“ (Zähler nur wenn > 0, wie `actionButton.ts`; Aktion `sync` = `pull`,
  dann `push`, VS Code `git.sync`; Upstream/Vorsprung/Rückstand aus `# branch.upstream` und
  `# branch.ab`). Kein `git.rebaseWhenSync`, kein Autofetch: `behind` ist erst nach einem Fetch
  bekannt. Einzelne Push-/Pull-Knöpfe gibt es wie in VS Code nicht. Gruppen „Merge
  Changes“ (nur bei Konflikten), „Staged Changes“ (nur wenn nicht leer), „Changes“ (immer,
  untracked darin = `git.untrackedChanges: mixed`). Zeile: Name, Ordner gedimmt, rechts Buchstabe
  in `theme.git_*` (VS Code `gitDecoration.*`), gelöscht durchgestrichen. Aktionen nur beim
  Überfahren (Reihenfolge wie `package.json`): Datei öffnen, Stage/Unstage, Discard; Köpfe:
  Stage All / Unstage All / Discard All. IDs `sc_act` mit Index `zeile * 8 + RowAction`.
- Daten `src/git/git_changes.zig` (Modul `git_changes`, unit-getestet): Gruppen aus der rohen
  porcelain-v2-Ausgabe, die `taskGitStatus` hinter 0x1c mitliefert (`splitStatusPayload`), Buchstabe/
  Farbe/Hover-Text/Durchstreichen wie `Resource` in `repository.ts`, Diff-Spec je Zeile
  (Staged = HEAD↔Index `index_ref`, Changes = Index↔Arbeitskopie `git_diff.worktree_ref`,
  Untracked = leerer Baum↔Arbeitskopie mit `syntheticAddHunk`), Auswahl, Discard-Rückfragen.
  Ansicht `src/ui/scm_changes_view.zig`, Aktionen laufen in `UI.runScmAction`.
- Worker `taskGitAction` (`FieldsParam`: Aktion, Repo, Pfade bzw. Nachricht): `stage` = `add -A --`,
  `unstage` = `reset -q HEAD --`, `discard_tracked` = `checkout -q --`, `discard_untracked` =
  `clean -f -q --`, `commit` = `commit --quiet --file - --allow-empty-message` (Nachricht über
  stdin, `runGitCaptureStdin`), `commit_all` = vorher `add -A` (VS Code smartCommit), `push` =
  `push --quiet` plus weitere Felder als Argumente (Publish Branch), `sync` = `pull --quiet`,
  bei Erfolg `push --quiet` (scheitert der Pull, etwa Konflikt oder divergiert ohne
  `pull.rebase`, kommt gits Meldung und kein Push). Fehler kommen
  als `git_action_error` mit stderr → Toast. Ergebnis setzt `git_status_wanted`, main.zig lädt
  den Status über den Debounce; nach Commit und Sync auch Graph und Timeline.
- **Generate Commit Message** (Sparkle rechts oben im Feld, wie VS Code Copilot / Zed): Worker-
  Aktion `commit_diff` liefert den gestagten Diff, sonst Arbeitskopie plus untracked Dateien;
  `git_changes.commitPrompt` (Conventional Commits, 72 Zeichen, Body, nur die Nachricht; Diff auf
  24 KiB gekappt) geht blockierend über `ai_worker.taskChatCompletion` mit eigenen Tags
  `ai_commit_message`/`_error` (`ChatParams.reply_tag`), damit die Antwort nicht im Chat landet;
  `cleanGeneratedMessage` entfernt Zäune, Anführungszeichen und Label. Ohne KI (`--ai=off`,
  Agent nicht `ready`) nur ein Toast. Kein Streaming, kein eigener Systemprompt-Schalter.
- Commit-Verhalten wie `smartCommit`: leere Nachricht → Hinweis unter dem Feld; keine Staged
  Changes → Rückfrage „stage all and commit“; nichts geändert → Toast. Discard fragt immer
  (Texte und Knöpfe aus `commands.ts`: Discard File / Restore File / Delete File / Discard All n
  Files). Rückfragen laufen über `active_dialog` mit `scm_pending`.
- Fokus: Ctrl+Shift+G setzt `sidebar_focus = .commit_input`; Tab wandert Feld → Changes-Liste →
  Graph → Feld. In der Liste ↑↓/PgUp/PgDn/Home/End, Enter öffnet den Diff bzw. klappt den Kopf,
  Entf = Discard mit Rückfrage, Escape gibt ab. Buchstaben gehen nur ins Feld.
- E2E `python3 scripts/e2e_scm_changes.py` (Fixture: geändert, gelöscht, untracked; stage, Diffs,
  unstage, discard mit Dialog, commit mit Rückfrage, Publish, Sync mit Vorsprung, Sync holt fremde
  Commits aus einem zweiten Klon über den großen Knopf nach Fetch und über den Kopf-Knopf ohne
  Fetch, Tastatur), Zustand in `scm_state.changes`. Das Skript baut **nicht** selbst, sondern
  startet `zig-out/bin/zid` direkt — vorher `zig build`, sonst testet es den alten Stand.
  Der RPC `open_project` wechselt den Projektordner wie der Dialog (Explorer, Watcher, Branch,
  git status), `open_folder` lädt nur den Explorer.

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
- Runs über `ShapedRunCache.MAX_TEXT_LEN` (2048 Bytes) liefert der Shaper stumm leer. Deshalb gibt der
  Editor pro Zeile nur den sichtbaren Spaltenausschnitt an Clay (`CodeEditor.visibleSliceOf`: ab
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
- Verwaiste Headless-Prozesse: Linux `pkill -f '[v]ulkan-ed --headless'` — ohne die Klammer trifft
  das Muster die eigene Shell, die den Befehl enthält. Windows `taskkill /F /IM zid.exe`.
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
- Testdaten der Suiten kommen aus `scripts/fixtures/` und `scripts/e2e_fixtures.py` (PDF, PNG
  werden erzeugt), nicht aus dem ignorierten `test_data/`. Git-Fixtures löscht
  `e2e_open_folder.rmtree` (setzt Rechte auf `.git/objects`, sonst bleibt das Fixture unter
  Windows still stehen); die Suiten stellen stdout auf UTF-8 (Pfeile in Meldungen).
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
