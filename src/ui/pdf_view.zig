const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const pdf_nav = @import("pdf_nav.zig");
const find_bar = @import("../editor/find_bar.zig");
const PdfHandler = @import("../rendering/pdf_handler.zig").PdfHandler;
const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;

/// Höchstens so viele Treffer-Rechtecke je Seite zeichnen (ein „e“ findet sonst tausende
/// und sprengt die Elementgrenze von Clay).
const max_marks_per_page = 400;

pub const PdfViewState = struct {
    /// ID eines Elements dieser Ansicht. Ein Split kopiert die Tabs, dasselbe PDF
    /// steht dann in beiden Panes: ohne Salz meldet Clay `duplicate_id` und
    /// `getElementData` der zweiten Pane bekommt die Box der ersten.
    pub fn idi(name: []const u8, salt: u32) clay.ElementId {
        return clay.ElementId.IDI(name, salt);
    }

    /// Puffer für Beschriftungen, die Clay erst beim Zeichnen liest (siehe `pageLabel`).
    pub const Labels = struct {
        page: [32]u8 = undefined,
        zoom: [16]u8 = undefined,
        find: [48]u8 = undefined,
    };

    /// Sichtfenster der Seite aus dem letzten Layout; null vor dem ersten Frame.
    pub fn viewport(salt: u32) ?pdf_nav.Box {
        const data = clay.getElementData(idi("pdf_viewport", salt));
        if (!data.found) return null;
        const bb = data.bounding_box;
        if (bb.width <= 0 or bb.height <= 0) return null;
        return .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
    }

    /// Geometrie der aktuellen Seite im Sichtfenster; null, solange Fenster oder Seite
    /// unbekannt sind.
    pub fn geometryOf(handler: *const PdfHandler, vp: pdf_nav.Box) ?pdf_nav.Geometry {
        if (handler.page_w <= 0 or handler.page_h <= 0) return null;
        return pdf_nav.geometry(vp.w, vp.h, handler.page_w, handler.page_h, handler.zoom, handler.scroll_x, handler.scroll_y);
    }

    /// Zoom auf `new_zoom`, der Punkt (ax, ay) (Fensterkoordinaten) bleibt stehen. Ohne
    /// Fenster (vor dem ersten Layout) nur den Wert setzen.
    pub fn applyZoom(handler: *PdfHandler, salt: u32, new_zoom: f32, ax: ?f32, ay: ?f32) void {
        const vp = viewport(salt) orelse {
            handler.zoom = new_zoom;
            return;
        };
        const g = geometryOf(handler, vp) orelse {
            handler.zoom = new_zoom;
            return;
        };
        const px = (ax orelse vp.x + vp.w / 2) - vp.x;
        const py = (ay orelse vp.y + vp.h / 2) - vp.y;
        const n = pdf_nav.zoomAround(vp.w, vp.h, handler.page_w, handler.page_h, g, new_zoom, px, py);
        handler.zoom = new_zoom;
        handler.scroll_x = n.scroll_x;
        handler.scroll_y = n.scroll_y;
    }

    /// Rückgabe: Seiten-Delta der Leiste, das der Aufrufer anwendet.
    pub fn render(
        labels: *Labels,
        arena: std.mem.Allocator,
        handler: *PdfHandler,
        maybe_texture: ?*anyopaque,
        theme: Theme,
        salt: u32,
        mouse_pressed: bool,
        mouse_x: f32,
        mouse_y: f32,
    ) ?i16 {
        var delta: ?i16 = null;
        const container_id = idi("pdf_view_container", salt);

        // Geometrie aus dem Sichtfenster des letzten Frames
        const vp = viewport(salt);
        var geo: ?pdf_nav.Geometry = if (vp) |v| geometryOf(handler, v) else null;
        if (vp != null and geo != null) {
            var g = geo.?;
            if (handler.reveal_hit and !handler.needs_render) {
                handler.reveal_hit = false;
                if (handler.search.current) |cur| {
                    const r = handler.search.hitBounds(cur);
                    const v = vp.?;
                    if (pdf_nav.reveal(g, r.y0 - handler.origin_y, r.y1 - handler.origin_y, v.h, true)) |s| handler.scroll_y = s;
                    if (pdf_nav.reveal(g, r.x0 - handler.origin_x, r.x1 - handler.origin_x, v.w, false)) |s| handler.scroll_x = s;
                    g = geometryOf(handler, v).?;
                }
            }
            // Geklemmten Bildlauf zurückschreiben (Mausrad zur vorigen Seite setzt „ganz unten“)
            handler.scroll_x = g.scroll_x;
            handler.scroll_y = g.scroll_y;
            handler.wanted_scale = @max(handler.wanted_scale, g.scale);
            geo = g;
        }

        clay.UI()(.{
            .id = container_id,
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .child_alignment = .{ .x = .center, .y = .top },
                .child_gap = 8,
                .padding = .all(8),
            },
            .background_color = theme.bg,
        })({
            clay.UI()(.{
                .id = idi("pdf_viewport", salt),
                .layout = .{ .sizing = .grow },
                .clip = .{
                    .horizontal = true,
                    .vertical = true,
                    .child_offset = if (geo) |g| .{ .x = g.x, .y = g.y } else .{ .x = 0, .y = 0 },
                },
            })({
                if (maybe_texture != null and geo != null) {
                    const g = geo.?;
                    clay.UI()(.{
                        .id = idi("pdf_image", salt),
                        .layout = .{ .sizing = .{ .w = .fixed(g.w), .h = .fixed(g.h) } },
                        .image = .{ .image_data = maybe_texture.? },
                        .background_color = .{ 255, 255, 255, 255 }, // Normaler Opaque Tint
                    })({
                        renderMarks(handler, g, salt);
                    });
                } else {
                    clay.text("Lade Seite ...", .{ .font_size = 24, .color = theme.text });
                }
            });

            // Leiste: Zurück, Seitenzahl, Weiter, dann Zoom. Gesperrte Ränder bleiben
            // sichtbar, damit die Leiste ihre Breite nicht ändert.
            clay.UI()(.{
                .id = idi("pdf_pager", salt),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = 12,
                    .padding = .all(4),
                },
            })({
                const back = pdf_nav.canGoBack(handler.current_page);
                const forward = pdf_nav.canGoForward(handler.current_page, handler.total_pages);

                if (pagerButton("pdf_prev_page", "‹", theme, salt, back, mouse_pressed, mouse_x, mouse_y)) delta = -1;

                clay.text(pdf_nav.pageLabel(&labels.page, handler.current_page, handler.total_pages), .{
                    .font_size = 18,
                    .color = theme.text,
                });

                if (pagerButton("pdf_next_page", "›", theme, salt, forward, mouse_pressed, mouse_x, mouse_y)) delta = 1;

                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(16) } } })({});

                const z = handler.zoom;
                const min_z = pdf_nav.zoom_levels[0];
                const max_z = pdf_nav.zoom_levels[pdf_nav.zoom_levels.len - 1];
                if (pagerButton("pdf_zoom_out", "−", theme, salt, z > min_z + 0.001, mouse_pressed, mouse_x, mouse_y))
                    applyZoom(handler, salt, pdf_nav.nextZoom(z, false), null, null);
                if (pagerButton("pdf_zoom_reset", pdf_nav.zoomLabel(&labels.zoom, z), theme, salt, true, mouse_pressed, mouse_x, mouse_y))
                    applyZoom(handler, salt, 1.0, null, null);
                if (pagerButton("pdf_zoom_in", "+", theme, salt, z < max_z - 0.001, mouse_pressed, mouse_x, mouse_y))
                    applyZoom(handler, salt, pdf_nav.nextZoom(z, true), null, null);
            });

            if (handler.find.active) {
                const status = handler.search.label(&labels.find, handler.find.len);
                find_bar.render(&handler.find, arena, .{ .widget = idi("pdf_find_widget", salt), .input = idi("pdf_find_input", salt) }, container_id.id, status);
            }
        });

        return delta;
    }

    /// Treffer der aktuellen Seite als halbdurchsichtige Flächen über dem Bild, der
    /// aktuelle kräftiger. Schwebend am Bild und auf das Sichtfenster beschnitten.
    fn renderMarks(handler: *const PdfHandler, g: pdf_nav.Geometry, salt: u32) void {
        if (!handler.find.active or handler.needs_render) return;
        const s = &handler.search;
        var drawn: u32 = 0;
        for (s.hits.items, 0..) |h, i| {
            if (h.page != handler.current_page) continue;
            const is_cur = s.current == i;
            for (s.hitRectsOf(i)) |r| {
                if (drawn >= max_marks_per_page and !is_cur) break;
                clay.UI()(.{
                    .id = idi("pdf_mark", salt *% 4099 +% drawn),
                    .floating = .{
                        .attach_to = .to_parent,
                        .attach_points = .{ .element = .left_top, .parent = .left_top },
                        .offset = .{ .x = (r.x0 - handler.origin_x) * g.scale, .y = (r.y0 - handler.origin_y) * g.scale },
                        .pointer_capture_mode = .passthrough,
                        .clip_to = .to_attached_parent,
                    },
                    .layout = .{ .sizing = .{ .w = .fixed((r.x1 - r.x0) * g.scale), .h = .fixed((r.y1 - r.y0) * g.scale) } },
                    .background_color = if (is_cur) .{ 255, 140, 0, 150 } else .{ 255, 220, 0, 90 },
                })({});
                drawn += 1;
            }
        }
    }

    /// Schaltfläche der Leiste. Eigener Button statt `components.Button`, weil
    /// Clays `pointerOver` in dieser Ansicht nichts meldet: Hover und Klick
    /// rechnen selbst gegen die Bounding-Box aus dem letzten Layout.
    /// Rückgabe: true, wenn in diesem Frame darauf geklickt wurde.
    fn pagerButton(
        id: []const u8,
        label: []const u8,
        theme: Theme,
        salt: u32,
        enabled: bool,
        mouse_pressed: bool,
        mouse_x: f32,
        mouse_y: f32,
    ) bool {
        const element_id = idi(id, salt);
        const hovered = enabled and over(element_id, mouse_x, mouse_y);

        const base_bg = if (enabled) theme.primary else theme.surface;
        // Deutlich sichtbar: heller Hintergrund und der Fokusrahmen.
        const bg = if (hovered) pdf_nav.brighten(base_bg, 45) else base_bg;

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
                .color = if (hovered) theme.border_focus else if (enabled) theme.accent else theme.border,
            },
        })({
            clay.text(label, .{
                .font_size = 24,
                .color = if (enabled) theme.text_on_primary else theme.muted,
            });
        });

        return hovered and mouse_pressed;
    }

    const button_ids = [_][]const u8{ "pdf_prev_page", "pdf_next_page", "pdf_zoom_out", "pdf_zoom_reset", "pdf_zoom_in" };

    /// Zeiger über einer Schaltfläche der Leiste? Für den Hand-Cursor.
    pub fn overPagerButton(salt: u32, mouse_x: f32, mouse_y: f32) bool {
        for (button_ids) |id| if (over(idi(id, salt), mouse_x, mouse_y)) return true;
        return false;
    }

    /// Zeiger über dem Element? Bounding-Box aus dem letzten Layout.
    fn over(element_id: clay.ElementId, mouse_x: f32, mouse_y: f32) bool {
        const data = clay.getElementData(element_id);
        if (!data.found) return false;
        const bb = data.bounding_box;
        return pdf_nav.hits(.{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height }, mouse_x, mouse_y);
    }
};
