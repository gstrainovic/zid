---
name: marp
description: >
  Marp-Decks in zid: Parser, Folienvorschau und PDF-Export über MuPDFs Story-Engine.
  Use when working on Marp decks, slide preview, PDF export, `src/ui/marp.zig`,
  `src/ui/marp_html.zig`, `src/rendering/marp_pdf.zig`, the `md_export_pdf` command,
  or MuPDF writer wrappers in `mupdf_wrapper/fitz-z.c`.
---

# Marp in zid

Ein Deck ist eine Markdown-Datei mit `marp: true` im Front-Matter. Alles andere bleibt
gewöhnliches Markdown.

## Die drei Schichten

| Datei | Modul | Aufgabe |
| --- | --- | --- |
| `src/ui/marp.zig` | `marp` | Deck-Parser, rein, 15 Tests |
| `src/ui/marp_html.zig` | `marp_html` | Folie → HTML-Fragment plus CSS |
| `src/rendering/marp_pdf.zig` | — | Seiten schreiben über `fz_story` |

**Parser:** Front-Matter, Folientrennung an `---` (nicht im Code-Zaun, nicht bei
Setext-Überschriften), `headingDivider`, globale Direktiven (`theme`, `style`, `size`,
`headingDivider`) und lokale mit Vererbung (`_`-Präfix gilt nur für diese Folie).
Kommentare ohne Direktiven werden Notizen. Das `Deck` hält eine eigene Arena, die
Quelle darf danach freigegeben werden.

**HTML:** über zigdowns `HtmlRenderer` mit `body_only`. Bewusst CSS 2.1 — MuPDFs
Story-Engine kennt weder Flexbox noch Grid noch Custom Properties.

**PDF:** eine Seite je Folie in Foliengröße. Hintergrund, Kopf-/Fußzeile und Seitenzahl
zeichnet das Modul selbst, weil MuPDFs CSS kein `position` kennt. Die
setjmp-Kapselung der Schreibfunktionen steht in `mupdf_wrapper/fitz-z.c`, gleiches
Muster wie beim Lesen.

## Folienvorschau

`MarkdownView` parst ihren Text beim Anlegen als Deck (`deck`-Feld). Gelingt das, zeigt
sie eine Folie im Seitenverhältnis des Decks (`md_slide`) plus Blätterleiste
(`md_slide_prev`, `md_slide_counter`, `md_slide_next`). Geblättert wird per Pfeil
links/rechts, Bild auf/ab, Pos1/Ende, Mausrad und den Schaltflächen.

Es ist immer nur **eine** Folie geparst (`slide_arena`, `slide_parsed`); der
Folienwechsel wirft sie weg. `UI.activeSlideDeckView` liefert die Vorschau des aktiven
Tabs, wenn sie ein Deck zeigt — darüber laufen Tasten und der RPC `slide_state`
(`deck`, `slides`, `current`, `scale`, `font_size`, `overflow`).

**Rahmengröße wird selbst gerechnet.** `renderDeck` nimmt die Fläche des
Wurzelelements aus dem letzten Frame und setzt Breite und Höhe als `.fixed`. Clays
`.aspect_ratio` zusammen mit `.w = .grow` ließ den Rahmen auf Inhaltsgröße stehen. Das
Wurzelelement clippt, sonst wächst es mit dem Rahmen und der nächste Frame rechnet
daraus einen größeren — der Zoom flackert dann.

**Maßstab:** Rahmenbreite geteilt durch Deckbreite. Ränder und Grundschrift stammen aus
denselben Konstanten wie der Export (`pdf_margin_x`, `pdf_margin_y`, `pdf_content_em`,
gespiegelt aus `marp_pdf.zig`); die Überschriftenfaktoren in `renderBlock`
(2.0 / 1.5 / 1.2) entsprechen dem Export-CSS. Untergrenze 6 px.

**Passt die Folie?** `marp_pdf.slideFits` legt sie mit `fz_place_story` aus und zeichnet
nichts. Bleibt Inhalt übrig, zeigt die Vorschau „Inhalt passt nicht auf die Folie"
(`md_slide_overflow`). Clay kann das nicht beantworten, weil der Rahmen clippt und die
gemessene Höhe deshalb nie über die Innenhöhe geht.

## Bedienung

Command `md_export_pdf` („Export to PDF") in `shortcuts.zig`, sichtbar im
Tab-Kontextmenü, im Editor-Kontextmenü, im Kontextmenü der Vorschau und im View-Menü.
Die drei Kontextmenüs zeigen ihn nur bei Marp-Decks: Editor und Tab-Menü prüfen
`marp.isMarpDeck` auf dem Buffer (ungespeichertes Front-Matter zählt), das Tab-Menü ohne
geladenen Buffer per `marp.isMarpDeckFile` auf dem Dateikopf, die Vorschau über ihr
`deck`-Feld. `md_preview` bleibt bei jeder `.md` sichtbar. Das Ergebnis landet neben der
Quelle (`deck.md` → `deck.pdf`) und öffnet sich als PDF-Tab. Über das View-Menü geht der
Export auch bei Nicht-Decks; fehlt `marp: true`, kommt ein Fehlerdialog statt einer Datei.

## Prüfen

```bash
python3 scripts/e2e_marp_pdf.py            # headless, deckt alles ab
mutool draw -F txt -o - DATEI.pdf SEITE    # einzelne Seite als Text
```

Fixture: `test_data/marp_test.md`.

## Grenzen

- Der Streifen für Kopf- und Fußzeile muss eine Zeile samt Abstand fassen, sonst
  platziert `fz_place_story` **gar nichts** (daher `chrome_h = 40` und `p { margin: 0 }`).
- Inhalt, der nicht auf die Folie passt, wird abgeschnitten statt verkleinert.
- zigdown maskiert nur Textstücke, die selbst eine spitze Klammer enthalten; ein
  alleinstehendes `&` bleibt roh.
- Mehrzeiliges YAML im Front-Matter (`style: |`) wird nicht zusammengefasst.
- `![bg]`-Hintergrundbilder bleiben im Markdown stehen.
- Die Vorschau bildet den Umbruch nach, ist aber keine Pixelkopie: sie zeichnet mit der
  Editor-Schrift, das PDF mit MuPDFs Serifenloser. Über die Foliengrenze entscheidet
  `slideFits`, nicht das Auge.
