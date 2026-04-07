//! DirectWrite backend for Windows text rendering
//!
//! Provides font loading and glyph rasterization using DirectWrite.

pub const bindings = @import("bindings.zig");
pub const DirectWriteFace = @import("face.zig").DirectWriteFace;

test {
    @import("std").testing.refAllDecls(@This());
}
