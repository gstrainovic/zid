//! Soft-Wrap für Editor-Zeilen (reine Logik, unit-getestet).
//!
//! Eine Buffer-Zeile wird in Segmente von höchstens `cols` Anzeigespalten zerlegt
//! (Codepoint = 1 Spalte, Tab = 4 wie in der Editor-Metrik). Gebrochen wird bevorzugt
//! hinter dem letzten Leerzeichen im Segment; ein Wort breiter als `cols` bricht hart.
const std = @import("std");

pub const tab_cols: usize = 4;

pub const Segment = struct {
    /// Byte-Bereich in der Zeile (halboffen)
    start: usize,
    end: usize,
    /// Anzeigespalte, an der das Segment beginnt
    col: usize,
};

fn charCols(c: u8) usize {
    return if (c == '\t') tab_cols else 1;
}

fn isContinuation(c: u8) bool {
    return (c & 0xC0) == 0x80;
}

/// Nächstes Segment ab Byte `start` (Spalte `start_col`); null am Zeilenende.
pub fn nextSegment(line: []const u8, cols: usize, start: usize, start_col: usize) ?Segment {
    if (start >= line.len) return null;
    const max = @max(cols, 1);
    var i = start;
    var used: usize = 0;
    var last_space: ?usize = null; // Byte hinter dem letzten Leerzeichen
    while (i < line.len) {
        const c = line[i];
        if (isContinuation(c)) {
            i += 1;
            continue;
        }
        const w = charCols(c);
        if (used + w > max) break;
        used += w;
        i += 1;
        while (i < line.len and isContinuation(line[i])) i += 1;
        if (c == ' ' or c == '\t') last_space = i;
    }
    if (i >= line.len) return .{ .start = start, .end = line.len, .col = start_col };
    // Wortgrenze bevorzugen, aber nie ein leeres Segment erzeugen
    const end = if (last_space) |ls| (if (ls > start) ls else i) else i;
    return .{ .start = start, .end = end, .col = start_col };
}

fn colsOf(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (isContinuation(c)) continue;
        n += charCols(c);
    }
    return n;
}

/// Alle Segmente einer Zeile; eine leere Zeile ergibt genau ein leeres Segment.
pub fn segments(alloc: std.mem.Allocator, line: []const u8, cols: usize) ![]Segment {
    var list: std.ArrayListUnmanaged(Segment) = .empty;
    errdefer list.deinit(alloc);
    var start: usize = 0;
    var col: usize = 0;
    while (nextSegment(line, cols, start, col)) |seg| {
        try list.append(alloc, seg);
        col += colsOf(line[seg.start..seg.end]);
        start = seg.end;
    }
    if (list.items.len == 0) try list.append(alloc, .{ .start = 0, .end = 0, .col = 0 });
    return list.toOwnedSlice(alloc);
}

/// Anzahl der Segmente ohne Allokation (mindestens 1).
pub fn segmentCount(line: []const u8, cols: usize) usize {
    var n: usize = 0;
    var start: usize = 0;
    while (nextSegment(line, cols, start, 0)) |seg| : (start = seg.end) n += 1;
    return @max(n, 1);
}

/// Segment, in dem Byte `byte` liegt (Zeilenende gehört zum letzten Segment).
pub fn segmentIndexOfByte(line: []const u8, cols: usize, byte: usize) usize {
    var idx: usize = 0;
    var start: usize = 0;
    while (nextSegment(line, cols, start, 0)) |seg| : (start = seg.end) {
        if (byte < seg.end) return idx;
        idx += 1;
    }
    return if (idx == 0) 0 else idx - 1;
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

fn expectSegs(expected: []const Segment, actual: []const Segment) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.start, a.start);
        try testing.expectEqual(e.end, a.end);
        try testing.expectEqual(e.col, a.col);
    }
}

test "segments: kurze und leere Zeile bleiben ein Segment" {
    const a = testing.allocator;
    const s1 = try segments(a, "hello", 10);
    defer a.free(s1);
    try expectSegs(&.{.{ .start = 0, .end = 5, .col = 0 }}, s1);
    const s2 = try segments(a, "", 10);
    defer a.free(s2);
    try expectSegs(&.{.{ .start = 0, .end = 0, .col = 0 }}, s2);
    try testing.expectEqual(@as(usize, 1), segmentCount("", 10));
}

test "segments: Umbruch hinter dem letzten Leerzeichen, Folgesegment kennt seine Spalte" {
    const a = testing.allocator;
    //            0123456789012345678
    const line = "foo bar baz quux end";
    const s = try segments(a, line, 10);
    defer a.free(s);
    // "foo bar " (8) | "baz quux " (9) | "end"
    try expectSegs(&.{
        .{ .start = 0, .end = 8, .col = 0 },
        .{ .start = 8, .end = 17, .col = 8 },
        .{ .start = 17, .end = 20, .col = 17 },
    }, s);
    try testing.expectEqual(@as(usize, 3), segmentCount(line, 10));
    try testing.expectEqual(@as(usize, 0), segmentIndexOfByte(line, 10, 7));
    try testing.expectEqual(@as(usize, 1), segmentIndexOfByte(line, 10, 8));
    try testing.expectEqual(@as(usize, 2), segmentIndexOfByte(line, 10, 20));
}

test "segments: Wort breiter als die Spaltenzahl bricht hart" {
    const a = testing.allocator;
    const s = try segments(a, "abcdefghijklmnop", 6);
    defer a.free(s);
    try expectSegs(&.{
        .{ .start = 0, .end = 6, .col = 0 },
        .{ .start = 6, .end = 12, .col = 6 },
        .{ .start = 12, .end = 16, .col = 12 },
    }, s);
}

test "segments: Tabs zählen 4 Spalten, UTF-8-Folgebytes keine" {
    const a = testing.allocator;
    const s = try segments(a, "\tab cd", 6);
    defer a.free(s);
    // Tab(4)+a+b = 6 Spalten, das Leerzeichen passt nicht mehr → Bruch hinter dem letzten
    // Whitespace, also hinter dem Tab; "ab cd" (5 Spalten) beginnt in Spalte 4
    try expectSegs(&.{ .{ .start = 0, .end = 1, .col = 0 }, .{ .start = 1, .end = 6, .col = 4 } }, s);
    const u = try segments(a, "äöü ab", 4);
    defer a.free(u);
    // ä ö ü + Leerzeichen = 4 Spalten (7 Bytes), dann "ab"
    try expectSegs(&.{ .{ .start = 0, .end = 7, .col = 0 }, .{ .start = 7, .end = 9, .col = 4 } }, u);
}
