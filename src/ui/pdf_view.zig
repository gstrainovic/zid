const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const components = @import("components/mod.zig");
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

                _ = components.Button("pdf_prev_page", "‹", pagerTheme(theme, back), false);
                if (back and clicked("pdf_prev_page", mouse_pressed, mouse_x, mouse_y)) delta = -1;

                clay.text(pdf_nav.pageLabel(label_buf, handler.current_page, handler.total_pages), .{
                    .font_size = 18,
                    .color = theme.text,
                });

                _ = components.Button("pdf_next_page", "›", pagerTheme(theme, forward), false);
                if (forward and clicked("pdf_next_page", mouse_pressed, mouse_x, mouse_y)) delta = 1;
            });
        });

        return delta;
    }

    /// Klick auf eine Schaltfläche: Clays `pointerOver` meldet in dieser Ansicht
    /// nichts, deshalb selbst gegen die Bounding-Box des letzten Layouts prüfen.
    fn clicked(id: []const u8, mouse_pressed: bool, mouse_x: f32, mouse_y: f32) bool {
        if (!mouse_pressed) return false;
        const data = clay.getElementData(clay.ElementId.ID(id));
        if (!data.found) return false;
        const bb = data.bounding_box;
        return pdf_nav.hits(.{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height }, mouse_x, mouse_y);
    }

    /// Gesperrte Richtung: gedämpfte Farben statt eigener Button-Variante.
    fn pagerTheme(theme: Theme, enabled: bool) Theme {
        if (enabled) return theme;
        var dimmed = theme;
        dimmed.primary = theme.surface;
        dimmed.text_on_primary = theme.muted;
        dimmed.accent = theme.border;
        return dimmed;
    }
};
