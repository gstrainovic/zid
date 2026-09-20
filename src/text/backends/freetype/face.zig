//! FreeType font face implementation
//!
//! Implements the FontFace interface using FreeType for glyph rasterization
//! and Fontconfig for font discovery on Linux.

const std = @import("std");
const ft = @import("bindings.zig");
const bitmap_scale = @import("../../bitmap_scale.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontFace = font_face_mod.FontFace;

/// Global FreeType library instance (initialized once)
var global_ft_library: ?ft.FT_Library = null;
var library_init_error: ?ft.FT_Error = null;

/// Initialize the global FreeType library
fn ensureLibraryInit() !ft.FT_Library {
    if (global_ft_library) |lib| return lib;
    if (library_init_error) |err| {
        std.log.err("FreeType library init failed: {s}", .{ft.ftErrorString(err)});
        return error.FreeTypeInitFailed;
    }

    var lib: ft.FT_Library = undefined;
    const err = ft.FT_Init_FreeType(&lib);
    if (err != 0) {
        library_init_error = err;
        std.log.err("FreeType init error: {s}", .{ft.ftErrorString(err)});
        return error.FreeTypeInitFailed;
    }

    global_ft_library = lib;
    return lib;
}

/// Maximum glyph ID for advance cache (covers most fonts)
const ADVANCE_CACHE_SIZE: usize = 4096;
/// Sentinel value for uncached advances
const ADVANCE_UNCACHED: f32 = -1.0;

/// FreeType-backed font face
pub const FreeTypeFace = struct {
    /// FreeType face handle
    ft_face: ft.FT_Face,
    /// HarfBuzz font (paired with FT_Face for shaping)
    hb_font: *ft.hb_font_t,
    /// Cached metrics
    metrics: Metrics,
    /// Font size in points
    point_size: f32,
    /// Verhältnis gewünschte Grösse zu fester Bitmap-Grösse. Nur Bitmap-Schriften
    /// (NotoColorEmoji, CBDT) haben feste Grössen; dort liefern FreeType und
    /// HarfBuzz Masse in Pixeln der Bitmap-Grösse, die damit umgerechnet werden.
    /// Schriften mit Umrissen haben 1.0.
    strike_scale: f32 = 1.0,
    /// Font file path (for debugging)
    font_path_buf: [512]u8,
    font_path_len: usize,
    /// Glyph advance cache - avoids expensive FT_Load_Glyph calls during measurement
    /// Index by glyph_id, stores advance_x. ADVANCE_UNCACHED means not yet loaded.
    advance_cache: [ADVANCE_CACHE_SIZE]f32,

    const Self = @This();

    /// Load a font directly from a file path
    pub fn init(path: []const u8, size: f32) !Self {
        std.log.debug("FreeTypeFace.init: path={s} size={d}", .{ path, size });
        const library = try ensureLibraryInit();
        
        // Ensure path is null-terminated for FT_New_Face
        var path_buf: [512]u8 = undefined;
        if (path.len >= path_buf.len) return error.FontPathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [:0]const u8 = path_buf[0..path.len :0];

        return initFromPath(library, path_z, path.len, size);
    }

    /// Schrift aus dem Speicher laden. `data` muss die Face überleben; für die
    /// eingebaute Schrift ist das der eingebettete Puffer im Binary.
    pub fn initFromMemory(data: []const u8, size: f32) !Self {
        const library = try ensureLibraryInit();
        var ft_face: ft.FT_Face = undefined;
        const err = ft.FT_New_Memory_Face(library, data.ptr, @intCast(data.len), 0, &ft_face);
        if (err != 0) {
            std.log.err("FreeType memory face load error: {s}", .{ft.ftErrorString(err)});
            return error.FontLoadFailed;
        }
        errdefer _ = ft.FT_Done_Face(ft_face);
        return finishFace(ft_face, "<eingebaute Schrift>", size);
    }

    fn initFromPath(library: ft.FT_Library, path: [:0]const u8, path_len: usize, size: f32) !Self {
        _ = path_len;
        var ft_face: ft.FT_Face = undefined;
        const err = ft.FT_New_Face(library, path.ptr, 0, &ft_face);
        if (err != 0) {
            std.log.err("FreeType face load error: {s}", .{ft.ftErrorString(err)});
            return error.FontLoadFailed;
        }
        errdefer _ = ft.FT_Done_Face(ft_face);
        return finishFace(ft_face, path, size);
    }

    /// Größe setzen, HarfBuzz-Font bauen, Metriken rechnen — für beide Ladewege gleich.
    fn finishFace(ft_face: ft.FT_Face, name: []const u8, size: f32) !Self {
        errdefer _ = ft.FT_Done_Face(ft_face);

        // Bitmap-Schriften lassen keine freie Grösse zu; dort die nächstliegende
        // feste Grösse wählen und den Faktor merken.
        var strike_scale: f32 = 1.0;
        if (ft.isBitmapOnly(ft_face)) {
            const strike = ft.bestStrike(ft_face, size) orelse return error.FontSizeError;
            const sel_err = ft.FT_Select_Size(ft_face, strike.index);
            if (sel_err != 0) {
                std.log.err("FreeType select size error: {s}", .{ft.ftErrorString(sel_err)});
                return error.FontSizeError;
            }
            strike_scale = size / strike.y_ppem;
        } else {
            // Set character size (in 1/64th points at 72 DPI for 1:1 point-to-pixel)
            // Using 96 DPI is more common on Linux
            const size_f26d6 = ft.floatToF26dot6(size);
            const size_err = ft.FT_Set_Char_Size(ft_face, 0, size_f26d6, 96, 96);
            if (size_err != 0) {
                std.log.err("FreeType set size error: {s}", .{ft.ftErrorString(size_err)});
                return error.FontSizeError;
            }
        }

        // Create HarfBuzz font from FreeType face
        const hb_font = ft.hb_ft_font_create_referenced(ft_face) orelse {
            return error.HarfBuzzError;
        };
        errdefer ft.hb_font_destroy(hb_font);

        // Set up HarfBuzz to use FreeType functions
        ft.hb_ft_font_set_funcs(hb_font);

        var self = Self{
            .ft_face = ft_face,
            .hb_font = hb_font,
            .metrics = undefined,
            .point_size = size,
            .strike_scale = strike_scale,
            .font_path_buf = undefined,
            .font_path_len = @min(name.len, 511),
            .advance_cache = [_]f32{ADVANCE_UNCACHED} ** ADVANCE_CACHE_SIZE,
        };

        // Store name for debugging
        @memcpy(self.font_path_buf[0..self.font_path_len], name[0..self.font_path_len]);
        self.font_path_buf[self.font_path_len] = 0;

        // Compute metrics
        self.metrics = computeMetrics(ft_face, size);
        if (strike_scale != 1.0) self.metrics = scaleMetrics(self.metrics, strike_scale, size);

        return self;
    }

    /// Masse einer Bitmap-Schrift von Bitmap-Pixeln auf die gewünschte Grösse rechnen.
    fn scaleMetrics(m: Metrics, strike_scale: f32, size: f32) Metrics {
        var out = m;
        out.ascender *= strike_scale;
        out.descender *= strike_scale;
        out.line_gap *= strike_scale;
        out.cap_height *= strike_scale;
        out.x_height *= strike_scale;
        out.underline_position *= strike_scale;
        out.underline_thickness = @max(1.0, m.underline_thickness * strike_scale);
        out.line_height *= strike_scale;
        out.cell_width *= strike_scale;
        out.point_size = size;
        return out;
    }

    /// Vorschub eines Glyphs einer Bitmap-Schrift, in Punkten der gewünschten
    /// Grösse. HarfBuzz meldet für solche Schriften 0, weil sie keine Umrisse
    /// haben; ohne eigene Rechnung stünde das nächste Zeichen im Emoji.
    pub fn strikeAdvance(self: *const Self, glyph_id: u16) f32 {
        if (ft.FT_Load_Glyph(self.ft_face, glyph_id, ft.FT_LOAD_DEFAULT | ft.FT_LOAD_COLOR) != 0) return 0;
        return ft.f26dot6ToFloat(self.ft_face.glyph.metrics.horiAdvance) * self.strike_scale;
    }

    /// Taugt diese Schrift als Emoji-Rückfall? Nur Bitmap-Schriften (CBDT) liefern
    /// über FreeType fertige Farbbilder. COLRv1-Schriften bestehen aus
    /// Malanweisungen, die FreeType nicht ausmalt: das Bitmap bliebe leer.
    pub fn isColorBitmapFont(self: *const Self) bool {
        return ft.hasColor(self.ft_face) and ft.isBitmapOnly(self.ft_face);
    }

    /// Hat diese Schrift ein Glyph für das Zeichen? 0 = fehlt (Clay zeichnet sonst
    /// ein leeres Kästchen). Grundlage der Rückfall-Kette auf die Emoji-Schrift.
    pub fn hasCodepoint(self: *const Self, cp: u21) bool {
        return ft.FT_Get_Char_Index(self.ft_face, cp) != 0;
    }

    /// Rohe FreeType-Face, für den Rückfall-Pfad im Glyph-Cache (`font_ref`).
    pub fn rawFace(self: *const Self) *anyopaque {
        return @ptrCast(self.ft_face);
    }

    pub fn deinit(self: *Self) void {
        ft.hb_font_destroy(self.hb_font);
        _ = ft.FT_Done_Face(self.ft_face);
        self.* = undefined;
    }

    /// Get as the generic FontFace interface
    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    /// Get glyph ID for a Unicode codepoint
    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        const glyph_idx = ft.FT_Get_Char_Index(self.ft_face, @intCast(codepoint));
        return @intCast(glyph_idx);
    }

    /// Get advance width for a glyph (fast path for text measurement)
    /// Uses cached value if available, otherwise loads and caches
    pub fn glyphAdvance(self: *Self, glyph_id: u16) f32 {
        // Check cache first (fast path)
        if (glyph_id < ADVANCE_CACHE_SIZE) {
            const cached = self.advance_cache[glyph_id];
            if (cached != ADVANCE_UNCACHED) {
                return cached;
            }
        }

        // Cache miss - load glyph with minimal work (no hinting, no bitmap)
        const err = ft.FT_Load_Glyph(self.ft_face, glyph_id, ft.FT_LOAD_NO_HINTING | ft.FT_LOAD_NO_BITMAP);
        if (err != 0) {
            return 0;
        }

        const advance = ft.f26dot6ToFloat(self.ft_face.glyph.metrics.horiAdvance);

        // Cache for future lookups
        if (glyph_id < ADVANCE_CACHE_SIZE) {
            // Cast away const for caching (cache is logically mutable even on const self)
            const mutable_self = @constCast(self);
            mutable_self.advance_cache[glyph_id] = advance;
        }

        return advance;
    }

    /// Get metrics for a specific glyph (full metrics, slower path)
    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        // Load glyph without rendering (just get metrics)
        const err = ft.FT_Load_Glyph(self.ft_face, glyph_id, ft.FT_LOAD_DEFAULT);
        if (err != 0) {
            return .{
                .glyph_id = glyph_id,
                .advance_x = 0,
                .advance_y = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .width = 0,
                .height = 0,
            };
        }

        const slot = self.ft_face.glyph;
        const m = slot.metrics;
        const advance_x = ft.f26dot6ToFloat(m.horiAdvance);

        // Update advance cache while we have it
        if (glyph_id < ADVANCE_CACHE_SIZE) {
            const mutable_self = @constCast(self);
            mutable_self.advance_cache[glyph_id] = advance_x;
        }

        // Convert from 26.6 fixed-point to float
        return .{
            .glyph_id = glyph_id,
            .advance_x = advance_x,
            .advance_y = ft.f26dot6ToFloat(m.vertAdvance),
            .bearing_x = ft.f26dot6ToFloat(m.horiBearingX),
            .bearing_y = ft.f26dot6ToFloat(m.horiBearingY),
            .width = ft.f26dot6ToFloat(m.width),
            .height = ft.f26dot6ToFloat(m.height),
        };
    }

    /// Render a glyph with subpixel positioning
    /// subpixel_x and subpixel_y are in range [0.0, 1.0)
    ///
    /// Uses FreeType's native bitmap output with its positioning values.
    /// offset_x = bitmap_left (horizontal offset from pen to left edge)
    /// offset_y = bitmap_top (vertical offset from baseline to top edge, positive = above)
    pub fn renderGlyphSubpixel(
        self: *const Self,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        std.debug.assert(font_size > 0);
        std.debug.assert(scale > 0);
        std.debug.assert(subpixel_x >= 0 and subpixel_x < 1.0);
        std.debug.assert(subpixel_y >= 0 and subpixel_y < 1.0);

        return renderGlyphInternal(
            self.ft_face,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    /// Render a glyph from any FT_Face (for fallback fonts)
    /// This is a static method that can render glyphs from fonts not owned by this face
    pub fn renderGlyphFromFont(
        ft_face: ft.FT_Face,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        std.debug.assert(font_size > 0);
        std.debug.assert(scale > 0);
        std.debug.assert(subpixel_x >= 0 and subpixel_x < 1.0);
        std.debug.assert(subpixel_y >= 0 and subpixel_y < 1.0);

        return renderGlyphInternal(
            ft_face,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    fn computeMetrics(face: ft.FT_Face, size: f32) Metrics {
        const size_metrics = face.size.metrics;

        // Convert from 26.6 fixed-point
        const ascender = ft.f26dot6ToFloat(size_metrics.ascender);
        const descender = -ft.f26dot6ToFloat(size_metrics.descender); // FreeType descender is negative
        const height = ft.f26dot6ToFloat(size_metrics.height);
        const line_gap = height - ascender - descender;

        // Get x-height and cap-height from OS/2 table if available
        // Fall back to estimates based on ascender
        var x_height = ascender * 0.5;
        var cap_height = ascender * 0.7;

        // Try to get 'x' and 'H' metrics for better estimates
        const x_glyph = ft.FT_Get_Char_Index(face, 'x');
        if (x_glyph != 0) {
            if (ft.FT_Load_Glyph(face, x_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                x_height = ft.f26dot6ToFloat(face.glyph.metrics.height);
            }
        }

        const h_glyph = ft.FT_Get_Char_Index(face, 'H');
        if (h_glyph != 0) {
            if (ft.FT_Load_Glyph(face, h_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                cap_height = ft.f26dot6ToFloat(face.glyph.metrics.height);
            }
        }

        // Underline metrics (from face, need scaling)
        const scale_factor = size / @as(f32, @floatFromInt(face.units_per_EM));
        const underline_position = @as(f32, @floatFromInt(face.underline_position)) * scale_factor;
        const underline_thickness = @max(1.0, @as(f32, @floatFromInt(face.underline_thickness)) * scale_factor);

        // Cell width for monospace (check 'M' and '0')
        var cell_width: f32 = 0;
        const m_glyph = ft.FT_Get_Char_Index(face, 'M');
        if (m_glyph != 0) {
            if (ft.FT_Load_Glyph(face, m_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                cell_width = ft.f26dot6ToFloat(face.glyph.metrics.horiAdvance);
            }
        }

        const zero_glyph = ft.FT_Get_Char_Index(face, '0');
        if (zero_glyph != 0) {
            if (ft.FT_Load_Glyph(face, zero_glyph, ft.FT_LOAD_DEFAULT) == 0) {
                const zero_advance = ft.f26dot6ToFloat(face.glyph.metrics.horiAdvance);
                cell_width = @max(cell_width, zero_advance);
            }
        }

        return .{
            .units_per_em = face.units_per_EM,
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .cap_height = cap_height,
            .x_height = x_height,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .line_height = height,
            .point_size = size,
            .is_monospace = ft.isMonospace(face),
            .cell_width = cell_width,
        };
    }
};

// =============================================================================
// Shared Internal Functions
// =============================================================================

/// Internal glyph rendering implementation shared by both public methods
fn renderGlyphInternal(
    ft_face: ft.FT_Face,
    glyph_id: u16,
    point_size: f32,
    scale: f32,
    subpixel_x: f32,
    subpixel_y: f32,
    buffer: []u8,
    buffer_size: u32,
) !RasterizedGlyph {
    // Assertions for input validation
    std.debug.assert(scale > 0);
    std.debug.assert(point_size > 0);

    // Bitmap-Schriften (Emoji) haben nur feste Grössen; sie brauchen einen
    // eigenen Weg mit Auswahl der Grösse und eigenem Verkleinern.
    if (ft.isBitmapOnly(ft_face)) {
        return renderStrikeGlyph(ft_face, glyph_id, point_size, scale, buffer, buffer_size);
    }

    // Apply subpixel offset via FT_Set_Transform
    const subpixel_offset_x = ft.floatToF26dot6(subpixel_x * scale);
    const subpixel_offset_y = ft.floatToF26dot6(subpixel_y * scale);

    const delta = ft.FT_Vector{
        .x = subpixel_offset_x,
        .y = subpixel_offset_y,
    };

    ft.FT_Set_Transform(ft_face, null, &delta);

    // Set scaled size for rendering (point_size * scale = physical pixels)
    const scaled_size = point_size * scale;
    const size_f26d6 = ft.floatToF26dot6(scaled_size);
    _ = ft.FT_Set_Char_Size(ft_face, 0, size_f26d6, 96, 96);

    // Load the glyph at scaled size to get correct metrics
    var load_flags = ft.FT_LOAD_DEFAULT;
    if (ft.hasColor(ft_face)) {
        load_flags |= ft.FT_LOAD_COLOR;
    }

    const load_err = ft.FT_Load_Glyph(ft_face, glyph_id, load_flags);
    if (load_err != 0) {
        ft.FT_Set_Transform(ft_face, null, null);
        _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);
        return error.GlyphLoadFailed;
    }

    const slot = ft_face.glyph;

    // Get metrics from the scaled glyph, then convert advance back to logical units
    const scaled_advance = ft.f26dot6ToFloat(slot.metrics.horiAdvance);
    const advance_x = scaled_advance / scale;
    const width_f = ft.f26dot6ToFloat(slot.metrics.width);
    const height_f = ft.f26dot6ToFloat(slot.metrics.height);

    // Handle empty glyphs (spaces, etc.)
    if (width_f < 1 or height_f < 1) {
        ft.FT_Set_Transform(ft_face, null, null);
        _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);
        return RasterizedGlyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .advance_x = advance_x,
            .is_color = false,
        };
    }

    // Render to bitmap if not already
    if (slot.format != .FT_GLYPH_FORMAT_BITMAP) {
        const render_err = ft.FT_Render_Glyph(slot, .FT_RENDER_MODE_NORMAL);
        if (render_err != 0) {
            ft.FT_Set_Transform(ft_face, null, null);
            _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);
            return error.GlyphRenderFailed;
        }
    }

    // Reset transform for future operations
    ft.FT_Set_Transform(ft_face, null, null);
    _ = ft.FT_Set_Char_Size(ft_face, 0, ft.floatToF26dot6(point_size), 96, 96);

    const bitmap = slot.bitmap;
    const width = bitmap.width;
    const height = bitmap.rows;
    const is_color = bitmap.pixel_mode == .FT_PIXEL_MODE_BGRA;

    std.debug.assert(width <= 256); // Reasonable glyph size limit
    std.debug.assert(height <= 256);

    // Copy bitmap to output buffer
    if (width > 0 and height > 0) {
        const src_pitch: usize = if (bitmap.pitch < 0)
            @intCast(-bitmap.pitch)
        else
            @intCast(bitmap.pitch);

        const bytes_per_pixel: usize = if (is_color) 4 else 1;
        const dst_pitch = width * bytes_per_pixel;

        var y: usize = 0;
        while (y < height) : (y += 1) {
            const src_row = bitmap.buffer + y * src_pitch;
            const dst_row = buffer.ptr + y * dst_pitch;

            if (is_color) {
                @memcpy(dst_row[0 .. width * 4], src_row[0 .. width * 4]);
            } else {
                @memcpy(dst_row[0..width], src_row[0..width]);
            }
        }
    }

    // Use FreeType's native bitmap positioning
    // bitmap_left: horizontal offset from pen position to left edge of bitmap
    // bitmap_top: vertical offset from baseline to top edge of bitmap (positive = above)
    return RasterizedGlyph{
        .width = width,
        .height = height,
        .offset_x = slot.bitmap_left,
        .offset_y = slot.bitmap_top,
        .advance_x = advance_x,
        .is_color = is_color,
    };
}

/// Glyph aus einer Bitmap-Schrift (CBDT-Emoji). Die Schrift kennt nur feste Grössen,
/// meist 128 px; das Bitmap wird deshalb selbst auf die Zielgrösse verkleinert.
/// Subpixel-Versatz entfällt: bei dieser Verkleinerung ist er nicht sichtbar.
fn renderStrikeGlyph(
    ft_face: ft.FT_Face,
    glyph_id: u16,
    point_size: f32,
    scale: f32,
    buffer: []u8,
    buffer_size: u32,
) !RasterizedGlyph {
    const target_px = point_size * scale;
    const strike = ft.bestStrike(ft_face, target_px) orelse return error.GlyphRenderFailed;
    if (ft.FT_Select_Size(ft_face, strike.index) != 0) return error.GlyphRenderFailed;

    if (ft.FT_Load_Glyph(ft_face, glyph_id, ft.FT_LOAD_DEFAULT | ft.FT_LOAD_COLOR) != 0) {
        return error.GlyphLoadFailed;
    }
    const slot = ft_face.glyph;
    if (slot.format != .FT_GLYPH_FORMAT_BITMAP) {
        if (ft.FT_Render_Glyph(slot, .FT_RENDER_MODE_NORMAL) != 0) return error.GlyphRenderFailed;
    }

    const bitmap = slot.bitmap;
    const factor = target_px / strike.y_ppem;
    const advance_x = ft.f26dot6ToFloat(slot.metrics.horiAdvance) * factor / scale;

    if (bitmap.width == 0 or bitmap.rows == 0) {
        return RasterizedGlyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .advance_x = advance_x,
            .is_color = false,
        };
    }

    const is_color = bitmap.pixel_mode == .FT_PIXEL_MODE_BGRA;
    if (!is_color) {
        // Einfarbige Bitmap-Schrift: kein Weg vorgesehen, lieber nichts zeichnen
        // als Grauwerte in der falschen Grösse.
        return error.GlyphRenderFailed;
    }

    const dst_w: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(bitmap.width)) * factor))));
    const dst_h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(bitmap.rows)) * factor))));
    if (dst_w * dst_h * 4 > buffer_size) return error.BufferTooSmall;

    const src_pitch: usize = if (bitmap.pitch < 0) @intCast(-bitmap.pitch) else @intCast(bitmap.pitch);
    const src = bitmap.buffer[0 .. src_pitch * bitmap.rows];
    bitmap_scale.downscaleBgraToRgba(src, bitmap.width, bitmap.rows, src_pitch, buffer, dst_w, dst_h);

    return RasterizedGlyph{
        .width = dst_w,
        .height = dst_h,
        .offset_x = @intFromFloat(@round(@as(f32, @floatFromInt(slot.bitmap_left)) * factor)),
        .offset_y = @intFromFloat(@round(@as(f32, @floatFromInt(slot.bitmap_top)) * factor)),
        .advance_x = advance_x,
        .is_color = true,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "load system font" {
    var face = try FreeTypeFace.initSystem(.monospace, 14.0);
    defer face.deinit();

    try std.testing.expect(face.metrics.ascender > 0);
    try std.testing.expect(face.metrics.line_height > 0);
}
