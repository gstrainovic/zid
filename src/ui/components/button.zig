const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

pub fn Button(id: []const u8, text: []const u8, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .axes(12, 24),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = theme.primary,
        .corner_radius = .all(4),
        .border = .{
            .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 },
            .color = theme.accent, // Accent border for better shape definition
        },
    })({
        clay.text(text, .{ 
            .font_size = 24, 
            .color = theme.text_on_primary,
        });
    });
}
