//! SVG Rendering Module for zid
//!
//! Provides atlas-cached SVG icon rendering with pure-Zig scanline rasterization.
//! Adapted from Gooey's SVG pipeline.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Atlas (Caching)
// =============================================================================

pub const SvgAtlas = @import("atlas.zig").SvgAtlas;
pub const SvgKey = @import("atlas.zig").SvgKey;
pub const CachedSvg = @import("atlas.zig").CachedSvg;

// =============================================================================
// Rasterizer (Platform-dispatched)
// =============================================================================

pub const rasterizer = @import("rasterizer.zig");
pub const rasterize = rasterizer.rasterize;
pub const rasterizeWithOptions = rasterizer.rasterizeWithOptions;
pub const RasterizedSvg = rasterizer.RasterizedSvg;
pub const RasterizeError = rasterizer.RasterizeError;
pub const StrokeOptions = rasterizer.StrokeOptions;

// =============================================================================
// Platform Backends (for advanced usage)
// =============================================================================

/// Platform-specific backends for direct access
pub const backends = struct {
    /// Cairo backend (Linux/Pure Zig Scanline)
    pub const cairo = if (builtin.os.tag == .linux or builtin.os.tag == .windows)
        @import("backends/cairo.zig")
    else
        struct {};

    /// Null/stub backend (unsupported platforms)
    pub const null_backend = @import("backends/null.zig");
};

// =============================================================================
// Clay Integration
// =============================================================================

/// Information passed to Clay for SVG rendering via image_data pointer
pub const SvgRenderInfo = struct {
    magic: u64 = MAGIC,
    path_data: []const u8,
    viewbox: f32 = 24.0,
    /// Tint color (RGBA, 0-255 range) — applied to alpha mask in GPU shader
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    /// Strichbreite in viewbox-Einheiten (Lucide: 2): Pfad wird als Kontur gezeichnet statt
    /// gefüllt. null = Füllung; damit bleiben reine Linienpfade wie „plus“ unsichtbar.
    stroke_width: ?f32 = null,

    pub const MAGIC: u64 = 0x5356475F49434F4E; // "SVG_ICON"
};

// =============================================================================
// Lucide Icons
// =============================================================================

// Wir werden die Lucide Icons später aus libs/gooey/src/components/svg.zig importieren
// oder eine eigene Version davon bauen.
