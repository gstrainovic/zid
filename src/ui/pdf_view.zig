const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const pdf_nav = @import("pdf_nav.zig");
const PdfHandler = @import("../rendering/pdf_handler.zig").PdfHandler;
const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;

pub const PdfViewState = struct {
    /// Rückgabe: Seiten-Delta, das die Hauptschleife anwendet.
    pub fn render(
        label_buf: []u8,
        handler: *PdfHandler,
        maybe_texture: ?*anyopaque,
        theme: Theme,
        mouse_pressed: bool,
        mouse_x: f32,
        mouse_y: f32,
    ) ?i16 {
        var delta: ?i16 = null;

        clay.UI()(.{
            .id = clay.ElementId.ID("pdf_view_container"),
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .child_alignment = .{ .x = .center, .y = .center },
                .child_gap = 8,
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

            // Leiste: Zurück, Seitenzahl, Weiter. Gesperrte Ränder bleiben
            // sichtbar, damit die Leiste ihre Breite nicht ändert.
            clay.UI()(.{
                .id = clay.ElementId.ID("pdf_pager"),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = 12,
                    .padding = .all(4),
                },
            })({
                const back = pdf_nav.canGoBack(handler.current_page);
                const forward = pdf_nav.canGoForward(handler.current_page, handler.total_pages);

                if (pagerButton("pdf_prev_page", "‹", theme, back, mouse_pressed, mouse_x, mouse_y)) delta = -1;

                clay.text(pdf_nav.pageLabel(label_buf, handler.current_page, handler.total_pages), .{
                    .font_size = 18,
                    .color = theme.text,
                });

                if (pagerButton("pdf_next_page", "›", theme, forward, mouse_pressed, mouse_x, mouse_y)) delta = 1;
            });
        });

        return delta;
    }

    /// Schaltfläche der Leiste. Eigener Button statt `components.Button`, weil
    /// Clays `pointerOver` in dieser Ansicht nichts meldet: Hover und Klick
    /// rechnen selbst gegen die Bounding-Box aus dem letzten Layout.
    /// Rückgabe: true, wenn in diesem Frame darauf geklickt wurde.
    fn pagerButton(
        id: []const u8,
        label: []const u8,
        theme: Theme,
        enabled: bool,
        mouse_pressed: bool,
        mouse_x: f32,
        mouse_y: f32,
    ) bool {
        const element_id = clay.ElementId.ID(id);
        const hovered = enabled and over(element_id, mouse_x, mouse_y);

        const base_bg = if (enabled) theme.primary else theme.surface;
        const bg = if (hovered) pdf_nav.brighten(base_bg, 30) else base_bg;

        clay.UI()(.{
            .id = element_id,
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .padding = .axes(12, 24),
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = bg,
            .corner_radius = .all(4),
            .border = .{
                .width = .all(2),
                .color = if (enabled) theme.accent else theme.border,
            },
        })({
            clay.text(label, .{
                .font_size = 24,
                .color = if (enabled) theme.text_on_primary else theme.muted,
            });
        });

        return hovered and mouse_pressed;
    }

    /// Zeiger über dem Element? Bounding-Box aus dem letzten Layout.
    fn over(element_id: clay.ElementId, mouse_x: f32, mouse_y: f32) bool {
        const data = clay.getElementData(element_id);
        if (!data.found) return false;
        const bb = data.bounding_box;
        return pdf_nav.hits(.{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height }, mouse_x, mouse_y);
    }

};
