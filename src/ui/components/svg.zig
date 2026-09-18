//! Clay SVG Component
//!
//! Helper for rendering SVG icons using Clay layout.

const std = @import("std");
const clay = @import("clay");
const svg_mod = @import("../../svg/mod.zig");

pub const Lucide = @import("lucide.zig").Lucide;

/// Helper to render an SVG icon in Clay
pub fn Svg(allocator: std.mem.Allocator, id: []const u8, path_data: []const u8, size: f32, color: [4]f32) void {
    SvgEx(allocator, id, path_data, size, color, null);
}

/// Icon als Kontur (Lucide-Original: Strichbreite 2 auf viewbox 24) statt gefüllt. Nötig für
/// Pfade ohne Fläche wie „plus“ und „minus“, die gefüllt unsichtbar bleiben.
pub fn SvgStroke(allocator: std.mem.Allocator, id: []const u8, path_data: []const u8, size: f32, color: [4]f32) void {
    SvgEx(allocator, id, path_data, size, color, 2.0);
}

pub fn SvgEx(allocator: std.mem.Allocator, id: []const u8, path_data: []const u8, size: f32, color: [4]f32, stroke_width: ?f32) void {
    // SvgRenderInfo in der Frame-Arena allozieren
    const info = allocator.create(svg_mod.SvgRenderInfo) catch {
        // Fallback: Leeres Image falls Allokation fehlschlägt
        clay.UI()(.{
            .id = clay.ElementId.ID(id),
            .layout = .{ .sizing = .{ .w = .fixed(size), .h = .fixed(size) } },
        })({});
        return;
    };

    info.* = .{
        .path_data = path_data,
        .viewbox = 24.0, // Lucide Standard
        .color = color,
        .stroke_width = stroke_width,
    };

    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = .fixed(size), .h = .fixed(size) },
        },
        .image = .{ .image_data = info },
        // Kein background_color — SVG wird als Image gerendert, Farbe kommt aus SvgRenderInfo
    })({});
}
