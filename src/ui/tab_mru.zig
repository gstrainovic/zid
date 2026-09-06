//! Reihenfolge „zuletzt benutzt“ für Tabs (reine Logik, unit-getestet).
//!
//! Tabs bekommen eine feste Seriennummer; die Liste hält Seriennummern, vorn die zuletzt
//! aktivierte. Ctrl+Tab läuft mit `cyclePos` durch diese Reihenfolge (wie VS Code/Zed).
const std = @import("std");

pub const Mru = struct {
    list: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *Mru, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }

    /// Seriennummer nach vorn holen (oder neu einfügen).
    pub fn touch(self: *Mru, alloc: std.mem.Allocator, serial: u32) !void {
        self.remove(serial);
        try self.list.insert(alloc, 0, serial);
    }

    pub fn remove(self: *Mru, serial: u32) void {
        for (self.list.items, 0..) |s, i| {
            if (s == serial) {
                _ = self.list.orderedRemove(i);
                return;
            }
        }
    }

    pub fn items(self: *const Mru) []const u32 {
        return self.list.items;
    }

    pub fn clone(self: *const Mru, alloc: std.mem.Allocator) !Mru {
        var out: Mru = .{};
        try out.list.appendSlice(alloc, self.list.items);
        return out;
    }
};

/// Nächste Position im Umschalter: ohne offenen Umschalter beginnt Vorwärts beim zweitjüngsten
/// Tab (Position 1), Rückwärts beim ältesten; sonst eine Position weiter mit Umlauf.
pub fn cyclePos(current: ?usize, dir: i32, n: usize) usize {
    if (n == 0) return 0;
    const cur = current orelse 0;
    if (dir >= 0) return (cur + 1) % n;
    return if (cur == 0) n - 1 else cur - 1;
}

const testing = std.testing;

test "touch holt nach vorn, remove entfernt, Reihenfolge bleibt sonst erhalten" {
    const a = testing.allocator;
    var m: Mru = .{};
    defer m.deinit(a);
    try m.touch(a, 1);
    try m.touch(a, 2);
    try m.touch(a, 3);
    try testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, m.items());
    try m.touch(a, 1);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 2 }, m.items());
    m.remove(3);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, m.items());
    m.remove(99);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, m.items());
    var c = try m.clone(a);
    defer c.deinit(a);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, c.items());
}

test "cyclePos: Ctrl+Tab beginnt beim zweitjüngsten, läuft um; Shift rückwärts" {
    try testing.expectEqual(@as(usize, 1), cyclePos(null, 1, 3));
    try testing.expectEqual(@as(usize, 2), cyclePos(1, 1, 3));
    try testing.expectEqual(@as(usize, 0), cyclePos(2, 1, 3));
    try testing.expectEqual(@as(usize, 2), cyclePos(null, -1, 3));
    try testing.expectEqual(@as(usize, 1), cyclePos(2, -1, 3));
    try testing.expectEqual(@as(usize, 0), cyclePos(null, 1, 0));
    try testing.expectEqual(@as(usize, 0), cyclePos(null, 1, 1));
}
