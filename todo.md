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

## File-Watcher flutet den Scheduler

Im Headless-Lauf mit Screenshot-Schreibzugriffen kamen >1400 Dateiereignisse, jedes
löst einen git-status-Task aus → "work queue full". Ereignisse debouncen oder
`tmp/` und `.zig-cache/` vom Watcher ausnehmen.
