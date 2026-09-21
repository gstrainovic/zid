//! Suche in der Markdown-Vorschau (Ctrl+F): was nur die Vorschau braucht. Treffer findet
//! `editor/find_ops.zig` (`Pattern`, dieselben Optionen wie im Editor), Leiste und Zustand
//! kommen aus `editor/find_bar.zig`.
//!
//! Die Vorschau ist virtualisiert, gezeichnet wird nur ein Fenster von Blöcken. Treffer
//! werden deshalb zweimal gezählt: einmal über den Klartext jedes Blocks auf oberster
//! Ebene (`Hit` = Block und laufende Nummer darin, für Zähler und Sprung) und beim
//! Zeichnen noch einmal je gezeichneter Zeile, in derselben Reihenfolge. Der n-te Treffer
//! beim Zeichnen eines Blocks ist der Treffer (Block, n). Ein Begriff, der über einen
//! weichen Zeilenumbruch reicht, wird im Klartext gefunden, in den Zeilen aber nicht; der
//! aktuelle Treffer ist dann eine Stelle weiter hinten markiert.

const std = @import("std");

pub const Range = struct { start: u32, end: u32 };

/// Treffer im Dokument: Block auf oberster Ebene und Nummer des Vorkommens darin.
pub const Hit = struct { block: u32, nth: u32 };

/// Hängt `n` Treffer des Blocks `block` an `hits` an.
pub fn appendHits(hits: *std.ArrayListUnmanaged(Hit), alloc: std.mem.Allocator, block: u32, n: u32) void {
    for (0..n) |k| hits.append(alloc, .{ .block = block, .nth = @intCast(k) }) catch return;
}

/// Erster Treffer ab Block `block` (Suche beginnt dort, wo man gerade liest), sonst der erste.
pub fn firstFrom(hits: []const Hit, block: u32) ?usize {
    if (hits.len == 0) return null;
    for (hits, 0..) |h, i| if (h.block >= block) return i;
    return 0;
}

/// Nächster bzw. vorheriger Treffer mit Umbruch an den Enden.
pub fn step(current: ?usize, total: usize, forward: bool) ?usize {
    if (total == 0) return null;
    const c = current orelse return if (forward) 0 else total - 1;
    return if (forward) (c + 1) % total else (c + total - 1) % total;
}

/// Anzeige „3 of 12“ bzw. „No results“; leer ohne Suchbegriff.
pub fn label(buf: []u8, current: ?usize, total: usize, query_len: usize) []const u8 {
    if (query_len == 0) return "";
    if (total == 0) return "No results";
    const c = (current orelse 0) + 1;
    return std.fmt.bufPrint(buf, "{d} of {d}", .{ c, total }) catch "";
}

/// Neuer Bildlauf, damit eine Stelle [pos, pos+len) im Sichtfenster [scroll, scroll+view)
/// steht; null, wenn sie schon mit `margin` Abstand sichtbar ist. Ausserhalb kommt sie an
/// ein Drittel des Fensters (wie Browser und Editor beim Suchen), geklemmt an [0, max].
pub fn reveal(pos: f32, len: f32, scroll: f32, view: f32, margin: f32, max: f32) ?f32 {
    if (view <= 0) return null;
    const m = @min(margin, view / 4);
    if (pos >= scroll + m and pos + len <= scroll + view - m) return null;
    return std.math.clamp(pos - view / 3, 0, @max(0, max));
}

/// Art eines Abschnitts beim Zeichnen: Auswahl hat Vorrang vor dem aktuellen Treffer,
/// der vor den übrigen Treffern.
pub const Kind = enum { plain, match, current, selection };

pub const Mark = struct { start: u32, end: u32, current: bool };

pub const Segment = struct { start: u32, end: u32, kind: Kind };

/// Zerlegt ein Textstück [piece_start, piece_start+len) einer Zeile nach Auswahl und
/// Treffern (alles in Zeilen-Offsets); Ergebnis relativ zum Stück, lückenlos, gleiche
/// Nachbarn zusammengefasst. Ein leeres Stück ergibt einen leeren Abschnitt.
pub fn segments(alloc: std.mem.Allocator, piece_start: u32, len: u32, sel: ?Range, marks: []const Mark) []Segment {
    if (len == 0) {
        const one = alloc.alloc(Segment, 1) catch return &.{};
        one[0] = .{ .start = 0, .end = 0, .kind = .plain };
        return one;
    }
    var cuts: std.ArrayListUnmanaged(u32) = .empty;
    defer cuts.deinit(alloc);
    cuts.append(alloc, 0) catch return &.{};
    cuts.append(alloc, len) catch return &.{};
    const addCut = struct {
        fn f(list: *std.ArrayListUnmanaged(u32), a: std.mem.Allocator, p: u32, s: u32, l: u32) void {
            if (p <= s or p >= s +| l) return;
            list.append(a, p - s) catch {};
        }
    }.f;
    if (sel) |r| {
        addCut(&cuts, alloc, r.start, piece_start, len);
        addCut(&cuts, alloc, r.end, piece_start, len);
    }
    for (marks) |mk| {
        addCut(&cuts, alloc, mk.start, piece_start, len);
        addCut(&cuts, alloc, mk.end, piece_start, len);
    }
    std.mem.sort(u32, cuts.items, {}, std.sort.asc(u32));

    var out: std.ArrayListUnmanaged(Segment) = .empty;
    var i: usize = 0;
    while (i + 1 < cuts.items.len) : (i += 1) {
        const a = cuts.items[i];
        const b = cuts.items[i + 1];
        if (a == b) continue;
        const abs = piece_start + a; // Abschnitt ist einheitlich, sein Anfang entscheidet
        var kind: Kind = .plain;
        for (marks) |mk| {
            if (abs >= mk.start and abs < mk.end) {
                if (mk.current) kind = .current else if (kind == .plain) kind = .match;
            }
        }
        if (sel) |r| if (abs >= r.start and abs < r.end) {
            kind = .selection;
        };
        if (out.items.len > 0 and out.items[out.items.len - 1].kind == kind) {
            out.items[out.items.len - 1].end = b;
        } else {
            out.append(alloc, .{ .start = a, .end = b, .kind = kind }) catch break;
        }
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "appendHits und firstFrom: Nummer je Block, Start ab Leseposition" {
    const a = testing.allocator;
    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    defer hits.deinit(a);
    appendHits(&hits, a, 0, 1);
    appendHits(&hits, a, 3, 2);
    appendHits(&hits, a, 5, 0);
    try testing.expectEqual(@as(usize, 3), hits.items.len);
    try testing.expectEqual(Hit{ .block = 3, .nth = 1 }, hits.items[2]);
    try testing.expectEqual(@as(?usize, 1), firstFrom(hits.items, 2));
    try testing.expectEqual(@as(?usize, 0), firstFrom(hits.items, 9)); // dahinter: von vorn
    try testing.expectEqual(@as(?usize, null), firstFrom(&.{}, 0));
}

test "step: vor und zurück mit Umbruch" {
    try testing.expectEqual(@as(?usize, 0), step(null, 3, true));
    try testing.expectEqual(@as(?usize, 2), step(null, 3, false));
    try testing.expectEqual(@as(?usize, 0), step(2, 3, true));
    try testing.expectEqual(@as(?usize, 2), step(0, 3, false));
    try testing.expectEqual(@as(?usize, null), step(1, 0, true));
}

test "label" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", label(&buf, null, 0, 0));
    try testing.expectEqualStrings("No results", label(&buf, null, 0, 3));
    try testing.expectEqualStrings("2 of 5", label(&buf, 1, 5, 3));
}

test "reveal: sichtbar bleibt, ausserhalb auf ein Drittel, geklemmt" {
    try testing.expectEqual(@as(?f32, null), reveal(300, 20, 100, 600, 40, 5000));
    try testing.expectEqual(@as(?f32, 1800), reveal(2000, 20, 100, 600, 40, 5000));
    try testing.expectEqual(@as(?f32, 0), reveal(50, 20, 400, 600, 40, 5000));
    try testing.expectEqual(@as(?f32, 1000), reveal(2000, 20, 100, 600, 40, 1000));
    try testing.expectEqual(@as(?f32, 490), reveal(690, 20, 100, 600, 40, 5000)); // unten am Rand
}

test "segments: Treffer, aktueller Treffer und Auswahl in einem Stück" {
    const a = testing.allocator;
    // Stück ab Zeilen-Offset 10, 10 Bytes lang: Treffer 12..14, aktueller 16..18, Auswahl 17..25
    const marks = [_]Mark{ .{ .start = 12, .end = 14, .current = false }, .{ .start = 16, .end = 18, .current = true } };
    const s = segments(a, 10, 10, .{ .start = 17, .end = 25 }, &marks);
    defer a.free(s);
    const want = [_]Segment{
        .{ .start = 0, .end = 2, .kind = .plain },
        .{ .start = 2, .end = 4, .kind = .match },
        .{ .start = 4, .end = 6, .kind = .plain },
        .{ .start = 6, .end = 7, .kind = .current },
        .{ .start = 7, .end = 10, .kind = .selection },
    };
    try testing.expectEqualSlices(Segment, &want, s);
}

test "segments: ohne Markierung ein Abschnitt, leeres Stück bleibt leer" {
    const a = testing.allocator;
    const s = segments(a, 0, 5, null, &.{});
    defer a.free(s);
    try testing.expectEqualSlices(Segment, &.{.{ .start = 0, .end = 5, .kind = .plain }}, s);
    const e = segments(a, 3, 0, null, &.{});
    defer a.free(e);
    try testing.expectEqual(@as(usize, 1), e.len);
    // Treffer, der über das Stück hinausreicht, wird geklemmt
    const c = segments(a, 4, 4, null, &.{.{ .start = 2, .end = 6, .current = false }});
    defer a.free(c);
    try testing.expectEqualSlices(Segment, &.{ .{ .start = 0, .end = 2, .kind = .match }, .{ .start = 2, .end = 4, .kind = .plain } }, c);
}
