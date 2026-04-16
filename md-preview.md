Verfügbare Markdown-Renderer (identifiziert in libs/ und reference/):

1. **Zigdown (libs/zigdown)**: Native Zig-Bibliothek, die einen AST (Abstract Syntax Tree) liefert. Jetzt integriert in src/ui/markdown_view.zig für ein reichhaltiges Rendering mittels Clay. Unterstützt:
   - Überschriften (H1-H6)
   - Listen und Listenpunkte
   - Zitate (Blockquotes) mit Akzent-Balken
   - Code-Blöcke und Inline-Code
   - Fett/Kursiv-Stile und Links (Basis-Support)
   - Alerts und horizontale Trennlinien

2. **Lite-XL (reference/lite-xl)**: Sprachunterstützung für Markdown über Lua-Plugins (Syntax-Hervorhebung).
3. **Ghostty (reference/ghostty)**: Verwendet Pandoc-Flavor Markdown für Konfigurationshilfen.
4. **SDL-Wiki (reference/sev/vendored/SDL)**: Skripte zur Markdown-Verarbeitung für Dokumentation.

Die primäre Lösung für die UI-Vorschau im Editor ist nun die auf **Zigdown** basierende Implementierung in src/ui/markdown_view.zig.

![Zig Logo](libs/gooey/assets/ziglang_logo.png)
