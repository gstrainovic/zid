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
4. **PDF-Auflösung uneinheitlich:** 1.5 beim Öffnen, 2.0 beim Blättern, fest statt aus der
   Pane-Größe; bei Größenänderung neu rendern.
5. **Unicode-Fallfaltung fehlerhaft** (`libs/flow-core/src/buffer/unicode.zig`: × → ÷, ß → ÿ,
   Σ/Τ, Č/Š/Ž und Kyrillisch fehlen). Heute ungenutzt; vor Groß-/Kleinschreibung (4.2) auf uucode
   umstellen wie flow.
6. **Suche ignoriert Groß/Klein nur für ASCII** (`find_ops.zig` `eqlIgnoreCase`): „Ä“ findet
   kein „ä“.
7. **Toter KI-Download-Zweig:** `triggerDownload` in `ai_chat.zig` ruft niemand mehr auf (seit
   `selfsetup.zig` lädt); `model_filename` (`Q4_K_M`, unsloth), `model_exists` und
   `is_downloading` hängen noch daran, `chat_state` meldet sie. Entfernen.
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

9. **mupdf stürzt bei manchen kaputten PDFs ab** (System-Bibliothek 1.27.2; `mutool draw` auf
    einem zu 40 % geschriebenen PDF: Segfault, in zid „double free“). Der Reload wartet deshalb
    auf eine ruhende Datei; eine dauerhaft kaputte Datei öffnen reißt zid aber weiter mit.
    Rendern in einen Kindprozess auslagern oder mupdf-Version prüfen.

## 3. Wichtige Funktionen

1. **KI: Deny beendet die Runde.** Heute geht der Fehler zurück ans Modell (eine volle Runde mehr,
   der abgelehnte Inhalt steht im Prompt) und weitere Aufrufe derselben Antwort laufen trotzdem.
   Neu: übrige Aufrufe als „skipped“, kein weiterer LLM-Aufruf. Erwartung: 3–8 s schneller nach
   Deny (`e2e_ai_tools.py` Schritt 5).
2. **Suchen und Ersetzen im ganzen Projekt:** Ergebnisliste mit Datei und Zeile, Klick öffnet die
   Stelle, Ersetzen einzeln und alle. Gemeinsamer Kern mit 3.3.
3. **KI: projektweite Suche als Werkzeug** anstelle von `find_in_editor` (gleiche Werkzeugzahl,
   Suchleiste bleibt über `command` erreichbar). Teilstring, `pfad:zeile:text`, höchstens 30
   Treffer, Zeilen auf 200 Zeichen, gitignored/`engines/`/`models/`/`reference/` ausgeschlossen.
   Werkzeugwahl mit `llm-bench/bench/agent_eval.py` prüfen.
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
   2.5).
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
   5. Zoom und Verschieben innerhalb der Seite (z. B. Ctrl+Rad), ohne das Blättern per Rad zu
      brechen.
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

Hängt an Konten und einem Windows-Rechner, nicht am Code. Stand: v0.1.1 liegt als
Release (Linux-Tarball, Windows-Zip, PKGBUILD), COPR hat 0.1.1-1 gebaut.

1. **Windows-Zip gegenprüfen:** `zid-0.1.1-x86_64-windows.zip` vom Release auf einem
   echten Windows starten. Gebaut und rauchgetestet (`zid.exe --version`) hat es die CI,
   gezeichnet hat es dort niemand.
2. **Scoop:** `packaging/scoop/zid.json` liegt fertig mit Prüfsumme. Es fehlt ein eigener
   Bucket (eigenes Repo `scoop-zid`), dann `scoop bucket add`.
3. **WinGet:** `packaging/winget/` (drei Manifeste, Schema 1.6) als Pull Request nach
   `microsoft/winget-pkgs`. Vorher lokal `winget validate --manifest packaging\winget`.
4. **AUR:** `packaging/aur/PKGBUILD` und `.SRCINFO` stehen auf 0.1.1. Registrierung bei
   `aur.archlinux.org` war zuletzt eingefroren (503); danach nach `ssh://aur@aur.archlinux.org/zid-bin.git`
   pushen.
5. **Binärgröße:** 155 MB entpackt, davon 109 MB tree-sitter-Parsetabellen. Strippen bringt
   1 MB, der Hebel wäre eine Auswahl an Grammatiken (`syntax`-Dependency).
