const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

pub inline fn ScrollContainer(id: []const u8, theme: Theme) fn (void) void {
    return clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .padding = .all(8),
        },
        .background_color = theme.surface,
        .corner_radius = .all(4),
        .clip = .{ .vertical = true },
    });
}
