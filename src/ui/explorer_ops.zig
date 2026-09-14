//! Reine Operationen für den File-Explorer: Namens-Editierpuffer und
//! Dateisystem-Aktionen (Umbenennen, Löschen). Kein Clay, keine UI, damit
//! alles mit tmpDir testbar bleibt.

const std = @import("std");
const env = @import("env");

pub const max_name_len = 255;

/// Editierpuffer mit fester Kapazität, UTF-8-bewusst (Inline-Umbenennen,
/// Pfad-Eingabe im Ordner-Dialog).
pub fn EditBuffer(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn init(initial: []const u8) Self {
            var e = Self{};
            e.set(initial);
            return e;
        }

        pub fn set(self: *Self, value: []const u8) void {
            const n = @min(value.len, capacity);
            @memcpy(self.buf[0..n], value[0..n]);
            self.len = n;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn insertCodepoint(self: *Self, cp: u21) void {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &tmp) catch return;
            if (self.len + n > capacity) return;
            @memcpy(self.buf[self.len .. self.len + n], tmp[0..n]);
            self.len += n;
        }

        /// Entfernt das letzte Codepoint (nicht nur das letzte Byte).
        pub fn backspace(self: *Self) void {
            if (self.len == 0) return;
            var i = self.len - 1;
            // UTF-8-Fortsetzungsbytes (10xxxxxx) überspringen bis zum Startbyte
            while (i > 0 and (self.buf[i] & 0xC0) == 0x80) i -= 1;
            self.len = i;
        }
    };
}

/// Editierpuffer für Inline-Umbenennen (Dateinamen bis 255 Bytes).
pub const RenameEdit = EditBuffer(max_name_len);

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

/// true wenn `path` ein Verzeichnis ist; Symlinks werden aufgelöst, damit ein
/// Link auf einen Ordner wie der Ordner behandelt wird (Explorer, Tab-Öffnen).
pub fn isDirectory(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.kind == .directory;
}

test "isDirectory: Ordner und Symlink auf Ordner ja, Datei, Symlink auf Datei und Fehlendes nein" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    try tmp.dir.makeDir("real_dir");
    _ = try tmp.dir.createFile("real_file", .{});
    try tmp.dir.symLink("real_dir", "dir_link", .{ .is_directory = true });
    try tmp.dir.symLink("real_file", "file_link", .{});

    const names = [_]struct { name: []const u8, dir: bool }{
        .{ .name = "real_dir", .dir = true },
        .{ .name = "dir_link", .dir = true },
        .{ .name = "real_file", .dir = false },
        .{ .name = "file_link", .dir = false },
        .{ .name = "missing", .dir = false },
    };
    for (names) |n| {
        const p = try std.fs.path.join(std.testing.allocator, &.{ base, n.name });
        defer std.testing.allocator.free(p);
        try std.testing.expectEqual(n.dir, isDirectory(p));
    }
}

/// true wenn `path` gleich `root` ist oder darunter liegt.
pub fn isPathOrUnder(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    return path.len > root.len and std.mem.startsWith(u8, path, root) and std.fs.path.isSep(path[root.len]);
}

/// Neuer Pfad für `path`, wenn `old_root` nach `new_root` umbenannt wurde:
/// exakt gleich oder darunter → Präfix ersetzt (owned), sonst null.
pub fn pathAfterRename(alloc: std.mem.Allocator, path: []const u8, old_root: []const u8, new_root: []const u8) !?[]u8 {
    if (!isPathOrUnder(path, old_root)) return null;
    return try std.mem.concat(alloc, u8, &.{ new_root, path[old_root.len..] });
}

pub const NameError = error{ InvalidName, PathAlreadyExists };

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\") == null;
}

fn exists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn isDir(path: []const u8) bool {
    // Kein statFile: das öffnet unter Windows als Datei und scheitert an Ordnern.
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

/// Legt `name` als Datei oder Ordner in `parent_dir` an (exklusiv, nie überschreiben).
/// Liefert den neuen absoluten Pfad (owned).
pub fn createEntry(alloc: std.mem.Allocator, parent_dir: []const u8, name: []const u8, is_folder: bool) ![]u8 {
    if (!validName(name)) return error.InvalidName;
    const path = try std.fs.path.join(alloc, &.{ parent_dir, name });
    errdefer alloc.free(path);
    if (is_folder) {
        std.fs.makeDirAbsolute(path) catch |err| return if (err == error.PathAlreadyExists) error.PathAlreadyExists else err;
    } else {
        const f = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch |err|
            return if (err == error.PathAlreadyExists) error.PathAlreadyExists else err;
        f.close();
    }
    return path;
}

/// Freier Zielpfad für `name` in `dir`: existiert er schon, „name copy.ext“,
/// „name copy 2.ext“ … (owned). Ordnernamen werden nicht an Punkten getrennt.
pub fn uniqueDestination(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (!validName(name)) return error.InvalidName;
    const first = try std.fs.path.join(alloc, &.{ dir, name });
    if (!exists(first)) return first;
    const first_is_dir = isDir(first);
    alloc.free(first);

    const ext = if (first_is_dir) "" else std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    var i: usize = 1;
    while (i < 10_000) : (i += 1) {
        const candidate_name = if (i == 1)
            try std.fmt.allocPrint(alloc, "{s} copy{s}", .{ stem, ext })
        else
            try std.fmt.allocPrint(alloc, "{s} copy {d}{s}", .{ stem, i, ext });
        defer alloc.free(candidate_name);
        const candidate = try std.fs.path.join(alloc, &.{ dir, candidate_name });
        if (!exists(candidate)) return candidate;
        alloc.free(candidate);
    }
    return error.PathAlreadyExists;
}

fn copyTree(alloc: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    try std.fs.makeDirAbsolute(dst);
    var dir = try std.fs.openDirAbsolute(src, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const s = try std.fs.path.join(alloc, &.{ src, entry.name });
        defer alloc.free(s);
        const d = try std.fs.path.join(alloc, &.{ dst, entry.name });
        defer alloc.free(d);
        if (entry.kind == .directory) {
            try copyTree(alloc, s, d);
        } else {
            try std.fs.copyFileAbsolute(s, d, .{});
        }
    }
}

/// Kopiert Datei oder Ordner (rekursiv) nach `dst_dir`, Name bleibt oder wird eindeutig.
/// Liefert den Zielpfad (owned).
pub fn copyPath(alloc: std.mem.Allocator, src: []const u8, dst_dir: []const u8) ![]u8 {
    if (isPathOrUnder(dst_dir, src) and isDir(src)) return error.InvalidName; // Ordner nicht in sich selbst
    const dst = try uniqueDestination(alloc, dst_dir, std.fs.path.basename(src));
    errdefer alloc.free(dst);
    if (isDir(src)) {
        try copyTree(alloc, src, dst);
    } else {
        try std.fs.copyFileAbsolute(src, dst, .{});
    }
    return dst;
}

/// Verschiebt Datei oder Ordner nach `dst_dir` (eindeutiger Name). Ziel gleich Quelle → No-op.
pub fn movePath(alloc: std.mem.Allocator, src: []const u8, dst_dir: []const u8) ![]u8 {
    const src_dir = std.fs.path.dirname(src) orelse return error.InvalidName;
    if (std.mem.eql(u8, src_dir, dst_dir)) return try alloc.dupe(u8, src);
    if (isPathOrUnder(dst_dir, src)) return error.InvalidName;
    const dst = try uniqueDestination(alloc, dst_dir, std.fs.path.basename(src));
    errdefer alloc.free(dst);
    try std.fs.renameAbsolute(src, dst);
    return dst;
}

fn writeTrashInfo(alloc: std.mem.Allocator, info_path: []const u8, original: []const u8) !void {
    const f = try std.fs.createFileAbsolute(info_path, .{ .exclusive = true });
    defer f.close();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "[Trash Info]\nPath=");
    for (original) |c| {
        const keep = std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~';
        if (keep) try buf.append(alloc, c) else try buf.writer(alloc).print("%{X:0>2}", .{c});
    }
    const secs: u64 = @intCast(@max(0, std.time.timestamp()));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try buf.writer(alloc).print("\nDeletionDate={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
    try f.writeAll(buf.items);
}

/// Verschiebt `path` in den freedesktop-Papierkorb unter `trash_root`
/// (`files/` + `info/<name>.trashinfo`). Liefert den Namen im Papierkorb (owned).
/// DeletionDate steht in UTC (kein Zeitzonen-Support in std).
pub fn trashPath(alloc: std.mem.Allocator, path: []const u8, trash_root: []const u8) ![]u8 {
    const files_dir = try std.fs.path.join(alloc, &.{ trash_root, "files" });
    defer alloc.free(files_dir);
    const info_dir = try std.fs.path.join(alloc, &.{ trash_root, "info" });
    defer alloc.free(info_dir);
    try std.fs.cwd().makePath(files_dir);
    try std.fs.cwd().makePath(info_dir);

    const base = std.fs.path.basename(path);
    var n: usize = 1;
    while (n < 10_000) : (n += 1) {
        const name = if (n == 1) try alloc.dupe(u8, base) else try std.fmt.allocPrint(alloc, "{s}.{d}", .{ base, n });
        errdefer alloc.free(name);
        const dest = try std.fs.path.join(alloc, &.{ files_dir, name });
        defer alloc.free(dest);
        const info = try std.fmt.allocPrint(alloc, "{s}/{s}.trashinfo", .{ info_dir, name });
        defer alloc.free(info);
        if (exists(dest) or exists(info)) {
            alloc.free(name);
            continue;
        }
        try writeTrashInfo(alloc, info, path);
        std.fs.renameAbsolute(path, dest) catch |err| {
            std.fs.deleteFileAbsolute(info) catch {};
            return err;
        };
        return name;
    }
    return error.PathAlreadyExists;
}

/// Standard-Papierkorb: $XDG_DATA_HOME/Trash oder ~/.local/share/Trash (owned).
pub fn defaultTrashRoot(alloc: std.mem.Allocator) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |x| {
        if (x.len > 0) return std.fs.path.join(alloc, &.{ x, "Trash" });
    }
    const home = env.home() orelse return error.InvalidName;
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "Trash" });
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

test "isPathOrUnder: exakt, darunter, nicht bloß gleicher Präfix" {
    try testing.expect(isPathOrUnder("/a/b", "/a/b"));
    try testing.expect(isPathOrUnder("/a/b/c.txt", "/a/b"));
    try testing.expect(!isPathOrUnder("/a/bc/x", "/a/b"));
    try testing.expect(!isPathOrUnder("/a", "/a/b"));
}

test "pathAfterRename: Datei, Ordner mit Kindern, unbeteiligte Pfade" {
    const f = try pathAfterRename(testing.allocator, "/p/old.txt", "/p/old.txt", "/p/new.txt");
    defer if (f) |x| testing.allocator.free(x);
    try testing.expectEqualStrings("/p/new.txt", f.?);

    const child = try pathAfterRename(testing.allocator, "/p/dir/sub/f.zig", "/p/dir", "/p/renamed");
    defer if (child) |x| testing.allocator.free(x);
    try testing.expectEqualStrings("/p/renamed/sub/f.zig", child.?);

    try testing.expect((try pathAfterRename(testing.allocator, "/p/dirx/f.zig", "/p/dir", "/p/renamed")) == null);
    try testing.expect((try pathAfterRename(testing.allocator, "/q/other", "/p/dir", "/p/renamed")) == null);
}

fn joinT(root: []const u8, sub: []const u8) ![]u8 {
    return std.fs.path.join(testing.allocator, &.{ root, sub });
}

test "createEntry: Datei und Ordner anlegen, vorhandenes nie überschreiben" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const f = try createEntry(testing.allocator, root, "neu.txt", false);
    defer testing.allocator.free(f);
    try testing.expectEqualStrings(std.fs.path.basename(f), "neu.txt");
    try tmp.dir.access("neu.txt", .{});
    try testing.expectError(error.PathAlreadyExists, createEntry(testing.allocator, root, "neu.txt", false));

    const d = try createEntry(testing.allocator, root, "ordner", true);
    defer testing.allocator.free(d);
    var ordner = try tmp.dir.openDir("ordner", .{});
    ordner.close();
    try testing.expectError(error.NotDir, tmp.dir.openDir("neu.txt", .{}));

    try testing.expectError(error.InvalidName, createEntry(testing.allocator, root, "", false));
    try testing.expectError(error.InvalidName, createEntry(testing.allocator, root, "a/b", false));
}

test "uniqueDestination: frei → gleicher Name, belegt → ' copy', dann ' copy 2'" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const free_path = try uniqueDestination(testing.allocator, root, "a.txt");
    defer testing.allocator.free(free_path);
    try testing.expectEqualStrings("a.txt", std.fs.path.basename(free_path));

    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "1" });
    const c1 = try uniqueDestination(testing.allocator, root, "a.txt");
    defer testing.allocator.free(c1);
    try testing.expectEqualStrings("a copy.txt", std.fs.path.basename(c1));

    try tmp.dir.writeFile(.{ .sub_path = "a copy.txt", .data = "2" });
    const c2 = try uniqueDestination(testing.allocator, root, "a.txt");
    defer testing.allocator.free(c2);
    try testing.expectEqualStrings("a copy 2.txt", std.fs.path.basename(c2));

    try tmp.dir.makePath("dir");
    const cd = try uniqueDestination(testing.allocator, root, "dir");
    defer testing.allocator.free(cd);
    try testing.expectEqualStrings("dir copy", std.fs.path.basename(cd));
}

test "copyPath: Datei ins selbe Verzeichnis dupliziert, Ordner rekursiv" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "hallo" });
    try tmp.dir.makePath("d/sub");
    try tmp.dir.writeFile(.{ .sub_path = "d/sub/x.txt", .data = "x" });
    try tmp.dir.makePath("ziel");

    const a = try joinT(root, "a.txt");
    defer testing.allocator.free(a);
    const dup = try copyPath(testing.allocator, a, root);
    defer testing.allocator.free(dup);
    try testing.expectEqualStrings("a copy.txt", std.fs.path.basename(dup));
    const content = try tmp.dir.readFileAlloc(testing.allocator, "a copy.txt", 100);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hallo", content);

    const d = try joinT(root, "d");
    defer testing.allocator.free(d);
    const ziel = try joinT(root, "ziel");
    defer testing.allocator.free(ziel);
    const copied = try copyPath(testing.allocator, d, ziel);
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings("d", std.fs.path.basename(copied));
    try tmp.dir.access("ziel/d/sub/x.txt", .{});
    try tmp.dir.access("d/sub/x.txt", .{}); // Quelle bleibt
}

test "movePath: verschiebt, gleiches Verzeichnis ist No-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "1" });
    try tmp.dir.makePath("ziel");
    const a = try joinT(root, "a.txt");
    defer testing.allocator.free(a);
    const ziel = try joinT(root, "ziel");
    defer testing.allocator.free(ziel);

    const same = try movePath(testing.allocator, a, root);
    defer testing.allocator.free(same);
    try testing.expectEqualStrings(a, same);
    try tmp.dir.access("a.txt", .{});

    const moved = try movePath(testing.allocator, a, ziel);
    defer testing.allocator.free(moved);
    try tmp.dir.access("ziel/a.txt", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access("a.txt", .{}));
}

test "trashPath: Datei landet in files/, info/ bekommt trashinfo mit Pfad" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(.{ .sub_path = "weg.txt", .data = "bye" });
    try tmp.dir.makePath("ordner/inner");
    const trash = try joinT(root, "Trash");
    defer testing.allocator.free(trash);
    const f = try joinT(root, "weg.txt");
    defer testing.allocator.free(f);

    const name = try trashPath(testing.allocator, f, trash);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("weg.txt", name);
    try testing.expectError(error.FileNotFound, tmp.dir.access("weg.txt", .{}));
    try tmp.dir.access("Trash/files/weg.txt", .{});
    const info = try tmp.dir.readFileAlloc(testing.allocator, "Trash/info/weg.txt.trashinfo", 4096);
    defer testing.allocator.free(info);
    try testing.expect(std.mem.startsWith(u8, info, "[Trash Info]\nPath="));
    try testing.expect(std.mem.indexOf(u8, info, "weg.txt\n") != null);
    try testing.expect(std.mem.indexOf(u8, info, "DeletionDate=20") != null);

    // Gleicher Name nochmal → eindeutiger Name im Papierkorb, Ordner rekursiv
    try tmp.dir.writeFile(.{ .sub_path = "weg.txt", .data = "again" });
    const name2 = try trashPath(testing.allocator, f, trash);
    defer testing.allocator.free(name2);
    try testing.expect(!std.mem.eql(u8, name, name2));
    const o = try joinT(root, "ordner");
    defer testing.allocator.free(o);
    const oname = try trashPath(testing.allocator, o, trash);
    defer testing.allocator.free(oname);
    try tmp.dir.access("Trash/files/ordner/inner", .{});
}
