# Editor Performance Optimierung

## Problem
Der Editor war bei großen Dateien (>1000 Zeilen) extrem langsam beim Bearbeiten.
Jeder Tastendruck führte zu einem vollständigen Neuparsen des gesamten Dokuments durch tree-sitter.

## Ursache
In `ensureHighlightFresh()` wurde **immer** `hl.resetTree()` aufgerufen, was den gesamten
tree-sitter AST verwirft. Beim nächsten `reparseFromBuffer()` musste tree-sitter dann das
**gesamte Dokument neu parsen** - bei 50.000 Zeilen also 50.000 Zeilen pro Tastendruck.

Der Kommentar im Code (Zeile 296-297) bestätigte das:
> "Edits werden (noch) nicht pro Action per `pushEdit` gemeldet → alten Baum verwerfen"

**Aber:** `pushEditForChange()` wurde bereits an allen Edit-Stellen aufgerufen! Das Problem
war nur daß `ensureHighlightFresh` das nicht genutzt hat.

## Lösung

### 1. Inkrementelle tree-sitter-Updates (Hauptoptimierung)

**Datei:** `src/editor/code_editor.zig`

Neue Felder in CodeEditor:
```zig
/// Trackt ob seit dem letzten Reparse Edits korrekt via pushEdit gemeldet wurden.
edits_fully_tracked: bool = true,

/// Zeilen-Bereich der seit dem letzten Reparse geändert wurde (inclusive).
dirty_line_start: usize = 0,
dirty_line_end: usize = 0,
has_dirty_lines: bool = false,
```

**ensureHighlightFresh()** Logik:
```zig
// ALT (immer langsam):
if (self.last_parsed_root != null) hl.resetTree();  // ← Wirft AST weg

// NEU (inkrementell wenn möglich):
if (!self.edits_fully_tracked) {
    hl.resetTree();  // Nur wenn Edits fehlen (z.B. setText, Undo/Redo)
}
// Sonst: tree-sitter nutzt den bestehenden AST + pushEdit für inkrementellen Parse
```

**pushEditForChange()** trackt jetzt:
- `edits_fully_tracked = true` (alle Edits wurden gemeldet)
- `dirty_line_start` und `dirty_line_end` (welche Zeilen betroffen sind)

**setText()** setzt:
- `edits_fully_tracked = false` (weil kompletter Inhalt ersetzt wurde)

### 2. Performance-Tests

**Dateien:**
- `src/editor/highlight_perf_test.zig` - Performance-Messfunktionen
- `src/editor/highlight_perf_tests.zig` - Tests die Vorher/Nachher vergleichen

**Tests:**
```bash
zig build test
```

Die Tests messen:
1. Full Reparse Zeit für 1000 Zeilen
2. Incremental Edit Zeit für einzelne Änderung
3. Erwartet: Incremental ist mindestens 2x schneller

### 3. Benchmark (manuell)

**Datei:** `src/editor/highlight_benchmark.zig`

```bash
# Benchmark mit 5000 Zeilen, 3 Iterationen, 10 Edits
zig build benchmark -- --lines 5000 --iterations 3 --edits 10
```

## Erwartete Verbesserung

### Vorher (vollständiger Reparse)
- 1000 Zeilen: ~50-100ms pro Tastendruck
- 5000 Zeilen: ~200-500ms pro Tastendruck
- 10000 Zeilen: ~500-1000ms pro Tastendruck (spürbar langsam!)

### Nachher (inkrementell)
- 1000 Zeilen: ~5-10ms pro Tastendruck (10x schneller)
- 5000 Zeilen: ~10-20ms pro Tastendruck (20x schneller)
- 10000 Zeilen: ~20-50ms pro Tastendruck (20-50x schneller)

Die genaue Verbesserung hängt von der Datei ab:
- **Viele kleine Edits** (Tippen): Sehr schnell, nur betroffene Region wird geparst
- **setText** (Datei öffnen): Einmalig langsam (voller Reparse), dann wieder schnell
- **Undo/Redo**: Langsam wenn keine Edit-Events vorhanden sind

## Technische Details

### Wie tree-sitter inkrementell arbeitet

1. `hl.pushEdit(edit)` - Bearbeitet den bestehenden AST:
   - Verschiebt Knoten-Positionen
   - Markiert betroffene Regionen als "dirty"
   - **Parst noch nicht neu!**

2. `hl.reparseFromBuffer(buffer, metrics)` - Parst neu:
   - Nutzt `old_tree` als ersten Parameter
   - tree-sitter vergleicht Input mit old_tree
   - **Unveränderte Regionen** werden übernommen (schnell!)
   - **Dirty Regionen** werden neu geparst

### Wann resetTree() nötig ist

- `setText()` - Kompletter Inhalt wird ersetzt
- `Undo/Redo` - Wenn keine Edit-Events getrackt wurden
- Datei neu laden - Anderer Inhalt

In diesen Fällen ist der AST "stale" (Offsets stimmen nicht mehr) und ein
inkrementeller Parse würde falsche Ergebnisse liefern.

## Debug Logging

Um zu sehen welcher Pfad genommen wird:
```zig
std.log.scoped(.highlight).debug("incremental reparse: edits tracked", .{});
std.log.scoped(.highlight).debug("resetTree: edits not fully tracked", .{});
```

## Nächste Optimierungsmöglichkeiten

1. **Highlighting-Cache**: Tags pro Zeile cachen, nur bei Änderung neu berechnen
2. **Syntax-Highlighting deaktivierbar**: Für sehr große Dateien (>100k Zeilen)
3. **Lazy Rendering**: Nur sichtbare Zeilen highlighten (nicht alle)
4. **Parse-Throttling**: Bei schnellen Tippen nur alle X ms neu parsen
