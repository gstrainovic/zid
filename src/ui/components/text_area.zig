//! TextArea Component für vulkan-ed
//!
//! Multi-line Text-Input Feld mit Clay Layout.

const std = @import("std");
const clay = @import("clay");

pub const TextArea = struct {
    placeholder: []const u8,
    value: []const u8,
    x: f32,
    y: f32,
    width: f32 = 300.0,
    height: f32 = 100.0,
    is_focused: bool = false,

    const Self = @This();

    /// TextArea rendern
    pub fn render(self: Self) void {
        const bg_color = if (self.is_focused)
            clay.Color{ .r = 40, .g = 40, .b = 60, .a = 255 }
        else
            clay.Color{ .r = 30, .g = 30, .b = 50, .a = 255 };

        const border_color = if (self.is_focused)
            clay.Color{ .r = 100, .g = 150, .b = 255, .a = 255 }
        else
            clay.Color{ .r = 60, .g = 60, .b = 80, .a = 255 };

        // Hintergrund
        clay.UI()(.{
            .id = clay.ElementId.ID("textarea_bg"),
            .layout = .{
                .sizing = .{ .w = .fixed(self.width), .h = .fixed(self.height) },
                .padding = .all(8),
            },
            .background_color = bg_color,
            .corner_radius = .all(4),
            .border = .{
                .color = border_color,
                .width = .all(1),
            },
        })({
            // Multi-line Text
        });
    }
};
