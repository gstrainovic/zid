const std = @import("std");

const c = @cImport({
    @cInclude("fitz-z.h");
    @cInclude("mupdf/fitz.h");
    @cInclude("mupdf/pdf.h");
});

pub const PdfHandler = struct {
    allocator: std.mem.Allocator,
    ctx: *c.fz_context,
    doc: *c.fz_document,
    total_pages: u16,
    current_page: u16 = 0,
    scale: f32 = 1.0,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*PdfHandler {
        // null terminated path for C
        const path_c = try allocator.dupeZ(u8, path);
        defer allocator.free(path_c);

        const ctx = c.fz_new_context(null, null, c.FZ_STORE_UNLIMITED) orelse {
            return error.FailedToCreateContext;
        };
        errdefer c.fz_drop_context(ctx);

        c.fz_register_document_handlers(ctx);
        
        // Use the wrapper to open document (handles setjmp/longjmp)
        const doc = c.fz_open_document_z(ctx, path_c.ptr) orelse {
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
        c.fz_drop_document(self.ctx, self.doc);
        c.fz_drop_context(self.ctx);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn renderPage(
        self: *PdfHandler,
        page_number: u16,
        scale: f32,
    ) !struct { pixels: []u8, width: u32, height: u32 } {
        const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse {
            return error.FailedToLoadPage;
        };
        defer c.fz_drop_page(self.ctx, page);
        
        const bound = c.fz_bound_page(self.ctx, page);
        const width = @as(u32, @intFromFloat((bound.x1 - bound.x0) * scale));
        const height = @as(u32, @intFromFloat((bound.y1 - bound.y0) * scale));

        const bbox = c.fz_make_irect(0, 0, @intCast(width), @intCast(height));
        const pix = c.fz_new_pixmap_with_bbox_z(self.ctx, c.fz_device_rgb(self.ctx), bbox, null, 0) orelse {
            return error.FailedToCreatePixmap;
        };
        defer c.fz_drop_pixmap(self.ctx, pix);
        
        c.fz_clear_pixmap_with_value(self.ctx, pix, 0xFF);

        const ctm = c.fz_scale(scale, scale);
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
};
