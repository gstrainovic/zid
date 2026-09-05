//! Reine Operationen für den File-Explorer: Namens-Editierpuffer und
//! Dateisystem-Aktionen (Umbenennen, Löschen). Kein Clay, keine UI, damit
//! alles mit tmpDir testbar bleibt.

const std = @import("std");

pub const max_name_len = 255;

/// Editierpuffer für Inline-Umbenennen. Fester Speicher, UTF-8-bewusst.
pub const RenameEdit = struct {
    buf: [max_name_len]u8 = undefined,
    len: usize = 0,

    pub fn init(name: []const u8) RenameEdit {
        var e = RenameEdit{};
        const n = @min(name.len, max_name_len);
        @memcpy(e.buf[0..n], name[0..n]);
        e.len = n;
        return e;
    }

    pub fn text(self: *const RenameEdit) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn insertCodepoint(self: *RenameEdit, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.len + n > max_name_len) return;
        @memcpy(self.buf[self.len .. self.len + n], tmp[0..n]);
        self.len += n;
    }

    /// Entfernt das letzte Codepoint (nicht nur das letzte Byte).
    pub fn backspace(self: *RenameEdit) void {
        if (self.len == 0) return;
        var i = self.len - 1;
        // UTF-8-Fortsetzungsbytes (10xxxxxx) überspringen bis zum Startbyte
        while (i > 0 and (self.buf[i] & 0xC0) == 0x80) i -= 1;
        self.len = i;
    }
};

pub const RenameError = error{InvalidName} || std.fs.Dir.RenameError || std.mem.Allocator.Error;

/// Benennt die Datei oder den Ordner an `old_path` (absolut) innerhalb desselben
/// Verzeichnisses in `new_name` um. Liefert den neuen absoluten Pfad (owned).
/// Gleicher Name: kein Dateisystemzugriff, nur Kopie des Pfads.
pub fn renamePath(alloc: std.mem.Allocator, old_path: []const u8, new_name: []const u8) RenameError![]u8 {
    if (new_name.len == 0) return error.InvalidName;
    if (std.mem.eql(u8, new_name, ".") or std.mem.eql(u8, new_name, "..")) return error.InvalidName;
    if (std.mem.indexOfAny(u8, new_name, "/\\") != null) return error.InvalidName;

    const dir = std.fs.path.dirname(old_path) orelse return error.InvalidName;
    const new_path = try std.fs.path.join(alloc, &.{ dir, new_name });
    errdefer alloc.free(new_path);
    if (std.mem.eql(u8, new_path, old_path)) return new_path;

    try std.fs.renameAbsolute(old_path, new_path);
    return new_path;
}

/// Löscht Datei oder Ordner (rekursiv) an absolutem Pfad.
pub fn deletePath(path: []const u8, is_folder: bool) !void {
    if (is_folder) {
        try std.fs.deleteTreeAbsolute(path);
    } else {
        try std.fs.deleteFileAbsolute(path);
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "RenameEdit: init übernimmt den Namen, insert und backspace arbeiten in Codepoints" {
    var e = RenameEdit.init("foo.txt");
    try testing.expectEqualStrings("foo.txt", e.text());
    e.insertCodepoint('x');
    try testing.expectEqualStrings("foo.txtx", e.text());
    e.backspace();
    try testing.expectEqualStrings("foo.txt", e.text());
    e.insertCodepoint('ü');
    try testing.expectEqualStrings("foo.txtü", e.text());
    e.backspace();
    try testing.expectEqualStrings("foo.txt", e.text());
}

test "RenameEdit: backspace auf leerem Puffer und Überlauf sind harmlos" {
    var e = RenameEdit.init("");
    e.backspace();
    try testing.expectEqualStrings("", e.text());
    var i: usize = 0;
    while (i < max_name_len + 10) : (i += 1) e.insertCodepoint('a');
    try testing.expectEqual(max_name_len, e.text().len);
}

test "renamePath: benennt Datei im selben Verzeichnis um und liefert neuen Pfad" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "hi" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const old = try std.fs.path.join(testing.allocator, &.{ root, "a.txt" });
    defer testing.allocator.free(old);

    const new_path = try renamePath(testing.allocator, old, "b.txt");
    defer testing.allocator.free(new_path);

    const expected = try std.fs.path.join(testing.allocator, &.{ root, "b.txt" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, new_path);
    try tmp.dir.access("b.txt", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access("a.txt", .{}));
}

test "renamePath: leerer Name oder Pfadtrenner sind ungültig, gleicher Name ist ein No-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "hi" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const old = try std.fs.path.join(testing.allocator, &.{ root, "a.txt" });
    defer testing.allocator.free(old);

    try testing.expectError(error.InvalidName, renamePath(testing.allocator, old, ""));
    try testing.expectError(error.InvalidName, renamePath(testing.allocator, old, "x/y"));
    try testing.expectError(error.InvalidName, renamePath(testing.allocator, old, ".."));
    const same = try renamePath(testing.allocator, old, "a.txt");
    defer testing.allocator.free(same);
    try testing.expectEqualStrings(old, same);
    try tmp.dir.access("a.txt", .{});
}

test "deletePath: löscht Datei und Ordner mit Inhalt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "x" });
    try tmp.dir.makePath("d/sub");
    try tmp.dir.writeFile(.{ .sub_path = "d/sub/inner.txt", .data = "y" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const f = try std.fs.path.join(testing.allocator, &.{ root, "f.txt" });
    defer testing.allocator.free(f);
    const d = try std.fs.path.join(testing.allocator, &.{ root, "d" });
    defer testing.allocator.free(d);

    try deletePath(f, false);
    try testing.expectError(error.FileNotFound, tmp.dir.access("f.txt", .{}));
    try deletePath(d, true);
    try testing.expectError(error.FileNotFound, tmp.dir.access("d", .{}));
}
