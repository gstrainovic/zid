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
