# Todo

Keine offenen Punkte (Stand 2026-09-05). Bekannte Grenzen stehen in AGENTS.md.
Erledigt-Log:

## AI Chat Markdown Rendering — umgesetzt (2026-09-05)

Chat-Nachrichten laufen jetzt über `src/ai/chat_markdown.zig` (Tool-Call-Erkennung,
Anzeige-Markdown) und `MarkdownView.renderDocument` (Blöcke ohne Scroll-Container).
Tool-Calls werden als `json`-Codeblock mit Syntax-Highlighting gerendert, Tool-Ergebnisse
(system-Rolle) als Codeblock, damit Dateiinhalte nicht als Markdown geparst werden.

### Inline-Styling — umgesetzt (2026-09-05)
Es gibt nur eine Font-Face, deshalb zeigt die MarkdownView Styles über Farbe:
fett = primary, kursiv = accent, Codespan = warning, Link = blau, durchgestrichen = muted.
Umbruch mit Per-Wort-Farben läuft über `src/ui/word_wrap.zig` (gemessene Stücke,
greedy-Zeilen), Chat und Vorschau nutzen denselben Pfad.

### Parse-Cache — umgesetzt (2026-09-05)
Jede MarkdownView parst ihren Text genau einmal (Heap-Arena + ParseResult) und rendert
danach nur noch den gecachten Baum. Grenzen von zigdown und Font-Renderer stehen in AGENTS.md.

## File-Watcher-Flut — behoben (2026-09-05)

Debounce im Main-Loop (ein git-status-Task pro 300-ms-Fenster), Watcher unterdrückt
direkt aufeinanderfolgende identische Ereignisse und ignoriert `zig-out`/`node_modules`.
Headless-Lauf mit Screenshot: 2037 → 2 Ereignisse, keine vollen Queues mehr.
