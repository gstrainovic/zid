//! Engine und Modell ins Datenverzeichnis holen und auspacken.
//!
//! Die Release-Archive von llama.cpp sind unterschiedlich gebaut: das Windows-ZIP
//! legt alles flach ab, das Linux-Tar hat einen Ordner `llama-<tag>/` davor. Beim
//! Auspacken wird diese Ebene deshalb plattformabhängig übersprungen.

const std = @import("std");
const builtin = @import("builtin");
const setup = @import("setup.zig");
const download = @import("download");

const log = std.log.scoped(.ai_setup);

/// Ebenen, die beim Auspacken des Engine-Archivs wegfallen.
pub fn stripComponents() u32 {
    return if (builtin.os.tag == .windows) 0 else 1;
}

/// `.tar.gz` nach `dest_dir` auspacken.
pub fn extractTarGz(archive: []const u8, dest_dir: []const u8, strip: u32) !void {
    var file = try std.fs.cwd().openFile(archive, .{});
    defer file.close();
    var read_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(&read_buf);

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&fr.interface, .gzip, &window);

    try std.fs.cwd().makePath(dest_dir);
    var dir = try std.fs.cwd().openDir(dest_dir, .{});
    defer dir.close();

    try std.tar.pipeToFileSystem(dir, &decomp.reader, .{
        .strip_components = strip,
        .mode_mode = .executable_bit_only,
    });
}

/// `.zip` nach `dest_dir` auspacken (Ablage wie im Archiv, kein `strip_components`).
///
/// Eigene Schleife statt `std.zip.extract`: das nutzt `flate.Decompress` mit eigenem
/// Fensterpuffer (indirekter Modus), und der endet in Zig 0.15.2 bei manchen Einträgen
/// in „reached unreachable“ (`unreachableRebase` in `writeMatch`); beim Zip von
/// chrome-headless-shell zuverlässig. Hier läuft der direkte Modus (leerer Puffer): der
/// Dekompressor schreibt in den Datei-Writer, dessen Puffer den Verlauf (32 KiB) hält.
/// Unterstützt `store` und `deflate`, wie `std.zip`.
pub fn extractZip(archive: []const u8, dest_dir: []const u8) !void {
    var file = try std.fs.cwd().openFile(archive, .{});
    defer file.close();
    var read_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(&read_buf);

    try std.fs.cwd().makePath(dest_dir);
    var dir = try std.fs.cwd().openDir(dest_dir, .{});
    defer dir.close();

    var iter = try std.zip.Iterator.init(&fr);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > name_buf.len) return error.ZipBadFilename;
        const name = name_buf[0..entry.filename_len];
        try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name);
        std.mem.replaceScalar(u8, name, '\\', '/');
        if (!safeZipName(name)) return error.ZipBadFilename;

        if (name[name.len - 1] == '/') {
            try dir.makePath(name[0 .. name.len - 1]);
            continue;
        }
        if (std.fs.path.dirname(name)) |parent| try dir.makePath(parent);

        try fr.seekTo(entry.file_offset);
        const local = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig)) return error.ZipBadFileOffset;
        try fr.seekTo(entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len);

        var out = try dir.createFile(name, .{});
        defer out.close();
        var out_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var fw = out.writer(&out_buf);
        switch (entry.compression_method) {
            .store => try fr.interface.streamExact64(&fw.interface, entry.uncompressed_size),
            .deflate => {
                var inflate: std.compress.flate.Decompress = .init(&fr.interface, .raw, &.{});
                try inflate.reader.streamExact64(&fw.interface, entry.uncompressed_size);
            },
            else => return error.UnsupportedCompressionMethod,
        }
        try fw.end();
    }
}

/// Relativ und ohne `..`-Teil: ein Eintrag darf nicht aus `dest_dir` herausführen.
fn safeZipName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, ':') != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Engine laden und auspacken. Danach liegt `llama-server` unter `engines/<tag>/`.
pub fn engine(allocator: std.mem.Allocator, root: []const u8, progress: *download.Progress) !void {
    const dir = try setup.engineDir(allocator, root);
    defer allocator.free(dir);

    const asset = setup.engineAsset();
    const archive = try std.fs.path.join(allocator, &.{ dir, asset });
    defer allocator.free(archive);

    const url = try setup.engineUrl(allocator);
    defer allocator.free(url);

    progress.total.store(35_000_000, .monotonic); // Richtwert für die Anzeige
    log.info("lade Engine: {s}", .{url});
    try download.toFile(allocator, url, archive, progress);

    if (std.mem.endsWith(u8, asset, ".zip"))
        try extractZip(archive, dir)
    else
        try extractTarGz(archive, dir, stripComponents());

    // Das Archiv wird nach dem Auspacken nicht mehr gebraucht.
    std.fs.cwd().deleteFile(archive) catch {};

    const exe = try setup.enginePath(allocator, root);
    defer allocator.free(exe);
    if (!setup.present(exe)) {
        log.err("llama-server fehlt nach dem Auspacken: {s}", .{exe});
        return error.EngineIncomplete;
    }
    log.info("Engine bereit: {s}", .{exe});
}

/// Modell laden (rund 2,7 GB).
pub fn model(allocator: std.mem.Allocator, root: []const u8, progress: *download.Progress) !void {
    const dest = try setup.modelPath(allocator, root);
    defer allocator.free(dest);

    progress.total.store(setup.model_bytes, .monotonic);
    log.info("lade Modell: {s}", .{setup.model_url});
    try download.toFile(allocator, setup.model_url, dest, progress);
    log.info("Modell bereit: {s}", .{dest});
}

const testing = std.testing;

test "safeZipName lässt nur Pfade innerhalb des Ziels zu" {
    try testing.expect(safeZipName("a/b.txt"));
    try testing.expect(safeZipName("chrome-headless-shell-win64/chrome.dll"));
    try testing.expect(!safeZipName("../x"));
    try testing.expect(!safeZipName("a/../../x"));
    try testing.expect(!safeZipName("/etc/passwd"));
    try testing.expect(!safeZipName("C:/x"));
}

test "strip hängt an der Plattform: Windows flach, sonst eine Ebene" {
    const expected: u32 = if (builtin.os.tag == .windows) 0 else 1;
    try testing.expectEqual(expected, stripComponents());
}

test "extractTarGz packt aus und überspringt die oberste Ebene" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // braucht tar im PATH

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);

    // Archiv mit der Struktur des echten Releases bauen: <prefix>/llama-server
    try tmp.dir.makePath("llama-b1/sub");
    try tmp.dir.writeFile(.{ .sub_path = "llama-b1/llama-server", .data = "binary" });
    try tmp.dir.writeFile(.{ .sub_path = "llama-b1/sub/lib.so", .data = "lib" });

    const tar_path = try std.fs.path.join(testing.allocator, &.{ base, "a.tar.gz" });
    defer testing.allocator.free(tar_path);
    var child = std.process.Child.init(&.{ "tar", "czf", tar_path, "-C", base, "llama-b1" }, testing.allocator);
    _ = try child.spawnAndWait();

    const out = try std.fs.path.join(testing.allocator, &.{ base, "out" });
    defer testing.allocator.free(out);
    try extractTarGz(tar_path, out, 1);

    const server = try std.fs.path.join(testing.allocator, &.{ out, "llama-server" });
    defer testing.allocator.free(server);
    try testing.expect(setup.present(server));

    const lib = try std.fs.path.join(testing.allocator, &.{ out, "sub", "lib.so" });
    defer testing.allocator.free(lib);
    try testing.expect(setup.present(lib));
}
