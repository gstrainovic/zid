//! Greedy-Zeilenumbruch für vorgemessene Text-Stücke (Wörter und Leerzeichen).
//!
//! Reines Modul ohne UI-Abhängigkeiten. MarkdownView misst jedes Inline-Stück,
//! lässt hier die Zeilen berechnen und rendert dann pro Zeile eine Reihe
//! einzeln gefärbter Textelemente. So bleibt Umbruch mit Per-Wort-Styling
//! möglich, was Clay-Textelemente allein nicht können.

const std = @import("std");

pub const Item = struct {
    width: f32,
    is_space: bool = false,
};

/// Halboffener Bereich items[start..end] einer Zeile.
pub const Line = struct {
    start: usize,
    end: usize,
};

/// Regeln: Wörter werden greedy aufgefüllt. Umgebrochen wird nur an Leerzeichen —
/// ein Wort ist die ganze Folge der Stücke bis zum nächsten Leerzeichen, denn
/// zigdown liefert `code`, Satzzeichen und Wortteile als eigene Stücke: „Nr." kommt
/// als „Nr" und „.", und eine Trennung dazwischen gäbe es in keinem Browser.
/// Leerzeichen am Zeilenanfang werden verschluckt, am Zeilenende dürfen sie stehen
/// bleiben, solange sie noch passen. Ein Wort breiter als max_width bekommt eine
/// eigene Zeile. Rückgabe gehört dem Aufrufer.
pub fn wrapLines(alloc: std.mem.Allocator, items: []const Item, max_width: f32) ![]Line {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    errdefer lines.deinit(alloc);

    var i: usize = 0;
    while (i < items.len) {
        // Leerzeichen am Zeilenanfang verschlucken
        while (i < items.len and items[i].is_space) i += 1;
        if (i >= items.len) break;

        const start = i;
        var width: f32 = 0;
        while (i < items.len) {
            var end = i;
            var word: f32 = 0;
            while (end < items.len and !items[end].is_space) : (end += 1) word += items[end].width;
            if (width + word > max_width and i > start) break;
            width += word;
            i = end;
            // Leerzeichen hinter dem Wort gehören noch auf diese Zeile, solange sie passen
            var fits = true;
            while (i < items.len and items[i].is_space) {
                if (width + items[i].width > max_width) {
                    fits = false;
                    break;
                }
                width += items[i].width;
                i += 1;
            }
            if (!fits) break;
        }
        try lines.append(alloc, .{ .start = start, .end = i });
    }
    return lines.toOwnedSlice(alloc);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const w = Item{ .width = 10 };
const sp = Item{ .width = 2, .is_space = true };

fn expectLines(expected: []const Line, actual: []const Line) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.start, a.start);
        try testing.expectEqual(e.end, a.end);
    }
}

test "wrapLines: alles passt in eine Zeile" {
    const lines = try wrapLines(testing.allocator, &.{ w, sp, w, sp, w }, 100);
    defer testing.allocator.free(lines);
    try expectLines(&.{.{ .start = 0, .end = 5 }}, lines);
}

test "wrapLines: Umbruch vor dem Wort, das nicht mehr passt; Leerzeichen bleibt am Zeilenende" {
    const lines = try wrapLines(testing.allocator, &.{ w, sp, w, sp, w }, 24);
    defer testing.allocator.free(lines);
    try expectLines(&.{ .{ .start = 0, .end = 4 }, .{ .start = 4, .end = 5 } }, lines);
}

test "wrapLines: Leerzeichen am Zeilenanfang werden verschluckt" {
    // w sp w sp w sp w bei 22: Zeile 1 = w sp w (22), sp passt nicht → Zeile 2 beginnt beim Wort
    const lines = try wrapLines(testing.allocator, &.{ w, sp, w, sp, w, sp, w }, 22);
    defer testing.allocator.free(lines);
    try expectLines(&.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } }, lines);
}

test "wrapLines: überlanges Wort bekommt eine eigene Zeile" {
    const long = Item{ .width = 50 };
    const lines = try wrapLines(testing.allocator, &.{ w, sp, long, sp, w }, 24);
    defer testing.allocator.free(lines);
    try expectLines(&.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 3 }, .{ .start = 4, .end = 5 } }, lines);
}

test "wrapLines: Stücke ohne Leerzeichen dazwischen bleiben zusammen" {
    // „Nr" + „." ist ein Wort: bei 12 passt es nicht neben das erste, wandert aber
    // als Ganzes auf die nächste Zeile statt zwischen „Nr" und „." zu brechen.
    const nr = Item{ .width = 8 };
    const dot = Item{ .width = 4 };
    const lines = try wrapLines(testing.allocator, &.{ w, sp, nr, dot }, 12);
    defer testing.allocator.free(lines);
    try expectLines(&.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 4 } }, lines);
}

test "wrapLines: leere Eingabe und nur Leerzeichen ergeben keine Zeilen" {
    const none = try wrapLines(testing.allocator, &.{}, 24);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    const spaces = try wrapLines(testing.allocator, &.{ sp, sp }, 24);
    defer testing.allocator.free(spaces);
    try testing.expectEqual(@as(usize, 0), spaces.len);
}
