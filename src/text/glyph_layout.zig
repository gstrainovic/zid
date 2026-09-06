//! Reine Layout-Helfer für den GPU-Text-Renderer (ohne wgpu, unit-getestet).
//!
//! `renderText` arbeitet mit festen Stack-Puffern von `max_batch_glyphs` Einträgen.
//! Längere Runs (z. B. eine 2-KB-"Zeile" einer Binärdatei) werden in Blöcke zerlegt;
//! damit die Blöcke nahtlos aneinander liegen, gibt `computeGlyphDevicePositions`
//! die Stiftposition nach dem letzten Glyph zurück und der nächste Block startet dort.

const std = @import("std");

/// Größe der Stack-Puffer in `renderText`. Ein Run mit mehr Glyphen wird blockweise gerendert.
pub const max_batch_glyphs: usize = 256;

const SUBPIXEL_VARIANTS_F: f32 = 4.0;

/// Device-Pixel-Positionen und Subpixel-Offsets für einen Block Glyphen.
/// `shaped_glyphs` ist ein Slice von Structs mit `x_offset`, `y_offset`, `x_advance`
/// (anytype, damit das Modul ohne den Text-System-Import testbar bleibt).
/// Rückgabe: Stiftposition (logische Pixel) nach dem letzten Glyph.
pub fn computeGlyphDevicePositions(
    shaped_glyphs: anytype,
    start_x: f32,
    baseline_y: f32,
    size_scale: f32,
    scale_factor: f32,
    out_device_x: []f32,
    out_device_y: []f32,
    out_subpixel_x: []u8,
) f32 {
    var pen_x = start_x;
    for (shaped_glyphs, 0..) |glyph, index| {
        const scaled_x_offset = glyph.x_offset * size_scale;
        const scaled_y_offset = glyph.y_offset * size_scale;
        const scaled_advance = glyph.x_advance * size_scale;

        const device_x = (pen_x + scaled_x_offset) * scale_factor;
        const device_y = (baseline_y + scaled_y_offset) * scale_factor;

        const fractional_x = device_x - @floor(device_x);

        out_device_x[index] = device_x;
        out_device_y[index] = device_y;
        out_subpixel_x[index] = @intFromFloat(@floor(fractional_x * SUBPIXEL_VARIANTS_F));

        pen_x += scaled_advance;
    }
    return pen_x;
}

// ---------------------------------------------------------------- Tests

const TestGlyph = struct { x_offset: f32 = 0, y_offset: f32 = 0, x_advance: f32 };

test "computeGlyphDevicePositions: Stift rückt um die skalierten Advances vor" {
    const glyphs = [_]TestGlyph{ .{ .x_advance = 10 }, .{ .x_advance = 6, .x_offset = 1 }, .{ .x_advance = 4 } };
    var dx: [3]f32 = undefined;
    var dy: [3]f32 = undefined;
    var sub: [3]u8 = undefined;

    const pen = computeGlyphDevicePositions(glyphs[0..], 100, 50, 0.5, 2.0, &dx, &dy, &sub);

    // Advances 10+6+4 = 20, size_scale 0.5 → 10 logische Pixel
    try std.testing.expectApproxEqAbs(@as(f32, 110), pen, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), dx[0], 0.001); // 100 * 2
    try std.testing.expectApproxEqAbs(@as(f32, 211), dx[1], 0.001); // (105 + 0.5) * 2
    try std.testing.expectApproxEqAbs(@as(f32, 216), dx[2], 0.001); // 108 * 2
    try std.testing.expectApproxEqAbs(@as(f32, 100), dy[0], 0.001); // 50 * 2
    try std.testing.expectEqual(@as(u8, 0), sub[0]);
}

test "computeGlyphDevicePositions: Subpixel-Offset aus dem Nachkommateil" {
    const glyphs = [_]TestGlyph{ .{ .x_advance = 1, .x_offset = 0.3 }, .{ .x_advance = 1, .x_offset = 0.8 } };
    var dx: [2]f32 = undefined;
    var dy: [2]f32 = undefined;
    var sub: [2]u8 = undefined;
    _ = computeGlyphDevicePositions(glyphs[0..], 0, 0, 1.0, 1.0, &dx, &dy, &sub);
    try std.testing.expectEqual(@as(u8, 1), sub[0]); // floor(0.3 * 4)
    try std.testing.expectEqual(@as(u8, 3), sub[1]); // floor(1.8 - 1) * 4 = 3
}

test "blockweise Positionierung liefert dieselben Positionen wie ein einziger Aufruf" {
    // 600 Glyphen: mehr als zwei volle 256er-Blöcke — genau der Fall, der als
    // `index out of bounds: index 463, len 256` in renderText abgestürzt ist.
    const n = 600;
    var glyphs: [n]TestGlyph = undefined;
    for (&glyphs, 0..) |*g, i| {
        g.* = .{ .x_advance = 7.25 + @as(f32, @floatFromInt(i % 5)), .x_offset = 0.1 * @as(f32, @floatFromInt(i % 3)) };
    }

    var whole_x: [n]f32 = undefined;
    var whole_y: [n]f32 = undefined;
    var whole_sub: [n]u8 = undefined;
    const whole_pen = computeGlyphDevicePositions(glyphs[0..], 12.5, 40, 0.75, 1.5, &whole_x, &whole_y, &whole_sub);

    var pen: f32 = 12.5;
    var offset: usize = 0;
    while (offset < n) : (offset += max_batch_glyphs) {
        const end = @min(offset + max_batch_glyphs, n);
        const chunk = glyphs[offset..end];
        var dx: [max_batch_glyphs]f32 = undefined;
        var dy: [max_batch_glyphs]f32 = undefined;
        var sub: [max_batch_glyphs]u8 = undefined;
        pen = computeGlyphDevicePositions(chunk, pen, 40, 0.75, 1.5, dx[0..chunk.len], dy[0..chunk.len], sub[0..chunk.len]);
        for (chunk, 0..) |_, i| {
            try std.testing.expectApproxEqAbs(whole_x[offset + i], dx[i], 0.0005);
            try std.testing.expectApproxEqAbs(whole_y[offset + i], dy[i], 0.0005);
            try std.testing.expectEqual(whole_sub[offset + i], sub[i]);
        }
    }
    try std.testing.expectApproxEqAbs(whole_pen, pen, 0.0005);
    try std.testing.expect(whole_pen > 12.5 + 600 * 7 * 0.75);
}
