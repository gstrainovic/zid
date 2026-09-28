---
name: marp
description: >
  Marp-Decks in zid: Parser, Folienvorschau und PDF-Export über marp-cli, das zid selbst
  einrichtet (samt chrome-headless-shell, wenn kein Browser da ist).
  Use when working on Marp decks, slide preview, PDF export, `src/ui/marp.zig`,
  `src/rendering/marp_cli.zig`, the `md_export_pdf` command, `ZID_TOOLS_DIR`,
  or background images (`![bg]`) and SVG images in the preview.
---

# Marp in zid

Ein Deck ist eine Markdown-Datei mit `marp: true` im Front-Matter. Alles andere bleibt
gewöhnliches Markdown.

## Die Teile

| Datei | Modul | Aufgabe |
| --- | --- | --- |
| `src/ui/marp.zig` | `marp` | Deck-Parser, rein, unit-getestet |
| `src/ui/markdown_view.zig` | — | Folienvorschau (`renderDeck`) |
| `src/rendering/marp_cli.zig` | `marp_cli` | PDF-Export: marp-cli einrichten und aufrufen |

**Parser:** Front-Matter, Folientrennung an `---` (nicht im Code-Zaun, nicht bei
Setext-Überschriften), YAML-Blockskalare im Front-Matter, `headingDivider`, globale
Direktiven (`theme`, `style`, `size`, `headingDivider`) und lokale mit Vererbung
(`_`-Präfix gilt nur für diese Folie). Kommentare ohne Direktiven werden Notizen. Das
`Deck` hält eine eigene Arena, die Quelle darf danach freigegeben werden.

**Hintergrundbilder:** Zeilen nur aus `![bg …](src)` nimmt der Parser aus dem Markdown
heraus und legt sie als `Slide.backgrounds` ab (Seite `left`/`right` mit Anteil, `cover`/
`contain`/`fit`/`auto`, `N%`). `marp.Split.of` liefert die Teilung, `Background.fitSize`
die Bildgröße. Das braucht nur die Vorschau; der Export gibt das Deck unverändert an
marp-cli.

## PDF-Export über marp-cli

Das PDF macht nie zid selbst, sondern marp-cli, Marps eigener Konverter (Marp Core,
gedruckt von einem Browser). Das Ergebnis ist dasselbe wie in VS Code. MuPDF bleibt für
das Anzeigen von PDFs und Bildern zuständig.

- **Einrichtung beim ersten Export:** `Exporter` in `marp_cli.zig` lädt die eigenständige
  marp-cli (Node eingebaut, ein Programm, gepinnt `marp_tag`) nach
  `<Datenverzeichnis>/tools/marp-cli-<tag>/`. Download und Auspacken über `download` und
  `ai_selfsetup.install` wie bei der KI.
- **Browser:** marp-cli sucht Chrome, Edge, Firefox. Meldet es „No suitable browser
  found“, lädt zid chrome-headless-shell (Chrome for Testing, gepinnt `chrome_version`,
  rund 121 MB) nach `tools/chrome-headless-shell-<version>/` und ruft marp-cli erneut mit
  `--browser chrome --browser-path`. Linux auf ARM hat keine chrome-headless-shell:
  dort Fehlermeldung. Unter Windows ist Edge immer da.
- **Aufruf:** `marp --no-stdin --pdf --allow-local-files deck.md -o deck.pdf`.
  `--no-stdin` ist Pflicht: ohne Terminal liest marp sonst die Eingabe als Markdown.
- **Ablauf:** eigener Thread, Zustand atomar (`loading_marp`, `loading_browser`,
  `converting`, `done`, `failed`), `wake` weckt den Frame-Loop. `UI.pollMarpExport` (am
  Anfang von `renderExample`) meldet Wechsel per Toast, öffnet das PDF als Tab bzw. lädt
  einen offenen Tab neu, und zeigt Fehler als Dialog. Kein PDF bei Fehler, kein
  MuPDF-Rückfall.
- **`ZID_TOOLS_DIR`** ersetzt den Ablageort; die E2E setzt `tmp/tools`, damit nur der
  erste Lauf lädt. Unter Windows wirkt `XDG_DATA_HOME` nicht, ohne die Variable landeten
  E2E-Downloads im echten Profil.
- **Zip-Entpacker:** `install.extractZip` ist eine eigene Schleife über
  `std.zip.Iterator`, `flate.Decompress` im direkten Modus (leerer Puffer). Der indirekte
  Modus, den `std.zip.extract` nutzt, stürzt in Zig 0.15.2 bei manchen Einträgen ab
  („reached unreachable“ in `writeMatch`), beim Zip von chrome-headless-shell zuverlässig.

## Folienvorschau

`MarkdownView` parst ihren Text beim Anlegen als Deck (`deck`-Feld). Gelingt das, zeigt
sie eine Folie im Seitenverhältnis des Decks (`md_slide`) plus Blätterleiste
(`md_slide_prev`, `md_slide_counter`, `md_slide_next`). Geblättert wird per Pfeil
links/rechts, Bild auf/ab, Pos1/Ende, Mausrad und den Schaltflächen.

Es ist immer nur **eine** Folie geparst (`slide_arena`, `slide_parsed`); der
Folienwechsel wirft sie weg. `UI.activeSlideDeckView` liefert die Vorschau des aktiven
Tabs, wenn sie ein Deck zeigt — darüber laufen Tasten und der RPC `slide_state`
(`deck`, `slides`, `current`, `scale`, `font_size`).

Die Vorschau ist eine Annäherung zum Bearbeiten, keine Kopie des PDFs: eigene Schrift,
kein CSS (`style`, Themes), Ränder und Grundschrift aus `slide_margin_x`,
`slide_margin_y`, `slide_content_em`. Ob eine Folie überläuft, sagt nur das PDF.

**Rahmengröße wird selbst gerechnet.** `renderDeck` nimmt die Fläche des
Wurzelelements aus dem letzten Frame und setzt Breite und Höhe als `.fixed`. Clays
`.aspect_ratio` zusammen mit `.w = .grow` ließ den Rahmen auf Inhaltsgröße stehen. Das
Wurzelelement clippt, sonst wächst es mit dem Rahmen und der nächste Frame rechnet
daraus einen größeren — der Zoom flackert dann.

**Maßstab:** Rahmenbreite geteilt durch Deckbreite, Überschriftenfaktoren in
`renderBlock` 2.0 / 1.5 / 1.2, Untergrenze 6 px.

**Bildspalte und Hintergrund:** `md_slide` ist eine Zeile aus Bildspalte
(`md_slide_bg`) und Inhalt (`md_slide_content`). Ein volles `![bg]` liegt im Fluss, der
Inhalt schwebt darüber (`z_index` 1): in Clay zeichnet nur ein schwebendes Element über
ein Geschwister. Am Bildelement ist `background_color` die Tönung des Bildes, keine
Füllung — ohne Weiß dort wird das Bild schwarz; der weiße Grund unter transparenten
Skizzen kommt aus einer eigenen Hülle.

**SVG-Bilder** rastert die Vorschau über MuPDF, nicht nanosvg: nanosvg kennt weder
`<text>` noch `<use>`/`<symbol>`. MuPDF selbst liest die `viewBox` eines Symbols vom
`<use>` und erbt `font-family` nicht vom `<svg>`; `src/rendering/svg_fixup.zig` schreibt
beides vor dem Öffnen um. `<pattern>`-Füllungen (werden schwarz) und `stroke-dasharray`
(durchgezogen) kann MuPDF nicht. nanosvg bleibt Rückfall.

## Bedienung

Command `md_export_pdf` („Export to PDF") in `shortcuts.zig`, sichtbar im
Tab-Kontextmenü, im Editor-Kontextmenü, im Kontextmenü der Vorschau und im View-Menü.
Die drei Kontextmenüs zeigen ihn nur bei Marp-Decks: Editor und Tab-Menü prüfen
`marp.isMarpDeck` auf dem Buffer (ungespeichertes Front-Matter zählt), das Tab-Menü ohne
geladenen Buffer per `marp.isMarpDeckFile` auf dem Dateikopf, die Vorschau über ihr
`deck`-Feld. `md_preview` bleibt bei jeder `.md` sichtbar. Exportiert wird die Datei auf
der Platte, nicht ein ungespeicherter Buffer. Das Ergebnis landet neben der Quelle
(`deck.md` → `deck.pdf`). Über das View-Menü geht der Befehl auch bei Nicht-Decks; fehlt
`marp: true`, kommt ein Fehlerdialog statt einer Datei.

## Prüfen

```bash
python3 scripts/e2e_marp_pdf.py            # headless, deckt alles ab
```

RPC `marp_export_state`: `state`, `last` (Ergebnis des letzten Exports), `message`.
Fixture: `scripts/fixtures/marp_test.md` (eingecheckt, sieben Folien), Folie 2 mit
`![bg right:40% contain](marp_skizze.svg)`. Die E2E prüft Einrichtung und Export über
marp-cli, Seitenzahl und Skizzentext im PDF (Suche im PDF-Tab), Spaltenbreite und Farbe
der Skizze in der Vorschau.

Den Browser-Rückfall deckt die Suite nicht ab (121 MB): von Hand prüfen, indem zid mit
`PROGRAMFILES`, `PROGRAMFILES(X86)` und `LOCALAPPDATA` auf einen leeren Ordner startet
(Windows); dann findet marp-cli keinen Browser. Vorher normal bauen, der Zig-Cache
braucht das echte `LOCALAPPDATA`.

## Grenzen

- zigdown maskiert nur Textstücke, die selbst eine spitze Klammer enthalten; ein
  alleinstehendes `&` bleibt roh (Vorschau).
- Im Front-Matter kennt der Parser nur `key: value` und Blockskalare (`style: |`,
  `>`, mit `-`/`+`); Listen und verschachtelte Maps nicht.
- `![bg]` erkennt die Vorschau nur, wenn die Zeile aus nichts anderem besteht. Filter
  (`blur`, `sepia` …) und `vertical` fehlen; `N%` skaliert relativ zur contain-Größe.
  Volle Hintergründe gelten nur auf ungeteilten Folien.
