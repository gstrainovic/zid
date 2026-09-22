const std = @import("std");
const find_bar = @import("../editor/find_bar.zig");
const find_ops = @import("../editor/find_ops.zig");
const pdf_find = @import("../ui/pdf_find.zig");

const c = @cImport({
    @cInclude("fitz-z.h");
    @cInclude("mupdf/fitz.h");
    @cInclude("mupdf/pdf.h");
});

/// Obergrenze für eine gerenderte Seite (Pixel). Darüber wird die Textur hochskaliert,
/// statt bei Zoom 400 % auf A4 über 100 MB anzulegen.
const max_pixels: f32 = 16 * 1024 * 1024;
/// Texturkante, die jede GPU kann (WebGPU-Mindestwert).
const max_edge: f32 = 8192;

pub const PdfHandler = struct {
    allocator: std.mem.Allocator,
    ctx: *c.fz_context,
    doc: *c.fz_document,
    total_pages: u16,
    current_page: u16 = 0,
    path: []const u8,

    // ---- Ansicht: Zoom und Bildlauf (Pixel), gemeinsam für alle Panes mit diesem PDF ----
    /// 1.0 = Seitenbreite (`pdf_nav.geometry`)
    zoom: f32 = 1.0,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Größe der aktuellen Seite in pt, aus dem letzten Rendern
    page_w: f32 = 0,
    page_h: f32 = 0,
    /// Linke obere Ecke der Seite in Seitenkoordinaten (MediaBox muss nicht bei 0 beginnen);
    /// Such-Rechtecke werden darum verschoben.
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    /// Maßstab (px/pt), mit dem die Textur zuletzt angefordert wurde
    requested_scale: f32 = 0,
    /// Von der Ansicht je Frame gesetzt (größter Wert aller Panes), von der Hauptschleife
    /// gelesen und zurückgesetzt. Weicht er deutlich ab, wird neu gerendert.
    wanted_scale: f32 = 0,
    /// Seite gewechselt: die Hauptschleife rendert neu.
    needs_render: bool = false,

    // ---- Suche (Ctrl+F) ----
    find: find_bar.FindState = .{},
    search: pdf_find.Search = .{},
    /// Aktuellen Treffer in den Sichtbereich holen, sobald seine Seite gerendert ist.
    reveal_hit: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*PdfHandler {
        // null terminated path for C
        const path_c = try allocator.dupeZ(u8, path);
        defer allocator.free(path_c);

        const ctx = c.fz_new_context(null, null, c.FZ_STORE_UNLIMITED) orelse {
            return error.FailedToCreateContext;
        };
        errdefer c.fz_drop_context(ctx);

        c.fz_register_document_handlers(ctx);
        
        // Aus einer Kopie im Speicher öffnen, nicht über den Pfad: mupdf hielte die Datei
        // sonst offen, und unter Windows scheitert dann jedes Ersetzen per Rename durch ein
        // anderes Programm (LaTeX, Typst, Export) mit „Zugriff verweigert“.
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1 << 30) catch return error.FailedToOpenDocument;
        defer allocator.free(bytes);
        const doc = c.fz_open_document_from_bytes_z(ctx, path_c.ptr, bytes.ptr, bytes.len) orelse {
            return error.FailedToOpenDocument;
        };
        errdefer c.fz_drop_document(ctx, doc);

        const total_pages = @as(u16, @intCast(c.fz_count_pages_z(ctx, doc)));

        const self = try allocator.create(PdfHandler);
        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .doc = doc,
            .total_pages = total_pages,
            .path = try allocator.dupe(u8, path),
        };
        return self;
    }

    pub fn deinit(self: *PdfHandler) void {
        self.search.deinit(self.allocator);
        c.fz_drop_document(self.ctx, self.doc);
        c.fz_drop_context(self.ctx);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub const Rendered = struct { pixels: []u8, width: u32, height: u32 };

    /// Seite als RGBA. Für die aktuelle Seite merkt sich der Handler Größe und Maßstab
    /// (Zoom-Geometrie, Neu-Rendern bei anderer Fenstergröße).
    pub fn renderPage(self: *PdfHandler, page_number: u16, scale: f32) !Rendered {
        const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse {
            return error.FailedToLoadPage;
        };
        defer c.fz_drop_page(self.ctx, page);

        const bound = c.fz_bound_page(self.ctx, page);
        const pw = bound.x1 - bound.x0;
        const ph = bound.y1 - bound.y0;
        if (pw <= 0 or ph <= 0) return error.FailedToLoadPage;
        if (page_number == self.current_page) {
            self.page_w = pw;
            self.page_h = ph;
            self.origin_x = bound.x0;
            self.origin_y = bound.y0;
            self.requested_scale = scale;
        }
        const scale_final = @min(scale, @sqrt(max_pixels / (pw * ph)), max_edge / @max(pw, ph));
        return self.renderScaled(page, bound, scale_final);
    }

    fn renderScaled(self: *PdfHandler, page: *c.fz_page, bound: c.fz_rect, scale: f32) !Rendered {
        const width = @max(1, @as(u32, @intFromFloat((bound.x1 - bound.x0) * scale)));
        const height = @max(1, @as(u32, @intFromFloat((bound.y1 - bound.y0) * scale)));

        const bbox = c.fz_make_irect(0, 0, @intCast(width), @intCast(height));
        const pix = c.fz_new_pixmap_with_bbox_z(self.ctx, c.fz_device_rgb(self.ctx), bbox, null, 0) orelse {
            return error.FailedToCreatePixmap;
        };
        defer c.fz_drop_pixmap(self.ctx, pix);

        c.fz_clear_pixmap_with_value(self.ctx, pix, 0xFF);

        // Seiten mit Ursprung ungleich (0,0) (MediaBox verschoben) an die Pixmap-Ecke rücken
        const ctm = c.fz_pre_translate(c.fz_scale(scale, scale), -bound.x0, -bound.y0);
        const dev = c.fz_new_draw_device_z(self.ctx, ctm, pix) orelse {
            return error.FailedToCreateDevice;
        };
        defer c.fz_drop_device(self.ctx, dev);
        
        c.fz_run_page_z(self.ctx, page, dev, c.fz_identity, null);
        c.fz_close_device(self.ctx, dev);

        const samples = c.fz_pixmap_samples(self.ctx, pix);
        
        const pixels = try self.allocator.alloc(u8, width * height * 4);
        errdefer self.allocator.free(pixels);

        // Convert RGB to RGBA (optimized loop)
        const total_pixels = width * height;
        for (0..total_pixels) |i| {
            const src_idx = i * 3;
            const dst_idx = i * 4;
            pixels[dst_idx + 0] = samples[src_idx + 0];
            pixels[dst_idx + 1] = samples[src_idx + 1];
            pixels[dst_idx + 2] = samples[src_idx + 2];
            pixels[dst_idx + 3] = 255;
        }

        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
        };
    }

    // ---- Suche ------------------------------------------------------------------------

    /// Text der Seite mit Boxen je Zeichen (Seitenkoordinaten).
    fn pageText(self: *PdfHandler, page_number: u16) !pdf_find.PageText {
        var codes: [*c]c_int = null;
        var boxes: [*c]c.fz_rect = null;
        const n = c.fz_page_text_z(self.ctx, self.doc, page_number, &codes, &boxes);
        defer {
            c.fz_free(self.ctx, codes);
            c.fz_free(self.ctx, boxes);
        }
        if (n < 0) return error.FailedToExtractText;
        const len: usize = @intCast(n);
        const rects = try self.allocator.alloc(pdf_find.Rect, len);
        defer self.allocator.free(rects);
        for (0..len) |i| rects[i] = .{ .x0 = boxes[i].x0, .y0 = boxes[i].y0, .x1 = boxes[i].x1, .y1 = boxes[i].y1 };
        const code_slice: []const i32 = if (len == 0) &.{} else @as([*]const i32, @ptrCast(codes))[0..len];
        return pdf_find.PageText.init(self.allocator, code_slice, rects);
    }

    /// Suche neu starten (Begriff oder Option geändert); der erste Treffer ab der
    /// aktuellen Seite wird angesprungen, sobald er gefunden ist.
    pub fn restartSearch(self: *PdfHandler) void {
        const has = self.find.active and find_ops.Pattern.init(self.find.text(), self.find.options()) != null;
        self.search.restart(self.current_page, has);
        self.find.not_found = self.find.len > 0 and !has; // ungültige Regex
    }

    pub fn closeFind(self: *PdfHandler) void {
        self.find.active = false;
        self.search.clear();
    }

    /// Einige Seiten durchsuchen, bis `budget_ns` verbraucht ist. Liefert true, wenn sich
    /// etwas geändert hat (neue Treffer, Sprung).
    pub fn searchStep(self: *PdfHandler, budget_ns: u64) bool {
        const page0 = self.search.next_page orelse return false;
        const pat = find_ops.Pattern.init(self.find.text(), self.find.options()) orelse {
            self.search.clear();
            return true;
        };
        var timer = std.time.Timer.start() catch null;
        var page = page0;
        var ranges: std.ArrayListUnmanaged([2]usize) = .empty;
        defer ranges.deinit(self.allocator);
        while (true) {
            if (self.pageText(page)) |text_c| {
                var text = text_c;
                defer text.deinit(self.allocator);
                ranges.clearRetainingCapacity();
                var it = pat.iterate(text.text);
                while (it.next()) |h| ranges.append(self.allocator, h) catch break;
                self.search.addPage(self.allocator, page, &text, ranges.items) catch {};
            } else |err| {
                std.log.warn("PDF search: page {d}: {}", .{ page + 1, err });
            }
            if (self.search.pageDone(page, self.total_pages)) |i| self.jumpToHit(i);
            const next = self.search.next_page orelse break;
            page = next;
            if (timer) |*t| {
                if (t.read() >= budget_ns) break;
            } else break;
        }
        if (!self.search.running()) self.find.not_found = self.search.hits.items.len == 0;
        return true;
    }

    /// Enter / Shift+Enter in der Suchleiste.
    pub fn findStep(self: *PdfHandler, forward: bool) void {
        if (self.search.step(forward)) |i| self.jumpToHit(i);
    }

    fn jumpToHit(self: *PdfHandler, i: usize) void {
        const page = self.search.hits.items[i].page;
        if (page != self.current_page) {
            self.current_page = page;
            self.needs_render = true;
        }
        self.reveal_hit = true;
    }

    /// Seite wechseln (Tasten, Knöpfe, Mausrad). `scroll_y` ist der neue Bildlauf.
    pub fn setPage(self: *PdfHandler, page: u16, scroll_y: f32) void {
        if (page == self.current_page) return;
        self.current_page = page;
        self.scroll_y = scroll_y;
        self.needs_render = true;
    }
};
