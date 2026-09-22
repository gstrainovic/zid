# Offene Punkte

Sortiert nach Dringlichkeit: Abstürze und falsches Verhalten zuerst, Komfort zuletzt.

KI-Punkte: Wirkung vorab schätzen, vorher/nachher messen (`scripts/e2e_ai_read_limits.py`,
`scripts/e2e_ai_tools.py`); Antworten streuen bei Temperatur 0.7, also Fälle wiederholen.

## 2. Fehler: sichtbar falsch, aber ohne Datenverlust

1. **Verschachtelte Clips** ersetzen sich statt sich zu schneiden (`clay_renderer/mod.zig`
   `scissor_start`/`scissor_end` setzen absolut bzw. aufs ganze Fenster zurück). Clip-Stapel mit
   Schnittmenge wie gooey `scene.zig` `pushClip`/`popClip`.
2. **`corner_radius` wird ignoriert:** 69 Stellen in `src/` werden eckig gezeichnet. SDF-Shader
   aus gooey `platform/wgpu/shaders/unified.wgsl` (WGSL, übertragbar), dazu Rahmen mit Radius.
3. **Horizontales Scrollen ohne Grenze:** `scrollColumns` (`code_editor.zig`) erhöht `view.col`
   endlos; flow klemmt auf `longest_line_len - cols + 1`, `maxLineWidth()` gibt es schon.
4. **Unicode-Fallfaltung fehlerhaft** (`libs/flow-core/src/buffer/unicode.zig`: × → ÷, ß → ÿ,
   Σ/Τ, Č/Š/Ž und Kyrillisch fehlen). Heute ungenutzt; vor Groß-/Kleinschreibung (4.2) auf uucode
   umstellen wie flow.
5. **Suche ignoriert Groß/Klein nur für ASCII** (`find_ops.zig` `eqlIgnoreCase`): „Ä“ findet
   kein „ä“ (Editor, Markdown- und PDF-Vorschau).
6. **mupdf stürzt bei manchen kaputten PDFs ab** (System-Bibliothek 1.27.2; `mutool draw` auf
    einem zu 40 % geschriebenen PDF: Segfault, in zid „double free“). Der Reload wartet deshalb
    auf eine ruhende Datei; eine dauerhaft kaputte Datei öffnen reißt zid aber weiter mit.
    Rendern in einen Kindprozess auslagern oder mupdf-Version prüfen.
7. **Clay `duplicate_id` in Serie beim Öffnen einer Markdown-Datei** (Windows, Fenster,
   21.09.2026): rund 140 Meldungen, dieselbe ID `3113540797` unter wechselnden Elternelementen (`908726519`,
   `3402408544`, `3494701479`, …), dazu `1800183164` unter `3921318746`. Die Diagnose meldet
   „keine doppelte ID in den Render-Commands (das Element zeichnet nichts)“ — also eine feste ID
   in einer Schleife, vermutlich ein unsichtbares Element je Zeile/Block. Datei headless öffnen,
   `ui_state.clay_errors` messen, ID über `clay.ElementId.ID`-Hashes der Kandidaten zuordnen.

## 3. Wichtige Funktionen

1. **KI: Deny beendet die Runde.** Heute geht der Fehler zurück ans Modell (eine volle Runde mehr,
   der abgelehnte Inhalt steht im Prompt) und weitere Aufrufe derselben Antwort laufen trotzdem.
   Neu: übrige Aufrufe als „skipped“, kein weiterer LLM-Aufruf. Erwartung: 3–8 s schneller nach
   Deny (`e2e_ai_tools.py` Schritt 5).
2. **KI: projektweite Suche als Werkzeug** anstelle von `find_in_editor` (gleiche Werkzeugzahl,
   Suchleiste bleibt über `command` erreichbar), über `project_search.Runner` wie Ctrl+Shift+F.
   Teilstring, `pfad:zeile:text`, höchstens 30 Treffer, Zeilen auf 200 Zeichen,
   `engines/`/`models/`/`reference/` ausgeschlossen. Werkzeugwahl mit
   `llm-bench/bench/agent_eval.py` prüfen.
3. **Suche im Projekt, Rest zu VS Code:** Ersetzen in offenen Buffern mit ungespeicherten
   Änderungen (heute übersprungen, per Undo rücknehmbar wie VS Code), Include/Exclude-Globs,
   Suchverlauf mit ↑/↓, „Find in Folder“ im Explorer-Kontextmenü.
4. **LSP:** Diagnosen (publishDiagnostics, inline und Sprung zur nächsten), inkrementelles
   `didChange`, Hover, Referenzen, Umbenennen (WorkspaceEdit), Datei-Symbole, Server je Dateityp
   (`libs/flow-core/src/file_type_lsp.zig` ist vorhanden, `src/` nutzt nur zls), Formatieren über
   den Formatter-Eintrag derselben Tabelle (auch beim Speichern).
5. **Autovervollständigung:** Wörter aus offenen Dokumenten, LSP-Vorschläge, falls ein Server
   läuft (`lsp_completion` ist im Client vorhanden, aber ungenutzt).
6. **Suche im Editor:** alle Treffer markieren, Trefferzahl in der Statuszeile, F3/Shift+F3.
7. **Git-Änderungsmarken im Gutter** (`flow_core.diff` ist exportiert, ungenutzt) und Sprung zur
   nächsten/vorigen Änderung.
8. **Inkrementelles Highlighting nach Undo/Redo/Reload:** alten gegen neuen Text diffen und als
   tree-sitter-Edits melden statt `resetTree()` (flow `editor.zig:6256-6285`).
9. **KI: `list_files` sortiert, ohne `.git/` und `.zig-cache/`; `read_file` lehnt Binärdateien
    ab** (NUL in den ersten 512 Bytes).

## 4. Komfort

1. **Leerzeichen am Zeilenende beim Speichern entfernen** (abschaltbar, wie Autosave gemerkt).
2. **Editier-Befehle:** Zeile darunter/darüber einfügen (Ctrl+Enter, Ctrl+Shift+Enter), Zeile
   markieren (Ctrl+L), alle Vorkommen markieren (Ctrl+Shift+L), Groß-/Kleinschreibung (braucht
   2.4).
3. **Editier-Komfort aus flow:** Smart Home (erst Codeanfang, dann Spalte 0), Smart Backspace (eine
   Einrückstufe), Auswahl nach Syntaxbaum vergrößern/verkleinern, zur passenden Klammer springen,
   Zeilen verbinden, letzten Mehrfach-Cursor zurücknehmen, Cursor an alle Zeilenenden.
4. **PDF-Ansicht** (Ideen aus fancy-cat, `src/ui/pdf_view.zig`, `src/ui/pdf_nav.zig`,
   `src/rendering/pdf_handler.zig`):
   1. Umschalten ganze Seite / volle Breite (heute immer volle Breite).
   2. Dunkelmodus: Seite in Theme-Farben umfärben (`fz_tint_pixmap`).
   3. Zu Seite N springen, dazu Home/End.
   4. LRU-Cache gerenderter Seiten (Schlüssel: Seite, Zoom, Modus, Farbe), Textur beim Verdrängen
      freigeben.
   5. Seite mit gedrückter Maus verschieben (heute nur Rad und Shift+Rad).
5. **IME:** wio liefert `preview_reset`/`preview_char`/`preview_cursor`, `platform/mod.zig` wirft
   sie weg; Vorschautext unterstrichen zeichnen, Cursor-Rechteck an `enableTextInput` geben.
6. **Schatten** für Dialoge, Menüs, Tooltips, Picker (gleicher Shader wie 2.2, `PRIM_SHADOW`).
7. **Debug:** Clays eingebauten Debug-Modus (`setDebugModeEnabled`) per Kürzel schaltbar; später
   Profiler-Overlay mit Zeiten je Phase (Layout, Render, Atlas-Upload).
8. **Weiches Scrollen:** Pixel-Versatz statt ganzer Zeilen, Feder-Physik (gooey
   `animation/spring.zig`); `src/ui/animation.zig` wird bisher nirgends benutzt.

## Aufräumen

1. **Referenz-Klone löschen:** `reference/KrillClaw`, `reference/pls`, `reference/lite-xl`,
   `reference/flow`, `reference/gooey`, sobald die übernommenen Punkte oben umgesetzt sind.

## Verteilung

Stand: v0.1.1 liegt als Release (Linux-Tarball, Windows-Zip), COPR hat 0.1.1-1
gebaut, Windows installiert über den Scoop-Bucket `gstrainovic/scoop-zid`.

1. **Binärgröße:** 155 MB entpackt, davon 109 MB tree-sitter-Parsetabellen. Strippen bringt
   1 MB, der Hebel wäre eine Auswahl an Grammatiken (`syntax`-Dependency).
