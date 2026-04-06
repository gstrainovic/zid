const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

pub fn TextInput(id: []const u8, value: []const u8, placeholder: []const u8, theme: Theme) void {
    const text_to_show = if (value.len > 0) value else placeholder;
    const text_color = if (value.len > 0) theme.text else theme.muted;

    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(35) },
            .padding = .axes(0, 12),
            .child_alignment = .{ .x = .left, .y = .center },
        },
        .background_color = theme.overlay,
        .corner_radius = .all(4),
        .border = .{
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .color = theme.primary, // Primary colored border for better visibility
        },

    })({
        clay.text(text_to_show, .{ 
            .font_size = 24, 
            .color = text_color,
        });
    });
}
