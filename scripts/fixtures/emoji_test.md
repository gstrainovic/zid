# Emoji-Test 🎨

Kurze Datei zum Anschauen: sie deckt die Stellen ab, an denen Emoji in echten
Dateien vorkommen. Öffnen mit `zid scripts/fixtures/emoji_test.md`, Vorschau mit
Ctrl+Shift+V.

## Fliesstext

Der Bau läuft 🔧, die Tests sind grün ✅, ein Fehler ist offen ⚠️ und einer
abgestürzt ❌. Danach: Rakete 🚀 und Feierabend 🎉.

## Liste

- ✅ Rückfall auf die Emoji-Schrift
- 🎨 Farbatlas neben dem Textatlas
- 📦 Schrift wird bei Bedarf nachgeladen
- 🐧 Linux über FreeType, 🪟 Windows über DirectWrite

## Tabelle

| Zustand | Zeichen | Bedeutung |
|---------|---------|-----------|
| fertig  | ✅      | Schritt lief durch |
| Warnung | ⚠️      | lief, aber mit Anmerkung |
| Fehler  | ❌      | abgebrochen |
| läuft   | ⏳      | noch nicht fertig |

## Codeblock

```zig
// Emoji im Quelltext, etwa in einer Log-Zeile
std.log.info("Fertig ✅ in {d} ms", .{elapsed});
```

## Randfälle

- Variantenwähler: ⚠️ farbig gegen ⚠ einfarbig
- Zusammengesetzt (ZWJ): 👩‍💻 und 👨‍👩‍👧
- Hautton: 👍🏽
- Fahne: 🇨🇭
- Zahlzeichen: 1️⃣
- Umlaute daneben: Grösse, Fuss, Straße 🧪 🧵
