//! Textauswahl in der Markdown-Vorschau: reine Logik ohne Clay.
//!
//! Die Vorschau zeichnet Text als Zeilen aus Stücken (`MarkdownView.flushPieces`,
//! Codeblock-Zeilen). Eine Position ist (Block, Zeile im Block, Byte-Offset in der
//! Zeile); Blöcke sind die Kinder auf oberster Ebene des Dokuments, Zeilen zählen in
//! Zeichenreihenfolge. Damit bleibt eine Auswahl gültig, während die Virtualisierung
//! andere Blöcke zeichnet.

const std = @import("std");

/// Kopie des Quelltexts mit LF-Zeilenenden. Der Editor normalisiert CRLF beim Laden,
/// die Vorschau liest die Datei aber roh (und der Editor gibt beim Export den
/// Datei-Modus zurück): ohne das trägt jede Codeblock-Zeile ein `\r`, das mitgezeichnet
/// und mitkopiert wird. Ein einzelnes `\r` ohne `\n` bleibt stehen.
pub fn ownedLf(allocator: std.mem.Allocator, text: []const u8) []u8 {
    const crlf = std.mem.count(u8, text, "\r\n");
    if (crlf == 0) return allocator.dupe(u8, text) catch "";
    const out = allocator.alloc(u8, text.len - crlf) catch return "";
    var n: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        out[n] = c;
        n += 1;
    }
    return out;
}

test "ownedLf: CRLF wird zu LF, LF und einzelnes CR bleiben" {
    const a = std.testing.allocator;
    const crlf = ownedLf(a, "# T\r\n\r\n```\r\nx\r\n```\r\n");
    defer a.free(crlf);
    try std.testing.expectEqualStrings("# T\n\n```\nx\n```\n", crlf);
    const lf = ownedLf(a, "a\nb\r");
    defer a.free(lf);
    try std.testing.expectEqualStrings("a\nb\r", lf);
}

pub const Pos = struct {
    block: u32,
    line: u32,
    offset: u32,

    pub fn eql(a: Pos, b: Pos) bool {
        return a.block == b.block and a.line == b.line and a.offset == b.offset;
    }
};

pub fn lessThan(a: Pos, b: Pos) bool {
    if (a.block != b.block) return a.block < b.block;
    if (a.line != b.line) return a.line < b.line;
    return a.offset < b.offset;
}

pub const Span = struct { start: Pos, end: Pos };

/// Anker und Kopf in Dokumentreihenfolge; null bei leerer Auswahl.
pub fn ordered(anchor: Pos, head: Pos) ?Span {
    if (anchor.eql(head)) return null;
    return if (lessThan(anchor, head)) .{ .start = anchor, .end = head } else .{ .start = head, .end = anchor };
}

/// Senkrechte Lage einer gezeichneten Zeile (Bounding-Box aus dem Vorframe).
pub const LineBox = struct { y: f32, h: f32 };

/// Zeile zu y: die getroffene Zeile, sonst die letzte Zeile darüber (Lücke zwischen
/// Blöcken, Ziehen unter den Rand), über der ersten Zeile die erste. Null ohne Zeilen.
pub fn lineAtY(boxes: []const LineBox, y: f32) ?usize {
    if (boxes.len == 0) return null;
    var best: ?usize = null;
    for (boxes, 0..) |b, i| {
        if (y >= b.y and y < b.y + b.h) return i;
        if (b.y + b.h <= y) {
            if (best == null or boxes[best.?].y < b.y) best = i;
        }
    }
    if (best) |i| return i;
    // Über allen Zeilen: die oberste
    var top: usize = 0;
    for (boxes, 0..) |b, i| if (b.y < boxes[top].y) {
        top = i;
    };
    return top;
}

pub const Measure = *const fn (text: []const u8, size: f32) f32;

/// Byte-Offset der Zeichengrenze, die x (relativ zum Zeilenanfang) am nächsten liegt.
/// Misst Codepoint für Codepoint (Monospace, keine Ligaturen), trennt nie in einem Zeichen.
pub fn offsetAtX(measure: Measure, size: f32, text: []const u8, x: f32) u32 {
    if (x <= 0) return 0;
    var i: usize = 0;
    var left: f32 = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(text.len, i + n);
        const w = measure(text[i..end], size);
        if (x < left + w / 2) return @intCast(i);
        left += w;
        i = end;
    }
    return @intCast(text.len);
}

pub const Range = struct { start: u32, end: u32 };

/// Ausgewählter Bereich einer Zeile in Zeilen-Offsets, null wenn die Zeile außerhalb liegt.
/// `end` ist `maxInt` für Zeilen, die nicht die Endzeile sind (Aufrufer klemmt an die Länge).
pub fn lineRange(span: Span, block: u32, line: u32) ?Range {
    const here_start = Pos{ .block = block, .line = line, .offset = 0 };
    const here_end = Pos{ .block = block, .line = line, .offset = std.math.maxInt(u32) };
    if (lessThan(here_end, span.start)) return null; // Zeile liegt ganz vor dem Anfang
    if (!lessThan(here_start, span.end)) return null; // Zeile beginnt am oder nach dem Ende
    const from: u32 = if (span.start.block == block and span.start.line == line) span.start.offset else 0;
    const to: u32 = if (span.end.block == block and span.end.line == line) span.end.offset else std.math.maxInt(u32);
    if (from >= to) return null;
    return .{ .start = from, .end = to };
}

/// Schnitt eines Stücks [piece_start, piece_start+len) mit dem Zeilenbereich, relativ zum Stück.
pub fn intersect(range: Range, piece_start: u32, piece_len: u32) ?Range {
    const a = @max(range.start, piece_start);
    const b = @min(range.end, piece_start +| piece_len);
    if (a >= b) return null;
    return .{ .start = a - piece_start, .end = b - piece_start };
}

/// Trenner zwischen zwei kopierten Zeilen: weicher Umbruch → Leerzeichen, harte Zeile im
/// selben Block → Zeilenumbruch, neuer Block → Leerzeile (wie ein Browser Absätze kopiert).
pub fn joinWith(prev_block: u32, next_block: u32, next_soft: bool) []const u8 {
    if (prev_block != next_block) return "\n\n";
    return if (next_soft) " " else "\n";
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn fakeMeasure(text: []const u8, size: f32) f32 {
    _ = size;
    const n = std.unicode.utf8CountCodepoints(text) catch text.len;
    return @as(f32, @floatFromInt(n)) * 8;
}

test "ordered: Anker nach Kopf wird gedreht, gleiche Position ist keine Auswahl" {
    const a = Pos{ .block = 2, .line = 0, .offset = 5 };
    const b = Pos{ .block = 1, .line = 3, .offset = 0 };
    const s = ordered(a, b).?;
    try testing.expect(s.start.eql(b) and s.end.eql(a));
    try testing.expect(ordered(a, a) == null);
    try testing.expect(lessThan(.{ .block = 1, .line = 0, .offset = 9 }, .{ .block = 1, .line = 1, .offset = 0 }));
}

test "lineAtY: Treffer, Lücke, darüber, darunter" {
    const boxes = [_]LineBox{ .{ .y = 100, .h = 20 }, .{ .y = 140, .h = 20 }, .{ .y = 200, .h = 20 } };
    try testing.expectEqual(@as(?usize, 1), lineAtY(&boxes, 150));
    try testing.expectEqual(@as(?usize, 0), lineAtY(&boxes, 130)); // Lücke: Zeile darüber
    try testing.expectEqual(@as(?usize, 0), lineAtY(&boxes, 10)); // über allem: erste
    try testing.expectEqual(@as(?usize, 2), lineAtY(&boxes, 900)); // unter allem: letzte
    try testing.expect(lineAtY(&.{}, 5) == null);
}

test "offsetAtX: nächste Zeichengrenze, UTF-8-sicher, klemmt an Anfang und Ende" {
    try testing.expectEqual(@as(u32, 0), offsetAtX(fakeMeasure, 20, "abc", -3));
    try testing.expectEqual(@as(u32, 0), offsetAtX(fakeMeasure, 20, "abc", 3));
    try testing.expectEqual(@as(u32, 1), offsetAtX(fakeMeasure, 20, "abc", 5));
    try testing.expectEqual(@as(u32, 3), offsetAtX(fakeMeasure, 20, "abc", 100));
    try testing.expectEqual(@as(u32, 2), offsetAtX(fakeMeasure, 20, "äb", 9)); // ä = 2 Bytes
    try testing.expectEqual(@as(u32, 0), offsetAtX(fakeMeasure, 20, "", 50));
}

test "lineRange: Start-, Mittel-, End- und Außenzeilen" {
    const span = Span{ .start = .{ .block = 1, .line = 1, .offset = 3 }, .end = .{ .block = 3, .line = 0, .offset = 4 } };
    try testing.expect(lineRange(span, 1, 0) == null);
    try testing.expect(lineRange(span, 0, 7) == null);
    try testing.expectEqual(Range{ .start = 3, .end = std.math.maxInt(u32) }, lineRange(span, 1, 1).?);
    try testing.expectEqual(Range{ .start = 0, .end = std.math.maxInt(u32) }, lineRange(span, 2, 5).?);
    try testing.expectEqual(Range{ .start = 0, .end = 4 }, lineRange(span, 3, 0).?);
    try testing.expect(lineRange(span, 3, 1) == null);
    try testing.expect(lineRange(span, 4, 0) == null);
    const same = Span{ .start = .{ .block = 0, .line = 0, .offset = 2 }, .end = .{ .block = 0, .line = 0, .offset = 6 } };
    try testing.expectEqual(Range{ .start = 2, .end = 6 }, lineRange(same, 0, 0).?);
}

test "intersect: Stück ganz, teilweise oder gar nicht in der Auswahl" {
    const r = Range{ .start = 4, .end = 10 };
    try testing.expect(intersect(r, 0, 4) == null);
    try testing.expectEqual(Range{ .start = 2, .end = 5 }, intersect(r, 2, 5).?);
    try testing.expectEqual(Range{ .start = 0, .end = 3 }, intersect(r, 5, 3).?);
    try testing.expectEqual(Range{ .start = 0, .end = 2 }, intersect(r, 8, 6).?);
    try testing.expect(intersect(r, 10, 3) == null);
    try testing.expectEqual(Range{ .start = 1, .end = 3 }, intersect(.{ .start = 1, .end = std.math.maxInt(u32) }, 0, 3).?);
}

test "joinWith: weich = Leerzeichen, hart = Umbruch, Blockwechsel = Leerzeile" {
    try testing.expectEqualStrings(" ", joinWith(2, 2, true));
    try testing.expectEqualStrings("\n", joinWith(2, 2, false));
    try testing.expectEqualStrings("\n\n", joinWith(2, 3, true));
}
