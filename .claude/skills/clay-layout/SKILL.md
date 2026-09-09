---
name: clay-layout
description: >
  Clay-Layout in zid: Fallstricke, die im Projekt schon Zeit gekostet haben —
  Elementgrenze, Mindestbreite von Text ohne Umbruch, verschachteltes Clipping,
  feste IDs in Schleifen, Fehlerbehandlung, Virtualisierung.
  Use when touching Clay layout code (clay.UI, clay.text, ElementId, sizing, clip),
  when a Clay error appears ("Layout elements exceeded", "duplicate_id"), when an
  element overflows its container, when text is clipped or misaligned, or when a
  list renders a large document.
---

# Clay in zid

Clay ist CSS-nah, aber die Voreinstellungen unterscheiden sich an ein paar Stellen
schmerzhaft. Die folgenden Punkte sind alle im Projekt aufgetreten.

## Zuerst messen, dann ändern

Bei jedem Layout-Problem **erst die tatsächliche Geometrie holen**, bevor irgendetwas
geändert wird:

```python
result_json("element_bounds", ["mein_element"])       # {found, x, y, w, h}
result_json("element_bounds_i", ["prefix", index])
```

Eine einzige Messung hat den Picker-Fehler erklärt, nachdem drei Änderungen ins Leere
gingen: Kasten 720 breit, Zeile 1236. Ohne die Zahl rät man an Symptomen herum.

`element_bounds` beantwortet **nicht** „existiert das Element gerade?" — Clay behält
Daten verschwundener Elemente. Dafür `ui_state` nehmen.

## Text ohne Umbruch ist eine Mindestbreite

`clay.text(..., .{ .wrap_mode = .none })` meldet die volle Textbreite als Mindestmaß.
Clay zieht Zeile, Liste und Kasten darauf auf. Das entspricht `min-width: auto` bei
einem Flex-Element in CSS, nur ohne bekannten Gegenschalter.

**Abhilfe:** Obergrenze auf dem Container.

```zig
.sizing = .{ .w = .growMinMax(.{ .min = 0, .max = ROW_WIDTH }), .h = .fixed(H) }
```

Danach muss der Text selbst passen, also kürzen (siehe `src/ui/path_display.zig`).

## Erst prüfen, ob der Rahmen mitwachsen darf

Nicht vorschnell selbst rechnen. Der Standardweg ist dynamisch:

- Rahmen `.w = .fit`, Kinder `.w = .grow` → Clay misst das breiteste Kind und zieht
  alle anderen darauf. So stehen Kürzel in den Aufklappmenüs rechtsbündig, ohne dass
  irgendwer misst.
- Nur wenn der Rahmen **fest** sein muss (Modal mit fixer Breite) und der Inhalt
  unbegrenzt ist (Dateipfade), braucht es Obergrenze plus Kürzen.

Für eigenes Messen: `ui.measureTextWidth(text, font_size)`. Zeichen zu zählen geht
schief, sobald zwei Schriftgrößen in einer Zeile stehen.

## Verschachteltes Clipping ersetzt das äußere

`.clip` auf einem Kind eines bereits clippenden Containers **schneidet sich nicht** mit
dem äußeren Bereich, es ersetzt ihn. Ein Clip auf der Zeile ließ die ganze Liste unten
aus ihrem Kasten laufen. Also kein Clip als Notnagel gegen Überlauf — die Größe
begrenzen.

## Feste IDs gehören nie in eine Schleife

```zig
.id = clay.ElementId.ID("indent"),          // FALSCH in einer Zeilenschleife
.id = clay.ElementId.IDI("indent", @intCast(index)),  // richtig
```

Ohne Index meldet Clay `duplicate_id` — im Projekt 45 mal pro Frame. Wird das Element
nirgends abgefragt (Abstandhalter), einfach **keine ID** vergeben.

## Elementgrenze

Clays Standard sind 8192 Elemente pro Frame. Beim Überlauf erscheint rot
„Layout elements exceeded Clay__maxElementCount" und der Lauf bricht ab.

Reihenfolge laut Clay-README, sie ist zwingend:

```zig
clay.setMaxElementCount(N);          // zuerst
const min_memory = clay.minMemorySize();  // hängt an N
// Arena mit dieser Größe anlegen, dann clay.initialize
```

Arenagröße je Grenze: 8192 → 10 MB, 16384 → 12 MB, 32768 → 24 MB, 65536 → 47 MB.
`UI.MAX_CLAY_ELEMENTS` steht in `src/ui/mod.zig`.

Die Grenze anzuheben ist die zweitbeste Lösung. Die beste ist Virtualisierung.

## Fehler landen im Log, nicht nur im Fenster

`clay.initialize(arena, dims, .{ .error_handler_function = clayError })`. Ohne Handler
malt Clay die Meldung ins Fenster und headless sieht man gar nichts — ein Absturz beim
User war deshalb nicht nachstellbar. Der Handler hat sofort einen zweiten, jahrealten
Fehler sichtbar gemacht.

**Prüfe nach Layout-Arbeit das Log auf `error(ui): Clay:`.**
`scripts/e2e_md_preview.py` tut das automatisch.

## Große Inhalte virtualisieren

Ein langes Dokument nicht komplett anlegen. Muster in
`MarkdownView.renderDocumentVirtualized`:

1. Höhe je Block aus dem letzten Frame merken (`getElementData` auf `IDI(name, i)`).
2. Sichtbaren Indexbereich aus Scroll-Offset und Viewport bestimmen, ein Bildschirm
   Vorlauf in beide Richtungen.
3. Davor und danach je einen Abstandhalter mit der Summe der übersprungenen Höhen.

Noch nie gezeigte Blöcke brauchen eine Schätzung. `estimateBlockHeight` rechnet sie aus
Blockart und Textlänge: Überschriften nach Ebene, Codeblöcke nach Zeilenumbrüchen (sie
brechen nicht um), Fließtext aus Zeichenzahl geteilt durch Zeichen je Zeile, Container
als Summe ihrer Kinder. Eine feste Zahl lag bei Tabellen und Codeblöcken weit daneben.

Achtung: dasselbe Render-Verfahren wird oft an zwei Stellen benutzt (Vorschau und
Chat). Virtualisieren nur dort, wo es einen echten Viewport gibt.
