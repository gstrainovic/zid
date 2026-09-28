//! SVG für MuPDF aufbereiten, bevor es gerastert wird.
//!
//! MuPDFs SVG-Interpreter weicht an zwei Stellen vom Browser ab, auch im aktuellen
//! Upstream:
//! - `<use href="#s">` auf ein `<symbol>` liest `viewBox` und `preserveAspectRatio`
//!   vom `<use>` statt vom `<symbol>`. Das Symbol wird dann nicht auf `width`/`height`
//!   des `<use>` skaliert. Abhilfe: beide Attribute des Symbols ans `<use>` kopieren.
//! - `font-family` wirkt nur direkt am `<text>`, nicht geerbt vom `<svg>`. Ohne
//!   Angabe nimmt MuPDF eine Serifenschrift. Abhilfe: die Schrift des Wurzelelements
//!   an jedes `<text>` ohne eigene Angabe schreiben.
//!
//! Reine Textbearbeitung auf Tag-Ebene, kein XML-Parser: Attribute in `"…"` oder
//! `'…'`, Kommentare und CDATA werden nicht gesondert behandelt.

const std = @import("std");

const Symbol = struct {
    id: []const u8,
    view_box: ?[]const u8,
    preserve: ?[]const u8,
};

/// Liefert das aufbereitete SVG; das Ergebnis gehört dem Aufrufer.
pub fn fixup(allocator: std.mem.Allocator, svg: []const u8) ![]u8 {
    var symbols: std.ArrayListUnmanaged(Symbol) = .empty;
    defer symbols.deinit(allocator);
    var root_font: ?[]const u8 = null;

    var it = TagIterator{ .src = svg };
    while (it.next()) |tag| {
        if (root_font == null and isTag(tag.text, "svg")) root_font = attr(tag.text, "font-family");
        if (isTag(tag.text, "symbol")) {
            const id = attr(tag.text, "id") orelse continue;
            try symbols.append(allocator, .{
                .id = id,
                .view_box = attr(tag.text, "viewBox"),
                .preserve = attr(tag.text, "preserveAspectRatio"),
            });
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    it = .{ .src = svg };
    while (it.next()) |tag| {
        // Einfügestelle: direkt hinter dem Tag-Namen.
        const name_end = tag.start + 1 + tagName(tag.text).len;
        var extra: std.ArrayListUnmanaged(u8) = .empty;
        defer extra.deinit(allocator);

        if (isTag(tag.text, "use")) {
            const href = attr(tag.text, "href") orelse attr(tag.text, "xlink:href");
            if (href) |h| if (h.len > 1 and h[0] == '#') {
                for (symbols.items) |s| {
                    if (!std.mem.eql(u8, s.id, h[1..])) continue;
                    if (s.view_box) |vb| if (attr(tag.text, "viewBox") == null) {
                        try extra.print(allocator, " viewBox=\"{s}\"", .{vb});
                    };
                    if (s.preserve) |pa| if (attr(tag.text, "preserveAspectRatio") == null) {
                        try extra.print(allocator, " preserveAspectRatio=\"{s}\"", .{pa});
                    };
                    break;
                }
            };
        } else if (isTag(tag.text, "text")) {
            if (root_font) |f| if (attr(tag.text, "font-family") == null) {
                try extra.print(allocator, " font-family=\"{s}\"", .{f});
            };
        }

        if (extra.items.len > 0) {
            try out.appendSlice(allocator, svg[pos..name_end]);
            try out.appendSlice(allocator, extra.items);
            pos = name_end;
        }
    }
    try out.appendSlice(allocator, svg[pos..]);
    return out.toOwnedSlice(allocator);
}

const Tag = struct { start: usize, text: []const u8 };

/// Öffnende Tags `<name …>`; schließende, Kommentare und `<?…?>` übersprungen.
const TagIterator = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *TagIterator) ?Tag {
        while (std.mem.indexOfScalarPos(u8, self.src, self.pos, '<')) |lt| {
            const end = std.mem.indexOfScalarPos(u8, self.src, lt, '>') orelse return null;
            self.pos = end + 1;
            if (lt + 1 < self.src.len and std.ascii.isAlphabetic(self.src[lt + 1])) {
                return .{ .start = lt, .text = self.src[lt .. end + 1] };
            }
        }
        return null;
    }
};

fn tagName(tag: []const u8) []const u8 {
    var i: usize = 1;
    while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>' and tag[i] != '/') i += 1;
    return tag[1..i];
}

fn isTag(tag: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, tagName(tag), name);
}

/// Wert eines Attributs; der Name muss vollständig passen (`href` trifft nicht
/// `xlink:href`).
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, from, name)) |i| {
        from = i + 1;
        if (i == 0 or !std.ascii.isWhitespace(tag[i - 1])) continue;
        var j = i + name.len;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const q = tag[j];
        const close = std.mem.indexOfScalarPos(u8, tag, j + 1, q) orelse return null;
        return tag[j + 1 .. close];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "use auf ein symbol bekommt dessen viewBox und preserveAspectRatio" {
    const src =
        \\<svg viewBox="0 0 100 100"><defs>
        \\<symbol id="quer" viewBox="0 0 40 30" preserveAspectRatio="none"><rect width="40" height="30"/></symbol>
        \\</defs><use href="#quer" x="20" y="40" width="92" height="69"/></svg>
    ;
    const out = try fixup(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out,
        \\<use viewBox="0 0 40 30" preserveAspectRatio="none" href="#quer"
    ) != null);
}

test "use auf eine Gruppe bleibt unverändert" {
    const src =
        \\<svg><defs><g id="text"><rect/></g></defs><use href="#text" x="1"/></svg>
    ;
    const out = try fixup(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "xlink:href und vorhandene viewBox am use" {
    const src =
        \\<svg><symbol id="s" viewBox="0 0 1 1"/><use xlink:href="#s"/><use href="#s" viewBox="0 0 2 2"/></svg>
    ;
    const out = try fixup(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<use viewBox=\"0 0 1 1\" xlink:href=\"#s\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<use href=\"#s\" viewBox=\"0 0 2 2\"/>") != null);
}

test "text erbt die Schrift des Wurzelelements, eigene Angabe bleibt" {
    const src =
        \\<svg font-family="Arial, sans-serif"><text x="1">A</text><text font-family="Courier">B</text></svg>
    ;
    const out = try fixup(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\<svg font-family="Arial, sans-serif"><text font-family="Arial, sans-serif" x="1">A</text><text font-family="Courier">B</text></svg>
    , out);
}

test "attr trifft nur ganze Namen" {
    try testing.expectEqualStrings("#a", attr("<use xlink:href=\"#a\"/>", "xlink:href").?);
    try testing.expect(attr("<use xlink:href=\"#a\"/>", "href") == null);
    try testing.expectEqualStrings("x", attr("<a b = 'x'>", "b").?);
}
