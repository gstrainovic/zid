//! Reine Suchlogik für die Suchleiste (Ctrl+F): findet Treffer in einem
//! zeilenweisen Text, vorwärts/rückwärts ab einer Position, mit Umbruch am
//! Ende. Optionen: Groß/Klein, Ganzwort, Regex (tiny_regex.zig). Spalten sind Anzeige-
//! spalten wie im Editor (Tab = 4, sonst ein Codepoint = 1). Kein Editor, kein Clay.

const std = @import("std");
const tiny_regex = @import("tiny_regex.zig");

pub const Pos = struct { row: usize, col: usize };
pub const Match = struct { begin: Pos, end: Pos };

pub const Options = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
    regex: bool = false,
};

pub const tab_width: usize = 4;

/// Anzeigespalte des Byte-Offsets (Tab = 4 Spalten, jedes andere Codepoint = 1).
pub fn colOfByte(line: []const u8, byte: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len and i < byte) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        col += if (line[i] == '\t') tab_width else 1;
        i += len;
    }
    return col;
}

/// Zeilenquelle: `lineCount()` und `line(i)` liefern die Zeilen ohne Umbruch.
pub fn Finder(comptime Source: type) type {
    return struct {
        /// Nächster Treffer ab `from` (exklusiv, d.h. ein Treffer genau an `from`
        /// zählt nicht), vorwärts oder rückwärts, mit Umbruch. null wenn keiner.
        pub fn find(src: Source, query: []const u8, from: Pos, forward: bool) ?Match {
            return findOpts(src, query, from, forward, .{});
        }

        /// Wie find, mit Optionen. Ungültige Regex → null.
        pub fn findOpts(src: Source, query: []const u8, from: Pos, forward: bool, opts: Options) ?Match {
            const n = src.lineCount();
            if (n == 0) return null;
            const pat = Pattern.init(query, opts) orelse return null;
            var row = @min(from.row, n - 1);
            var i: usize = 0;
            while (i <= n) : (i += 1) {
                const line = src.line(row);
                const cols = colOfByte(line, line.len);
                if (forward) {
                    // In der Startzeile erst nach `from.col` suchen, danach ab Spalte 0
                    const start_col: usize = if (i == 0) @min(from.col + 1, cols) else 0;
                    if (matchFrom(line, start_col, true, &pat)) |m| return mk(row, m);
                    row = (row + 1) % n;
                } else {
                    const start_col: ?usize = if (i == 0) (if (from.col == 0) null else from.col - 1) else cols;
                    if (start_col) |sc| {
                        if (matchFrom(line, sc, false, &pat)) |m| return mk(row, m);
                    }
                    row = if (row == 0) n - 1 else row - 1;
                }
            }
            return null;
        }

        fn mk(row: usize, m: [2]usize) Match {
            return .{ .begin = .{ .row = row, .col = m[0] }, .end = .{ .row = row, .col = m[1] } };
        }
    };
}

/// Suchbegriff mit Optionen, einmal übersetzt (Regex). Der Editor sucht damit schrittweise
/// (`Finder`), die Markdown-Vorschau zählt und markiert damit alle Treffer einer Zeile.
pub const Pattern = struct {
    query: []const u8,
    opts: Options,
    re: ?tiny_regex.Regex = null,

    /// null bei leerem Begriff oder ungültiger Regex.
    pub fn init(query: []const u8, opts: Options) ?Pattern {
        if (query.len == 0) return null;
        var p = Pattern{ .query = query, .opts = opts };
        if (opts.regex) p.re = tiny_regex.compile(query, opts.case_sensitive) catch return null;
        return p;
    }

    /// Erster Treffer mit Beginn ab Byte `from` als Byte-Bereich; Ganzwort ist geprüft.
    pub fn next(self: *const Pattern, line: []const u8, from: usize) ?[2]usize {
        var byte = from;
        while (byte <= line.len) {
            var hit: ?[2]usize = null;
            if (self.re) |*r| {
                const m = r.find(line, byte) orelse return null;
                hit = .{ m.start, m.end };
            } else if (byte < line.len and startsWith(line[byte..], self.query, self.opts.case_sensitive)) {
                hit = .{ byte, byte + self.query.len };
            }
            if (hit) |h| {
                if (!self.opts.whole_word or (isBoundary(line, h[0], true) and isBoundary(line, h[1], false))) return h;
                byte = self.resumeAt(line, h);
                continue;
            }
            if (byte >= line.len) return null;
            byte += std.unicode.utf8ByteSequenceLength(line[byte]) catch 1;
        }
        return null;
    }

    /// Wo nach Treffer `h` weitergesucht wird: Regex hinter dem Treffer, sonst ein Zeichen
    /// weiter (der Editor findet so auch überlappende Vorkommen).
    fn resumeAt(self: *const Pattern, line: []const u8, h: [2]usize) usize {
        if (self.re != null) return if (h[1] > h[0]) h[1] else h[0] + 1;
        return h[0] + (std.unicode.utf8ByteSequenceLength(line[h[0]]) catch 1);
    }

    /// Nicht überlappende Treffer einer Zeile nacheinander (Suche über Fließtext):
    /// `var it = pat.iterate(line); while (it.next()) |h| …`.
    pub fn iterate(self: *const Pattern, line: []const u8) Iterator {
        return .{ .pat = self, .line = line };
    }

    pub const Iterator = struct {
        pat: *const Pattern,
        line: []const u8,
        byte: usize = 0,

        pub fn next(it: *Iterator) ?[2]usize {
            if (it.byte > it.line.len) return null;
            const h = it.pat.next(it.line, it.byte) orelse return null;
            it.byte = if (h[1] > h[0]) h[1] else h[0] + 1;
            return h;
        }
    };

    /// Anzahl nicht überlappender Treffer im Text.
    pub fn count(self: *const Pattern, text: []const u8) u32 {
        var it = self.iterate(text);
        var n: u32 = 0;
        while (it.next() != null) n += 1;
        return n;
    }
};

/// Treffer der Zeile als Spaltenpaar: erster ab `start_col` (vorwärts) bzw. letzter mit
/// Beginn ≤ `start_col` (rückwärts).
fn matchFrom(line: []const u8, start_col: usize, forward: bool, pat: *const Pattern) ?[2]usize {
    var best: ?[2]usize = null;
    var byte: usize = 0;
    while (byte <= line.len) {
        const h = pat.next(line, byte) orelse break;
        const cols = [2]usize{ colOfByte(line, h[0]), colOfByte(line, h[1]) };
        if (forward) {
            if (cols[0] >= start_col) return cols;
        } else {
            if (cols[0] <= start_col) best = cols else break;
        }
        byte = pat.resumeAt(line, h);
    }
    return best;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Wortgrenze vor (`before` = true) bzw. hinter dem Treffer
fn isBoundary(line: []const u8, byte: usize, before: bool) bool {
    if (before) {
        if (byte == 0) return true;
        return !isWordByte(line[byte - 1]) or byte >= line.len or !isWordByte(line[byte]);
    }
    if (byte >= line.len) return true;
    return !isWordByte(line[byte]) or byte == 0 or !isWordByte(line[byte - 1]);
}

fn startsWith(hay: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (hay.len < needle.len) return false;
    if (case_sensitive) return std.mem.eql(u8, hay[0..needle.len], needle);
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

test "Optionen: Groß/Klein, Ganzwort, Regex; Tabs zählen 4 Spalten" {
    const src = SliceSource{ .lines = &.{ "Cat concat cat", "\tx cat" } };
    // Groß/Klein: Standard ignoriert, sensitiv findet nur "cat"
    const cs = F.findOpts(src, "cat", .{ .row = 0, .col = 0 }, true, .{ .case_sensitive = true }).?;
    try testing.expectEqual(@as(usize, 7), cs.begin.col); // in "concat"
    // Ganzwort: überspringt "concat", nächstes eigenständiges "cat"
    const ww = F.findOpts(src, "cat", .{ .row = 0, .col = 0 }, true, .{ .whole_word = true }).?;
    try testing.expectEqual(@as(usize, 11), ww.begin.col);
    // Tab = 4 Spalten: "\tx cat" → cat beginnt in Spalte 4 + 2 = 6
    const tabbed = F.findOpts(src, "cat", .{ .row = 0, .col = 11 }, true, .{}).?;
    try testing.expectEqual(@as(usize, 1), tabbed.begin.row);
    try testing.expectEqual(@as(usize, 6), tabbed.begin.col);
    try testing.expectEqual(@as(usize, 9), tabbed.end.col);
    // Regex: Ende aus dem Treffer, nicht aus der Musterlänge
    // Regex: Ende aus dem Treffer, nicht aus der Musterlänge; ab Zeile 1 ist "cat" in Zeile 1 der nächste
    const rx = F.findOpts(src, "c[ao]n?c?a?t", .{ .row = 1, .col = 0 }, true, .{ .regex = true }).?;
    try testing.expectEqual(@as(usize, 1), rx.begin.row);
    try testing.expectEqual(@as(usize, 6), rx.begin.col);
    try testing.expectEqual(@as(usize, 9), rx.end.col);
    const rx_wrap = F.findOpts(src, "^c[ao]t", .{ .row = 1, .col = 5 }, true, .{ .regex = true }).?;
    try testing.expectEqual(@as(usize, 0), rx_wrap.begin.row);
    try testing.expectEqual(@as(usize, 3), rx_wrap.end.col);
    const rx2 = F.findOpts(src, "con\\w+", .{ .row = 0, .col = 0 }, true, .{ .regex = true }).?;
    try testing.expectEqual(@as(usize, 10), rx2.end.col);
    try testing.expect(F.findOpts(src, "(", .{ .row = 0, .col = 0 }, true, .{ .regex = true }) == null);
    try testing.expectEqual(@as(usize, 5), colOfByte("\tab", 2));
}

test "find: leere Suche oder kein Treffer liefert null; Spalten sind Codepoints" {
    const src = SliceSource{ .lines = &.{ "äöü foo", "" } };
    try testing.expect(F.find(src, "", .{ .row = 0, .col = 0 }, true) == null);
    try testing.expect(F.find(src, "nope", .{ .row = 0, .col = 0 }, true) == null);
    const m = F.find(src, "foo", .{ .row = 1, .col = 0 }, true).?;
    try testing.expectEqual(@as(usize, 4), m.begin.col);
}

test "Pattern.iterate: alle Treffer einer Zeile als Bytes, nicht überlappend, mit Optionen" {
    const plain = Pattern.init("aa", .{}).?;
    var it = plain.iterate("äaaaA");
    try testing.expectEqual([2]usize{ 2, 4 }, it.next().?); // ä = 2 Bytes
    try testing.expectEqual([2]usize{ 4, 6 }, it.next().?); // "aA" ohne Groß/Klein
    try testing.expect(it.next() == null);
    const word = Pattern.init("cat", .{ .whole_word = true }).?;
    try testing.expectEqual(@as(u32, 2), word.count("cat concat cat"));
    const re = Pattern.init("c[ao]t", .{ .regex = true }).?;
    try testing.expectEqual(@as(u32, 3), re.count("cat cot concat"));
    try testing.expect(Pattern.init("", .{}) == null);
    try testing.expect(Pattern.init("(", .{ .regex = true }) == null);
}
