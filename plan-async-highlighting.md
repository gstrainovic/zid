# Plan: Asynchrones Chunked Highlighting

**Ziel:** Edit-Operationen bei 40k+ Lines dürfen den Render-Frame nicht blockieren.
**Referenz:** lite-xl's `Highlighter:start()` mit Coroutine + Time-Budgeting.
**Datum:** 14. April 2026

---

## Problem-Analyse

### Aktueller Pfad (blockierend):
```
Tastendruck → insertString()
  → pushEditForChange()    ← Edit an tree-sitter melden (schnell ✓)
  → buffer.insert_chars()  ← Rope ändern (schnell ✓)
  → render()
    → ensureHighlightFresh()
      → reparseFromBuffer() ← ❌ BLOCKIERT — tree-sitter parst synchron
```

### Zielpfad (nicht-blockierend):
```
Tastendruck → insertString()
  → pushEditForChange()    ← Edit an tree-sitter melden (schnell ✓)
  → buffer.insert_chars()  ← Rope ändern (schnell ✓)
  → markDirty()            ← ❗NUR Dirty-Flag setzen (O(1))
  → render()               ← ❗KEIN Reparse hier — alten Cache nutzen

Main-Loop (nach render):
  → highlightChunked()     ← chunked parsen, max 8ms pro Frame
  → Rest im nächsten Frame
```

---

## Phasen

### Phase 1: Dirty-Flag System einbauen

**Datei:** `src/editor/code_editor.zig`

Bestehende Felder prüfen (`has_dirty_lines`, `dirty_line_start`, `dirty_line_end`):
```zig
// Zeilen ~240-260 — bereits vorhanden aber nicht korrekt genutzt:
has_dirty_lines: bool = false,
dirty_line_start: usize = 0,
dirty_line_end: usize = 0,
```

Neu: `markDirty()` die NUR das Flag setzt, OHNE Reparse:
```zig
fn markDirty(self: *Self, start_line: usize, end_line: usize) void {
    self.edits_fully_tracked = true;
    self.has_dirty_lines = true;
    if (!self.has_dirty_lines) {
        self.dirty_line_start = start_line;
        self.dirty_line_end = end_line;
    } else {
        self.dirty_line_start = @min(self.dirty_line_start, start_line);
        self.dirty_line_end = @max(self.dirty_line_end, end_line);
    }
}
```

`pushEditForChange()` aufräumen — ruft bereits markDirty-Logik auf, muss
sicherstellen dass es KEINEN Reparse triggert.

---

### Phase 2: render() darf NICHT blockieren

**Datei:** `src/editor/code_editor.zig` — `render()` Methode (Zeile ~1289)

**Änderung:** `self.ensureHighlightFresh()` aus render() entfernen:
```zig
pub fn render(self: *Self, arena: std.mem.Allocator) void {
    self.desired_cursor = .arrow;
    // ❌ ENTFERNEN: self.ensureHighlightFresh();
    // ✅ NEU: Nichts — Highlighting kommt asynchron
    ...
}
```

**Konsequenz:** Beim ersten Laden einer Datei oder nach vielen Edits kann
es sein dass Zeilen noch nicht gehighlighted sind. Das ist OK — sie werden
mit Plain-Color gerendert bis der Chunk sie erreicht hat.

---

### Phase 3: Chunked Reparse im Main-Loop

**Dateien:**
- `src/editor/code_editor.zig` — neue Methode `highlightChunked()`
- `src/main.zig` — Aufruf NACH renderFrameWithText

**Neue Methode in code_editor.zig:**
```zig
/// Chunked Reparse — max `max_ms` Millisekunden pro Aufruf.
/// Gibt `true` zurück wenn noch Arbeit übrig ist.
pub fn highlightChunked(self: *Self, max_ms: u64) bool {
    if (!self.has_dirty_lines) return false;
    const hl = self.highlighter orelse return false;

    const start = std.time.milliTimestamp();

    // Prüfen ob Reparse nötig
    if (self.last_parsed_root) |lpr| {
        if (lpr == self.buffer.root) {
            // Baum hat sich nicht geändert → Dirty-Flags zurücksetzen
            self.has_dirty_lines = false;
            return false;
        }
    }

    // Wenn Edits fehlen: resetTree() nötig
    if (!self.edits_fully_tracked) {
        if (self.last_parsed_root != null) {
            hl.resetTree();
        }
    }

    // Reparse starten — aber mit Zeitlimit
    hl.reparseFromBuffer(self.buffer.root, self.metrics()) catch |err| {
        std.log.scoped(.highlight).err("reparse failed: {s}", .{@errorName(err)});
        self.has_dirty_lines = false;
        return false;
    };

    self.last_parsed_root = self.buffer.root;
    self.edits_fully_tracked = true;
    self.has_dirty_lines = false;

    // Zeit prüfen — wenn zu lange, im nächsten Frame weiter
    const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start));
    if (elapsed >= max_ms) {
        std.log.scoped(.highlight).debug("highlight chunk took {d}ms, deferring", .{elapsed});
    }

    return self.has_dirty_lines;
}
```

**Problem:** `reparseFromBuffer` ist aktuell ein einzelner synchroner Aufruf.
tree-sitter's `refresh_from_buffer` kennt kein Time-Budgeting von Haus aus.

**Lösung:** Der Aufruf muss so gestückelt werden dass tree-sitter nur einen
Teil der Änderungen pro Chunk verarbeitet. Dafür gibt es zwei Ansätze:

**Ansatz A:** tree-sitter's `edit()` Aufruf puffern und nur einen Teil
der Edits pro Chunk anwenden, dann `refresh_from_buffer` aufrufen.

**Ansatz B:** tree-sitter's `refresh_from_buffer` als Ganzes aufrufen — es
ist inkrementell und sollte bei lokalen Edits schnell sein. Das Problem
tritt hauptsächlich beim **initialen Parse** auf (setText). Für Edits
sollte es OK sein. Der echte Bottleneck ist der **erste Parse**.

→ **Entscheidung:** Ansatz B zuerst versuchen. Falls inkrementeller
Reparse bei Edits trotzdem zu langsam ist, auf Ansatz A wechseln.

**Aufruf in main.zig** — NACH renderFrameWithText (Zeile ~340):
```zig
// Highlighting chunked aktualisieren (nicht-blockierend)
const _ = ui_system.code_editor.highlightChunked(8); // max 8ms
```

---

### Phase 4: Initialer Parse beim Datei-Laden

Beim `setText()` (Datei öffnen) wird der HIGHLIGHTER KOMPLETT NEU erstellt
und muss die GANZE Datei parsen. Das ist der Haupt-Bottleneck.

**Aktuell:**
```zig
setText() → setLanguageFromPath() → neuer Highlighter
→ ensureHighlightFresh() → voller Reparse (❌ blockiert Frame)
```

**Neu:**
```zig
setText() → setLanguageFromPath() → neuer Highlighter + has_dirty_lines = true
→ render() → noch kein Highlighting (Plain-Color)
→ highlightChunked() → parst chunked im Hintergrund
→ nach ~N Frames: alles gehighlighted
```

**Änderung in `setLanguageFromPath`:**
```zig
pub fn setLanguageFromPath(self: *Self, file_path: []const u8) void {
    self.destroyHighlighter();
    const content = self.buffer.store_to_string_cached(...);
    const hl = flow_core.highlight.SyntaxHighlighter.createByPath(...) catch return;
    self.highlighter = hl;
    self.last_parsed_root = null;
    // ❗Dirty-Flag setzen statt sofort zu parsen:
    self.edits_fully_tracked = false;
    self.has_dirty_lines = true;
    self.dirty_line_start = 0;
    self.dirty_line_end = self.lineCount();
}
```

---

### Phase 5: Visuelles Feedback während Highlighting läuft

Optional: Status-Bar oder Indicator zeigen dass noch Highlighting läuft.

---

## Zusammenfassung der Änderungen

| Datei | Änderung |
|---|---|
| `src/editor/code_editor.zig` | `ensureHighlightFresh()` aus render() entfernen, `highlightChunked()` neu |
| `src/main.zig` | `highlightChunked(8)` NACH renderFrameWithText aufrufen |
| `libs/flow-core/src/highlight/mod.zig` | Evtl. anpassen für chunked Reparse (falls nötig) |

## Test-Plan

1. Große Datei öffnen (40k+ Lines) — sollte sofort rendern, Highlighting kommt nach
2. Tippen in großer Datei — kein Frame-Drop spürbar
3. Highlighting-Verifizierung: nach kurzer Zeit alles korrekt gehighlighted
4. Mit `--profile` oder Logging messen: highlightChunked soll ≤ 8ms brauchen
