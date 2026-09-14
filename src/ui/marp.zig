//! Reine Logik für Marp-Decks: Front-Matter, Folientrennung und Direktiven.
//! Kein Clay, kein zigdown, keine Datei-IO — damit alles unit-testbar bleibt.
//!
//! Marp-Semantik (https://marpit.marp.app/directives):
//! - Ein Deck ist nur dann eines, wenn das YAML-Front-Matter `marp: true` setzt.
//! - Globale Direktiven (`theme`, `style`, `size`, `headingDivider`) gelten fürs
//!   ganze Deck, egal wo sie stehen.
//! - Lokale Direktiven (`paginate`, `class`, `header`, `footer`, `color`,
//!   `background*`) gelten ab ihrer Folie bis zum Ende; mit `_`-Präfix nur für
//!   die Folie, auf der sie stehen.

const std = @import("std");

pub const ParseError = error{NotAMarpDeck} || std.mem.Allocator.Error;

/// Foliengröße in CSS-Pixeln, wie Marp sie verwendet (16:9 = 1280x720).
pub const Size = struct {
    w: u32 = 1280,
    h: u32 = 720,
};

/// Direktiven, die für das gesamte Deck gelten.
pub const Global = struct {
    theme: ?[]const u8 = null,
    style: ?[]const u8 = null,
    size: Size = .{},
    /// 0 = aus. Sonst: Überschriften bis zu dieser Ebene beginnen eine Folie.
    heading_divider: u8 = 0,
};

/// Direktiven, die pro Folie gelten und sich auf die folgenden vererben.
pub const Local = struct {
    paginate: bool = false,
    class: ?[]const u8 = null,
    header: ?[]const u8 = null,
    footer: ?[]const u8 = null,
    color: ?[]const u8 = null,
    background_color: ?[]const u8 = null,
    background_image: ?[]const u8 = null,
    background_size: ?[]const u8 = null,
    background_position: ?[]const u8 = null,
    background_repeat: ?[]const u8 = null,
};

pub const Slide = struct {
    /// Folieninhalt ohne Direktiv-Kommentare und ohne Notizen.
    markdown: []const u8,
    /// Kommentare, die keine Direktiven sind — Marp behandelt sie als
    /// Präsentationsnotizen und rendert sie nicht.
    notes: []const []const u8,
    local: Local,
};

pub const Deck = struct {
    arena: std.heap.ArenaAllocator,
    global: Global,
    slides: []const Slide,

    pub fn deinit(self: *Deck) void {
        self.arena.deinit();
    }
};

/// Erkennt ein Marp-Deck an `marp: true` im Front-Matter, ohne zu parsen.
pub fn isMarpDeck(source: []const u8) bool {
    const fm = frontMatter(source) orelse return false;
    var it = std.mem.splitScalar(u8, fm.yaml, '\n');
    while (it.next()) |raw| {
        const kv = splitKeyValue(std.mem.trim(u8, raw, " \t\r")) orelse continue;
        if (std.mem.eql(u8, kv.key, "marp")) return std.mem.eql(u8, kv.value, "true");
    }
    return false;
}

/// Wie `isMarpDeck`, aber für eine Datei auf der Platte: liest nur den Kopf
/// (Front-Matter steht vorn). Unlesbare oder fehlende Datei zählt als kein Deck.
pub fn isMarpDeckFile(path: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    var head: [16 * 1024]u8 = undefined;
    const n = file.readAll(&head) catch return false;
    return isMarpDeck(head[0..n]);
}

/// Zerlegt eine Markdown-Quelle in Folien. Alle Slices im Ergebnis gehören der
/// Arena des Decks, die Quelle darf danach freigegeben werden.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Deck {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const fm = frontMatter(source) orelse return error.NotAMarpDeck;

    var global: Global = .{};
    var running: Local = .{};
    var is_marp = false;
    var yaml_it = std.mem.splitScalar(u8, fm.yaml, '\n');
    while (yaml_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const kv = splitKeyValue(line) orelse continue;
        if (std.mem.eql(u8, kv.key, "marp")) {
            is_marp = std.mem.eql(u8, kv.value, "true");
            continue;
        }
        if (try applyGlobal(&global, kv.key, kv.value, arena)) continue;
        _ = try applyLocal(&running, kv.key, kv.value, arena);
    }
    if (!is_marp) return error.NotAMarpDeck;

    const lines = try scanLines(arena, fm.body);
    const comments = try scanComments(arena, lines);

    // Globale Direktiven gelten unabhängig davon, wo sie stehen — deshalb ein
    // eigener Durchgang vor der Folientrennung. Späteres überschreibt früheres.
    for (comments) |c| {
        for (c.directives) |kv| {
            _ = try applyGlobal(&global, kv.key, kv.value, arena);
        }
    }

    var slides: std.ArrayListUnmanaged(Slide) = .empty;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    var notes: std.ArrayListUnmanaged([]const u8) = .empty;
    var effective = running;

    // Beendet die laufende Folie und beginnt eine neue.
    const flush = struct {
        fn call(
            a: std.mem.Allocator,
            out: *std.ArrayListUnmanaged(Slide),
            buf: *std.ArrayListUnmanaged(u8),
            nts: *std.ArrayListUnmanaged([]const u8),
            local: Local,
        ) !void {
            const text = std.mem.trim(u8, buf.items, " \t\r\n");
            try out.append(a, .{
                .markdown = try a.dupe(u8, text),
                .notes = try nts.toOwnedSlice(a),
                .local = local,
            });
            buf.clearRetainingCapacity();
        }
    }.call;

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];

        if (line.comment) |ci| {
            const c = comments[ci];
            if (c.directives.len == 0) {
                try notes.append(arena, c.note);
            } else for (c.directives) |kv| {
                if (isGlobalKey(kv.key)) continue; // schon oben angewandt
                if (kv.spot) {
                    _ = try applyLocal(&effective, kv.key, kv.value, arena);
                } else {
                    _ = try applyLocal(&running, kv.key, kv.value, arena);
                    _ = try applyLocal(&effective, kv.key, kv.value, arena);
                }
            }
            continue;
        }

        if (!line.in_fence) {
            // `---` trennt nur, wenn davor eine Leerzeile steht — sonst ist es
            // in Markdown die Unterstreichung einer Setext-Überschrift.
            if (isRuler(line.text) and isBlankTail(body.items)) {
                try flush(arena, &slides, &body, &notes, effective);
                effective = running;
                continue;
            }
            if (global.heading_divider > 0 and
                headingLevel(line.text) > 0 and
                headingLevel(line.text) <= global.heading_divider and
                std.mem.trim(u8, body.items, " \t\r\n").len > 0)
            {
                try flush(arena, &slides, &body, &notes, effective);
                effective = running;
            }
        }

        try body.appendSlice(arena, line.text);
        try body.append(arena, '\n');
    }
    try flush(arena, &slides, &body, &notes, effective);

    return .{
        .arena = arena_state,
        .global = global,
        .slides = try slides.toOwnedSlice(arena),
    };
}

// --- Front-Matter --------------------------------------------------------

const FrontMatter = struct { yaml: []const u8, body: []const u8 };

fn frontMatter(source: []const u8) ?FrontMatter {
    const first_nl = std.mem.indexOfScalar(u8, source, '\n') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, source[0..first_nl], " \t\r"), "---")) return null;

    var idx = first_nl + 1;
    const yaml_start = idx;
    while (idx <= source.len) {
        const nl = std.mem.indexOfScalarPos(u8, source, idx, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[idx..nl], " \t\r");
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "...")) {
            return .{
                .yaml = source[yaml_start..idx],
                .body = if (nl < source.len) source[nl + 1 ..] else "",
            };
        }
        if (nl >= source.len) break;
        idx = nl + 1;
    }
    return null;
}

// --- Zeilen und Kommentare -----------------------------------------------

const Line = struct {
    text: []const u8,
    in_fence: bool,
    /// Index in die Kommentarliste, wenn die Zeile zu einem Kommentar gehört.
    comment: ?usize = null,
};

fn scanLines(arena: std.mem.Allocator, body: []const u8) ![]Line {
    var out: std.ArrayListUnmanaged(Line) = .empty;
    var fence: ?struct { ch: u8, len: usize } = null;

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const text = std.mem.trimRight(u8, raw, "\r");
        const trimmed = std.mem.trimLeft(u8, text, " \t");
        var in_fence = fence != null;

        if (fenceMarker(trimmed)) |m| {
            if (fence) |open| {
                if (m.ch == open.ch and m.len >= open.len) fence = null;
            } else {
                fence = .{ .ch = m.ch, .len = m.len };
                in_fence = true;
            }
        }
        try out.append(arena, .{ .text = text, .in_fence = in_fence });
    }
    // splitScalar liefert nach einem abschließenden \n eine leere Zeile.
    if (out.items.len > 0 and out.items[out.items.len - 1].text.len == 0) {
        _ = out.pop();
    }
    return out.toOwnedSlice(arena);
}

fn fenceMarker(trimmed: []const u8) ?struct { ch: u8, len: usize } {
    if (trimmed.len < 3) return null;
    const ch = trimmed[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == ch) n += 1;
    if (n < 3) return null;
    return .{ .ch = ch, .len = n };
}

const Kv = struct { key: []const u8, value: []const u8, spot: bool };

const Comment = struct {
    /// Leer, wenn der Kommentar keine Direktiven enthält — dann ist er Notiz.
    directives: []const Kv,
    note: []const u8,
};

fn scanComments(arena: std.mem.Allocator, lines: []Line) ![]Comment {
    var out: std.ArrayListUnmanaged(Comment) = .empty;

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        if (lines[i].in_fence) continue;
        const trimmed = std.mem.trimLeft(u8, lines[i].text, " \t");
        if (!std.mem.startsWith(u8, trimmed, "<!--")) continue;

        var end = i;
        while (end < lines.len and std.mem.indexOf(u8, lines[end].text, "-->") == null) end += 1;
        if (end >= lines.len) continue; // unabgeschlossen: als Text behandeln

        var inner: std.ArrayListUnmanaged(u8) = .empty;
        var j = i;
        while (j <= end) : (j += 1) {
            var piece = lines[j].text;
            if (j == i) piece = piece[std.mem.indexOf(u8, piece, "<!--").? + 4 ..];
            if (j == end) piece = piece[0..std.mem.indexOf(u8, piece, "-->").?];
            if (j > i) try inner.append(arena, '\n');
            try inner.appendSlice(arena, piece);
        }

        const idx = out.items.len;
        for (lines[i .. end + 1]) |*l| l.comment = idx;
        try out.append(arena, try classifyComment(arena, inner.items));
        i = end;
    }
    return out.toOwnedSlice(arena);
}

/// Ein Kommentar ist genau dann Direktivblock, wenn jede nicht-leere Zeile ein
/// bekanntes `key: value` ist. Sonst behandelt Marp ihn als Notiz.
fn classifyComment(arena: std.mem.Allocator, inner: []const u8) !Comment {
    var kvs: std.ArrayListUnmanaged(Kv) = .empty;
    var it = std.mem.splitScalar(u8, inner, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const kv = splitKeyValue(line) orelse return note(arena, inner);
        const spot = std.mem.startsWith(u8, kv.key, "_");
        const key = if (spot) kv.key[1..] else kv.key;
        if (!isGlobalKey(key) and !isLocalKey(key)) return note(arena, inner);
        try kvs.append(arena, .{ .key = key, .value = kv.value, .spot = spot });
    }
    if (kvs.items.len == 0) return note(arena, inner);
    return .{ .directives = try kvs.toOwnedSlice(arena), .note = "" };
}

fn note(arena: std.mem.Allocator, inner: []const u8) !Comment {
    return .{ .directives = &.{}, .note = try arena.dupe(u8, std.mem.trim(u8, inner, " \t\r\n")) };
}

// --- Direktiven ----------------------------------------------------------

fn splitKeyValue(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    if (key.len == 0) return null;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
        value = value[1 .. value.len - 1];
    }
    return .{ .key = key, .value = value };
}

const global_keys = [_][]const u8{ "theme", "style", "size", "headingDivider" };

fn isGlobalKey(key: []const u8) bool {
    for (global_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn isLocalKey(key: []const u8) bool {
    const keys = [_][]const u8{
        "paginate",        "class",           "header",         "footer",             "color",
        "backgroundColor", "backgroundImage", "backgroundSize", "backgroundPosition", "backgroundRepeat",
    };
    for (keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn applyGlobal(g: *Global, key: []const u8, value: []const u8, arena: std.mem.Allocator) !bool {
    if (std.mem.eql(u8, key, "theme")) {
        g.theme = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "style")) {
        g.style = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "size")) {
        g.size = parseSize(value);
    } else if (std.mem.eql(u8, key, "headingDivider")) {
        g.heading_divider = std.fmt.parseInt(u8, value, 10) catch 0;
        if (g.heading_divider > 6) g.heading_divider = 6;
    } else return false;
    return true;
}

fn applyLocal(l: *Local, key: []const u8, value: []const u8, arena: std.mem.Allocator) !bool {
    if (std.mem.eql(u8, key, "paginate")) {
        l.paginate = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "class")) {
        l.class = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "header")) {
        l.header = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "footer")) {
        l.footer = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "color")) {
        l.color = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "backgroundColor")) {
        l.background_color = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "backgroundImage")) {
        l.background_image = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "backgroundSize")) {
        l.background_size = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "backgroundPosition")) {
        l.background_position = try dupeOrNull(arena, value);
    } else if (std.mem.eql(u8, key, "backgroundRepeat")) {
        l.background_repeat = try dupeOrNull(arena, value);
    } else return false;
    return true;
}

/// Marp löscht eine vererbte Direktive, wenn der Wert leer oder `""` ist.
fn dupeOrNull(arena: std.mem.Allocator, value: []const u8) !?[]const u8 {
    if (value.len == 0) return null;
    return try arena.dupe(u8, value);
}

fn parseSize(value: []const u8) Size {
    if (std.mem.eql(u8, value, "4:3")) return .{ .w = 960, .h = 720 };
    return .{ .w = 1280, .h = 720 };
}

// --- Zeilenklassifikation ------------------------------------------------

fn isRuler(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len < 3) return false;
    for (t) |c| {
        if (c != '-') return false;
    }
    return true;
}

fn isBlankTail(body: []const u8) bool {
    if (body.len == 0) return true;
    // body endet immer auf '\n'; davor muss eine leere Zeile stehen.
    const without_last = body[0 .. body.len - 1];
    const start = if (std.mem.lastIndexOfScalar(u8, without_last, '\n')) |n| n + 1 else 0;
    return std.mem.trim(u8, without_last[start..], " \t\r").len == 0;
}

fn headingLevel(text: []const u8) u8 {
    const t = std.mem.trimLeft(u8, text, " \t");
    var n: u8 = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return 0;
    if (n < t.len and t[n] != ' ' and t[n] != '\t') return 0;
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isMarpDeck erkennt marp: true im Front-Matter" {
    try testing.expect(isMarpDeck("---\nmarp: true\n---\n\n# Titel\n"));
    try testing.expect(isMarpDeck("---\r\ntheme: gaia\r\nmarp: true\r\n---\r\n"));
}

test "isMarpDeck lehnt gewöhnliches Markdown ab" {
    try testing.expect(!isMarpDeck("# Titel\n\nText\n"));
    try testing.expect(!isMarpDeck("---\ntitle: Notiz\n---\n\n# Titel\n"));
    try testing.expect(!isMarpDeck("---\nmarp: false\n---\n"));
    try testing.expect(!isMarpDeck(""));
    // marp: true erst im Rumpf zählt nicht.
    try testing.expect(!isMarpDeck("# Titel\n\nmarp: true\n"));
}

test "isMarpDeckFile liest nur den Dateikopf und erkennt Decks auf der Platte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "deck.md", .data = "---\nmarp: true\n---\n\n# Eins\n" });
    try tmp.dir.writeFile(.{ .sub_path = "plain.md", .data = "# Notiz\n\nmarp: true\n" });
    const deck_path = try tmp.dir.realpathAlloc(testing.allocator, "deck.md");
    defer testing.allocator.free(deck_path);
    const plain_path = try tmp.dir.realpathAlloc(testing.allocator, "plain.md");
    defer testing.allocator.free(plain_path);
    const missing_path = try std.fs.path.join(testing.allocator, &.{ std.fs.path.dirname(deck_path).?, "fehlt.md" });
    defer testing.allocator.free(missing_path);

    try testing.expect(isMarpDeckFile(deck_path));
    try testing.expect(!isMarpDeckFile(plain_path));
    try testing.expect(!isMarpDeckFile(missing_path));
}

test "parse verweigert Nicht-Decks" {
    try testing.expectError(error.NotAMarpDeck, parse(testing.allocator, "# Nur Markdown\n"));
}

test "parse trennt Folien an --- und lässt das Front-Matter weg" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\# Eins
        \\
        \\---
        \\
        \\# Zwei
        \\
        \\---
        \\
        \\# Drei
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expectEqual(@as(usize, 3), deck.slides.len);
    try testing.expectEqualStrings("# Eins", deck.slides[0].markdown);
    try testing.expectEqualStrings("# Zwei", deck.slides[1].markdown);
    try testing.expectEqualStrings("# Drei", deck.slides[2].markdown);
}

test "parse trennt nicht innerhalb eines Code-Zauns" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\# Eins
        \\
        \\```yaml
        \\---
        \\key: value
        \\---
        \\```
        \\
        \\---
        \\
        \\# Zwei
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expectEqual(@as(usize, 2), deck.slides.len);
    try testing.expect(std.mem.indexOf(u8, deck.slides[0].markdown, "key: value") != null);
    try testing.expectEqualStrings("# Zwei", deck.slides[1].markdown);
}

test "parse liest globale Direktiven aus dem Front-Matter" {
    const src =
        \\---
        \\marp: true
        \\theme: gaia
        \\size: 4:3
        \\---
        \\
        \\# Eins
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expectEqualStrings("gaia", deck.global.theme.?);
    try testing.expectEqual(@as(u32, 960), deck.global.size.w);
    try testing.expectEqual(@as(u32, 720), deck.global.size.h);
}

test "parse nutzt 16:9 als Standardgröße" {
    var deck = try parse(testing.allocator, "---\nmarp: true\n---\n\n# Eins\n");
    defer deck.deinit();

    try testing.expectEqual(@as(u32, 1280), deck.global.size.w);
    try testing.expectEqual(@as(u32, 720), deck.global.size.h);
    try testing.expect(deck.global.theme == null);
}

test "parse übernimmt lokale Direktiven aus dem Front-Matter für alle Folien" {
    const src =
        \\---
        \\marp: true
        \\paginate: true
        \\footer: Fußzeile
        \\---
        \\
        \\# Eins
        \\
        \\---
        \\
        \\# Zwei
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    for (deck.slides) |slide| {
        try testing.expect(slide.local.paginate);
        try testing.expectEqualStrings("Fußzeile", slide.local.footer.?);
    }
}

test "lokale Direktive im Kommentar vererbt sich auf die folgenden Folien" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\# Eins
        \\
        \\---
        \\
        \\<!-- paginate: true -->
        \\
        \\# Zwei
        \\
        \\---
        \\
        \\# Drei
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expect(!deck.slides[0].local.paginate);
    try testing.expect(deck.slides[1].local.paginate);
    try testing.expect(deck.slides[2].local.paginate);
}

test "Spot-Direktive mit Unterstrich gilt nur für ihre Folie" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\# Eins
        \\
        \\---
        \\
        \\<!-- _class: lead -->
        \\
        \\# Zwei
        \\
        \\---
        \\
        \\# Drei
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expect(deck.slides[0].local.class == null);
    try testing.expectEqualStrings("lead", deck.slides[1].local.class.?);
    try testing.expect(deck.slides[2].local.class == null);
}

test "Direktiv-Kommentare verschwinden aus dem Folien-Markdown" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\<!-- _backgroundColor: #123456
        \\     _color: white -->
        \\
        \\# Eins
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expectEqualStrings("# Eins", deck.slides[0].markdown);
    try testing.expectEqualStrings("#123456", deck.slides[0].local.background_color.?);
    try testing.expectEqualStrings("white", deck.slides[0].local.color.?);
    try testing.expectEqual(@as(usize, 0), deck.slides[0].notes.len);
}

test "Kommentare ohne Direktiven werden zu Notizen" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\# Eins
        \\
        \\<!-- Hier langsam sprechen -->
        \\
        \\Text
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expectEqual(@as(usize, 1), deck.slides[0].notes.len);
    try testing.expectEqualStrings("Hier langsam sprechen", deck.slides[0].notes[0]);
    try testing.expect(std.mem.indexOf(u8, deck.slides[0].markdown, "sprechen") == null);
    try testing.expect(std.mem.indexOf(u8, deck.slides[0].markdown, "Text") != null);
}

test "headingDivider trennt an Überschriften" {
    const src =
        \\---
        \\marp: true
        \\headingDivider: 2
        \\---
        \\
        \\# Eins
        \\
        \\## Zwei
        \\
        \\Text
        \\
        \\### Kein Trenner
        \\
        \\## Drei
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expectEqual(@as(u8, 2), deck.global.heading_divider);
    try testing.expectEqual(@as(usize, 3), deck.slides.len);
    try testing.expectEqualStrings("# Eins", deck.slides[0].markdown);
    try testing.expect(std.mem.startsWith(u8, deck.slides[1].markdown, "## Zwei"));
    try testing.expect(std.mem.indexOf(u8, deck.slides[1].markdown, "### Kein Trenner") != null);
    try testing.expectEqualStrings("## Drei", deck.slides[2].markdown);
}

test "globale Direktive im Kommentar gilt rückwirkend fürs ganze Deck" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\# Eins
        \\
        \\---
        \\
        \\<!-- theme: uncover -->
        \\
        \\# Zwei
        \\
    ;
    var deck = try parse(testing.allocator, src);
    defer deck.deinit();

    try testing.expectEqualStrings("uncover", deck.global.theme.?);
    try testing.expectEqual(@as(usize, 2), deck.slides.len);
}

test "leeres Deck ohne Rumpf hat eine leere Folie" {
    var deck = try parse(testing.allocator, "---\nmarp: true\n---\n");
    defer deck.deinit();

    try testing.expectEqual(@as(usize, 1), deck.slides.len);
    try testing.expectEqualStrings("", deck.slides[0].markdown);
}
