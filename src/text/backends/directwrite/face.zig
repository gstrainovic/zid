//! DirectWrite font face implementation
//!
//! Implements the FontFace interface using DirectWrite for glyph rasterization
//! on Windows.

const std = @import("std");
const dw = @import("bindings.zig");
const types = @import("../../types.zig");
const bitmap_scale = @import("../../bitmap_scale.zig");
const font_face_mod = @import("../../font_face.zig");
const windows = std.os.windows;

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const ShapedGlyph = types.ShapedGlyph;
const ShapedRun = types.ShapedRun;

/// HarfBuzz aus MuPDFs Drittbibliothek, über `emoji_hb.c` (nur Windows gebaut).
const HbGlyph = extern struct { glyph: c_uint, cluster: c_uint, x_advance: c_int, x_offset: c_int, y_offset: c_int };
extern fn zid_hb_open(path: [*:0]const u8) ?*anyopaque;
extern fn zid_hb_upem(h: *anyopaque) c_uint;
extern fn zid_hb_shape(h: *anyopaque, text: [*]const u8, len: c_int, out: [*]HbGlyph, max: c_int) c_int;
extern fn zid_hb_close(h: ?*anyopaque) void;
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

var global_dw_factory2: ?*anyopaque = null;

/// IDWriteFactory2 für Farbschriften (Windows 8.1+), aus der vorhandenen Factory erfragt.
fn ensureFactory2() !*anyopaque {
    if (global_dw_factory2) |f| return f;
    const factory = try ensureFactory();
    var f2: ?*anyopaque = null;
    const hr = dw.vtable(dw.IUnknown_VTable, factory).QueryInterface(factory, &dw.IID_IDWriteFactory2, &f2);
    if (hr < 0 or f2 == null) return error.DWriteFactory2Unavailable;
    global_dw_factory2 = f2;
    return f2.?;
}

/// Kantenlänge der GDI-Bitmap, in die Glyphen gerastert werden, und Rand darin.
const rt_size: u32 = 256;
const rt_padding: f32 = 8.0;

/// Deckung einer Schicht, Zwischenpuffer für `renderColorGlyph`. Gerastert wird unter der
/// Sperre des Glyph-Caches, nie gleichzeitig.
var layer_coverage: [rt_size * rt_size]u8 = undefined;

/// Farbe für Schichten ohne eigene Farbe (Palette 0xFFFF = Textfarbe). Der Farbatlas kennt
/// keine Textfarbe; hell, weil zid standardmässig dunkel ist.
const foreground_color = [4]f32{ 0.85, 0.85, 0.85, 1 };

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
    /// HarfBuzz-Schrift für Emoji-Folgen (`enableShaping`), sonst null
    hb: ?*anyopaque = null,
    hb_upem: u32 = 0,
    /// Gemerkte Antworten von `hasCodepoint` für die BMP (auf dem Heap, damit Kopien der Face
    /// ihn teilen). Ohne ihn kostete jedes Formen ohne Cache-Treffer einen COM-Aufruf je
    /// Zeichen über ASCII; die Vorschau von AGENTS.md wurde so langsam, dass e2e_md_preview
    /// mitten im Scrollen mass.
    cp_cache: ?*CodepointCache = null,

    const CodepointCache = struct {
        known: std.StaticBitSet(0x10000) = .initEmpty(),
        has: std.StaticBitSet(0x10000) = .initEmpty(),
    };

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

        const cp_cache = std.heap.page_allocator.create(CodepointCache) catch null;
        if (cp_cache) |c| c.* = .{};
        return Self{
            .factory = factory,
            .font_face = face_ptr,
            .metrics = metrics,
            .point_size = size,
            .cp_cache = cp_cache,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.render_target) |rt| {
            _ = dw.Release(rt);
        }
        if (self.hb) |h| zid_hb_close(h);
        if (self.cp_cache) |c| std.heap.page_allocator.destroy(c);
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

    // ---- Emoji-Rückfall (Farbschrift, `TextSystem.ensureEmojiFace`) ----------------------

    /// Hat die Schrift einen Glyph für dieses Zeichen?
    pub fn hasCodepoint(self: *const Self, codepoint: u21) bool {
        const c = self.cp_cache orelse return self.glyphIndex(codepoint) != 0;
        if (codepoint >= 0x10000) return self.glyphIndex(codepoint) != 0;
        if (c.known.isSet(codepoint)) return c.has.isSet(codepoint);
        const has = self.glyphIndex(codepoint) != 0;
        c.known.set(codepoint);
        c.has.setValue(codepoint, has);
        return has;
    }

    /// Zeiger, über den der Glyph-Cache Rückfall-Glyphen dieser Schrift rastert
    /// (`GlyphCache.renderFallbackGlyph` → `renderColorGlyph`). Die Schrift liegt im
    /// TextSystem und wandert nicht.
    pub fn rawFace(self: *const Self) *anyopaque {
        return @ptrCast(@constCast(self));
    }

    /// Emoji-Folgen formen können (nur die Emoji-Schrift, `TextSystem.tryEmojiFace`):
    /// HarfBuzz lädt dieselbe Datei, die Glyph-IDs passen also zu DirectWrite.
    pub fn enableShaping(self: *Self, path: []const u8) void {
        var buf: [512:0]u8 = undefined;
        if (path.len >= buf.len) return;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const h = zid_hb_open(&buf) orelse return;
        self.hb = h;
        self.hb_upem = zid_hb_upem(h);
    }

    /// Lauf mit HarfBuzz formen: ZWJ-Folgen, Hautton, Tasten und Flaggen werden zu einem
    /// Glyph (GSUB-Ligaturen), was `SimpleShaper` nicht kann. null ohne HarfBuzz.
    pub fn shapeRun(self: *const Self, text: []const u8, allocator: std.mem.Allocator) !?ShapedRun {
        const h = self.hb orelse return null;
        if (text.len == 0 or self.hb_upem == 0) return null;
        // Nie mehr Glyphen als Bytes: jedes Zeichen ist mindestens ein Byte
        const raw = try allocator.alloc(HbGlyph, text.len);
        defer allocator.free(raw);
        const n = zid_hb_shape(h, text.ptr, @intCast(text.len), raw.ptr, @intCast(raw.len));
        if (n <= 0) return null;

        const scale = self.point_size / @as(f32, @floatFromInt(self.hb_upem));
        const glyphs = try allocator.alloc(ShapedGlyph, @intCast(n));
        var width: f32 = 0;
        for (raw[0..@intCast(n)], glyphs) |g, *out| {
            const adv = @as(f32, @floatFromInt(g.x_advance)) * scale;
            out.* = .{
                .glyph_id = @intCast(g.glyph),
                .x_offset = @as(f32, @floatFromInt(g.x_offset)) * scale,
                .y_offset = @as(f32, @floatFromInt(g.y_offset)) * scale,
                .x_advance = adv,
                .y_advance = 0,
                .cluster = g.cluster,
            };
            width += adv;
        }
        return ShapedRun{ .glyphs = glyphs, .width = width, .owned = true };
    }

    /// Vorschub eines Glyphs; der Emoji-Pfad fragt, wenn der Shaper 0 meldet.
    pub fn strikeAdvance(self: *const Self, glyph_id: u16) f32 {
        return self.glyphMetrics(glyph_id).advance_x;
    }

    /// Liefert DirectWrite für diese Schrift Farbschichten? Name wie beim FreeType-Backend
    /// (dort Bitmap-Emoji); hier heisst es COLR, etwa Segoe UI Emoji. Geprüft an 😀.
    pub fn isColorBitmapFont(self: *const Self) bool {
        const glyph = self.glyphIndex(0x1F600);
        if (glyph == 0) return false;
        const factory2 = ensureFactory2() catch return false;
        var ids = [_]u16{glyph};
        var advances = [_]f32{0};
        const run = dw.DWRITE_GLYPH_RUN{
            .fontFace = self.font_face,
            .fontEmSize = self.point_size,
            .glyphCount = 1,
            .glyphIndices = &ids,
            .glyphAdvances = &advances,
            .glyphOffsets = null,
            .isSideways = windows.FALSE,
            .bidiLevel = 0,
        };
        var layers: ?*anyopaque = null;
        const hr = dw.vtable(dw.IDWriteFactory2_VTable, factory2).TranslateColorGlyphRun(factory2, 0, 0, &run, null, .NATURAL, null, 0, &layers);
        if (hr < 0 or layers == null) return false;
        _ = dw.Release(layers.?);
        return true;
    }

    /// Farb-Emoji: DirectWrite zerlegt den Glyph in einfarbige Schichten
    /// (`TranslateColorGlyphRun`), jede wird wie ein normaler Glyph in Graustufen gerastert
    /// und mit ihrer Farbe über das Bild gelegt (`bitmap_scale.blendLayer`). Ergebnis RGBA ohne
    /// Vormultiplikation wie beim FreeType-Pfad. Die Masse kommen aus der Em-Box: der
    /// Grundglyph einer Farbschrift muss keinen eigenen Umriss haben.
    pub fn renderColorGlyph(
        self: *Self,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        const factory2 = try ensureFactory2();
        const rt = try self.ensureRenderTarget();
        const vt_rt = dw.vtable(dw.IDWriteBitmapRenderTarget_VTable, rt);
        const hdc = vt_rt.GetMemoryDC(rt);

        const ratio = font_size * scale / self.point_size;
        const gm = self.glyphMetrics(glyph_id);
        const ascent_px = @ceil(self.metrics.ascender * ratio);
        const descent_px = @ceil(self.metrics.descender * ratio);
        const width: u32 = @as(u32, @intFromFloat(@ceil(gm.advance_x * ratio))) + 2;
        const height: u32 = @as(u32, @intFromFloat(ascent_px + descent_px)) + 2;
        const pad: u32 = @intFromFloat(rt_padding);
        if (width + pad > rt_size or height + pad > rt_size) return error.GlyphTooLarge;
        if (width * height * 4 > buffer_size or width * height * 4 > buffer.len) return error.BufferTooSmall;

        var ids = [_]u16{glyph_id};
        var advances = [_]f32{0};
        const run = dw.DWRITE_GLYPH_RUN{
            .fontFace = self.font_face,
            .fontEmSize = font_size * scale,
            .glyphCount = 1,
            .glyphIndices = &ids,
            .glyphAdvances = &advances,
            .glyphOffsets = null,
            .isSideways = windows.FALSE,
            .bidiLevel = 0,
        };
        const origin_x = rt_padding + subpixel_x;
        const origin_y = rt_padding + ascent_px;
        var layers: ?*anyopaque = null;
        const hr = dw.vtable(dw.IDWriteFactory2_VTable, factory2).TranslateColorGlyphRun(
            factory2,
            origin_x,
            origin_y,
            &run,
            null,
            .NATURAL,
            null,
            0,
            &layers,
        );
        if (hr < 0 and hr != dw.DWRITE_E_NOCOLOR) return error.ColorGlyphFailed;
        defer if (layers) |l| {
            _ = dw.Release(l);
        };

        var params: ?*anyopaque = null;
        if (dw.vtable(dw.IDWriteFactory_VTable, self.factory).CreateRenderingParams(self.factory, &params) < 0) return error.RenderingParamsFailed;
        defer _ = dw.Release(params.?);

        const out = buffer[0 .. width * height * 4];
        @memset(out, 0);
        const cov = layer_coverage[0 .. width * height];

        // Glyph ohne Farbschichten (Textform wie ⚠, Bausteine einer Folge wie der
        // Zero-Width-Joiner): einfarbig in Vordergrundfarbe (else-Zweig unten). Ein
        // Fehler hier liesse sonst das Zeichnen des ganzen Frames abbrechen.
        if (layers) |en| {
            const vt_en = dw.vtable(dw.IDWriteColorGlyphRunEnumerator_VTable, en);
            while (true) {
                var has_run: dw.BOOL = windows.FALSE;
                if (vt_en.MoveNext(en, &has_run) < 0 or has_run == windows.FALSE) break;
                var layer: *const dw.DWRITE_COLOR_GLYPH_RUN = undefined;
                if (vt_en.GetCurrentRun(en, &layer) < 0) break;

                _ = dw.PatBlt(hdc, 0, 0, @intCast(rt_size), @intCast(rt_size), 0x00000042); // BLACKNESS
                if (vt_rt.DrawGlyphRun(rt, layer.baselineOriginX, layer.baselineOriginY, .NATURAL, &layer.glyphRun, params, 0x00FFFFFF, null) < 0) continue;
                readCoverage(hdc, width, height, cov);
                const color: [4]f32 = if (layer.paletteIndex == 0xFFFF)
                    foreground_color
                else
                    .{ layer.runColor.r, layer.runColor.g, layer.runColor.b, layer.runColor.a };
                bitmap_scale.blendLayer(out, cov, color);
            }
        } else {
            _ = dw.PatBlt(hdc, 0, 0, @intCast(rt_size), @intCast(rt_size), 0x00000042); // BLACKNESS
            if (vt_rt.DrawGlyphRun(rt, origin_x, origin_y, .NATURAL, &run, params, 0x00FFFFFF, null) >= 0) {
                readCoverage(hdc, width, height, cov);
                bitmap_scale.blendLayer(out, cov, foreground_color);
            }
        }

        return RasterizedGlyph{
            .width = width,
            .height = height,
            .offset_x = 0,
            .offset_y = @intFromFloat(ascent_px),
            .advance_x = gm.advance_x * (font_size / self.point_size),
            .is_color = true,
        };
    }

    /// GDI-Bitmap zum Rastern, einmal je Schrift angelegt (Graustufen-Kantenglättung).
    fn ensureRenderTarget(self: *Self) !*anyopaque {
        if (self.render_target) |rt| return rt;
        const interop = try ensureGdiInterop();
        var rt: ?*anyopaque = null;
        const hr = dw.vtable(dw.IDWriteGdiInterop_VTable, interop).CreateBitmapRenderTarget(interop, null, rt_size, rt_size, &rt);
        if (hr < 0 or rt == null) return error.RenderTargetCreationFailed;
        _ = dw.vtable(dw.IDWriteBitmapRenderTarget_VTable, rt.?).SetTextAntialiasMode(rt.?, .GRAYSCALE);
        self.render_target = rt;
        return rt.?;
    }

    /// Deckung (Rotkanal, weiss auf schwarz gezeichnet) des Bereichs ab dem Rand lesen.
    fn readCoverage(hdc: windows.HDC, width: u32, height: u32, out: []u8) void {
        const dib = dw.GetCurrentObject(hdc, 7); // OBJ_BITMAP
        var bitmap: dw.BITMAP = undefined;
        _ = dw.GetObjectW(dib, @sizeOf(dw.BITMAP), &bitmap);
        const pixels: [*]u8 = @ptrCast(bitmap.bmBits.?);
        const pad: usize = @intFromFloat(@floor(rt_padding));
        for (0..height) |y| {
            for (0..width) |x| {
                const src_idx = (y + pad) * @as(usize, @intCast(bitmap.bmWidthBytes)) + (x + pad) * 4;
                out[y * width + x] = pixels[src_idx + 2];
            }
        }
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

        const rt = try self.ensureRenderTarget();
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
        // Die Grundlinie liegt auf einem ganzen Pixel, die Bitmap-Kante um den ganzzahligen
        // Teil der Bearing darüber bzw. links davon. Vorher lag die Grundlinie bei
        // padding + bearing (gebrochen) und offset_y war floor(bearing): jeder Glyph wurde bis
        // zu 1 px zu tief gesetzt, je nach Nachkommateil seiner Bearing — die Buchstaben
        // einer Zeile standen sichtbar auf verschiedenen Grundlinien.
        const bearing_x_px = @floor(gm.bearing_x * size_ratio);
        const bearing_y_px = @ceil(gm.bearing_y * size_ratio);
        const baseline_x = padding - bearing_x_px + subpixel_x;
        const baseline_y = padding + bearing_y_px;

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
            .offset_x = @as(i32, @intFromFloat(bearing_x_px)),
            .offset_y = @as(i32, @intFromFloat(bearing_y_px)),
            .advance_x = gm.advance_x * (font_size / self.point_size),
            .is_color = false,
        };
    }
};
