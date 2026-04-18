const std = @import("std");
const wio = @import("wio");
const gl = @import("gl");

pub fn init() !void {
    // Einfache Hintergrundfarbe: Blau
    gl.clearColor(0.2, 0.4, 0.8, 1.0);
}

pub fn draw() void {
    gl.clear(gl.COLOR_BUFFER_BIT);
}
