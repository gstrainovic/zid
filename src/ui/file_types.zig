const std = @import("std");

pub const FileKind = enum {
    text,
    image,
    pdf,
    terminal,
    markdown_preview,
    chat,
    /// Inhalt sieht nicht nach Text aus: der Tab zeigt nur einen Hinweis, kein Buffer wird geladen.
    binary,
    /// Git-Verlauf eines Repos oder einer Datei (`git-history://…`, siehe git_history.zig)
    git_history,
    /// Diff-Editor einer Datei in einem Commit (`git-diff://…`, siehe git_diff.zig)
    git_diff,
    /// Multi-File-Diff eines Commits (`git-commit://…`, siehe git_scm.zig)
    git_commit,
};

/// Dateiart nach Endung (Bild, PDF, sonst Text). Kennt den Inhalt nicht.
pub fn getFileKind(path: []const u8) FileKind {
    // Präfix wie git_history.scheme; das Modul steht hier nicht zur Verfügung (eigenes Test-Root)
    if (std.mem.startsWith(u8, path, "git-history://")) return .git_history;
    if (std.mem.startsWith(u8, path, "git-diff://")) return .git_diff;
    if (std.mem.startsWith(u8, path, "git-commit://")) return .git_commit;
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return .pdf;
    const images = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".svg" };

    // Einfacher Case-Insensitive Check ohne Buffer-Stress
    for (images) |img_ext| {
        if (std.ascii.eqlIgnoreCase(ext, img_ext)) return .image;
    }
    return .text;
}

/// Wie viele Bytes vom Dateianfang für die Binärerkennung gelesen werden (wie Zed).
pub const analysis_bytes: usize = 1024;

/// Dateiart nach Endung und Inhalt: Textdateien, deren erste `analysis_bytes` nach
/// Binärdaten aussehen, werden `.binary`. Nicht lesbare oder fehlende Dateien bleiben
/// `.text` (neue Datei, Fehler zeigt später der Lader).
pub fn detectFileKind(path: []const u8) FileKind {
    const kind = getFileKind(path);
    if (kind != .text) return kind;

    const file = std.fs.cwd().openFile(path, .{}) catch return .text;
    defer file.close();
    var head: [analysis_bytes]u8 = undefined;
    const n = file.readAll(&head) catch return .text;
    return if (looksBinary(head[0..n])) .binary else .text;
}

/// Heuristik wie Zeds `analyze_byte_content` (crates/language/src/file_content.rs):
/// bekannte Binär-Header, NUL-Anteil ab 1/16, sonst über 8 % nicht textartige Bytes.
/// UTF-16 gilt hier ebenfalls als binär, weil der Editor es nicht dekodiert.
pub fn looksBinary(bytes: []const u8) bool {
    if (bytes.len < 2) return false;
    if (hasKnownBinaryHeader(bytes)) return true;

    const limit: usize = @min(bytes.len, analysis_bytes); // @min würde auf u11 verengen
    var null_count: usize = 0;
    var non_text_count: usize = 0;
    for (bytes[0..limit]) |byte| {
        const text_like = switch (byte) {
            0 => false,
            '\t', '\n', '\r', 0x0c => true,
            0x20...0x7e => true,
            // UTF-8-Folgebytes und -Startbytes, Einzelbyte-Encodings
            0x80...0xbf, 0xc2...0xf4 => true,
            else => false,
        };
        if (byte == 0) null_count += 1;
        if (!text_like) non_text_count += 1;
    }

    if (null_count > 0 and null_count >= limit / 16) return true;
    return non_text_count * 100 >= limit * 8;
}

fn hasKnownBinaryHeader(bytes: []const u8) bool {
    const headers = [_][]const u8{
        "%PDF-",             "PK\x03\x04",   "PK\x05\x06",       "PK\x07\x08",
        "\x89PNG\r\n\x1a\n", "\xFF\xD8\xFF", "GIF87a",           "GIF89a",
        "RIFF",              "OggS",         "\x7fELF",          "\x1f\x8b",
        "\xFD7zXZ\x00",      "Rar!\x1a\x07", "\xCA\xFE\xBA\xBE",
    };
    for (headers) |h| {
        if (std.mem.startsWith(u8, bytes, h)) return true;
    }
    return false;
}

/// „4,2 MB“ / „318,0 KB“ / „12 Bytes“ — Dezimalpräfixe wie im Dateimanager, deutsches Komma.
pub fn formatFileSize(alloc: std.mem.Allocator, bytes: u64) ![]const u8 {
    if (bytes < 1000) return std.fmt.allocPrint(alloc, "{d} Bytes", .{bytes});
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var value: f64 = @as(f64, @floatFromInt(bytes)) / 1000;
    var unit: usize = 0;
    while (value >= 1000 and unit + 1 < units.len) : (unit += 1) value /= 1000;
    const tenths: u64 = @intFromFloat(@round(value * 10));
    return std.fmt.allocPrint(alloc, "{d},{d} {s}", .{ tenths / 10, tenths % 10, units[unit] });
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

test "git-history://-Pfade sind History-Tabs, ohne die Platte zu lesen" {
    try std.testing.expectEqual(FileKind.git_history, getFileKind("git-history://repo:/home/u/p"));
    try std.testing.expectEqual(FileKind.git_history, detectFileKind("git-history://file:/home/u/p/a.png"));
    try std.testing.expectEqual(FileKind.git_diff, getFileKind("git-diff://abc\x1fdef\x1f/r\x1fa.png\x1fa.png"));
    try std.testing.expectEqual(FileKind.git_commit, getFileKind("git-commit://abc\x1fdef\x1f/r\x1fBetreff.png"));
}

test "getFileKind: Endungen" {
    try testing.expectEqual(FileKind.pdf, getFileKind("/a/b.PDF"));
    try testing.expectEqual(FileKind.image, getFileKind("x.png"));
    try testing.expectEqual(FileKind.text, getFileKind("main.zig"));
    try testing.expectEqual(FileKind.text, getFileKind("osd.traineddata"));
}

test "looksBinary: Text bleibt Text" {
    try testing.expect(!looksBinary(""));
    try testing.expect(!looksBinary("a"));
    try testing.expect(!looksBinary("const std = @import(\"std\");\n\npub fn main() void {}\n"));
    try testing.expect(!looksBinary("Grüße aus Zürich — ä ö ü ß € 日本語\r\n\tTab\x0c"));
    // Ein einzelnes NUL in viel Text (z. B. defekte Zeile) macht noch keine Binärdatei
    var buf: [1024]u8 = undefined;
    @memset(&buf, 'x');
    buf[500] = 0;
    try testing.expect(!looksBinary(&buf));
}

test "looksBinary: bekannte Header" {
    try testing.expect(looksBinary("\x89PNG\r\n\x1a\nrest"));
    try testing.expect(looksBinary("%PDF-1.7\n"));
    try testing.expect(looksBinary("PK\x03\x04abc"));
    try testing.expect(looksBinary("\xFF\xD8\xFF\xE0"));
    try testing.expect(looksBinary("GIF89a"));
}

test "looksBinary: NUL-lastige und Steuerzeichen-lastige Daten" {
    // ELF-artiger Anfang: Magic + viele Nullen
    var elf: [256]u8 = [_]u8{0} ** 256;
    @memcpy(elf[0..4], "\x7fELF");
    try testing.expect(looksBinary(&elf));

    // Pseudo-zufällige Bytes wie in tmp/odd_binary.bin
    var rnd = std.Random.DefaultPrng.init(7);
    var blob: [3000]u8 = undefined;
    rnd.random().bytes(&blob);
    try testing.expect(looksBinary(&blob));

    // Nur Steuerzeichen (kein NUL), über 8 %
    var ctl: [100]u8 = [_]u8{'a'} ** 100;
    for (0..10) |i| ctl[i * 10] = 0x01;
    try testing.expect(looksBinary(&ctl));
    // Unter 8 % bleibt Text
    var few: [100]u8 = [_]u8{'a'} ** 100;
    few[0] = 0x01;
    few[50] = 0x02;
    try testing.expect(!looksBinary(&few));
}

test "looksBinary: UTF-16 wird nicht dekodiert und gilt als binär" {
    var utf16: [64]u8 = undefined;
    for (0..32) |i| {
        utf16[i * 2] = 'a';
        utf16[i * 2 + 1] = 0;
    }
    try testing.expect(looksBinary(&utf16));
}

test "detectFileKind: liest den Dateianfang" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "text.dat", .data = "hello\nworld\n" });
    var blob: [2048]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    prng.random().bytes(&blob);
    try tmp.dir.writeFile(.{ .sub_path = "model.traineddata", .data = &blob });
    try tmp.dir.writeFile(.{ .sub_path = "pic.png", .data = "not really" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var p1: [std.fs.max_path_bytes]u8 = undefined;
    var p2: [std.fs.max_path_bytes]u8 = undefined;
    var p3: [std.fs.max_path_bytes]u8 = undefined;
    var p4: [std.fs.max_path_bytes]u8 = undefined;

    try testing.expectEqual(FileKind.text, detectFileKind(try std.fmt.bufPrint(&p1, "{s}/text.dat", .{dir_path})));
    try testing.expectEqual(FileKind.binary, detectFileKind(try std.fmt.bufPrint(&p2, "{s}/model.traineddata", .{dir_path})));
    // Endung gewinnt: Bilder gehen an den Bild-Viewer, egal was drin steht
    try testing.expectEqual(FileKind.image, detectFileKind(try std.fmt.bufPrint(&p3, "{s}/pic.png", .{dir_path})));
    // Fehlende Datei = neue Textdatei
    try testing.expectEqual(FileKind.text, detectFileKind(try std.fmt.bufPrint(&p4, "{s}/neu.txt", .{dir_path})));
}

test "formatFileSize" {
    const a = testing.allocator;
    inline for (.{
        .{ 12, "12 Bytes" },
        .{ 999, "999 Bytes" },
        .{ 1000, "1,0 KB" },
        .{ 318_000, "318,0 KB" },
        .{ 4_200_000, "4,2 MB" },
        .{ 1_500_000_000, "1,5 GB" },
    }) |case| {
        const s = try formatFileSize(a, case[0]);
        defer a.free(s);
        try testing.expectEqualStrings(case[1], s);
    }
}
