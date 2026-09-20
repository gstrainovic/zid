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

/// `.zip` nach `dest_dir` auspacken. Zigs Entpacker kennt kein `strip_components`;
/// das Windows-Archiv braucht es auch nicht, es liegt flach.
pub fn extractZip(archive: []const u8, dest_dir: []const u8) !void {
    var file = try std.fs.cwd().openFile(archive, .{});
    defer file.close();
    var read_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(&read_buf);

    try std.fs.cwd().makePath(dest_dir);
    var dir = try std.fs.cwd().openDir(dest_dir, .{});
    defer dir.close();

    try std.zip.extract(dir, &fr, .{});
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
