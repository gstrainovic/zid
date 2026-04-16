//! DirectWrite font face implementation
//!
//! Implements the FontFace interface using DirectWrite for glyph rasterization
//! on Windows.

const std = @import("std");
const dw = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");
const windows = std.os.windows;

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const FontFace = font_face_mod.FontFace;

const log = std.log.scoped(.text_dw);

/// Global DirectWrite factory (initialized once)
var global_dw_factory: ?*anyopaque = null;
var global_gdi_interop: ?*anyopaque = null;

fn ensureFactory() !*anyopaque {
    if (global_dw_factory) |f| return f;
    var factory: ?*anyopaque = null;
    const hr = dw.DWriteCreateFactory(0, &dw.IID_IDWriteFactory, &factory);
    if (hr < 0) return error.DWriteInitFailed;
    global_dw_factory = factory;
    return factory.?;
}

fn ensureGdiInterop() !*anyopaque {
    if (global_gdi_interop) |i| return i;
    const factory = try ensureFactory();
    var interop: ?*anyopaque = null;
    const hr = dw.vtable(dw.IDWriteFactory_VTable, factory).CreateGdiInterop(factory, &interop);
    if (hr < 0) return error.GdiInteropFailed;
    global_gdi_interop = interop;
    return interop.?;
}

pub const DirectWriteFace = struct {
    factory: *anyopaque,
    font_face: *anyopaque,
    metrics: Metrics,
    point_size: f32,
    
    // Cache common objects
    render_target: ?*anyopaque = null,

    const Self = @This();

    pub fn init(path: []const u8, size: f32) !Self {
        const factory = try ensureFactory();
        const vt = dw.vtable(dw.IDWriteFactory_VTable, factory);

        // Convert path to UTF-16
        var path_w: [512:0]u16 = undefined;
        const path_len = try std.unicode.utf8ToUtf16Le(&path_w, path);
        path_w[path_len] = 0;

        // 1. Create font file reference
        var font_file: ?*anyopaque = null;
        var hr = vt.CreateFontFileReference(factory, &path_w, null, &font_file);
        if (hr < 0) return error.FontLoadFailed;
        defer _ = dw.Release(font_file.?);

        // 2. Create font face
        var font_face: ?*anyopaque = null;
        const files = [_]?*anyopaque{font_file};
        hr = vt.CreateFontFace(factory, .TRUETYPE, 1, &files, 0, .NONE, &font_face);
        if (hr < 0) return error.FontFaceCreationFailed;
        errdefer _ = dw.Release(font_face.?);

        const face_ptr = font_face.?;
        const vt_face = dw.vtable(dw.IDWriteFontFace_VTable, face_ptr);

        // 3. Compute metrics
        var dw_metrics: dw.DWRITE_FONT_METRICS = undefined;
        vt_face.GetMetrics(face_ptr, &dw_metrics);

        const scale = size / @as(f32, @floatFromInt(dw_metrics.designUnitsPerEm));
        const metrics = Metrics{
            .units_per_em = dw_metrics.designUnitsPerEm,
            .ascender = @as(f32, @floatFromInt(dw_metrics.ascent)) * scale,
            .descender = @as(f32, @floatFromInt(dw_metrics.descent)) * scale,
            .line_gap = @as(f32, @floatFromInt(dw_metrics.lineGap)) * scale,
            .cap_height = @as(f32, @floatFromInt(dw_metrics.capHeight)) * scale,
            .x_height = @as(f32, @floatFromInt(dw_metrics.xHeight)) * scale,
            .underline_position = @as(f32, @floatFromInt(dw_metrics.underlinePosition)) * scale,
            .underline_thickness = @as(f32, @floatFromInt(dw_metrics.underlineThickness)) * scale,
            .line_height = @as(f32, @floatFromInt(dw_metrics.ascent + dw_metrics.descent + @as(u16, @intCast(@max(0, dw_metrics.lineGap))))) * scale,
            .point_size = size,
            .is_monospace = false,
            .cell_width = 0,
        };

        return Self{
            .factory = factory,
            .font_face = face_ptr,
            .metrics = metrics,
            .point_size = size,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.render_target) |rt| {
            _ = dw.Release(rt);
        }
        _ = dw.Release(self.font_face);
        self.* = undefined;
    }

    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        const cp = [_]u32{@intCast(codepoint)};
        var idx: [1]u16 = undefined;
        const hr = dw.vtable(dw.IDWriteFontFace_VTable, self.font_face).GetGlyphIndices(self.font_face, &cp, 1, &idx);
        return if (hr < 0) 0 else idx[0];
    }

    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        const ids = [_]u16{glyph_id};
        var m: [1]dw.DWRITE_GLYPH_METRICS = undefined;
        const hr = dw.vtable(dw.IDWriteFontFace_VTable, self.font_face).GetDesignGlyphMetrics(self.font_face, &ids, 1, &m, windows.FALSE);
        if (hr < 0) return std.mem.zeroes(GlyphMetrics);

        const scale = self.point_size / @as(f32, @floatFromInt(self.metrics.units_per_em));
        
        // In DirectWrite, the black box top relative to the baseline is (verticalOriginY - topSideBearing).
        // Since Y points down, the top is at negative coordinates.
        // FreeType bearing_y is the distance from baseline UP to the top of the glyph.
        const bearing_y = @as(f32, @floatFromInt(m[0].verticalOriginY - m[0].topSideBearing));
        
        return .{
            .glyph_id = glyph_id,
            .advance_x = @as(f32, @floatFromInt(m[0].advanceWidth)) * scale,
            .advance_y = 0,
            .bearing_x = @as(f32, @floatFromInt(m[0].leftSideBearing)) * scale,
            .bearing_y = bearing_y * scale,
            .width = @as(f32, @floatFromInt(@as(i32, @intCast(m[0].advanceWidth)) - m[0].leftSideBearing - m[0].rightSideBearing)) * scale,
            .height = @as(f32, @floatFromInt(@as(i32, @intCast(m[0].advanceHeight)) - m[0].topSideBearing - m[0].bottomSideBearing)) * scale,
        };
    }

    pub fn renderGlyphSubpixel(
        self: *Self,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        _ = buffer_size;
        _ = subpixel_y;

        const interop = try ensureGdiInterop();
        
        // Ensure render target is large enough (max glyph size 256x256)
        if (self.render_target == null) {
            var rt: ?*anyopaque = null;
            const hr = dw.vtable(dw.IDWriteGdiInterop_VTable, interop).CreateBitmapRenderTarget(interop, null, 256, 256, &rt);
            if (hr < 0) return error.RenderTargetCreationFailed;
            self.render_target = rt;
            
            // Set grayscale antialiasing
            _ = dw.vtable(dw.IDWriteBitmapRenderTarget_VTable, rt.?).SetTextAntialiasMode(rt.?, .GRAYSCALE);
        }
        
        const rt = self.render_target.?;
        const vt_rt = dw.vtable(dw.IDWriteBitmapRenderTarget_VTable, rt);

        // Clear target to black
        const hdc = vt_rt.GetMemoryDC(rt);
        _ = dw.PatBlt(hdc, 0, 0, 256, 256, 0x00000042); // BLACKNESS

        var glyph_indices = [_]u16{glyph_id};
        var glyph_advances = [_]f32{0.0};
        
        const run = dw.DWRITE_GLYPH_RUN{
            .fontFace = self.font_face,
            .fontEmSize = font_size * scale,
            .glyphCount = 1,
            .glyphIndices = &glyph_indices,
            .glyphAdvances = &glyph_advances,
            .glyphOffsets = null,
            .isSideways = windows.FALSE,
            .bidiLevel = 0,
        };

        // Get metrics to calculate exact size and offsets
        const gm = self.glyphMetrics(glyph_id);
        
        // Ratio between the requested physical rasterization size and the base point_size
        const physical_size = font_size * scale;
        const size_ratio = physical_size / self.point_size;
        
        const physical_width = @as(u32, @intFromFloat(@ceil(gm.width * size_ratio))) + 2;
        const physical_height = @as(u32, @intFromFloat(@ceil(gm.height * size_ratio))) + 2;
        
        // Render at padding offset
        const padding = 8.0;
        // The glyph starts at baseline_x + gm.bearing_x * size_ratio. 
        // We want the resulting RasterizedGlyph to have the correct internal offsets.
        const baseline_x = padding - (gm.bearing_x * size_ratio) + subpixel_x;
        const baseline_y = padding + (gm.bearing_y * size_ratio);

        // Create default rendering params
        var rendering_params: ?*anyopaque = null;
        const hr_params = dw.vtable(dw.IDWriteFactory_VTable, self.factory).CreateRenderingParams(self.factory, &rendering_params);
        if (hr_params >= 0) {
            defer _ = dw.Release(rendering_params.?);
            
            // Draw in white (0x00FFFFFF)
            const hr = vt_rt.DrawGlyphRun(rt, baseline_x, baseline_y, .NATURAL, &run, rendering_params, 0x00FFFFFF, null);
            if (hr < 0) {
                log.err("DrawGlyphRun failed with HRESULT: 0x{x}", .{@as(u32, @bitCast(hr))});
                return error.GlyphRenderFailed;
            }
        } else {
            return error.RenderingParamsFailed;
        }

        // Get bitmap data
        const dib = dw.GetCurrentObject(hdc, 7); // OBJ_BITMAP
        var bitmap: dw.BITMAP = undefined;
        _ = dw.GetObjectW(dib, @sizeOf(dw.BITMAP), &bitmap);

        const pixels: [*]u8 = @ptrCast(bitmap.bmBits.?);
        
        // Copy to output buffer (grayscale)
        // We read from (0,0) because baseline_x/y already include the padding
        // so the glyph starts at (padding, padding) in the bitmap.
        for (0..physical_height) |y| {
            for (0..physical_width) |x| {
                const src_x = x + @as(u32, @intFromFloat(@floor(padding)));
                const src_y = y + @as(u32, @intFromFloat(@floor(padding)));
                const src_idx = src_y * @as(usize, @intCast(bitmap.bmWidthBytes)) + src_x * 4;
                // Red channel as grayscale alpha
                buffer[y * physical_width + x] = pixels[src_idx + 2];
            }
        }

        return RasterizedGlyph{
            .width = physical_width,
            .height = physical_height,
            .offset_x = @as(i32, @intFromFloat(@floor(gm.bearing_x * size_ratio))),
            .offset_y = @as(i32, @intFromFloat(@floor(gm.bearing_y * size_ratio))),
            .advance_x = gm.advance_x * (font_size / self.point_size),
            .is_color = false,
        };
    }
};
