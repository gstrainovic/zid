//! Text zeichenweise durchgehen, ohne an kaputtem UTF-8 zu scheitern.
//!
//! zid zeichnet auch, was kein gültiges UTF-8 ist: Dateinamen kommen roh vom
//! Dateisystem, Dateiinhalte roh von der Platte. `std.unicode.Utf8View` prüft
//! nichts und bricht beim ersten falschen Byte mit `catch unreachable` ab — ein
//! einzelnes Byte riss damit den ganzen Editor mit.

const std = @import("std");

/// Nächsten Codepoint ab `i.*` lesen und `i.*` weiterrücken; ein ungültiges Byte oder eine
/// abgeschnittene Sequenz ergibt U+FFFD und rückt genau ein Byte weiter.
pub fn decodeLossy(text: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > text.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(text[i.* .. i.* + len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

/// Fehlt der Schrift `face` ein Zeichen dieses Textes? `face` braucht nur
/// `hasCodepoint(u21) bool`. ASCII wird übersprungen (das hat jede Schrift),
/// kaputte Bytes entscheiden nichts — für sie gibt es keine zweite Schrift.
pub fn hasMissingGlyph(text: []const u8, face: anytype) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < 0x80) {
            i += 1;
            continue;
        }
        const cp = decodeLossy(text, &i);
        if (cp == 0xFFFD) continue;
        if (!face.hasCodepoint(cp)) return true;
    }
    return false;
}

const testing = std.testing;

test "decodeLossy: gültige Sequenzen, kaputtes Byte und abgeschnittene Sequenz" {
    var i: usize = 0;
    const t = "a\xc3\xa4\xff\xe2\x82";
    try testing.expectEqual(@as(u21, 'a'), decodeLossy(t, &i));
    try testing.expectEqual(@as(u21, 0xE4), decodeLossy(t, &i));
    try testing.expectEqual(@as(u21, 0xFFFD), decodeLossy(t, &i));
    try testing.expectEqual(@as(usize, 4), i);
    try testing.expectEqual(@as(u21, 0xFFFD), decodeLossy(t, &i));
    try testing.expectEqual(@as(u21, 0xFFFD), decodeLossy(t, &i));
    try testing.expectEqual(t.len, i);
}

/// Schrift mit Latin-1, ohne Emoji — wie JetBrains Mono.
const LatinFace = struct {
    fn hasCodepoint(_: LatinFace, cp: u21) bool {
        return cp < 0x250;
    }
};

test "reiner ASCII-Text braucht keine zweite Schrift" {
    try testing.expect(!hasMissingGlyph("plain ascii 123", LatinFace{}));
}

test "Umlaute kennt die Schrift, Emoji nicht" {
    try testing.expect(!hasMissingGlyph("Grösse, Fuss, Straße", LatinFace{}));
    try testing.expect(hasMissingGlyph("fertig \u{1F527}", LatinFace{}));
}

test "kaputte Bytes stürzen nicht ab und lösen keinen Rückfall aus" {
    try testing.expect(!hasMissingGlyph("gut \xff\xfe kaputt", LatinFace{}));
    try testing.expect(!hasMissingGlyph("\xff", LatinFace{}));
    // Abgeschnittene Sequenz am Ende: drei Bytes angekündigt, eins da.
    try testing.expect(!hasMissingGlyph("abc\xe2", LatinFace{}));
}

test "kaputtes Byte vor einem Emoji verdeckt es nicht" {
    try testing.expect(hasMissingGlyph("\xff\u{2705}", LatinFace{}));
}
