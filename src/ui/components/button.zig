const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

pub fn Button(id: []const u8, text: []const u8, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .axes(8, 16),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = theme.primary,
        .corner_radius = .all(4),
    })({
        clay.text(text, .{ 
            .font_size = 16, 
            .color = theme.text_on_primary,
        });
    });
}
