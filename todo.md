# todo.md — UI-Lücken gegenüber gängigen Editor-Best-Practices (Zed, VS Code, nvim-tree, yazi)

Nur offene Punkte. Prioritäten: **P1** Datenverlust/Absturz/Blocker, **P2** tägliche Bedienung, **P3** Komfort.
Belege aus der Sitzung vom 06.09.2026 (Log mit Panic in `gpu_renderer.zig:305`) stehen in Klammern.

## Robustheit bei großen und merkwürdigen Dateien

- [ ] **P1 Zeilen über 2048 Bytes sind unsichtbar**: `shapeTextInto` gibt oberhalb von
      `ShapedRunCache.MAX_TEXT_LEN` stumm einen leeren Run zurück, die Zeile fehlt einfach
      (`tmp/e2e_odd_odd_long_line.txt.png`: Zeile 1 mit 5000 Zeichen ist leer). Lösung: der Editor gibt
      pro Zeile nur den sichtbaren Spaltenausschnitt an Clay (heute `getLine(i)` komplett), dann
      brauchen weder Shaper noch Renderer Riesen-Runs.
- [ ] **P2 Horizontales Scrollen** im Editor: lange Zeilen werden am rechten Rand abgeschnitten, der
      Cursor kann aus dem Sichtbereich laufen (kein `view.col`), keine horizontale Scrollbar,
      kein Word-Wrap-Umschalter.
- [ ] **P2 Große Dateien**: 5-MB-Datei mit 100 000 Zeilen öffnet in 0,2 s, aber ein getipptes Zeichen
      am Dateiende braucht 1,2–2,4 s bis es sichtbar ist (`scripts/e2e_odd_files.py`, zwei Läufe). Profilieren
      (Verdacht: Reparse/`lineCount`/Gutter-Messung pro Frame), Ziel < 50 ms.
- [ ] **P2 Ladefehler dem User zeigen**: `readFileAlloc` bricht über 64 MB ohne Meldung ab; VS Code
      fragt „Datei ist groß (n MB), trotzdem öffnen?“. Fehler beim Laden/Speichern als Toast/Dialog,
      nicht nur ins Log.
- [ ] **P2 Markdown-Preview baut Highlighter pro Frame**: `renderCodeBlock` zerstört und erzeugt den
      Tree-sitter-Highlighter bei jedem Sprachwechsel neu — bei vier Codeblöcken in vier Sprachen also
      viermal pro Frame (der Log-Spam „highlighter created“ war das Symptom, seit heute nur noch debug).
      Highlighter pro Sprache in einer Map halten.
- [ ] **P3 llama-server 503 während des Warmups** landet als `error: Llama Server Error: 503` im Log
      statt als Status im Chat-Kopf.
- [ ] **P3 Log-Rauschen** weiter senken: `info(highlight)` (markDirty, background parse, swapped) und
      `info(main): Opening file/Switching to tab` auf debug, sonst ist ein Sitzungs-Log nicht lesbar.

## Explorer

- [ ] **P1 Löschen per Tastatur bestätigen**: der Delete-Dialog (und alle anderen Dialoge) reagiert nur
      auf Maus — Enter oder `d` bestätigt, Escape bricht ab, Tab wechselt den Button, Fokus sichtbar.
      `dialog.zig` hat kein Key-Handling, `UI.handleKeyPress` blockt bei offenem Dialog nur die Kürzel.
- [ ] **P1 Buchstaben-Kürzel im Explorer-Scope** wie nvim-tree/yazi/Zed: `d` löschen, `r` umbenennen,
      `a` neue Datei, `A` neuer Ordner, `y` kopieren, `x` ausschneiden, `p` einfügen, `c` Pfad
      kopieren, `R` neu laden. Heute landet `d` im Editor und macht die Datei dirty (Log:
      `handleChar: 'd'` direkt nach dem Explorer-Klick). Voraussetzung: mit `explorer_focused` gehen
      Tasten nicht mehr an den Editor, und der Fokus ist sichtbar (Rahmen/Hintergrund der Sidebar).
- [ ] **P1 Löschen in den Papierkorb** (freedesktop Trash / `gio trash`) statt unwiderruflich;
      Dialogtext entsprechend („In den Papierkorb verschieben“), Undo im Idealfall.
- [ ] **P2 Mehrfachauswahl**: Ctrl+Klick toggelt, Shift+Klick markiert einen Bereich (der User hat im
      Log mehrfach Shift gedrückt), Ctrl+A im Explorer; Löschen/Ausschneiden/Kopieren wirken auf die
      Auswahl, Dialog nennt die Anzahl. `selected_index` ist heute ein einzelner Index.
- [ ] **P2 Tastaturnavigation**: ↑/↓ markieren, ←/→ zu-/aufklappen bzw. zum Elternordner, Enter
      öffnet, Space öffnet als Vorschau, Home/End, PageUp/PageDown, Tipp-zum-Springen (type-ahead).
- [ ] **P2 Ordner-Klick markiert nicht**: `renderTreeEntry` setzt für Ordner nur `pending_toggle`,
      `selectEntry` läuft nur für Dateien — F2/Entf auf Ordnern gehen erst nach Rechtsklick.
- [ ] **P2 Neue Datei / neuer Ordner** im Kontextmenü, per Kürzel und mit Inline-Eingabe des Namens
      am richtigen Ort (Ctrl+N legt heute „New File.txt“ ohne Ort und ohne Namensabfrage an).
- [ ] **P2 Kontextmenü erweitern**: New File, New Folder, Cut, Copy, Paste, Duplicate, Copy Path,
      Copy Relative Path, Reveal in File Manager, Open in Terminal, Collapse All (heute nur
      Rename/Delete).
- [ ] **P2 Vorschau-Tabs**: Einfachklick öffnet heute sofort einen festen Tab; Zed/VS Code öffnen
      einen Preview-Tab (kursiv, wird vom nächsten Klick ersetzt), Doppelklick oder Bearbeiten macht
      ihn fest. Gehört zusammen mit der Tab-Leiste umgesetzt.
- [ ] **P2 Lange Namen werden hart abgeschnitten** (Screenshot: `test_dat`, `referenc`, `CLAUDE.m`):
      Ellipsis + Tooltip mit vollem Pfad, oder Sidebar horizontal scrollen; Sidebar-Breite merken.
- [ ] **P3 Versteckte Dateien** (`.`-Einträge werden in `loadDirectory` übersprungen) und
      .gitignore-Einträge umschaltbar anzeigen (ausgegraut statt versteckt).
- [ ] **P3 Collapse All**, „Reveal active file“ (Explorer folgt dem aktiven Tab, klappt auf),
      Filterfeld (Tippen filtert den Baum).
- [ ] **P3 Drag & Drop** zum Verschieben (mit Bestätigung), Duplizieren.
- [ ] **P3 Icons nach Dateityp** (heute Blitz/Seite), Git-Status-Farbe auch für Ordner
      (Propagation nach oben).

## Tab-Leiste

- [ ] **P2 Aktiver Tab wird nicht in den Sichtbereich gescrollt** (Screenshot: `odd_long_line.tx`
      rechts abgeschnitten, Schließen-Kreuz unerreichbar).
- [ ] **P2 Mittelklick schließt**, Drag & Drop zum Umordnen, Kontextmenü: Close, Close Others, Close
      to the Right, Close All, Close Saved, Copy Path, Reveal in Explorer, Split Right/Down.
- [ ] **P2 Ungespeichert-Dialog per Tastatur** (Save / Don't Save / Cancel mit Enter/Escape),
      Punkt statt Stern als Indikator, Ctrl+S auch wenn der Fokus nicht im Editor liegt.
- [ ] **P3 Ctrl+Shift+T** (zuletzt geschlossenen Tab wieder öffnen), Ctrl+1…9 (Tab n),
      Ctrl+PgUp/PgDn, Tab anpinnen.
- [ ] **P3 Titel bei Namensgleichheit** um den Ordner ergänzen (`a/mod.zig` vs `b/mod.zig`).

## Editor

- [ ] **P2 Auto-Indent bei Enter**, Autoclose von Klammern/Anführungszeichen, Tab rückt eine
      Auswahl ein / Shift+Tab aus (heute fügt Tab immer ein Zeichen ein), Ctrl+/ Kommentar
      umschalten, Alt+↑/↓ Zeile verschieben, Ctrl+Shift+D Zeile duplizieren.
- [ ] **P2 Ctrl+G Gehe zu Zeile**, Ctrl+P Datei-Schnellöffner (fuzzy), Ctrl+Shift+P Command Palette
      über die Kürzel-Tabelle, Ctrl+H Ersetzen in der Suchleiste (Regex/Case-Toggle; `find_ops`
      zählt Codepoints, Tabs/Breitzeichen fehlen).
- [ ] **P2 Maus**: Dreifachklick markiert die Zeile, Shift+Klick erweitert die Auswahl, Autoscroll
      beim Ziehen über den Rand, Ctrl+Klick geht zur Definition (LSP vorhanden).
- [ ] **P2 Statusleiste**: Zeile:Spalte, Auswahlgröße, Encoding, EOL, Sprache, Einrückung —
      heute nur Git-Branch im Header.
- [ ] **P2 Datei außerhalb geändert** → Reload-Hinweis im Tab (File-Watcher läuft bereits).
- [ ] **P3 Klammern hervorheben**, Einrück-Guides, Whitespace anzeigen, aktuelle Zeile im Gutter,
      Minimap, Mehrfach-Cursor (Ctrl+D nächstes Vorkommen, Ctrl+Alt+↑/↓), Schriftgröße
      Ctrl+±/Ctrl+0, Theme umschalten.
- [ ] **P3 Autosave/Backup** und CRLF-Dateien beim Speichern unverändert lassen.

## Fenster, Splits, Menüs

- [ ] **P2 Pane-Kürzel**: Ctrl+\ splitten, Ctrl+K ←/→ Fokus wechseln, Pane schließt sich mit dem
      letzten Tab, Ctrl+Shift+E Fokus in den Explorer, Ctrl+J Terminal-Panel.
- [ ] **P3 Menüleiste per Tastatur** (Alt+F …, Pfeile, Escape schließt), Kürzel-Dialog scrollbar,
      Toasts für Erfolg/Fehler (gespeichert, gelöscht, Ladefehler).
