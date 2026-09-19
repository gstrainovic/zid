# Offene Punkte

Sortiert nach Dringlichkeit: Abstürze und falsches Verhalten zuerst, Komfort zuletzt.

KI-Punkte: Wirkung vorab schätzen, vorher/nachher messen (`scripts/e2e_ai_read_limits.py`,
`scripts/e2e_ai_tools.py`); Antworten streuen bei Temperatur 0.7, also Fälle wiederholen.

## 1. Kritisch: Datenverlust, Absturz, falscher Stand, stilles Scheitern

1. **Fenster schließen verwirft ungespeicherte Änderungen ohne Nachfrage:** `.close` in
   `src/platform/mod.zig:208-209` setzt sofort `running = false`, Autosave ist standardmäßig aus.
   Den Dialog „Unsaved Changes“ gibt es nur beim Tab-Schließen (`src/ui/mod.zig`). Beim Schließen
   des Fensters über alle geänderten Tabs fragen (Speichern / Verwerfen / Abbrechen).
2. **Undo/Redo setzen den Cursor an den Dateianfang** (`code_editor.zig` `.Undo`/`.Redo`:
   `self.cursor = .{}`) und der Geändert-Status stimmt danach nicht: `is_modified` wird nur in
   `pushEditForChange` gesetzt, Undo nach dem Speichern zeigt einen sauberen Tab mit geändertem
   Inhalt (Autosave greift nicht), Undo zurück auf den gespeicherten Stand bleibt geändert.
   Cursor aus der Undo-`meta` wiederherstellen, Dirty-Status über `Buffer.is_dirty()` (flow-core,
   vergleicht `root` mit `last_save`, bisher ungenutzt).
3. **Absturz in `View.clamp_row`** (`libs/flow-core/src/buffer/View.zig:112-113`): bei einer
   sichtbaren Zeile und unterem Abstand 2 läuft `view.row + 1 - 2` über (Panic in Debug/
   ReleaseSafe). flow rechnet mit `-|`. Auslösbar im auf 40 px verkleinerten Chat-Eingabefeld mit
   zwei Zeilen oder bei großem Zoom.
4. **Clay-Überlauf bei langen Chat-Antworten:** eine Antwort mit 1 844 Token löste
   `elements_capacity_exceeded` aus (`e2e_ai_read_limits.py 40000:first`); Elemente fehlen dann.
5. **PDF zeigt nach Änderung den alten Stand:** ein offenes PDF zeigt nach erneutem Marp-Export
   den alten Stand (`handleExternalChange` kennt nur Text-Buffer, `main.zig` lädt nur, wenn der Pfad
   noch nicht in `open_pdfs` ist). Neu laden bei Dateiänderung, bei halb geschriebener Datei kurz
   erneut versuchen, Seite klemmen, wenn das Dokument kürzer wird.
6. **Grenzwerte laut statt still:** Shaper liefert bei > 2048 Bytes leeren Text, Clay-Kapazität
   läuft ohne Meldung voll. Zentral (`limits`-Modul), loggen und im RPC zählen, nicht abstürzen
   (Vorbild gooey `core/limits.zig`).
7. **KI: `finish_reason: "length"` auswerten.** Läuft die Antwort ans Ende von `-c 8192`, ist sie
   still abgeschnitten; abgeschnittene Tool-Argumente enden als „arguments are not valid JSON“.
   Neu: Hinweis „abgeschnitten“, abgeschnittene Aufrufe nicht ausführen. Kein `max_tokens`, das
   würde lange `write_file`-Inhalte kappen. Nachstellen: 20-KB-Datei lesen und vollständig
   wiedergeben lassen.

## 2. Fehler: sichtbar falsch, aber ohne Datenverlust

1. **Verschachtelte Clips** ersetzen sich statt sich zu schneiden (`clay_renderer/mod.zig`
   `scissor_start`/`scissor_end` setzen absolut bzw. aufs ganze Fenster zurück). Clip-Stapel mit
   Schnittmenge wie gooey `scene.zig` `pushClip`/`popClip`.
2. **`corner_radius` wird ignoriert:** 69 Stellen in `src/` werden eckig gezeichnet. SDF-Shader
   aus gooey `platform/wgpu/shaders/unified.wgsl` (WGSL, übertragbar), dazu Rahmen mit Radius.
3. **Horizontales Scrollen ohne Grenze:** `scrollColumns` (`code_editor.zig`) erhöht `view.col`
   endlos; flow klemmt auf `longest_line_len - cols + 1`, `maxLineWidth()` gibt es schon.
4. **PDF-Auflösung uneinheitlich:** 1.5 beim Öffnen, 2.0 beim Blättern, fest statt aus der
   Pane-Größe; bei Größenänderung neu rendern.
5. **Unicode-Fallfaltung fehlerhaft** (`libs/flow-core/src/buffer/unicode.zig`: × → ÷, ß → ÿ,
   Σ/Τ, Č/Š/Ž und Kyrillisch fehlen). Heute ungenutzt; vor Groß-/Kleinschreibung (4.3) auf uucode
   umstellen wie flow.
6. **Suche ignoriert Groß/Klein nur für ASCII** (`find_ops.zig` `eqlIgnoreCase`): „Ä“ findet
   kein „ä“.
7. **KI-Download-Zweig veraltet:** `model_filename` und URL in `ai_chat.zig` zeigen auf
   `gemma-4-E2B-it-Q4_K_M` (unsloth), das Standardmodell ist `gemma-4-E2B-it-Q4_0` (ggml-org,
   `src/ai/paths.zig`); der Knopf erscheint nur für Ollama. Umstellen oder Zweig entfernen.
8. **Windows: Watcher folgt Symlink-Ordnern nicht.** `src/async/file_watcher_win.zig` hält ein
   `ReadDirectoryChangesW`-Handle auf die Wurzel mit `bWatchSubtree=TRUE`; Windows folgt dabei
   keinen Reparse-Points. Linux ist seit `bc6872c` behoben (`scripts/e2e_external_change.py`).
   1. Skript auf dem Windows-PC laufen lassen. Erwartung: `inplace`, `atomic`, `symlink` grün,
      `symlink_out` rot. `os.symlink` braucht dort Developer-Mode oder Admin; sonst Junction per
      `mklink /J` als Fallback.
   2. Für `symlink_out`: beim Start je Symlink-/Junction-Ordner mit Ziel außerhalb der Wurzel ein
      eigenes Handle öffnen (gleiche Filter und Overlapped-Schleife), Ereignisse unter dem
      Link-Pfad melden.
   3. AGENTS.md-Satz „Der Windows-Watcher folgt Symlink-Ordnern nicht“ danach streichen.

## 3. Wichtige Funktionen

1. **KI: Werkzeugergebnisse als Klartext statt JSON-String** (in Arbeit). Das Modell sah `\n`
   und `\"` statt echter Zeilen. Ein Kopf (`path:`) galt ihm als erste Dateizeile, daher roher
   Inhalt ohne Kopf, Kürzungshinweis am Ende.
2. **KI: Deny beendet die Runde.** Heute geht der Fehler zurück ans Modell (eine volle Runde mehr,
   der abgelehnte Inhalt steht im Prompt) und weitere Aufrufe derselben Antwort laufen trotzdem.
   Neu: übrige Aufrufe als „skipped“, kein weiterer LLM-Aufruf. Erwartung: 3–8 s schneller nach
   Deny (`e2e_ai_tools.py` Schritt 5).
3. **Suchen und Ersetzen im ganzen Projekt:** Ergebnisliste mit Datei und Zeile, Klick öffnet die
   Stelle, Ersetzen einzeln und alle. Gemeinsamer Kern mit 3.4.
4. **KI: projektweite Suche als Werkzeug** anstelle von `find_in_editor` (gleiche Werkzeugzahl,
   Suchleiste bleibt über `command` erreichbar). Teilstring, `pfad:zeile:text`, höchstens 30
   Treffer, Zeilen auf 200 Zeichen, gitignored/`engines/`/`models/`/`reference/` ausgeschlossen.
   Werkzeugwahl mit `llm-bench/bench/agent_eval.py` prüfen.
5. **LSP:** Diagnosen (publishDiagnostics, inline und Sprung zur nächsten), inkrementelles
   `didChange`, Hover, Referenzen, Umbenennen (WorkspaceEdit), Datei-Symbole, Server je Dateityp
   (`libs/flow-core/src/file_type_lsp.zig` ist vorhanden, `src/` nutzt nur zls), Formatieren über
   den Formatter-Eintrag derselben Tabelle (auch beim Speichern).
6. **Autovervollständigung:** Wörter aus offenen Dokumenten, LSP-Vorschläge, falls ein Server
   läuft (`lsp_completion` ist im Client vorhanden, aber ungenutzt).
7. **Suche im Editor:** alle Treffer markieren, Trefferzahl in der Statuszeile, F3/Shift+F3.
8. **Git-Änderungsmarken im Gutter** (`flow_core.diff` ist exportiert, ungenutzt) und Sprung zur
   nächsten/vorigen Änderung.
9. **Inkrementelles Highlighting nach Undo/Redo/Reload:** alten gegen neuen Text diffen und als
   tree-sitter-Edits melden statt `resetTree()` (flow `editor.zig:6256-6285`).
10. **KI: `list_files` sortiert, ohne `.git/` und `.zig-cache/`; `read_file` lehnt Binärdateien
    ab** (NUL in den ersten 512 Bytes).

## 4. Komfort

1. **Leerzeichen am Zeilenende beim Speichern entfernen** (abschaltbar, wie Autosave gemerkt).
2. **Undo/Redo in einzeiligen Feldern** (`line_edit.zig`: Suche, Picker, Umbenennen,
   Commit-Nachricht, Ordnerauswahl), schnelle Eingaben zu einem Schritt zusammenfassen (gooey
   `widgets/edit_history.zig`).
3. **Editier-Befehle:** Zeile darunter/darüber einfügen (Ctrl+Enter, Ctrl+Shift+Enter), Zeile
   markieren (Ctrl+L), alle Vorkommen markieren (Ctrl+Shift+L), Groß-/Kleinschreibung (braucht
   2.5).
4. **Editier-Komfort aus flow:** Smart Home (erst Codeanfang, dann Spalte 0), Smart Backspace (eine
   Einrückstufe), Auswahl nach Syntaxbaum vergrößern/verkleinern, zur passenden Klammer springen,
   Zeilen verbinden, letzten Mehrfach-Cursor zurücknehmen, Cursor an alle Zeilenenden.
5. **PDF-Ansicht** (Ideen aus fancy-cat, `src/ui/pdf_view.zig`, `src/ui/pdf_nav.zig`,
   `src/rendering/pdf_handler.zig`):
   1. Umschalten ganze Seite / volle Breite (heute immer volle Breite).
   2. Dunkelmodus: Seite in Theme-Farben umfärben (`fz_tint_pixmap`).
   3. Zu Seite N springen, dazu Home/End.
   4. LRU-Cache gerenderter Seiten (Schlüssel: Seite, Zoom, Modus, Farbe), Textur beim Verdrängen
      freigeben.
   5. Zoom und Verschieben innerhalb der Seite (z. B. Ctrl+Rad), ohne das Blättern per Rad zu
      brechen.
6. **IME:** wio liefert `preview_reset`/`preview_char`/`preview_cursor`, `platform/mod.zig` wirft
   sie weg; Vorschautext unterstrichen zeichnen, Cursor-Rechteck an `enableTextInput` geben.
7. **Schatten** für Dialoge, Menüs, Tooltips, Picker (gleicher Shader wie 2.2, `PRIM_SHADOW`).
8. **Debug:** Clays eingebauten Debug-Modus (`setDebugModeEnabled`) per Kürzel schaltbar; später
   Profiler-Overlay mit Zeiten je Phase (Layout, Render, Atlas-Upload).
9. **Weiches Scrollen:** Pixel-Versatz statt ganzer Zeilen, Feder-Physik (gooey
   `animation/spring.zig`); `src/ui/animation.zig` wird bisher nirgends benutzt.

## Aufräumen

1. **Referenz-Klone löschen:** `reference/KrillClaw`, `reference/pls`, `reference/lite-xl`,
   `reference/flow`, `reference/gooey`, sobald die übernommenen Punkte oben umgesetzt sind.
