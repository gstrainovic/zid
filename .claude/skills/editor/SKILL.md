---
name: editor
description: >
  Der Text-Editor in zid: Bearbeiten/Auto-Indent/Autoclose, Maus, Mehrfach-Cursor, Word-Wrap, Suche/Ersetzen, Statusleiste, Panes, externe Änderungen — und die zwei Sorten Textfelder (CodeEditor vs. line_edit). Use when touching src/editor/*, edit_ops.zig, wrap_ops.zig, find_ops.zig, tiny_regex.zig, code_editor.zig, keymap.zig, CodeEditor/line_edit/EditBuffer, or scripts/e2e_editor.py, e2e_find_preview.py, e2e_external_change.py, e2e_line_edit.py.
---

Aus AGENTS.md hierher verschoben (21.09.2026), Wortlaut unverändert.

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
- **`line_edit` in einem Dialog braucht `Config.z_index` über dem Dialog.** Cursorstrich
  und Markierung sind schwebende Elemente, und Clay sortiert z-Indizes global, nicht relativ
  zum Elternteil. Mit dem Standard 10 lagen sie unter Ordner-Dialog und Picker (z 2000) und
  waren unsichtbar (bis 22.09.2026). Beide Felder stehen jetzt auf 2002; E2E prüft das Pixel
  am Cursor in `e2e_open_folder.py`.
- Jeder eingebettete `CodeEditor` braucht die Modifier: `UI.setCtrlState`/`setAltState`/
  `setShiftState` reichen sie an Chat **und** Commit-Feld weiter. Ohne das greift die
  Keymap des Editors nicht und Ctrl+Z tut nichts.
- Ebenso Uhr und Zwischenablage: `time_ms` bekommt in `UI.update` der aktive Editor, der Chat
  (`updateTimeMs`) und das Commit-Feld. Ohne Uhr galt jeder zweite Klick in dieselbe Zeile als
  Doppelklick (bis 21.09.2026 im Commit-Feld). Copy/Cut/Paste laufen über `clipboard_hook`
  (gesetzt in `ensureEditorHooks` für Panes, Chat und Commit-Feld) → `UI.setClipboard`; vorher
  nur ans Fenster, headless kam nichts an. Neuer eingebetteter Editor: beides mitverdrahten.
- Die Auswahl eines `CodeEditor` hat kein eigenes Clay-Element (anders als `line_edit`,
  `<feld>_sel`). E2E prüfen den Text: `scm_state.changes.selected_text`, `editor_state.selection`.
