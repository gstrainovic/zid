//! Code Editor Component für vulkan-ed
//!
//! Einfacher Code Editor mit Line Numbers und Syntax Highlighting.

const std = @import("std");
const clay = @import("clay");

pub const CodeEditor = struct {
    content: []const u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    font_size: f32 = 14.0,
    line_height: f32 = 20.0,
    gutter_width: f32 = 50.0,

    const Self = @This();

    /// Code Editor rendern
    pub fn render(self: Self) void {
        // Editor Container
        clay.UI()(.{
            .id = clay.ElementId.ID("code_editor"),
            .layout = .{
                .sizing = .{ .w = .fixed(self.width), .h = .fixed(self.height) },
            },
            .background_color = .{ 30, 30, 46, 255 },
            .corner_radius = .all(4),
        })({
            // Line Numbers Gutter (links)
            clay.UI()(.{
                .id = clay.ElementId.ID("line_numbers"),
                .layout = .{
                    .sizing = .{ .w = .fixed(self.gutter_width), .h = .fill },
                },
                .background_color = .{ 24, 24, 37, 255 },
            })({});

            // Code Content (rechts)
            clay.UI()(.{
                .id = clay.ElementId.ID("code_content"),
                .layout = .{
                    .sizing = .grow,
                    .padding = .all(8),
                },
                .background_color = .{ 30, 30, 46, 255 },
            })({});
        });
    }

    /// Anzahl Zeilen berechnen
    pub fn lineCount(self: Self) usize {
        var count: usize = 1;
        for (self.content) |char| {
            if (char == '\n') count += 1;
        }
        return count;
    }
};
