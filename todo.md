# AI Chat Markdown Rendering

## Status
Geplant, nicht umgesetzt.

## Was nötig wäre
AI-Chat-Antworten werden aktuell als Plain-Text via `clay.text()` gerendert (ai_chat.zig:594).

Um Markdown-Formatierung einzubauen (wie in markdown_view.zig):

1. **Erst** Tool-Call-JSON parsen (im rohen String, für `tryExecuteToolCall`)
2. **Dann** String als Markdown parsen (zigdown Block/Inline Tree)
3. Blocks rendern mit Syntax-Highlighting
4. Tool-Call-JSON als Code-Block behandeln

## Warum komplex
- `tryExecuteToolCall` sucht nach JSON-Fragmente im gesamten `payload` String
- Bei Markdown-Parse wird der String in strukturierte Blocks zerlegt
- Tool-Call-Logik muss weiterhin funktionieren
- Message-Logik von `addMessage` bis `render` muss neu strukturiert werden