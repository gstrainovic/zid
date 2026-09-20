//! Eingebettete WGSL-Shader. zid übersetzt sie zur Laufzeit, liest sie aber aus
//! dem Binary: ein installiertes zid hat kein `zig-out/share` neben sich.

pub const triangle = @embedFile("triangle.wgsl");
pub const rectangle = @embedFile("rectangle.wgsl");
pub const texture = @embedFile("texture.wgsl");
pub const text_atlas = @embedFile("text_atlas.wgsl");
pub const svg_atlas = @embedFile("svg_atlas.wgsl");
