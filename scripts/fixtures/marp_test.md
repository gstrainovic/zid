---
marp: true
theme: default
size: 16:9
paginate: true
footer: zid
style: |
  section { font-size: 24px; }
  table { font-size: 22px; }
---

# Marp-Testdeck

Fixture für `src/ui/marp.zig` und später für die Folienvorschau.

---

<!-- _class: lead -->

## Spot-Direktive

![bg right:40% contain](marp_skizze.svg)

Diese Folie ist `lead`, die nächste wieder nicht. Rechts steht eine Skizze mit
`<symbol>`, `<use>` und `<text>` als Bildspalte.

---

## Vererbte Direktive

<!-- backgroundColor: "#101418" -->

Ab hier gilt die Hintergrundfarbe bis zum Ende des Decks.

<!-- Notiz: hier eine Pause machen -->

---

## Trennlinien in Code

Der Zaun darf keine neue Folie beginnen:

```yaml
---
marp: true
---
```

Danach geht es auf derselben Folie weiter.

---

## Setext statt Trenner

Eine Trennlinie ohne Leerzeile davor ist in Markdown eine Überschrift:

Zweite Ebene
---

Deshalb steht dieser Absatz noch auf derselben Folie.

---

## Listen und Tabelle

- erster Punkt
- zweiter Punkt
  - eingerückt

| Direktive | Bereich |
| --------- | ------- |
| `theme`   | global  |
| `class`   | lokal   |

---

<!--
_paginate: false
_footer: ""
-->

## Letzte Folie

Ohne Seitenzahl und ohne Fußzeile.
