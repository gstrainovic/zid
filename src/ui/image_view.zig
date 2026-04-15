const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;

pub const ImageViewState = struct {
    pub fn render(
        arena: std.mem.Allocator,
        path: []const u8,
        theme: Theme,
        open_images: *std.StringHashMap(*anyopaque),
    ) void {
        _ = arena;
        const maybe_texture = open_images.get(path);

        clay.UI()(.{
            .id = clay.ElementId.ID("image_view_container"),
            .layout = .{
                .sizing = .grow,
                .child_alignment = .{ .x = .center, .y = .center },
                .padding = .all(32),
            },
            .background_color = theme.bg,
        })({
            if (maybe_texture) |texture_ptr| {
                // SVG-Texturen sind weiße Alpha-Masken — Tint via theme.text.
                // Raster-Bilder (PNG/JPG/...) bleiben untinted (weiß = passthrough).
                const is_svg = std.ascii.endsWithIgnoreCase(path, ".svg");
                const tint: clay.Color = if (is_svg) theme.text else .{ 255, 255, 255, 255 };

                // Aspect-Ratio aus ImageTexture, damit Clay nicht streckt
                const tex: *const ImageTexture = @ptrCast(@alignCast(texture_ptr));
                const aspect: f32 = if (tex.height > 0)
                    @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height))
                else
                    1.0;

                clay.UI()(.{
                    .id = clay.ElementId.ID("image_display"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                    },
                    .aspect_ratio = .{ .aspect_ratio = aspect },
                    .image = .{ .image_data = texture_ptr },
                    .background_color = tint,
                })({});
            } else {
                // Platzhalter / Laden
                clay.UI()(.{
                    .id = clay.ElementId.ID("image_placeholder"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .grow },
                        .child_alignment = .{ .x = .center, .y = .center },
                        .direction = .top_to_bottom,
                        .child_gap = 16,
                    },
                    .background_color = theme.surface,
                    .border = .{ .width = .all(1), .color = theme.border },
                })({
                    clay.text("Lade Bild...", .{ .font_size = 32, .color = theme.text });
                    clay.text(path, .{ .font_size = 20, .color = theme.muted });
                });
            }
        });
    }
};
