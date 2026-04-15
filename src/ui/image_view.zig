const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;

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
                // Echtes Bild rendern
                clay.UI()(.{
                    .id = clay.ElementId.ID("image_display"),
                    .layout = .{
                        .sizing = .grow,
                    },
                    .image = .{ .image_data = texture_ptr },
                    .background_color = .{ 255, 255, 255, 255 }, // Full white tint = no tint
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
