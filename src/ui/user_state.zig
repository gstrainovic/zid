//! Gemerkter UI-Zustand zwischen Sitzungen (Sidebar-Breite, versteckte Dateien):
//! `$XDG_CONFIG_HOME/vulkan-ed/state` bzw. `~/.config/vulkan-ed/state`, Zeilen `key=value`.
//! Parsen/Formatieren ist rein und unit-getestet; Laden/Speichern nimmt einen expliziten Pfad.

const std = @import("std");

pub const State = struct {
    sidebar_width: f32 = 250,
    show_hidden: bool = false,
};

/// `key=value`-Zeilen lesen; unbekannte Schlüssel und kaputte Werte werden ignoriert.
pub fn parse(text: []const u8) State {
    var st = State{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "sidebar_width")) {
            const w = std.fmt.parseFloat(f32, value) catch continue;
            if (w >= 100 and w <= 600) st.sidebar_width = w;
        } else if (std.mem.eql(u8, key, "show_hidden")) {
            st.show_hidden = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
        }
    }
    return st;
}

pub fn format(alloc: std.mem.Allocator, st: State) ![]u8 {
    return std.fmt.allocPrint(alloc, "# vulkan-ed state\nsidebar_width={d}\nshow_hidden={s}\n", .{
        @as(u32, @intFromFloat(@round(st.sidebar_width))), if (st.show_hidden) "true" else "false",
    });
}

/// Pfad der State-Datei (owned): $XDG_CONFIG_HOME/vulkan-ed/state oder ~/.config/vulkan-ed/state.
pub fn defaultPath(alloc: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return std.fs.path.join(alloc, &.{ x, "vulkan-ed", "state" });
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".config", "vulkan-ed", "state" });
}

pub fn loadFrom(alloc: std.mem.Allocator, path: []const u8) State {
    const text = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return State{};
    defer alloc.free(text);
    return parse(text);
}

pub fn saveTo(alloc: std.mem.Allocator, path: []const u8, st: State) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const text = try format(alloc, st);
    defer alloc.free(text);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

test "parse: Werte, Grenzen, Kommentare, Unbekanntes" {
    const st = parse("# kommentar\nsidebar_width=320\nshow_hidden=true\nfoo=bar\n");
    try testing.expectEqual(@as(f32, 320), st.sidebar_width);
    try testing.expect(st.show_hidden);
    const bad = parse("sidebar_width=9999\nshow_hidden=nein\n");
    try testing.expectEqual(@as(f32, 250), bad.sidebar_width);
    try testing.expect(!bad.show_hidden);
    try testing.expectEqual(@as(f32, 250), parse("").sidebar_width);
}

test "format und loadFrom/saveTo sind umkehrbar" {
    const a = testing.allocator;
    const text = try format(a, .{ .sidebar_width = 301.4, .show_hidden = true });
    defer a.free(text);
    try testing.expectEqualStrings("# vulkan-ed state\nsidebar_width=301\nshow_hidden=true\n", text);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "cfg", "vulkan-ed", "state" });
    defer a.free(path);
    try saveTo(a, path, .{ .sidebar_width = 180, .show_hidden = false });
    const back = loadFrom(a, path);
    try testing.expectEqual(@as(f32, 180), back.sidebar_width);
    try testing.expect(!back.show_hidden);
    try testing.expectEqual(@as(f32, 250), loadFrom(a, "/nonexistent/state").sidebar_width);
}
