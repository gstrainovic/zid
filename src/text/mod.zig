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

// Simple TextRenderer wrapper für vulkan-ed (adaptiert von Gooey TextSystem)
pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    config: FontConfig,
    ts: TextSystem,
    initialized: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: FontConfig) !Self {
        log.info("Initializing text renderer", .{});
        log.info("Platform: {s}", .{@tagName(builtin.os.tag)});
        log.info("Font: {s} size={d}", .{ config.font_path, config.size });

        // TODO: Gooey TextSystem initialisieren (crasht aktuell)
        // var ts = try TextSystem.init(allocator);

        return Self{
            .allocator = allocator,
            .config = config,
            .ts = undefined,
            .initialized = false,
        };
    }

    pub fn deinit(self: *Self) void {
        log.info("Text renderer shutdown", .{});
        self.ts.deinit();
    }

    /// Text messen
    pub fn measureText(self: *Self, text: []const u8) f32 {
        return self.ts.measureText(text) catch 0;
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
