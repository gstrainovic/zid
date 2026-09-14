//! Reine Logik für den "Open Folder"-Dialog: Pfad-Eingabe, ~-Expansion,
//! Unterordner-Liste und das Picker-Modell (Navigation, Bestätigen).
//! Kein Clay, keine UI, damit alles mit tmpDir testbar bleibt.

const std = @import("std");
const explorer_ops = @import("explorer_ops.zig");
const env = @import("env");

/// Editierpuffer für den Pfad im Dialog.
pub const PathEdit = explorer_ops.EditBuffer(std.fs.max_path_bytes);


/// Ersetzt ein führendes "~" oder "~/" durch das Home-Verzeichnis. Ohne Home
/// oder ohne Tilde-Präfix kommt eine Kopie der Eingabe zurück (immer owned).
pub fn expandHome(alloc: std.mem.Allocator, input: []const u8, home: ?[]const u8) ![]u8 {
    if (home) |h| {
        if (std.mem.eql(u8, input, "~")) return alloc.dupe(u8, h);
        if (std.mem.startsWith(u8, input, "~/")) {
            return std.fs.path.join(alloc, &.{ h, input[2..] });
        }
    }
    return alloc.dupe(u8, input);
}

pub const ResolveError = error{ NotDir, FileNotFound } || std.mem.Allocator.Error || std.fs.Dir.RealPathError || std.fs.Dir.StatFileError;

/// Löst eine Benutzereingabe (relativ, mit ~, mit Slash am Ende …) zu einem
/// kanonischen absoluten Ordnerpfad auf. Dateien und fehlende Pfade sind Fehler.
pub fn resolveFolder(alloc: std.mem.Allocator, input: []const u8, home: ?[]const u8) ResolveError![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.FileNotFound;
    const expanded = try expandHome(alloc, trimmed, home);
    defer alloc.free(expanded);

    const real = try std.fs.cwd().realpathAlloc(alloc, expanded);
    errdefer alloc.free(real);
    const st = try std.fs.cwd().statFile(real);
    if (st.kind != .directory) return error.NotDir;
    return real;
}

/// Sichtbare Unterordner (ohne ".…"), alphabetisch ohne Groß/Klein-Unterschied.
pub fn listSubdirs(alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer freeList(alloc, names.items);
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, lessThanIgnoreCase);
    return names.toOwnedSlice(alloc);
}

fn lessThanIgnoreCase(_: void, a: []u8, b: []u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

pub fn freeList(alloc: std.mem.Allocator, list: [][]u8) void {
    for (list) |n| alloc.free(n);
    alloc.free(list);
}

/// Zustand des Ordner-Dialogs ohne Darstellung: aktueller Ordner, seine
/// Unterordner, der editierbare Pfad und eine etwaige Fehlermeldung.
pub const Picker = struct {
    alloc: std.mem.Allocator,
    dir: ?[]u8 = null,
    entries: [][]u8 = &.{},
    edit: PathEdit = .{},
    error_msg: ?[]const u8 = null,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
    }

    fn clear(self: *Self) void {
        if (self.dir) |d| self.alloc.free(d);
        self.dir = null;
        freeList(self.alloc, self.entries);
        self.entries = &.{};
    }

    /// Dialog auf einen Startordner setzen.
    pub fn start(self: *Self, dir_path: []const u8) !void {
        self.error_msg = null;
        try self.navigate(dir_path);
    }

    /// In einen Ordner wechseln: Liste und Eingabe folgen. Bei Fehler bleibt
    /// der alte Zustand stehen und die Meldung wird gesetzt.
    pub fn navigate(self: *Self, path: []const u8) !void {
        const resolved = resolveFolder(self.alloc, path, homeDir()) catch |err| {
            self.error_msg = errorMessage(err);
            return;
        };
        errdefer self.alloc.free(resolved);
        const list = try listSubdirs(self.alloc, resolved);
        self.clear();
        self.dir = resolved;
        self.entries = list;
        self.edit.set(resolved);
        self.error_msg = null;
    }

    /// In den Unterordner mit Index `index` wechseln.
    pub fn enter(self: *Self, index: usize) !void {
        if (index >= self.entries.len) return;
        const dir = self.dir orelse return;
        const target = try std.fs.path.join(self.alloc, &.{ dir, self.entries[index] });
        defer self.alloc.free(target);
        try self.navigate(target);
    }

    /// In den Elternordner wechseln; an der Wurzel passiert nichts.
    pub fn up(self: *Self) !void {
        const dir = self.dir orelse return;
        const parent = std.fs.path.dirname(dir) orelse return;
        const copy = try self.alloc.dupe(u8, parent);
        defer self.alloc.free(copy);
        try self.navigate(copy);
    }

    pub fn insertCodepoint(self: *Self, cp: u21) void {
        self.error_msg = null;
        self.edit.insertCodepoint(cp);
    }

    pub fn backspace(self: *Self) void {
        self.error_msg = null;
        self.edit.backspace();
    }

    /// Eingabe auflösen. Erfolg: kanonischer Pfad (owned). Fehler: null und
    /// Meldung gesetzt.
    pub fn confirm(self: *Self) ?[]u8 {
        return resolveFolder(self.alloc, self.edit.text(), homeDir()) catch |err| {
            self.error_msg = errorMessage(err);
            return null;
        };
    }

    fn errorMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.NotDir => "Not a folder",
            error.FileNotFound => "Folder not found",
            error.AccessDenied => "Access denied",
            else => "Cannot open folder",
        };
    }
};

fn homeDir() ?[]const u8 {
    return env.home();
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "expandHome: ~ und ~/x werden mit HOME ersetzt, sonst unverändert" {
    const a = testing.allocator;
    const h = try expandHome(a, "~", "/home/u");
    defer a.free(h);
    try testing.expectEqualStrings("/home/u", h);

    const p = try expandHome(a, "~/projects", "/home/u");
    defer a.free(p);
    try testing.expectEqualStrings("/home/u/projects", p);

    const abs = try expandHome(a, "/tmp/x", "/home/u");
    defer a.free(abs);
    try testing.expectEqualStrings("/tmp/x", abs);

    // "~foo" ist kein Home-Präfix
    const tilde_name = try expandHome(a, "~foo", "/home/u");
    defer a.free(tilde_name);
    try testing.expectEqualStrings("~foo", tilde_name);

    // Ohne HOME bleibt ~ stehen
    const no_home = try expandHome(a, "~/x", null);
    defer a.free(no_home);
    try testing.expectEqualStrings("~/x", no_home);
}

test "resolveFolder: liefert kanonischen Ordnerpfad, Datei und Nichtexistentes sind Fehler" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("sub");
    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = "x" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const with_slash = try std.fmt.allocPrint(a, "{s}/sub/", .{root});
    defer a.free(with_slash);
    const resolved = try resolveFolder(a, with_slash, null);
    defer a.free(resolved);
    const expected = try std.fs.path.join(a, &.{ root, "sub" });
    defer a.free(expected);
    try testing.expectEqualStrings(expected, resolved);

    const file_path = try std.fs.path.join(a, &.{ root, "file.txt" });
    defer a.free(file_path);
    try testing.expectError(error.NotDir, resolveFolder(a, file_path, null));

    const missing = try std.fs.path.join(a, &.{ root, "nope" });
    defer a.free(missing);
    try testing.expectError(error.FileNotFound, resolveFolder(a, missing, null));

    try testing.expectError(error.FileNotFound, resolveFolder(a, "", null));
}

test "listSubdirs: nur Ordner, ohne versteckte, alphabetisch" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("zeta");
    try tmp.dir.makeDir("Alpha");
    try tmp.dir.makeDir("beta");
    try tmp.dir.makeDir(".hidden");
    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = "x" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const list = try listSubdirs(a, root);
    defer freeList(a, list);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("Alpha", list[0]);
    try testing.expectEqualStrings("beta", list[1]);
    try testing.expectEqualStrings("zeta", list[2]);
}

test "Picker: start listet Ordner, enter steigt ab, up steigt auf, Eingabe folgt" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("a/inner");
    try tmp.dir.makeDir("b");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var p = Picker.init(a);
    defer p.deinit();
    try p.start(root);
    try testing.expectEqualStrings(root, p.dir.?);
    try testing.expectEqualStrings(root, p.edit.text());
    try testing.expectEqual(@as(usize, 2), p.entries.len);

    try p.enter(0);
    const a_path = try std.fs.path.join(a, &.{ root, "a" });
    defer a.free(a_path);
    try testing.expectEqualStrings(a_path, p.dir.?);
    try testing.expectEqualStrings(a_path, p.edit.text());
    try testing.expectEqual(@as(usize, 1), p.entries.len);
    try testing.expectEqualStrings("inner", p.entries[0]);

    try p.up();
    try testing.expectEqualStrings(root, p.dir.?);

    // Ungültiger Index ist harmlos
    try p.enter(99);
    try testing.expectEqualStrings(root, p.dir.?);
}

test "Picker: confirm löst die Eingabe auf, Fehler bleibt als Meldung stehen" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("b");
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var p = Picker.init(a);
    defer p.deinit();
    try p.start(root);

    // Getippter Pfad: Eingabe leeren und "<root>/b/" tippen
    while (p.edit.len > 0) p.backspace();
    for (root) |c| p.insertCodepoint(c);
    for ("/b/") |c| p.insertCodepoint(c);
    const chosen = p.confirm() orelse return error.TestExpectedConfirm;
    defer a.free(chosen);
    const b_path = try std.fs.path.join(a, &.{ root, "b" });
    defer a.free(b_path);
    try testing.expectEqualStrings(b_path, chosen);
    try testing.expect(p.error_msg == null);

    // Nicht existierender Pfad: kein Ergebnis, Fehlermeldung gesetzt
    for ("/nope") |c| p.insertCodepoint(c);
    try testing.expect(p.confirm() == null);
    try testing.expect(p.error_msg != null);
    // Weitertippen löscht die Meldung
    p.backspace();
    try testing.expect(p.error_msg == null);
}

test "Picker: up an der Wurzel bleibt stehen" {
    var p = Picker.init(testing.allocator);
    defer p.deinit();
    try p.start("/");
    try p.up();
    try testing.expectEqualStrings("/", p.dir.?);
}
