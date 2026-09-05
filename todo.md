# Offene Punkte

## AI Chat Markdown Rendering — umgesetzt (2026-09-05)

Chat-Nachrichten laufen jetzt über `src/ai/chat_markdown.zig` (Tool-Call-Erkennung,
Anzeige-Markdown) und `MarkdownView.renderDocument` (Blöcke ohne Scroll-Container).
Tool-Calls werden als `json`-Codeblock mit Syntax-Highlighting gerendert, Tool-Ergebnisse
(system-Rolle) als Codeblock, damit Dateiinhalte nicht als Markdown geparst werden.

### Bekannte Grenzen
- **fett**/*kursiv* werden geparst, aber nicht gestylt (MarkdownView ignoriert TextStyle).
- Links erscheinen als Text ohne Farbe; Fließtext wird für den Umbruch zu einem Element
  zusammengefügt.
- Jede Nachricht parst ihr Markdown pro Frame neu (gleiches Verhalten wie die Vorschau).

## File-Watcher-Flut — behoben (2026-09-05)

Debounce im Main-Loop (ein git-status-Task pro 300-ms-Fenster), Watcher unterdrückt
direkt aufeinanderfolgende identische Ereignisse und ignoriert `zig-out`/`node_modules`.
Headless-Lauf mit Screenshot: 2037 → 2 Ereignisse, keine vollen Queues mehr.
