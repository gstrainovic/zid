//! Sicherungskopie vor dem Überschreiben beim Speichern: eine Kopie je Datei unter
//! `$XDG_DATA_HOME/vulkan-ed/backup/<name>.<hash>.bak` (bzw. ~/.local/share/…), wird bei jedem
//! Speichern ersetzt. Kein Verlauf, kein Müll neben der Datei. Reine Pfadlogik ist unit-getestet.

const std = @import("std");

/// Zielpfad der Sicherung für `file_path` unter `data_home` (owned).
pub fn backupPathFor(alloc: std.mem.Allocator, data_home: []const u8, file_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(file_path);
    const hash = std.hash.Wyhash.hash(0, file_path);
    return std.fmt.allocPrint(alloc, "{s}/vulkan-ed/backup/{s}.{x}.bak", .{ data_home, base, hash });
}

/// $XDG_DATA_HOME oder ~/.local/share (owned).
pub fn defaultDataHome(alloc: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |x| {
        if (x.len > 0) return alloc.dupe(u8, x);
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".local", "share" });
}

/// Vorhandene Datei nach `data_home` sichern; fehlt sie, gibt es nichts zu sichern.
pub fn backupInto(alloc: std.mem.Allocator, data_home: []const u8, file_path: []const u8) !void {
    std.fs.accessAbsolute(file_path, .{}) catch return;
    const dest = try backupPathFor(alloc, data_home, file_path);
    defer alloc.free(dest);
    if (std.fs.path.dirname(dest)) |dir| try std.fs.cwd().makePath(dir);
    try std.fs.copyFileAbsolute(file_path, dest, .{});
}

/// Wie backupInto mit dem Standard-Datenordner.
pub fn backup(alloc: std.mem.Allocator, file_path: []const u8) !void {
    const home = try defaultDataHome(alloc);
    defer alloc.free(home);
    try backupInto(alloc, home, file_path);
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

test "backupPathFor: Name bleibt lesbar, Hash trennt gleichnamige Dateien" {
    const a = testing.allocator;
    const p1 = try backupPathFor(a, "/data", "/proj/a/mod.zig");
    defer a.free(p1);
    const p2 = try backupPathFor(a, "/data", "/proj/b/mod.zig");
    defer a.free(p2);
    try testing.expect(std.mem.startsWith(u8, p1, "/data/vulkan-ed/backup/mod.zig."));
    try testing.expect(std.mem.endsWith(u8, p1, ".bak"));
    try testing.expect(!std.mem.eql(u8, p1, p2));
}

test "backupInto: kopiert die alte Version, fehlende Datei ist kein Fehler" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "alt" });
    const f = try std.fs.path.join(a, &.{ root, "f.txt" });
    defer a.free(f);
    try backupInto(a, root, f);
    const dest = try backupPathFor(a, root, f);
    defer a.free(dest);
    const copy = try std.fs.cwd().readFileAlloc(a, dest, 100);
    defer a.free(copy);
    try testing.expectEqualStrings("alt", copy);
    const missing = try std.fs.path.join(a, &.{ root, "nope.txt" });
    defer a.free(missing);
    try backupInto(a, root, missing);
}
