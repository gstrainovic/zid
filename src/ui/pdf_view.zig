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
        var page_delta: ?i16 = null;

        clay.UI()(.{
            .id = clay.ElementId.ID("pdf_view_container"),
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .child_alignment = .{ .x = .center, .y = .center },
                .padding = .all(16),
                .child_gap = 16,
            },
            .background_color = theme.bg,
        })({
            // Toolbar
            clay.UI()(.{
                .id = clay.ElementId.ID("pdf_toolbar"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(48) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = 16,
                },
                .background_color = theme.surface,
                .border = .{ .width = .{ .bottom = 1 }, .color = theme.border },
                .corner_radius = .all(8),
            })({
                if (components.Button("PdfPrev", "<", theme, mouse_pressed)) {
                    page_delta = -1;
                }
                
                var buf: [64]u8 = undefined;
                const page_text = std.fmt.bufPrint(&buf, "Seite {d} / {d}", .{ handler.current_page + 1, handler.total_pages }) catch "PDF";
                clay.text(page_text, .{ .font_size = 20, .color = theme.text });

                if (components.Button("PdfNext", ">", theme, mouse_pressed)) {
                    page_delta = 1;
                }
            });

            // Page display
            clay.UI()(.{
                .id = clay.ElementId.ID("pdf_display_scroll"),
                .layout = .{
                    .sizing = .grow,
                    .child_alignment = .{ .x = .center, .y = .top },
                    .padding = .all(8),
                },
                .background_color = theme.bg,
                .clip = .{ .vertical = true, .horizontal = true },
            })({
                if (maybe_texture) |texture_ptr| {
                    const tex: *const ImageTexture = @ptrCast(@alignCast(texture_ptr));
                    const aspect: f32 = if (tex.height > 0)
                        @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height))
                    else
                        0.7;

                    clay.UI()(.{
                        .id = clay.ElementId.ID("pdf_image"),
                        .layout = .{
                            .sizing = .{ .w = .fit, .h = .grow },
                        },
                        .aspect_ratio = .{ .aspect_ratio = aspect },
                        .image = .{ .image_data = texture_ptr },
                        .background_color = .{ 255, 255, 255, 255 },
                    })({});
                } else {
                    clay.text("Lade Seite...", .{ .font_size = 24, .color = theme.muted });
                }
            });
        });
        
        return page_delta;
    }
};
