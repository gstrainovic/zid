# Offene Punkte

## Windows: Watcher folgt Symlink-Ordnern nicht

`src/async/file_watcher_win.zig` hält ein `ReadDirectoryChangesW`-Handle auf die Wurzel mit
`bWatchSubtree=TRUE`; Windows folgt dabei keinen Reparse-Points (Symlink, Junction). Linux ist
seit `bc6872c` behoben (`scripts/e2e_external_change.py`, vier Fälle grün).

1. `python3 scripts/e2e_external_change.py` auf dem Windows-PC laufen lassen. Erwartung: `inplace`
   und `atomic` grün (main.zig reicht `file_created` jetzt weiter), `symlink` vermutlich grün
   (Ereignis kommt über den echten Pfad, `UI.bufferKeyForPath` vergleicht per realpath),
   `symlink_out` rot. `os.symlink` braucht dort Developer-Mode oder Admin; sonst Junction per
   `mklink /J` im Skript als Fallback.
2. Für `symlink_out`: beim Start den Baum einmal durchgehen, je Symlink-/Junction-Ordner mit Ziel
   außerhalb der Wurzel ein eigenes `ReadDirectoryChangesW`-Handle öffnen (gleiche Filter, gleiche
   Overlapped-Schleife), Ereignispfade unter dem Link-Pfad melden. Ziel innerhalb der Wurzel
   braucht kein zweites Handle.
3. AGENTS.md-Satz „Der Windows-Watcher folgt Symlink-Ordnern nicht“ danach streichen.

## KI-Agent

Jeder Punkt mit geschätzter Wirkung vorab, gemessen vorher/nachher (`scripts/e2e_ai_read_limits.py`,
`scripts/e2e_ai_tools.py`); Antworten streuen bei Temperatur 0.7, also Fälle wiederholen.

1. **Werkzeugergebnisse als Klartext statt JSON-String.** `read_file` liefert heute
   `{"path","content"}` als String; das gemma4-Template reicht ihn unverändert durch, das Modell
   sieht `\n` und `\"` statt echter Zeilen. Erwartung: 5–10 % weniger Prompt-Token bei Code, evtl.
   zuverlässigere „letzte Zeile“ ab 12 KB. `ai_tools.shrinkToolResult` muss das neue Format kürzen.
2. **Deny beendet die Runde.** Heute geht `{"error":"the user denied this action"}` zurück ans Modell
   (eine volle Runde mehr, der abgelehnte Inhalt steht im Prompt) und weitere Aufrufe derselben
   Antwort laufen trotzdem. Neu: übrige Aufrufe als „skipped“ eintragen, kein weiterer LLM-Aufruf.
   Erwartung: 3–8 s schneller nach Deny (`e2e_ai_tools.py` Schritt 5).
3. **`finish_reason: "length"` auswerten.** Läuft die Antwort ans Ende von `-c 8192`, ist sie still
   abgeschnitten; abgeschnittene Tool-Argumente enden als „arguments are not valid JSON“. Neu:
   Hinweis „abgeschnitten“, abgeschnittene Aufrufe nicht ausführen. Kein `max_tokens`, das würde
   lange `write_file`-Inhalte kappen. Nachstellen: 20-KB-Datei lesen und vollständig wiedergeben
   lassen.
4. **`list_files` sortiert, ohne `.git/` und `.zig-cache/`; `read_file` lehnt Binärdateien ab**
   (NUL in den ersten 512 Bytes).
5. **Projektweite Suche als Werkzeug** anstelle von `find_in_editor` (gleiche Werkzeugzahl, die
   Suchleiste bleibt über `command` erreichbar). Teilstring, `pfad:zeile:text`, höchstens 30
   Treffer, Zeilen auf 200 Zeichen, gitignored/`engines/`/`models/`/`reference/` ausgeschlossen.
   Gemeinsamer Kern mit der Projektsuche im Editor. Werkzeugwahl mit `llm-bench/bench/agent_eval.py`
   prüfen.
6. **Clay-Überlauf bei langen Chat-Antworten:** eine Antwort mit 1 844 Token löste
   `elements_capacity_exceeded` aus (`e2e_ai_read_limits.py 40000:first`).
7. **Download-Zweig in `ai_chat.zig` ist veraltet:** `model_filename` und die URL zeigen auf
   `gemma-4-E2B-it-Q4_K_M` (unsloth), das Standardmodell ist `gemma-4-E2B-it-Q4_0` (ggml-org,
   `src/ai/paths.zig`); der Knopf erscheint nur für Ollama. Auf das Standardmodell umstellen oder
   den Zweig entfernen.

## Editor

1. **Suchen und Ersetzen im ganzen Projekt:** Ergebnisliste mit Datei und Zeile, Klick öffnet die
   Stelle, Ersetzen einzeln und alle. Kern teilt sich die Suche mit dem Agent-Werkzeug.
2. **Leerzeichen am Zeilenende beim Speichern entfernen** (abschaltbar, wie Autosave gemerkt).
3. **Editier-Befehle:** Zeile darunter/darüber einfügen (Ctrl+Enter, Ctrl+Shift+Enter), Zeile
   markieren (Ctrl+L), alle Vorkommen markieren (Ctrl+Shift+L), Groß-/Kleinschreibung.
4. **Autovervollständigung:** Wörter aus offenen Dokumenten, LSP-Vorschläge, falls ein Server
   läuft (`lsp_completion` ist im Client schon vorhanden, aber ungenutzt).
5. **PDF-Ansicht** (Ideen aus fancy-cat, `src/ui/pdf_view.zig`, `src/ui/pdf_nav.zig`,
   `src/rendering/pdf_handler.zig`):
   1. Neu laden, wenn sich die Datei ändert: ein offenes PDF zeigt nach erneutem Marp-Export den
      alten Stand (`handleExternalChange` kennt nur Text-Buffer, `main.zig` lädt nur, wenn der Pfad
      noch nicht in `open_pdfs` ist). Bei halb geschriebener Datei kurz erneut versuchen, Seite
      klemmen, wenn das Dokument kürzer wird.
   2. Render-Auflösung aus der Pane-Größe statt fest (heute 1.5 beim Öffnen, 2.0 beim Blättern),
      bei Größenänderung neu rendern.
   3. Umschalten ganze Seite / volle Breite (heute immer volle Breite).
   4. Dunkelmodus: Seite in Theme-Farben umfärben (`fz_tint_pixmap`).
   5. Zoom und Verschieben innerhalb der Seite (z. B. Ctrl+Rad), ohne das Blättern per Rad zu
      brechen.
   6. LRU-Cache gerenderter Seiten (Schlüssel: Seite, Zoom, Modus, Farbe), Textur beim Verdrängen
      freigeben.
   7. Zu Seite N springen, dazu Home/End.
6. **Rendering und Eingabe** (Ideen aus gooey, `reference/gooey`):
   1. Clip-Stapel: verschachtelte Clips schneiden statt ersetzen (`clay_renderer/mod.zig`
      `scissor_start`/`scissor_end` setzen absolut bzw. aufs ganze Fenster zurück). Vorbild
      `scene.zig` `pushClip`/`popClip` mit Schnittmenge.
   2. Abgerundete Ecken und Rahmen mit Radius: der Renderer ignoriert `corner_radius` (69 Stellen in
      `src/` werden eckig gezeichnet). SDF-Shader aus gooey `platform/wgpu/shaders/unified.wgsl`
      ist WGSL und übertragbar.
   3. Schatten für Dialoge, Menüs, Tooltips, Picker (gleicher Shader, `PRIM_SHADOW`).
   4. Undo/Redo in einzeiligen Feldern (`line_edit.zig`: Suche, Picker, Umbenennen,
      Commit-Nachricht, Ordnerauswahl), schnelle Eingaben zu einem Schritt zusammenfassen
      (gooey `widgets/edit_history.zig`).
   5. IME: wio liefert `preview_reset`/`preview_char`/`preview_cursor`, `platform/mod.zig` wirft
      sie weg; Vorschautext unterstrichen zeichnen, Cursor-Rechteck an `enableTextInput` geben.
   6. Debug: Clays eingebauten Debug-Modus (`setDebugModeEnabled`) per Kürzel schaltbar; später
      Profiler-Overlay mit Zeiten je Phase (Layout, Render, Atlas-Upload).
   7. Weiches Scrollen: Pixel-Versatz statt ganzer Zeilen, Feder-Physik (gooey
      `animation/spring.zig`); `src/ui/animation.zig` wird bisher nirgends benutzt.
   8. Grenzwerte zentral (`limits`-Modul) und laut statt still: Shaper liefert bei > 2048 Bytes
      leer, Clay-Kapazität läuft ohne Meldung voll. Loggen und im RPC zählen, nicht abstürzen.
7. **Referenz-Klone löschen:** `reference/KrillClaw`, `reference/pls`, `reference/lite-xl`, `reference/flow`, `reference/gooey`, sobald
   die Punkte oben umgesetzt sind.
