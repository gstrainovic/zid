const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const components = @import("components/mod.zig");
const PdfHandler = @import("../rendering/pdf_handler.zig").PdfHandler;
const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;

pub const PdfViewState = struct {
    pub fn render(
        handler: *PdfHandler,
        maybe_texture: ?*anyopaque,
        theme: Theme,
        mouse_pressed: bool,
    ) ?i16 {
        _ = mouse_pressed;
        const log = @import("std").log;
        log.info("PdfViewState.render called for page {}", .{handler.current_page});


        clay.UI()(.{
            .id = clay.ElementId.ID("pdf_view_container"),
            .layout = .{
                .sizing = .grow,
                .child_alignment = .{ .x = .center, .y = .center },
                .padding = .all(16),
            },
            .background_color = theme.bg,
        })({
            if (maybe_texture) |texture_ptr| {
                const tex: *const ImageTexture = @ptrCast(@alignCast(texture_ptr));
                const aspect: f32 = if (tex.height > 0)
                    @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height))
                else
                    1.0;

                clay.UI()(.{
                    .id = clay.ElementId.ID("pdf_image"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                    },
                    .aspect_ratio = .{ .aspect_ratio = aspect },
                    .image = .{ .image_data = texture_ptr },
                    .background_color = .{ 255, 255, 255, 255 }, // Normaler Opaque Tint
                })({});
            } else {
                clay.text("Lade Seite ...", .{ .font_size = 24, .color = theme.text });
            }
        });

        return null;
    }
};
