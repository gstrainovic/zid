//! Suchpfade für mitgelieferte Dateien. Linux bettet Schrift, Logo und Shader ins
//! Binary ein; unter Windows lädt DirectWrite eine Schrift nur aus einer Datei
//! (`FreeTypeFace.initFromMemory` hat dort keine Entsprechung). Die Schrift liegt
//! deshalb neben der exe, und dieses Modul sagt, wo gesucht wird.
//!
//! Reine Funktion über Zeichenketten, damit die Reihenfolge ohne Dateisystem
//! testbar bleibt; wer sie benutzt, probiert die Kandidaten der Reihe nach.

const std = @import("std");

/// Suchreihenfolge für `rel` (z. B. "fonts/JetBrainsMono-Regular.ttf"):
/// 1. Arbeitsverzeichnis — der Entwicklungsbaum, `zig build run` im Repo.
/// 2. neben der exe — so liegt es im Windows-ZIP.
/// 3. `<exe>/../share/zid/` — Unix-Installationslayout (`/usr/bin`, `/usr/share/zid`).
///
/// Ohne `exe_dir` bleibt nur der erste Eintrag. Der Aufrufer gibt den Speicher frei
/// (`freeCandidates`).
pub fn candidates(
    allocator: std.mem.Allocator,
    exe_dir: ?[]const u8,
    rel: []const u8,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    try out.append(allocator, try allocator.dupe(u8, rel));
    if (exe_dir) |dir| {
        try out.append(allocator, try std.fs.path.join(allocator, &.{ dir, rel }));
        try out.append(allocator, try std.fs.path.join(allocator, &.{ dir, "..", "share", "zid", rel }));
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeCandidates(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |p| allocator.free(p);
    allocator.free(list);
}

/// Erster Kandidat, den es wirklich gibt. Null, wenn keiner existiert; der Aufrufer
/// gibt den zurückgegebenen Pfad frei.
pub fn find(allocator: std.mem.Allocator, exe_dir: ?[]const u8, rel: []const u8) !?[]const u8 {
    const list = try candidates(allocator, exe_dir, rel);
    defer freeCandidates(allocator, list);

    for (list) |p| {
        const ok = if (std.fs.path.isAbsolute(p))
            std.fs.accessAbsolute(p, .{})
        else
            std.fs.cwd().access(p, .{});
        if (ok) |_| return try allocator.dupe(u8, p) else |_| {}
    }
    return null;
}

const testing = std.testing;

test "ohne exe-Verzeichnis bleibt nur der relative Pfad" {
    const list = try candidates(testing.allocator, null, "fonts/x.ttf");
    defer freeCandidates(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("fonts/x.ttf", list[0]);
}

test "Arbeitsverzeichnis zuerst, dann neben der exe, dann share" {
    const sep = std.fs.path.sep_str;
    const list = try candidates(testing.allocator, "/opt/zid/bin", "fonts/x.ttf");
    defer freeCandidates(testing.allocator, list);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("fonts/x.ttf", list[0]);
    try testing.expectEqualStrings("/opt/zid/bin" ++ sep ++ "fonts/x.ttf", list[1]);
    try testing.expectEqualStrings("/opt/zid/bin" ++ sep ++ ".." ++ sep ++ "share" ++ sep ++ "zid" ++ sep ++ "fonts/x.ttf", list[2]);
}

test "find liefert den Kandidaten, den es gibt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("fonts");
    try tmp.dir.writeFile(.{ .sub_path = "fonts/x.ttf", .data = "ttf" });

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const hit = try find(testing.allocator, dir_path, "fonts/x.ttf");
    defer if (hit) |h| testing.allocator.free(h);
    try testing.expect(hit != null);
    try testing.expect(std.mem.endsWith(u8, hit.?, "x.ttf"));
}

test "find liefert null, wenn nichts da ist" {
    const hit = try find(testing.allocator, "/nicht/vorhanden", "fonts/gibtsnicht.ttf");
    try testing.expect(hit == null);
}
