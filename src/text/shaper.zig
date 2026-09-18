//! Text shaping - converts text strings into positioned glyphs
//!
//! Provides both a simple shaper (works with any FontFace) and an interface
//! for complex platform-specific shaping (ligatures, kerning, RTL, etc.)

const std = @import("std");
const types = @import("types.zig");
const font_face = @import("font_face.zig");

pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const FontFace = font_face.FontFace;

/// Shaper interface for complex text shaping
/// Platform backends implement this for full Unicode support
pub const Shaper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        /// Full text shaping with ligatures, kerning, etc.
        shape: *const fn (ptr: *anyopaque, face: FontFace, text: []const u8, allocator: std.mem.Allocator) anyerror!ShapedRun,
        /// Release resources
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn shape(self: Shaper, face: FontFace, text: []const u8) !ShapedRun {
        return self.vtable.shape(self.ptr, face, text, self.allocator);
    }

    pub fn deinit(self: *Shaper) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};

/// A basic fallback shaper that maps characters 1:1 to glyphs
/// without any complex text layout features (no ligatures/kerning).
/// Gemeldete ungültige Strings (Obergrenze, sonst eine Zeile pro Frame).
var invalid_reports: u32 = 0;

/// Nächsten Codepoint ab `i.*` lesen und `i.*` weiterrücken; ein ungültiges Byte oder eine
/// abgeschnittene Sequenz ergibt U+FFFD und rückt genau ein Byte weiter.
pub fn decodeLossy(text: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > text.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(text[i.* .. i.* + len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

test "decodeLossy: gültige Sequenzen, kaputtes Byte und abgeschnittene Sequenz" {
    var i: usize = 0;
    const t = "a\xc3\xa4\xff\xe2\x82";
    try std.testing.expectEqual(@as(u21, 'a'), decodeLossy(t, &i));
    try std.testing.expectEqual(@as(u21, 0xE4), decodeLossy(t, &i));
    try std.testing.expectEqual(@as(u21, 0xFFFD), decodeLossy(t, &i));
    try std.testing.expectEqual(@as(usize, 4), i);
    try std.testing.expectEqual(@as(u21, 0xFFFD), decodeLossy(t, &i));
    try std.testing.expectEqual(@as(u21, 0xFFFD), decodeLossy(t, &i));
    try std.testing.expectEqual(t.len, i);
}

pub const SimpleShaper = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ?SimpleShaper {
        return SimpleShaper{
            .allocator = allocator,
        };
    }

    pub fn shape(self: *SimpleShaper, face: anytype, text: []const u8, allocator: std.mem.Allocator) anyerror!ShapedRun {
        _ = self;
        var glyphs = std.ArrayListUnmanaged(ShapedGlyph){};
        errdefer glyphs.deinit(allocator);

        var total_width: f32 = 0;
        if (std.unicode.utf8ValidateSlice(text) == false and invalid_reports < 5) {
            // Ein ungültiger String liess bisher den ganzen Frame scheitern (Swap-Chain zeigte
            // das alte Bild von zwei Frames zuvor: Zittern). Jetzt wird er verlustbehaftet
            // gezeichnet (U+FFFD je kaputtem Byte); wer ihn liefert, steht hier als Hex.
            invalid_reports += 1;
            const n = @min(text.len, 48);
            std.log.scoped(.shaper).warn("invalid UTF-8 text ({d} bytes): \"{f}\" hex={x}", .{ text.len, std.zig.fmtString(text[0..n]), text[0..n] });
            if (@import("builtin").mode == .Debug) std.debug.dumpCurrentStackTrace(null);
        }

        var i: usize = 0;
        while (i < text.len) {
            const cluster = i;
            const cp = decodeLossy(text, &i);
            const glyph_id = face.glyphIndex(cp);
            const metrics = face.glyphMetrics(glyph_id);

            try glyphs.append(allocator, .{
                .glyph_id = glyph_id,
                .x_offset = 0,
                .y_offset = 0,
                .x_advance = metrics.advance_x,
                .y_advance = 0,
                .cluster = @intCast(cluster),
                .font_ref = null,
                .is_color = false,
            });
            total_width += metrics.advance_x;
        }

        return ShapedRun{
            .glyphs = try glyphs.toOwnedSlice(allocator),
            .width = total_width,
            .owned = true,
        };
    }

    pub fn deinit(self: *SimpleShaper) void {
        self.* = undefined;
    }
};
