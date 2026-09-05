//! Reine Suchlogik für die Suchleiste (Ctrl+F): findet Treffer in einem
//! zeilenweisen Text, vorwärts/rückwärts ab einer Position, mit Umbruch am
//! Ende. Groß-/Kleinschreibung wird (ASCII) ignoriert. Kein Editor, kein Clay.

const std = @import("std");

pub const Pos = struct { row: usize, col: usize };
pub const Match = struct { begin: Pos, end: Pos };

/// Zeilenquelle: `lineCount()` und `line(i)` liefern die Zeilen ohne Umbruch.
pub fn Finder(comptime Source: type) type {
    return struct {
        /// Nächster Treffer ab `from` (exklusiv, d.h. ein Treffer genau an `from`
        /// zählt nicht), vorwärts oder rückwärts, mit Umbruch. null wenn keiner.
        pub fn find(src: Source, query: []const u8, from: Pos, forward: bool) ?Match {
            if (query.len == 0) return null;
            const n = src.lineCount();
            if (n == 0) return null;
            var row = @min(from.row, n - 1);
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                const line = src.line(row);
                const cols = std.unicode.utf8CountCodepoints(line) catch line.len;
                if (forward) {
                    // In der Startzeile erst nach `from.col` suchen, danach ab Spalte 0
                    const start_col: usize = if (i == 0) @min(from.col + 1, cols) else 0;
                    if (matchFrom(line, query, start_col, true)) |c| return mk(row, c, query, line);
                    row = (row + 1) % n;
                } else {
                    const start_col: ?usize = if (i == 0) (if (from.col == 0) null else from.col - 1) else cols;
                    if (start_col) |sc| {
                        if (matchFrom(line, query, sc, false)) |c| return mk(row, c, query, line);
                    }
                    row = if (row == 0) n - 1 else row - 1;
                }
            }
            return null;
        }

        fn mk(row: usize, col: usize, query: []const u8, line: []const u8) Match {
            _ = line;
            const qlen = std.unicode.utf8CountCodepoints(query) catch query.len;
            return .{ .begin = .{ .row = row, .col = col }, .end = .{ .row = row, .col = col + qlen } };
        }
    };
}

/// Spalte (Codepoints) des ersten Treffers ab `start_col` vorwärts, bzw. des
/// letzten Treffers, dessen Beginn ≤ `start_col` ist, rückwärts.
fn matchFrom(line: []const u8, query: []const u8, start_col: usize, forward: bool) ?usize {
    var best: ?usize = null;
    var col: usize = 0;
    var byte: usize = 0;
    while (byte < line.len) {
        if (startsWithIgnoreCase(line[byte..], query)) {
            if (forward) {
                if (col >= start_col) return col;
            } else {
                if (col <= start_col) best = col else break;
            }
        }
        const len = std.unicode.utf8ByteSequenceLength(line[byte]) catch 1;
        byte += len;
        col += 1;
    }
    return best;
}

fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const SliceSource = struct {
    lines: []const []const u8,
    fn lineCount(self: SliceSource) usize {
        return self.lines.len;
    }
    fn line(self: SliceSource, i: usize) []const u8 {
        return self.lines[i];
    }
};
const F = Finder(SliceSource);

test "find vorwärts: nächster Treffer nach der Startposition, Groß/Klein egal" {
    const src = SliceSource{ .lines = &.{ "Foo bar foo", "baz", "FOO" } };
    const m = F.find(src, "foo", .{ .row = 0, .col = 0 }, true).?;
    try testing.expectEqual(@as(usize, 0), m.begin.row);
    try testing.expectEqual(@as(usize, 8), m.begin.col);
    try testing.expectEqual(@as(usize, 11), m.end.col);
    const m2 = F.find(src, "foo", .{ .row = 0, .col = 8 }, true).?;
    try testing.expectEqual(@as(usize, 2), m2.begin.row);
}

test "find vorwärts: Umbruch ans Dateiende zurück zum Anfang" {
    const src = SliceSource{ .lines = &.{ "alpha", "beta", "gamma" } };
    const m = F.find(src, "alpha", .{ .row = 2, .col = 0 }, true).?;
    try testing.expectEqual(@as(usize, 0), m.begin.row);
    // Einziger Treffer genau an der Startposition: wird nach Umbruch wieder gefunden
    const same = F.find(src, "alpha", .{ .row = 0, .col = 0 }, true).?;
    try testing.expectEqual(@as(usize, 0), same.begin.row);
}

test "find rückwärts: vorheriger Treffer, Umbruch ans Ende" {
    const src = SliceSource{ .lines = &.{ "x foo", "foo y", "z" } };
    const m = F.find(src, "foo", .{ .row = 1, .col = 0 }, false).?;
    try testing.expectEqual(@as(usize, 0), m.begin.row);
    try testing.expectEqual(@as(usize, 2), m.begin.col);
    const wrapped = F.find(src, "foo", .{ .row = 0, .col = 0 }, false).?;
    try testing.expectEqual(@as(usize, 1), wrapped.begin.row);
}

test "find: leere Suche oder kein Treffer liefert null; Spalten sind Codepoints" {
    const src = SliceSource{ .lines = &.{ "äöü foo", "" } };
    try testing.expect(F.find(src, "", .{ .row = 0, .col = 0 }, true) == null);
    try testing.expect(F.find(src, "nope", .{ .row = 0, .col = 0 }, true) == null);
    const m = F.find(src, "foo", .{ .row = 1, .col = 0 }, true).?;
    try testing.expectEqual(@as(usize, 4), m.begin.col);
}
