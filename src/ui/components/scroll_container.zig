//! ScrollContainer Component für vulkan-ed
//!
//! Scrollbarer Container mit Clay Layout.

const std = @import("std");
const clay = @import("clay");

pub const ScrollContainer = struct {
    width: f32,
    height: f32,
    scroll_offset: f32 = 0.0,
    content_height: f32 = 0.0,

    const Self = @This();

    /// ScrollContainer rendern
    pub fn render(self: Self, comptime child_fn: anytype) void {
        // Scroll-Viewport
        clay.UI()(.{
            .id = clay.ElementId.ID("scroll_container"),
            .layout = .{
                .sizing = .{ .w = .fixed(self.width), .h = .fixed(self.height) },
                .padding = .all(4),
            },
            .background_color = .{ 40, 40, 60, 255 },
            .corner_radius = .all(4),
        })({
            // Scrollable content
            child_fn();
        });
    }

    /// Scrollbar rendern
    pub fn renderScrollbar(self: Self) void {
        if (self.content_height <= self.height) return;

        const scrollbar_height = (self.height / self.content_height) * self.height;
        const scrollbar_y = (self.scroll_offset / self.content_height) * self.height;

        clay.UI()(.{
            .id = clay.ElementId.ID("scrollbar"),
            .layout = .{
                .sizing = .{ .w = .fixed(8), .h = .fixed(self.height) },
            },
            .background_color = .{ 30, 30, 50, 255 },
            .corner_radius = .all(4),
        })({
            // Scrollbar thumb
            clay.UI()(.{
                .id = clay.ElementId.ID("scrollbar_thumb"),
                .layout = .{
                    .sizing = .{ .w = .fill, .h = .fixed(scrollbar_height) },
                },
                .background_color = .{ 80, 80, 120, 255 },
                .corner_radius = .all(4),
            })({});
        });
    }
};
