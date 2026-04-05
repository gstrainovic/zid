//! Button Component für vulkan-ed
//!
//! Einfacher Button mit Clay Layout und WGPU Rendering.

const std = @import("std");
const clay = @import("clay");

const log = std.log.scoped(.button);

pub const Button = struct {
    text: []const u8,
    x: f32,
    y: f32,
    width: f32 = 100.0,
    height: f32 = 40.0,
    is_hovered: bool = false,
    is_pressed: bool = false,
    on_click: ?*const fn () void = null,

    const Self = @This();

    /// Button rendern (gibt Clay RenderCommands zurück)
    pub fn render(self: Self) void {
        const bg_color = if (self.is_pressed)
            clay.Color{ .r = 100, .g = 100, .b = 150, .a = 255 }
        else if (self.is_hovered)
            clay.Color{ .r = 80, .g = 80, .b = 120, .a = 255 }
        else
            clay.Color{ .r = 60, .g = 60, .b = 100, .a = 255 };

        clay.UI()(.{
            .id = clay.ElementId.ID("button"),
            .layout = .{
                .sizing = .{ .w = .fixed(self.width), .h = .fixed(self.height) },
                .padding = .all(8),
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = bg_color,
            .corner_radius = .all(6),
        })({
            // Button text placeholder
        });
    }

    /// Prüfen ob Maus über Button
    pub fn contains(self: Self, mx: f32, my: f32) bool {
        return mx >= self.x and mx < self.x + self.width and
            my >= self.y and my < self.y + self.height;
    }
};
