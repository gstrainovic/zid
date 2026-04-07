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
        var i: usize = 0;
        var utf8 = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
        var iter = utf8.iterator();

        while (iter.nextCodepoint()) |cp| {
            const seq_len: usize = std.unicode.utf8CodepointSequenceLength(cp) catch 0;
            const cluster = iter.i - seq_len;
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
            i += 1;
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
