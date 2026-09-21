//! Farbige Emoji-Bitmaps verkleinern.
//!
//! CBDT-Schriften (NotoColorEmoji) liefern nur feste Grössen, meist 128 px. Für
//! Fliesstext muss zid das Bild selbst verkleinern. FreeType gibt BGRA mit
//! vormultipliziertem Alpha; die Textpipeline mischt mit `src_alpha`, erwartet
//! also RGBA ohne Vormultiplikation.

const std = @import("std");

/// Mittelt Quellpixel je Zielpixel (Kastenfilter), dreht BGRA auf RGBA und
/// rechnet die Vormultiplikation zurück.
pub fn downscaleBgraToRgba(
    src: []const u8,
    src_w: u32,
    src_h: u32,
    src_pitch: usize,
    dst: []u8,
    dst_w: u32,
    dst_h: u32,
) void {
    std.debug.assert(dst_w > 0 and dst_h > 0);
    std.debug.assert(src_w > 0 and src_h > 0);
    std.debug.assert(dst.len >= dst_w * dst_h * 4);

    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        const sy0 = dy * src_h / dst_h;
        const sy1 = @max(sy0 + 1, (dy + 1) * src_h / dst_h);
        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const sx0 = dx * src_w / dst_w;
            const sx1 = @max(sx0 + 1, (dx + 1) * src_w / dst_w);

            var sum_b: u32 = 0;
            var sum_g: u32 = 0;
            var sum_r: u32 = 0;
            var sum_a: u32 = 0;
            var count: u32 = 0;

            var sy = sy0;
            while (sy < sy1 and sy < src_h) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1 and sx < src_w) : (sx += 1) {
                    const p = sy * src_pitch + sx * 4;
                    sum_b += src[p];
                    sum_g += src[p + 1];
                    sum_r += src[p + 2];
                    sum_a += src[p + 3];
                    count += 1;
                }
            }
            if (count == 0) count = 1;

            const a = sum_a / count;
            const d = (dy * dst_w + dx) * 4;
            if (a == 0) {
                @memset(dst[d .. d + 4], 0);
                continue;
            }
            // Vormultiplikation zurückrechnen: c_unpremult = c * 255 / a.
            dst[d] = @intCast(@min(255, sum_r / count * 255 / a));
            dst[d + 1] = @intCast(@min(255, sum_g / count * 255 / a));
            dst[d + 2] = @intCast(@min(255, sum_b / count * 255 / a));
            dst[d + 3] = @intCast(a);
        }
    }
}

/// Eine Farbschicht über ein RGBA-Bild legen (Porter-Duff „over“, ohne Vormultiplikation):
/// `coverage` ist die Graustufen-Deckung der Schicht je Pixel, `color` ihre Farbe (0..1, mit
/// Alpha). DirectWrite liefert Farb-Emoji (COLR) als Folge solcher Schichten, jede ein
/// einfarbiger Umriss (`TranslateColorGlyphRun`); übereinandergelegt ergibt das das Bild.
pub fn blendLayer(dst: []u8, coverage: []const u8, color: [4]f32) void {
    std.debug.assert(dst.len >= coverage.len * 4);
    for (coverage, 0..) |cov, i| {
        if (cov == 0) continue;
        const a = @as(f32, @floatFromInt(cov)) / 255.0 * color[3];
        if (a <= 0) continue;
        const d = i * 4;
        const da = @as(f32, @floatFromInt(dst[d + 3])) / 255.0;
        const out_a = a + da * (1 - a);
        inline for (0..3) |c| {
            const dc = @as(f32, @floatFromInt(dst[d + c])) / 255.0;
            const v = (color[c] * a + dc * da * (1 - a)) / out_a;
            dst[d + c] = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
        dst[d + 3] = @intFromFloat(@round(std.math.clamp(out_a, 0, 1) * 255));
    }
}

const testing = std.testing;

test "blendLayer: volle Deckung übernimmt die Farbe, keine lässt alles stehen" {
    var dst = [_]u8{ 0, 0, 0, 0, 10, 20, 30, 255 };
    blendLayer(&dst, &.{ 255, 0 }, .{ 1, 0, 0, 1 });
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, dst[0..4]);
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, dst[4..8]);
}

test "blendLayer: obere Schicht deckt die untere, halbe Deckung mischt" {
    var dst = [_]u8{ 0, 0, 0, 0 };
    blendLayer(&dst, &.{255}, .{ 1, 0, 0, 1 }); // rot
    blendLayer(&dst, &.{255}, .{ 0, 0, 1, 1 }); // blau darüber
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &dst);
    blendLayer(&dst, &.{128}, .{ 1, 1, 1, 1 }); // halb weiss darüber
    try testing.expectEqual(@as(u8, 255), dst[3]);
    try testing.expect(dst[0] > 120 and dst[0] < 135);
    try testing.expectEqual(@as(u8, 255), dst[2]);
}

test "blendLayer: halbe Deckung auf leerem Grund ergibt halbes Alpha in voller Farbe" {
    var dst = [_]u8{ 0, 0, 0, 0 };
    blendLayer(&dst, &.{255}, .{ 0, 1, 0, 0.5 });
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 128 }, &dst);
}

test "vier Pixel werden zu einem gemittelt" {
    // 2x2 deckend: Blau, Grün, Rot, Weiss (BGRA).
    const src = [_]u8{
        255, 0,   0,   255, 0,   255, 0,   255,
        0,   0,   255, 255, 255, 255, 255, 255,
    };
    var dst: [4]u8 = undefined;
    downscaleBgraToRgba(&src, 2, 2, 8, &dst, 1, 1);

    try testing.expectEqual(@as(u8, 127), dst[0]); // R
    try testing.expectEqual(@as(u8, 127), dst[1]); // G
    try testing.expectEqual(@as(u8, 127), dst[2]); // B
    try testing.expectEqual(@as(u8, 255), dst[3]);
}

test "Vormultiplikation wird zurückgerechnet" {
    // Halbdurchsichtiges Rot, vormultipliziert: BGRA = 0,0,128,128.
    const src = [_]u8{ 0, 0, 128, 128 };
    var dst: [4]u8 = undefined;
    downscaleBgraToRgba(&src, 1, 1, 4, &dst, 1, 1);

    try testing.expectEqual(@as(u8, 255), dst[0]);
    try testing.expectEqual(@as(u8, 0), dst[1]);
    try testing.expectEqual(@as(u8, 0), dst[2]);
    try testing.expectEqual(@as(u8, 128), dst[3]);
}

test "durchsichtige Pixel bleiben leer" {
    const src = [_]u8{ 0, 0, 0, 0 };
    var dst: [4]u8 = undefined;
    downscaleBgraToRgba(&src, 1, 1, 4, &dst, 1, 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &dst);
}

test "Zeilenabstand der Quelle wird beachtet" {
    // 1x2 Bild mit Pitch 8: zweite Zeile beginnt erst nach vier Füllbytes.
    const src = [_]u8{
        0, 0, 255, 255, 9, 9, 9, 9,
        0, 0, 255, 255, 9, 9, 9, 9,
    };
    var dst: [4]u8 = undefined;
    downscaleBgraToRgba(&src, 1, 2, 8, &dst, 1, 1);

    try testing.expectEqual(@as(u8, 255), dst[0]); // Rot, nicht die Füllbytes
    try testing.expectEqual(@as(u8, 255), dst[3]);
}

test "Zielgrösse gleich Quellgrösse kopiert jeden Pixel" {
    const src = [_]u8{
        255, 0, 0, 255, 0, 0, 255, 255,
    };
    var dst: [8]u8 = undefined;
    downscaleBgraToRgba(&src, 2, 1, 8, &dst, 2, 1);

    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, dst[0..4]); // Blau
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, dst[4..8]); // Rot
}
