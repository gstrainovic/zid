//! Eingebaute Schrift als Datei bereitstellen.
//!
//! Auf Linux lädt FreeType die Schrift direkt aus dem Binary. DirectWrite unter
//! Windows kann das nicht: es will einen Dateipfad. Statt dem Nutzer einen
//! `fonts`-Ordner neben die exe zu legen, schreibt zid die eingebettete Schrift
//! einmalig in sein eigenes Datenverzeichnis und lädt sie von dort. Das Paket
//! bleibt damit eine einzige Datei.

const std = @import("std");

/// Zielpfad der entpackten Schrift: `<AppData>/zid/fonts/<name>`.
/// Der Aufrufer gibt den Pfad frei.
pub fn cachePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const base = try std.fs.getAppDataDir(allocator, "zid");
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "fonts", name });
}

/// Schrift ins Datenverzeichnis schreiben, falls sie dort fehlt oder eine andere
/// Länge hat (neue zid-Version, abgebrochener Schreibvorgang). Rückgabe ist der
/// Pfad zur Datei; der Aufrufer gibt ihn frei.
pub fn ensure(allocator: std.mem.Allocator, name: []const u8, data: []const u8) ![]u8 {
    const path = try cachePath(allocator, name);
    errdefer allocator.free(path);

    if (upToDate(path, data.len)) return path;

    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    try std.fs.cwd().makePath(dir);

    // Erst vollständig schreiben, dann umbenennen: ein Abbruch hinterlässt sonst
    // eine halbe Schrift, die FreeType und DirectWrite beide ablehnen.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = data });
    try std.fs.cwd().rename(tmp_path, path);
    return path;
}

fn upToDate(path: []const u8, len: usize) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.size == len;
}

const testing = std.testing;

test "cachePath endet auf fonts/<name> unter zid" {
    const p = try cachePath(testing.allocator, "X.ttf");
    defer testing.allocator.free(p);
    const sep = std.fs.path.sep_str;
    try testing.expect(std.mem.endsWith(u8, p, "zid" ++ sep ++ "fonts" ++ sep ++ "X.ttf"));
}

test "ensure schreibt die Datei und meldet sie beim zweiten Mal als vorhanden" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);

    const target = try std.fs.path.join(testing.allocator, &.{ dir, "fonts", "X.ttf" });
    defer testing.allocator.free(target);

    try testing.expect(!upToDate(target, 3));
    try std.fs.cwd().makePath(std.fs.path.dirname(target).?);
    try std.fs.cwd().writeFile(.{ .sub_path = target, .data = "abc" });
    try testing.expect(upToDate(target, 3));
    // Andere Länge (neue Version) gilt als veraltet.
    try testing.expect(!upToDate(target, 4));
}
