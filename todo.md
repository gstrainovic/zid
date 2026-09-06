# todo.md — UI-Lücken gegenüber gängigen Editor-Best-Practices (Zed, VS Code, nvim-tree, yazi)

Nur offene Punkte. Prioritäten: **P1** Datenverlust/Absturz/Blocker, **P2** tägliche Bedienung, **P3** Komfort.
Belege aus der Sitzung vom 06.09.2026 (Log mit Panic in `gpu_renderer.zig:305`) stehen in Klammern.

## Robustheit bei großen und merkwürdigen Dateien

- [ ] **P3 Word-Wrap-Umschalter** im Editor (horizontale Scrollbar, Shift+Mausrad und
      Cursor-Folgen gibt es seit 06.09.2026).
## Explorer

- [ ] **P3 .gitignore-Einträge ausgegraut** zeigen (versteckte Dateien schaltet `.` seit 06.09.2026
      um; ignorierte Dateien bräuchten `git status --ignored` im Git-Worker).
## Tab-Leiste

## Editor

- [ ] **P3 LSP anbinden**: `lsp_client.zig` kann definition/hover/completion, wird aber nirgends
      gestartet; Ctrl+Klick/F12 springen heute per Textmuster (`edit_ops.looksLikeDefinition`) nur
      innerhalb der Datei.
## Fenster, Splits, Menüs

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
