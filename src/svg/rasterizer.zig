//! SVG Rasterizer - Platform dispatcher
//!
//! Routes to platform-specific SVG rasterization backends:
//! - Software renderer (Linux/Windows) - backends/cairo.zig

const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux, .windows => @import("backends/cairo.zig"),
    else => @import("backends/null.zig"),
};

// Re-export types
pub const RasterizedSvg = backend.RasterizedSvg;
pub const RasterizeError = backend.RasterizeError;
pub const StrokeOptions = backend.StrokeOptions;

// Re-export functions
pub const rasterize = backend.rasterize;
pub const rasterizeWithOptions = backend.rasterizeWithOptions;
