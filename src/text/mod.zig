//! Text Rendering Modul für vulkan-ed
//!
//! Platform-spezifisches Text Rendering:
//! - Windows: DirectWrite (ClearType Subpixel-Rendering)
//! - Linux: FreeType + HarfBuzz + Fontconfig (von Gooey übernommen)
//!
//! Beide rendern Glyphen in einen GPU Glyph-Atlas.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.text);

// Core types (platform-agnostic)
pub const types = @import("types.zig");
pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const TextMeasurement = types.TextMeasurement;
pub const SystemFont = types.SystemFont;
pub const TextDecoration = types.TextDecoration;
pub const RasterizedGlyph = types.RasterizedGlyph;

// Interfaces
pub const font_face = @import("font_face.zig");
pub const FontFace = font_face.FontFace;

// Infrastructure
pub const Atlas = @import("atlas.zig").Atlas;
pub const Region = @import("atlas.zig").Region;
pub const cache = @import("cache.zig");
pub const GlyphCache = cache.GlyphCache;
pub const CachedGlyph = cache.CachedGlyph;

// High-level API
pub const TextSystem = @import("text_system.zig").TextSystem;
pub const ShapedRunCache = @import("text_system.zig").ShapedRunCache;
pub const SUBPIXEL_VARIANTS_X = @import("text_system.zig").SUBPIXEL_VARIANTS_X;

// Platform backends
const is_linux = builtin.os.tag == .linux;

pub const backends = if (is_linux)
    struct {
        pub const freetype = @import("backends/freetype/mod.zig");
    }
else
    struct {};

// Font config
pub const FontConfig = struct {
    font_path: []const u8,
    size: f32 = 14.0,
    line_height: f32 = 1.5,
};

pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    config: FontConfig,
    ts_ptr: *TextSystem,
    initialized: bool = false,

    const Self = @This();

    /// Atlas-Generation für GPU-Upload-Tracking (delegiert an TextSystem)
    pub fn atlasGeneration(self: *const Self) u32 {
        return self.ts_ptr.atlas_generation;
    }

    pub fn init(allocator: std.mem.Allocator, config: FontConfig) !Self {
        log.info("Initializing text renderer", .{});
        log.info("Platform: {s}", .{@tagName(builtin.os.tag)});
        log.info("Font: {s} size={d}", .{ config.font_path, config.size });

        // TextSystem ist ~1.7MB gross - muss auf Heap alloziert werden
        var ts_ptr = try allocator.create(TextSystem);
        errdefer allocator.destroy(ts_ptr);

        log.info("Creating TextSystem on heap...", .{});
        try ts_ptr.initInPlace(allocator, 1.0);
        log.info("TextSystem created successfully", .{});

        // Font laden
        if (is_linux) {
            log.info("Loading system monospace font...", .{});
            try ts_ptr.loadSystemFont(.monospace, config.size);
            log.info("Font loaded successfully", .{});
        }

        return Self{
            .allocator = allocator,
            .config = config,
            .ts_ptr = ts_ptr,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Self) void {
        log.info("Text renderer shutdown", .{});
        self.ts_ptr.deinit();
        self.allocator.destroy(self.ts_ptr);
    }

    pub fn measureText(self: *Self, text: []const u8) f32 {
        return self.ts_ptr.measureText(text) catch 0;
    }

    pub fn getAtlasData(self: *Self) []const u8 {
        return self.ts_ptr.cache.grayscale_atlas.data;
    }

    pub fn getAtlasSize(self: *Self) u32 {
        return self.ts_ptr.cache.grayscale_atlas.size;
    }

    pub fn cacheGlyph(self: *Self, glyph_id: u16) !?struct { x: u16, y: u16, w: u16, h: u16, advance: f32 } {
        if (self.ts_ptr.current_face) |*face| {
            var buffer: [256 * 256]u8 = undefined;
            const rasterized = face.renderGlyphSubpixel(
                glyph_id,
                face.metrics.point_size,
                1.0,
                0.0,
                0.0,
                &buffer,
                buffer.len,
            ) catch return null;

            if (rasterized.width == 0 or rasterized.height == 0) return null;

            const region = (try self.ts_ptr.cache.grayscale_atlas.reserve(rasterized.width, rasterized.height)) orelse return null;

            // Pixel in Atlas schreiben (row-by-row)
            const w = rasterized.width;
            const h = rasterized.height;
            const atlas_size = self.ts_ptr.cache.grayscale_atlas.size;
            const bpp = self.ts_ptr.cache.grayscale_atlas.format.bytesPerPixel();

            var py: u32 = 0;
            while (py < h) : (py += 1) {
                const src_row = py * w;
                const atlas_row = (region.y + py) * atlas_size + region.x;
                var px: u32 = 0;
                while (px < w) : (px += 1) {
                    const src_idx = src_row + px;
                    const atlas_idx = atlas_row + px;
                    self.ts_ptr.cache.grayscale_atlas.data[atlas_idx * bpp] = buffer[src_idx];
                }
            }

            return .{
                .x = region.x,
                .y = region.y,
                .w = region.width,
                .h = region.height,
                .advance = face.glyphAdvance(glyph_id),
            };
        }
        return null;
    }
};

// GPU Text Renderer
pub const GPURenderer = @import("gpu_renderer.zig").TextRendererGPU;

test {
    @import("std").testing.refAllDecls(@This());
}
