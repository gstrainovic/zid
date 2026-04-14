# Plan: Inkrementelles + asynchrones Highlighting

**Ziel:** Highlighting bei 40k+ Zeilen blockiert weder Edits noch erstes Rendern.
**Referenzen:**
- `reference/lite-xl/data/core/doc/highlighter.lua` — chunked coroutine, per-line cache, dirty-range tracking
- Zed-Muster — persistent tree, `ts_tree_edit` + `parser.parse(old_tree, …)` für inkrementellen Reparse, background thread
- `libs/gooey/docs/Tree Sitter Integration.md` — saubere API (StyledRun, Highlighter-VTable, SyntaxTheme)
**Datum:** 2026-04-14

---

## Problem-Analyse

### Warum ist der aktuelle Stand langsam?

Tree-sitter selbst ist inkrementell und schnell. Das **Wie** unserer Nutzung ist der Bottleneck:

1. **Kein `old_tree` beim Reparse.** `reparseFromBuffer` parst komplett neu statt `parser.parse(old_tree, …)`. → O(Dateigröße) pro Edit statt O(Edit-Größe).
2. **Synchron im Render-Pfad.** `render()` ruft `ensureHighlightFresh()` → parse blockiert den Frame.
3. **Query pro Zeile, kein Cache-Invalidieren.** `colorTagsForLine` führt Query jedes Render durch; neuer WIP-Cache invalidiert nicht bei Edits → stale Tags möglich (bereits im Commit dokumentiert).
4. **Kompletter File-Parse beim `setText()`**, auch wenn nur erste 40 Zeilen sichtbar.

**Lite-XL-Vergleich:** Lite-XL nutzt Regex-Tokenizer (kein TS), aber das Muster ist übertragbar:
- Per-line Cache `{text, init_state, tokens, resume}`
- Dirty-Range: `first_invalid_line`, `max_wanted_line`
- Coroutine, 40 Zeilen pro Tick, `yield`
- State-Chain: Zeile N-1 state → init für N; gleich + text gleich = skip

**Zed-Vergleich:** Tree-sitter tree lebt im Highlighter, bei jedem Edit wird `ts_tree_edit` gerufen, der eigentliche `parse(old_tree)` läuft in einem Background-Thread. UI liest den letzten fertigen Tree.

**Gooey-Doc:** API-Blueprint (StyledRun, VTable, SyntaxTheme). Enthält keine Performance-Strategie — ergänzen wir hier.

---

## Zielarchitektur

```
Edit → pushEditForChange (ts_tree_edit)   ← O(1)
     → buffer.insert_chars                ← Rope O(log n)
     → invalidate(line_start, line_end)   ← dirty-range update O(1)
     → render                              ← liest Cache, nichts parsen

main-loop (nach render):
     → highlightTick(budget_ms = 8)
        wenn dirty:
          parser.parse(old_tree, new_text) ← inkrementell, wenige ms
          tree.get_changed_ranges(old, new) → betroffene Zeilen
          requery nur diese Zeilen in ColorTag-Cache
          bei Zeitüberschreitung: yield, Rest nächster Frame
```

Zwei Stellschrauben:
1. **Inkrementeller Reparse** (persistent tree + `ts_tree_edit` + `parse(old_tree)`) — macht den Einzelparse schnell.
2. **Chunked Query-Update** (lite-xl-Muster) — verteilt Kosten über mehrere Frames wenn initialer Parse oder massive Änderung.

Background-Thread (Zed) bleibt Option für Phase 5, nicht Phase 1.

---

## Phasen

### Phase 0 — Tree-sitter inkrementell nutzen

**Zweck:** Allein diese Änderung bringt den Löwenanteil der Performance. Vor allem anderen.

**Datei:** `libs/flow-core/src/highlight/mod.zig` (oder wherever `reparseFromBuffer` lebt)

- Beim ersten Parse: Tree speichern in `SyntaxHighlighter.tree: ?*ts.Tree`.
- Bei Edits: `ts_tree_edit(tree, &edit)` im `pushEditForChange`-Pfad aufrufen **bevor** der Buffer geändert wird (tree-sitter braucht alte Offsets).
- `reparseFromBuffer`: statt `parser.parse(null, text)` → `parser.parse(self.tree, text)`. Alten Tree erst nach Übergabe freigeben.
- `tree.get_changed_ranges(old, new)` liefert die betroffenen Byte-Ranges → exakt die Zeilen, die re-highlighted werden müssen.

**Verifikation:** Benchmark: Einzel-Tastendruck in 40k-Zeilen-Zig-Datei. Vorher: volle Parse-Zeit. Nachher: ≤1 ms.

---

### Phase 1 — Dirty-Line-Tracking

**Datei:** `src/editor/code_editor.zig`

Felder bereits vorhanden (`has_dirty_lines`, `dirty_line_start`, `dirty_line_end`) — aber falsch genutzt. Semantik festschreiben nach lite-xl:

```zig
first_invalid_line: usize = 0,      // kleinste Zeile die Re-Query braucht
max_wanted_line: usize = 0,         // größte je gerenderte Zeile (lazy horizon)
```

- `invalidate(line)` — `first_invalid_line = min(first_invalid_line, line)`.
- `insertNotify(line, n)` + `removeNotify(line, n)` — verschiebt Cache-Einträge, setzt `invalidate(line)`.
- `getLine(idx)` (Render-Pfad) — liest aus Cache; bei Miss oder Text-Mismatch: on-demand query, `max_wanted_line = max(max_wanted_line, idx)`.

`first_invalid_line <= max_wanted_line` → Arbeit offen. Sonst idle.

---

### Phase 2 — `render()` darf nicht parsen

**Datei:** `src/editor/code_editor.zig`

`render()`:
- `ensureHighlightFresh()` entfernen.
- Für jede sichtbare Zeile `getLine(idx)` aufrufen — liest Cache, füllt On-Demand-Query nur bei Miss.
- Bei komplett ungehighlighteten Zeilen (initialer Load): Plain-Color-Fallback. Kein Block.

Konsequenz: beim Dateiöffnen sind Zeilen kurz plain, werden innerhalb weniger Frames nachgezeichnet. Akzeptabel.

---

### Phase 3 — `highlightTick` mit Zeitbudget

**Datei:** `src/editor/code_editor.zig` — neue Methode. **Aufrufer:** `src/main.zig` nach Render.

```zig
pub fn highlightTick(self: *Self, budget_ms: u64) bool {
    const hl = self.highlighter orelse return false;
    if (self.first_invalid_line > self.max_wanted_line) return false;

    const deadline_ns = std.time.nanoTimestamp() + budget_ms * std.time.ns_per_ms;

    // 1. Falls buffer-root veraendert: parser.parse(old_tree, ...) inkrementell
    if (self.last_parsed_root != self.buffer.root) {
        try hl.reparseIncremental(self.buffer.root, self.metrics());
        self.last_parsed_root = self.buffer.root;
    }

    // 2. Query nur changed lines, chunked
    const chunk_size: usize = 40;
    while (self.first_invalid_line <= self.max_wanted_line) {
        const end = @min(self.first_invalid_line + chunk_size, self.max_wanted_line + 1);
        for (self.first_invalid_line..end) |i| hl.requery(i);
        self.first_invalid_line = end;
        if (std.time.nanoTimestamp() >= deadline_ns) break;
    }

    return self.first_invalid_line <= self.max_wanted_line;
}
```

**`main.zig`** (nach `renderFrameWithText`):
```zig
_ = ui_system.code_editor.highlightTick(8);
```

---

### Phase 4 — Visible-Range-Priorität

Beim `setText()` großer Datei: sichtbarer Bereich zuerst, Rest lazy.

- `setLanguageFromPath`: Highlighter neu, `last_parsed_root = null`, `first_invalid_line = 0`, `max_wanted_line = 0`.
- Erster Render erhöht `max_wanted_line` auf unterstes sichtbares Zeilenende.
- `highlightTick` arbeitet genau diesen Bereich ab — keine 40k Zeilen beim Laden.
- Scroll nach unten: `max_wanted_line` wächst dynamisch → neue Zeilen werden in folgenden Ticks nachgehighlighted.

Effekt: Datei sofort sichtbar, Highlighting folgt in wenigen Frames für sichtbaren Bereich.

---

### Phase 5 — (Optional) Background-Thread

Falls Phase 0–4 nicht reicht (sehr große Dateien, schwerer Grammar):

- `hl.reparseIncremental` läuft in `std.Thread.Pool` Worker.
- Tree wird atomic geswappt wenn fertig (`std.atomic.Value(*Tree)`).
- Main-Thread liest letzten fertigen Tree; wenn Worker noch läuft → alter Tree = leicht veraltete Farben, kein Block.

Nicht vor Phase 4 anfassen — 8-ms-Budget reicht für die meisten Fälle.

---

### Phase 6 — (Später) API-Refactor zu `gooey-syntax`

Sobald Performance sitzt: Interface sauber schneiden nach `libs/gooey/docs/Tree Sitter Integration.md`:

- `StyledRun` statt `ColorTag` (einheitliche Primitive).
- `Highlighter`-VTable → tree-sitter + WASM-Backend tauschbar.
- `SyntaxTheme` mit `colorForCapture(name)` statt hart codierter Mappings.
- Paket `libs/gooey-syntax/` mit `createHighlighter(lang)` Factory.

Reiner Refactor, keine Perf-Änderung. Kann parallel zum Zed-Background-Thread.

---

## Reihenfolge + Zeit-Schätzung

| Phase | Beschreibung | Erwarteter Effekt | Aufwand |
|---|---|---|---|
| 0 | `ts_tree_edit` + `parse(old_tree)` | ~100× schneller pro Edit | 0.5 Tag |
| 1 | Dirty-Line-Tracking (first_invalid/max_wanted) | Vorbedingung für Chunking | 0.5 Tag |
| 2 | `render()` parst nicht | Frame sofort frei | 0.5 Tag |
| 3 | `highlightTick(8)` im Main-Loop | Chunks über Frames verteilt | 1 Tag |
| 4 | Visible-Range-Priorität | Große Dateien sofort sichtbar | 0.5 Tag |
| 5 | Background-Thread (opt.) | Nur falls 8-ms-Budget überzogen | 2 Tage |
| 6 | `gooey-syntax` API-Refactor | Sauberkeit, keine Perf | 2–3 Tage |

**Start:** Phase 0 → allein das beseitigt vermutlich den spürbaren Lag. Messen, dann weiter.

---

## Test-Plan

1. **Einzel-Edit, 40k Zeilen Zig-Datei** — Frame-Drop < 1 ms. Log `reparse took Xms`.
2. **Datei öffnen, 40k Zeilen** — erster Render < 16 ms; sichtbarer Bereich highlighted innerhalb 3 Frames.
3. **Massiver Paste** (2k Zeilen) — UI bleibt responsiv, Highlighting zieht chunked nach.
4. **Cache-Konsistenz** — nach Edit in Zeile N: exakt die betroffenen Zeilen (aus `get_changed_ranges`) neu gequeryed, keine stale Tags.
5. **Scroll durch 40k Zeilen** — nach jedem Scroll-Schritt werden neue Zeilen innerhalb ≤ 2 Frames gehighlighted.

Messung via `std.log.scoped(.highlight).debug`; später Perf-HUD (Frame-Zeit + `highlightTick`-Zeit).
