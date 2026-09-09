//! Pfade für Listen darstellen: Dateiname zuerst, Ordner danach und gekürzt.
//!
//! Der Picker zeigte bisher den ganzen Pfad von links und schnitt rechts ab.
//! In tiefen Bäumen verschwand damit ausgerechnet der Dateiname, also der Teil,
//! der die Zeilen unterscheidet. VSCode und Zed stellen den Namen deshalb nach
//! vorn; Zed kürzt zusätzlich gemeinsame Segmente, snacks.picker kürzt in der
//! Mitte. Dieses Modul macht beides: Name zuerst, Ordner mittig gekürzt.
//!
//! Reine Logik, keine Clay-Abhängigkeit. Zeichen statt Pixel, weil die einzige
//! Schrift im Projekt eine Monospace ist.

const std = @import("std");

/// Auslassungszeichen in der Mitte eines gekürzten Pfades.
pub const ellipsis = "…";

pub const Parts = struct {
    /// Reiner Dateiname ohne Ordner.
    name: []const u8,
    /// Ordneranteil ohne abschließenden Schrägstrich; leer im Wurzelverzeichnis.
    dir: []const u8,
};

/// Zerlegt einen Pfad in Dateiname und Ordner.
pub fn split(path: []const u8) Parts {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return .{ .name = path, .dir = "" };
    return .{ .name = path[cut + 1 ..], .dir = path[0..cut] };
}

/// Kürzt `text` auf höchstens `max_chars` Zeichen, indem die Mitte durch ein
/// Auslassungszeichen ersetzt wird. Schreibt nach `buf` und liefert den Teil
/// davon zurück; passt der Text schon, kommt er unverändert zurück.
pub fn truncateMiddle(buf: []u8, text: []const u8, max_chars: usize) []const u8 {
    const total = std.unicode.utf8CountCodepoints(text) catch return text;
    if (total <= max_chars) return text;
    if (max_chars <= 1) return ellipsis;

    // Anfang verrät das Teilprojekt, Ende den Dateinamen — das Ende bekommt
    // deshalb den Rest, wenn die Zeichen ungerade aufgehen.
    const keep = max_chars - 1;
    const head_chars = keep / 2;
    const tail_chars = keep - head_chars;

    const head_end = byteIndexAt(text, head_chars);
    const tail_start = byteIndexAt(text, total - tail_chars);

    var written: usize = 0;
    written += copyInto(buf[written..], text[0..head_end]);
    written += copyInto(buf[written..], ellipsis);
    written += copyInto(buf[written..], text[tail_start..]);
    return buf[0..written];
}

/// Längster gemeinsamer Ordnerpräfix aller Pfade, auf Segmentgrenzen.
/// Leer, wenn es keinen gibt oder weniger als zwei Pfade übergeben werden.
pub fn commonPrefix(paths: []const []const u8) []const u8 {
    if (paths.len < 2) return "";

    var end: usize = 0; // Bytes des bisher gesicherten Präfixes
    var i: usize = 0;
    while (true) {
        // Nächstes Segment aus dem ersten Pfad holen.
        const rest = paths[0][end..];
        const seg_len = (std.mem.indexOfScalar(u8, rest, '/') orelse return prefixOr(paths[0], end, i)) + 1;
        const candidate = paths[0][0 .. end + seg_len];
        for (paths[1..]) |p| {
            if (!std.mem.startsWith(u8, p, candidate)) return prefixOr(paths[0], end, i);
        }
        end += seg_len;
        i += 1;
    }
}

/// Präfix ohne abschließenden Schrägstrich; leer, wenn kein Segment passte.
fn prefixOr(path: []const u8, end: usize, segments: usize) []const u8 {
    if (segments == 0 or end == 0) return "";
    return path[0 .. end - 1];
}

/// Byte-Offset des `n`-ten Zeichens.
fn byteIndexAt(text: []const u8, n: usize) usize {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var seen: usize = 0;
    while (seen < n) : (seen += 1) {
        _ = it.nextCodepointSlice() orelse break;
    }
    return it.i;
}

fn copyInto(dest: []u8, src: []const u8) usize {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "split trennt Name und Ordner" {
    const p = split("engines/BitNet/3rdparty/README.md");
    try testing.expectEqualStrings("README.md", p.name);
    try testing.expectEqualStrings("engines/BitNet/3rdparty", p.dir);
}

test "split ohne Ordner liefert leeren Ordner" {
    const p = split("README.md");
    try testing.expectEqualStrings("README.md", p.name);
    try testing.expectEqualStrings("", p.dir);
}

test "split kommt mit Sonderfällen klar" {
    try testing.expectEqualStrings("", split("").name);
    try testing.expectEqualStrings("", split("a/").name);
    try testing.expectEqualStrings("a", split("a/").dir);
}

test "truncateMiddle lässt kurze Texte in Ruhe" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("src/ui", truncateMiddle(&buf, "src/ui", 20));
    try testing.expectEqualStrings("src/ui", truncateMiddle(&buf, "src/ui", 6));
}

test "truncateMiddle kürzt in der Mitte und behält beide Enden" {
    var buf: [128]u8 = undefined;
    const out = truncateMiddle(&buf, "engines/BitNet/3rdparty/llama.cpp/examples", 20);
    try testing.expect(std.mem.startsWith(u8, out, "engines"));
    try testing.expect(std.mem.endsWith(u8, out, "examples"));
    try testing.expect(std.mem.indexOf(u8, out, ellipsis) != null);
    // Zeichen zählen, nicht Bytes: das Auslassungszeichen ist mehrere Bytes lang.
    try testing.expectEqual(@as(usize, 20), try std.unicode.utf8CountCodepoints(out));
}

test "truncateMiddle bricht mehrbyte-Zeichen nicht auf" {
    var buf: [128]u8 = undefined;
    const out = truncateMiddle(&buf, "ordner/äöü-sehr-lang/unterordner/tief", 15);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expectEqual(@as(usize, 15), try std.unicode.utf8CountCodepoints(out));
}

test "truncateMiddle bei winziger Obergrenze" {
    var buf: [128]u8 = undefined;
    const out = truncateMiddle(&buf, "abcdefghij", 1);
    try testing.expectEqualStrings(ellipsis, out);
}

test "commonPrefix findet den gemeinsamen Ordner" {
    const paths = [_][]const u8{
        "engines/BitNet/3rdparty/a/README.md",
        "engines/BitNet/3rdparty/a/build.gradle.kts",
        "engines/BitNet/3rdparty/a/src/main/Manifest.xml",
    };
    try testing.expectEqualStrings("engines/BitNet/3rdparty/a", commonPrefix(&paths));
}

test "commonPrefix schneidet nur an Segmentgrenzen" {
    const paths = [_][]const u8{ "src/uikit/a.zig", "src/ui/b.zig" };
    try testing.expectEqualStrings("src", commonPrefix(&paths));
}

test "commonPrefix ohne gemeinsamen Anteil ist leer" {
    const paths = [_][]const u8{ "src/a.zig", "test/b.zig" };
    try testing.expectEqualStrings("", commonPrefix(&paths));
    const one = [_][]const u8{"src/a.zig"};
    try testing.expectEqualStrings("", commonPrefix(&one));
    try testing.expectEqualStrings("", commonPrefix(&.{}));
}
