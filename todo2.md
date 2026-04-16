# Aufgabenliste für die Implementierung in vulkan-ed

## Status
- [ ] 1. Analyse des Git-Feature-Sets von `libs/flow`.
- [ ] 2. Verschieben der `flow-core` Komponenten in `libs/flow-core/**` und Implementierung in `vulkan-ed`.

## Details zu den Aufgaben
### 1. Git-Integration
- **Ziel:** Implementierung von asynchronen Git-Status, Branch-Informationen, Blame und Datei-Tracking für UI-Dekorationen.
- **Kontext:** Die Git-Integration in `libs/flow/src/git.zig` dient als Datenlieferant, nicht als CLI-Ersatz.

### 2. Implementierung von `flow-core`
- **Ziel:** Integration der Core-Logik in `vulkan-ed`.
- **Komponenten:**
  - `TypedInt`: Typisierte IDs für Buffer/Nodes.
  - `Buffer/Node`: Kern-Rope-Struktur für Textverwaltung.
  - `Keybind`: Input-Parsers (`flow` und `vim` Stile).
  - `File Type Config`: Dateityp-spezifische Konfiguration.
  - `Highlighting`: Tree-sitter-basierte Syntax-Hervorhebung.
  - `Snippet`: Snippet-Parsing-Logik.
