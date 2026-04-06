const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

pub fn TextArea(id: []const u8, value: []const u8, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(150) },
            .padding = .all(12),
            .direction = .top_to_bottom,
            .child_gap = 4,
        },
        .background_color = theme.overlay,
        .corner_radius = .all(4),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.primary, // Brighter border for visibility
        },
    })({
        var it = std.mem.splitScalar(u8, value, '\n');
        while (it.next()) |line| {
            clay.text(line, .{ 
                .font_size = 24, 
                .color = theme.text,
            });
        }
    });
}
