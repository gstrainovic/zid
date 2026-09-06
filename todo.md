# todo.md — UI-Lücken gegenüber gängigen Editor-Best-Practices (Zed, VS Code, nvim-tree, yazi)

Nur offene Punkte. Prioritäten: **P1** Datenverlust/Absturz/Blocker, **P2** tägliche Bedienung, **P3** Komfort.
Belege aus der Sitzung vom 06.09.2026 (Log mit Panic in `gpu_renderer.zig:305`) stehen in Klammern.

## Robustheit bei großen und merkwürdigen Dateien

- [ ] **P3 Horizontale Scrollbar und Word-Wrap-Umschalter** im Editor (Shift+Mausrad und
      Cursor-Folgen gibt es seit 06.09.2026).
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

- [ ] **P2 Vorschau-Tabs**: Einfachklick öffnet heute sofort einen festen Tab; Zed/VS Code öffnen
      einen Preview-Tab (kursiv, wird vom nächsten Klick ersetzt), Doppelklick oder Bearbeiten macht
      ihn fest. Gehört zusammen mit der Tab-Leiste umgesetzt.
- [ ] **P2 Lange Namen werden hart abgeschnitten** (Screenshot: `test_dat`, `referenc`, `CLAUDE.m`):
      Ellipsis + Tooltip mit vollem Pfad, oder Sidebar horizontal scrollen; Sidebar-Breite merken.
- [ ] **P3 Versteckte Dateien** (`.`-Einträge werden in `loadDirectory` übersprungen) und
      .gitignore-Einträge umschaltbar anzeigen (ausgegraut statt versteckt).
- [ ] **P3 „Reveal active file“** (Explorer folgt dem aktiven Tab, klappt auf), Filterfeld
      (Tippen filtert den Baum).
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

## KI-Agent (aus `~/projects/bitnet-colibri-bench/HANDOFF-vulkan-ed.md`, 06.09.2026)

- [ ] **P2 Temperatur pro Anfrageart**: `agent.zig` `buildPayload` schickt fest `temperature: 0.7`,
      auch in Werkzeugrunden; der Bench misst die 10/10 Werkzeugwahl von Qwen3-4B bei 0.0. Messen
      (drei Läufe `bench/agent_eval.py` bei 0.7 gegen 0.0, Anleitung im Handoff); fällt die Quote,
      Temperatur 0 für Anfragen mit `tools`, 0.7 nur für reine Chat-Antworten (Unit-Test auf
      `buildPayload` zuerst). Bleibt sie bei 10/10, negatives Ergebnis in AGENTS.md notieren.
- [ ] **P3 CPU-Fallback ohne Batch-Threads**: `agent.zig` startet mit `-t min(Kerne, 8)` ohne `-tb`;
      der Bench nutzt `-t 8 -tb 12` (Qwen3-4B CPU 9,9 tok/s). Mit `llama-bench -p 128 -n 64` `-t 8`
      gegen `-t 8 -tb 12` messen; bringt es etwas, `-tb` an die Kernzahl gekoppelt ergänzen
      (Unit-Test auf den argv-Aufbau zuerst).
- [ ] **P2 Gemessene Grenzen in AGENTS.md**: Ein-Datei-Fix gelingt mit Qwen3-4B, Ursachen über einen
      Import hinweg scheitern (Qwen3 gefahrlos, Llama-3.2-3B destruktiv); Prompt-Verarbeitung auf
      der P1000 96 tok/s, Kontext wächst je Werkzeugrunde, `-c 8192` ohne Kürzen der Historie —
      prüfen, was llama-server an der Kontextgrenze tut, und entscheiden, ob alte Runden verworfen
      werden; Agenten-Änderungen nur in Git-Repos (nur Bestätigungsdialoge sichern) — mindestens
      dokumentieren, Warnung außerhalb eines Repos ist Produktentscheidung.
- Regeln aus dem Handoff: `python3 scripts/e2e_ai_tools.py` muss nach jeder Änderung an `agent.zig`
  grün bleiben; Messzahlen mit Engine-Commit und Modell-sha256; Referenz
  `bitnet-colibri-bench/results/linux-i7-8850H-gpu-und-neue-modelle.md`.
