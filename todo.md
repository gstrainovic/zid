# todo.md — UI-Lücken gegenüber gängigen Editor-Best-Practices (Zed, VS Code, nvim-tree, yazi)

Nur offene Punkte. Prioritäten: **P1** Datenverlust/Absturz/Blocker, **P2** tägliche Bedienung, **P3** Komfort.
Belege aus der Sitzung vom 06.09.2026 (Log mit Panic in `gpu_renderer.zig:305`) stehen in Klammern.

## Robustheit bei großen und merkwürdigen Dateien

- [ ] **P3 Horizontale Scrollbar und Word-Wrap-Umschalter** im Editor (Shift+Mausrad und
      Cursor-Folgen gibt es seit 06.09.2026).
- [ ] **P3 llama-server 503 während des Warmups** landet als `error: Llama Server Error: 503` im Log
      statt als Status im Chat-Kopf.
## Explorer

- [ ] **P2 Lange Namen werden hart abgeschnitten** (Screenshot: `test_dat`, `referenc`, `CLAUDE.m`):
      Ellipsis + Tooltip mit vollem Pfad, oder Sidebar horizontal scrollen; Sidebar-Breite merken.
- [ ] **P3 Versteckte Dateien** (`.`-Einträge werden in `loadDirectory` übersprungen) und
      .gitignore-Einträge umschaltbar anzeigen (ausgegraut statt versteckt).
- [ ] **P3 Filterfeld im Explorer** (Tippen filtert den Baum).
- [ ] **P3 Drag & Drop** zum Verschieben (mit Bestätigung), Duplizieren.
- [ ] **P3 Icons nach Dateityp** (heute Blitz/Seite), Git-Status-Farbe auch für Ordner
      (Propagation nach oben).

## Tab-Leiste

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
