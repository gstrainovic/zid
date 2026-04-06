const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

pub fn Button(id: []const u8, text: []const u8, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .axes(10, 24),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = theme.primary,
        .corner_radius = .all(theme.radius_sm),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.border,
        },
    })({
        clay.text(text, .{ 
            .font_size = 16, 
            .color = theme.text_on_primary,
        });
    });
}
