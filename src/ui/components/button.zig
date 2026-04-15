const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

pub fn Button(id: []const u8, text: []const u8, theme: Theme, mouse_pressed: bool) bool {
    const element_id = clay.ElementId.ID(id);
    const is_hovered = clay.pointerOver(element_id);
    
    // Hellerer Hintergrund bei Hover
    var bg_color = theme.primary;
    if (is_hovered) {
        bg_color[0] = @min(255, bg_color[0] + 30);
        bg_color[1] = @min(255, bg_color[1] + 30);
        bg_color[2] = @min(255, bg_color[2] + 30);
    }

    clay.UI()(.{
        .id = element_id,
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .axes(12, 24),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = bg_color,
        .corner_radius = .all(4),
        .border = .{
            .width = .all(2),
            .color = theme.accent,
        },
    })({
        clay.text(text, .{ 
            .font_size = 24, 
            .color = theme.text_on_primary,
        });
    });

    return is_hovered and mouse_pressed;
}
