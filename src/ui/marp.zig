//! Erkennt Marp-Decks: eine Markdown-Datei ist eines, wenn ihr YAML-Front-Matter
//! `marp: true` setzt (https://marpit.marp.app/directives).
//!
//! Mehr muss zid nicht verstehen: Vorschau und PDF erzeugt marp-cli
//! (`rendering/marp_cli.zig`), Marps eigener Konverter. Kein Clay, keine Datei-IO
//! außer `isMarpDeckFile` — damit alles unit-testbar bleibt.

const std = @import("std");

/// Erkennt ein Marp-Deck an `marp: true` im Front-Matter.
pub fn isMarpDeck(source: []const u8) bool {
    const yaml = frontMatter(source) orelse return false;
    var it = std.mem.splitScalar(u8, yaml, '\n');
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

/// YAML zwischen `---` in der ersten Zeile und dem nächsten `---` oder `...`.
fn frontMatter(source: []const u8) ?[]const u8 {
    const first_nl = std.mem.indexOfScalar(u8, source, '\n') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, source[0..first_nl], " \t\r"), "---")) return null;

    var idx = first_nl + 1;
    const yaml_start = idx;
    while (idx <= source.len) {
        const nl = std.mem.indexOfScalarPos(u8, source, idx, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[idx..nl], " \t\r");
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "...")) return source[yaml_start..idx];
        if (nl >= source.len) break;
        idx = nl + 1;
    }
    return null;
}

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isMarpDeck erkennt marp: true im Front-Matter" {
    try testing.expect(isMarpDeck("---\nmarp: true\n---\n\n# Titel\n"));
    try testing.expect(isMarpDeck("---\r\ntheme: gaia\r\nmarp: true\r\n---\r\n"));
    try testing.expect(isMarpDeck("---\nstyle: |\n  section { font-size: 24px; }\nmarp: \"true\"\n---\n"));
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
