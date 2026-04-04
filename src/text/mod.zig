//! Text Rendering Modul - Vollständig aus Gooey übernommen
//!
//! Platform-spezifisches Text Rendering:
//! - Linux: FreeType + HarfBuzz + Fontconfig
//! - Windows: DirectWrite (später)

const std = @import("std");
const builtin = @import("builtin");

// Public API - alles aus Gooey übernommen
pub const Atlas = @import("atlas.zig").Atlas;
pub const Cache = @import("cache.zig").Cache;
pub const renderText = @import("render.zig").renderText;
pub const RenderTextOptions = @import("render.zig").RenderTextOptions;
pub const TextSystem = @import("text_system.zig").TextSystem;
pub const ShapedRunCache = @import("text_system.zig").ShapedRunCache;

// Types
pub const types = @import("types.zig");
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const GlyphMetrics = types.GlyphMetrics;
pub const Metrics = types.Metrics;
pub const RasterizedGlyph = types.RasterizedGlyph;
pub const CachedGlyph = @import("cache.zig").CachedGlyph;

// Font Face
pub const FontFace = @import("font_face.zig").FontFace;
pub const createFontFace = @import("font_face.zig").createFontFace;

// Shaper
pub const Shaper = @import("shaper.zig").Shaper;

// FreeType Backend (nur Linux)
pub const freetype = if (builtin.os.tag == .linux) struct {
    pub const bindings = @import("backends/freetype/bindings.zig");
    pub const FreeTypeFace = @import("backends/freetype/face.zig").FreeTypeFace;
    pub const HarfBuzzShaper = @import("backends/freetype/shaper.zig").HarfBuzzShaper;
} else struct {};

test {
    @import("std").testing.refAllDecls(@This());
}
