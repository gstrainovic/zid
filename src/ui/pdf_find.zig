//! Suche in der PDF-Vorschau (Ctrl+F), frei von mupdf und Clay, damit sie testbar bleibt.
//! mupdf liefert je Seite Codepunkte mit Box (`fz_page_text_z`); daraus wird hier ein
//! UTF-8-Text, den `find_ops.Pattern` mit denselben Optionen wie im Editor durchsucht.
//! Ein Treffer ist ein Byte-Bereich im Text, gezeichnet wird er als Rechtecke je Zeile.
//!
//! Gesucht wird schrittweise, einige Seiten pro Frame (`Search.next_page`): ein Dokument
//! mit hunderten Seiten hielte sonst die Oberfläche an.

const std = @import("std");

/// Rechteck in Seitenkoordinaten (pt, Ursprung oben links wie bei mupdf).
pub const Rect = struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,

    fn isEmpty(r: Rect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }

    fn unite(a: Rect, b: Rect) Rect {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }
};

/// Text einer Seite: UTF-8, dazu je Zeichen der Byte-Anfang und die Box.
pub const PageText = struct {
    text: []u8,
    char_start: []u32,
    boxes: []Rect,

    /// Aus den Codepunkten und Boxen von mupdf. Ungültige Codepunkte werden zu U+FFFD.
    pub fn init(alloc: std.mem.Allocator, codes: []const i32, boxes: []const Rect) !PageText {
        var text: std.ArrayListUnmanaged(u8) = .empty;
        errdefer text.deinit(alloc);
        const starts = try alloc.alloc(u32, codes.len);
        errdefer alloc.free(starts);
        for (codes, 0..) |code, i| {
            starts[i] = @intCast(text.items.len);
            const cp: u21 = if (code >= 0 and code <= 0x10FFFF) @intCast(code) else 0xFFFD;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
            try text.appendSlice(alloc, buf[0..n]);
        }
        const own_boxes = try alloc.dupe(Rect, boxes);
        return .{ .text = try text.toOwnedSlice(alloc), .char_start = starts, .boxes = own_boxes };
    }

    pub fn deinit(self: *PageText, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.char_start);
        alloc.free(self.boxes);
    }

    /// Index des Zeichens, in dem Byte `byte` liegt.
    fn charAt(self: *const PageText, byte: usize) usize {
        var lo: usize = 0;
        var hi: usize = self.char_start.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.char_start[mid] <= byte) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Rechtecke für den Byte-Bereich [a, b): Nachbarzeichen einer Zeile werden vereint,
    /// Zeilenenden (leere Boxen) trennen. Liefert die Anzahl angehängter Rechtecke.
    pub fn hitRects(self: *const PageText, alloc: std.mem.Allocator, a: usize, b: usize, out: *std.ArrayListUnmanaged(Rect)) !u32 {
        if (b <= a or self.char_start.len == 0) return 0;
        const first = self.charAt(a);
        const last = self.charAt(b - 1);
        var n: u32 = 0;
        var cur: ?Rect = null;
        for (self.boxes[first .. last + 1]) |b_| {
            if (b_.isEmpty()) {
                if (cur) |r| {
                    try out.append(alloc, r);
                    n += 1;
                }
                cur = null;
                continue;
            }
            cur = if (cur) |r| r.unite(b_) else b_;
        }
        if (cur) |r| {
            try out.append(alloc, r);
            n += 1;
        }
        return n;
    }
};

/// Ein Treffer: Seite und seine Rechtecke in `Search.rects`.
pub const Hit = struct { page: u16, rect_start: u32, rect_len: u32 };

/// Zustand einer laufenden oder fertigen Suche im Dokument.
pub const Search = struct {
    hits: std.ArrayListUnmanaged(Hit) = .empty,
    rects: std.ArrayListUnmanaged(Rect) = .empty,
    current: ?usize = null,
    /// Nächste zu durchsuchende Seite; null, wenn fertig oder keine Suche läuft.
    next_page: ?u16 = null,
    /// Seite, ab der der erste Treffer angesprungen wird (Leseposition beim Start).
    start_page: u16 = 0,
    /// Beim ersten passenden Treffer springen; danach nicht mehr, damit ein späterer
    /// Fund den Leser nicht wegzieht.
    jump_pending: bool = false,

    pub fn deinit(self: *Search, alloc: std.mem.Allocator) void {
        self.hits.deinit(alloc);
        self.rects.deinit(alloc);
    }

    /// Neu beginnen ab Seite 0; der erste Treffer ab `from_page` wird angesprungen.
    pub fn restart(self: *Search, from_page: u16, has_query: bool) void {
        self.hits.clearRetainingCapacity();
        self.rects.clearRetainingCapacity();
        self.current = null;
        self.start_page = from_page;
        self.next_page = if (has_query) 0 else null;
        self.jump_pending = has_query;
    }

    pub fn clear(self: *Search) void {
        self.restart(0, false);
    }

    pub fn running(self: *const Search) bool {
        return self.next_page != null;
    }

    /// Treffer einer Seite anhängen. `ranges` sind Byte-Bereiche in `text`.
    pub fn addPage(self: *Search, alloc: std.mem.Allocator, page: u16, text: *const PageText, ranges: []const [2]usize) !void {
        for (ranges) |r| {
            const start: u32 = @intCast(self.rects.items.len);
            const n = try text.hitRects(alloc, r[0], r[1], &self.rects);
            if (n == 0) continue;
            try self.hits.append(alloc, .{ .page = page, .rect_start = start, .rect_len = n });
        }
    }

    /// Nach einer durchsuchten Seite: nächste Seite setzen und prüfen, ob jetzt ein Treffer
    /// angesprungen werden soll. Liefert den Index, wenn ja.
    pub fn pageDone(self: *Search, page: u16, total_pages: u16) ?usize {
        self.next_page = if (page + 1 < total_pages) page + 1 else null;
        if (!self.jump_pending) return null;
        for (self.hits.items, 0..) |h, i| {
            if (h.page >= self.start_page) {
                self.jump_pending = false;
                self.current = i;
                return i;
            }
        }
        // Fertig ohne Treffer ab der Leseposition: von vorn
        if (self.next_page == null and self.hits.items.len > 0) {
            self.jump_pending = false;
            self.current = 0;
            return 0;
        }
        return null;
    }

    /// Weiter bzw. zurück mit Umbruch. Liefert den neuen Index.
    pub fn step(self: *Search, forward: bool) ?usize {
        const total = self.hits.items.len;
        if (total == 0) return null;
        self.jump_pending = false;
        self.current = if (self.current) |c|
            (if (forward) (c + 1) % total else (c + total - 1) % total)
        else if (forward) 0 else total - 1;
        return self.current;
    }

    pub fn hitRectsOf(self: *const Search, i: usize) []const Rect {
        const h = self.hits.items[i];
        return self.rects.items[h.rect_start .. h.rect_start + h.rect_len];
    }

    /// Hülle aller Rechtecke eines Treffers, für den Bildlauf.
    pub fn hitBounds(self: *const Search, i: usize) Rect {
        const rs = self.hitRectsOf(i);
        var r = rs[0];
        for (rs[1..]) |x| r = r.unite(x);
        return r;
    }

    /// Anzeige „3 of 12“, während der Suche „3 of 12…“; „No results“ erst am Ende.
    pub fn label(self: *const Search, buf: []u8, query_len: usize) []const u8 {
        if (query_len == 0) return "";
        const total = self.hits.items.len;
        const more: []const u8 = if (self.running()) "…" else "";
        if (total == 0) return if (self.running()) "…" else "No results";
        const c = (self.current orelse 0) + 1;
        return std.fmt.bufPrint(buf, "{d} of {d}{s}", .{ c, total, more }) catch "";
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn box(x0: f32, y0: f32, x1: f32, y1: f32) Rect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

const none: Rect = .{};

test "PageText: UTF-8 mit Byte-Anfang je Zeichen" {
    const a = testing.allocator;
    const codes = [_]i32{ 'a', 0xE4, 'b', -5 };
    const boxes = [_]Rect{ box(0, 0, 1, 1), box(1, 0, 2, 1), box(2, 0, 3, 1), box(3, 0, 4, 1) };
    var pt = try PageText.init(a, &codes, &boxes);
    defer pt.deinit(a);
    try testing.expectEqualStrings("a\u{E4}b\u{FFFD}", pt.text);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 4 }, pt.char_start);
    try testing.expectEqual(@as(usize, 1), pt.charAt(2)); // zweites Byte von ä
}

test "hitRects: eine Zeile wird ein Rechteck, Zeilenende trennt" {
    const a = testing.allocator;
    // "ab cd" über zwei Zeilen: a b ␠(Zeilenende) c d
    const codes = [_]i32{ 'a', 'b', ' ', 'c', 'd' };
    const boxes = [_]Rect{ box(10, 0, 20, 12), box(20, 0, 30, 12), none, box(10, 14, 20, 26), box(20, 14, 30, 26) };
    var pt = try PageText.init(a, &codes, &boxes);
    defer pt.deinit(a);
    var out: std.ArrayListUnmanaged(Rect) = .empty;
    defer out.deinit(a);
    try testing.expectEqual(@as(u32, 1), try pt.hitRects(a, 0, 2, &out));
    try testing.expectEqual(box(10, 0, 30, 12), out.items[0]);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u32, 2), try pt.hitRects(a, 1, 5, &out));
    try testing.expectEqual(box(20, 0, 30, 12), out.items[0]);
    try testing.expectEqual(box(10, 14, 30, 26), out.items[1]);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u32, 0), try pt.hitRects(a, 2, 3, &out)); // nur Zeilenende
    try testing.expectEqual(@as(u32, 0), try pt.hitRects(a, 3, 3, &out)); // leer
}

test "Search: Sprung zum ersten Treffer ab der Leseposition, erst wenn gefunden" {
    const a = testing.allocator;
    const codes = [_]i32{ 'x', 'y' };
    const boxes = [_]Rect{ box(0, 0, 5, 5), box(5, 0, 10, 5) };
    var pt = try PageText.init(a, &codes, &boxes);
    defer pt.deinit(a);

    var s: Search = .{};
    defer s.deinit(a);
    s.restart(2, true);
    try testing.expect(s.running());
    try s.addPage(a, 0, &pt, &.{.{ 0, 1 }});
    try testing.expectEqual(@as(?usize, null), s.pageDone(0, 4)); // Seite 0 liegt vor der Leseposition
    try testing.expectEqual(@as(?usize, null), s.pageDone(1, 4));
    try s.addPage(a, 2, &pt, &.{ .{ 0, 1 }, .{ 1, 2 } });
    try testing.expectEqual(@as(?usize, 1), s.pageDone(2, 4));
    // Späterer Fund springt nicht mehr
    try s.addPage(a, 3, &pt, &.{.{ 0, 2 }});
    try testing.expectEqual(@as(?usize, null), s.pageDone(3, 4));
    try testing.expect(!s.running());
    try testing.expectEqual(@as(usize, 4), s.hits.items.len);
    try testing.expectEqual(box(0, 0, 10, 5), s.hitBounds(3));

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("2 of 4", s.label(&buf, 1));
    try testing.expectEqual(@as(?usize, 2), s.step(true));
    try testing.expectEqual(@as(?usize, 1), s.step(false));
    s.current = 3;
    try testing.expectEqual(@as(?usize, 0), s.step(true)); // Umbruch
}

test "Search: ohne Treffer ab Leseposition von vorn, Beschriftung während der Suche" {
    const a = testing.allocator;
    const codes = [_]i32{'x'};
    const boxes = [_]Rect{box(0, 0, 5, 5)};
    var pt = try PageText.init(a, &codes, &boxes);
    defer pt.deinit(a);

    var s: Search = .{};
    defer s.deinit(a);
    var buf: [32]u8 = undefined;
    s.restart(1, true);
    try testing.expectEqualStrings("…", s.label(&buf, 1));
    try s.addPage(a, 0, &pt, &.{.{ 0, 1 }});
    try testing.expectEqual(@as(?usize, null), s.pageDone(0, 2));
    try testing.expectEqualStrings("1 of 1…", s.label(&buf, 1));
    try testing.expectEqual(@as(?usize, 0), s.pageDone(1, 2));
    try testing.expectEqualStrings("1 of 1", s.label(&buf, 1));

    s.restart(0, true);
    _ = s.pageDone(0, 1);
    try testing.expectEqualStrings("No results", s.label(&buf, 1));
    s.clear();
    try testing.expect(!s.running());
    try testing.expectEqualStrings("", s.label(&buf, 0));
}
