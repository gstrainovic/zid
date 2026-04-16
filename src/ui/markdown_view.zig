const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;

pub const MarkdownView = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    font_size: u16 = 20,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, text: []const u8) Self {
        return .{
            .allocator = allocator,
            .text = allocator.dupe(u8, text) catch "",
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.text);
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme) void {
        clay.UI()(.{
            .id = clay.ElementId.ID("markdown_view"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .top_to_bottom,
                .padding = .all(32),
                .child_gap = 16,
            },
            .background_color = theme.bg,
            .clip = .{ .vertical = true },
        })({
            var lines = std.mem.splitScalar(u8, self.text, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (trimmed.len == 0) {
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(8) } } })({});
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "# ")) {
                    const h1_text = arena.dupe(u8, trimmed[2..]) catch "";
                    clay.text(h1_text, .{ .font_size = @intFromFloat(@as(f32, @floatFromInt(self.font_size)) * 1.5), .color = theme.accent });
                } else if (std.mem.startsWith(u8, trimmed, "## ")) {
                    const h2_text = arena.dupe(u8, trimmed[3..]) catch "";
                    clay.text(h2_text, .{ .font_size = @intFromFloat(@as(f32, @floatFromInt(self.font_size)) * 1.3), .color = theme.accent });
                } else if (std.mem.startsWith(u8, trimmed, "### ")) {
                    const h3_text = arena.dupe(u8, trimmed[4..]) catch "";
                    clay.text(h3_text, .{ .font_size = @intFromFloat(@as(f32, @floatFromInt(self.font_size)) * 1.1), .color = theme.accent });
                } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 8 },
                    })({
                        clay.text("•", .{ .font_size = self.font_size, .color = theme.text });
                        const list_text = arena.dupe(u8, trimmed[2..]) catch "";
                        clay.text(list_text, .{ .font_size = self.font_size, .color = theme.text });
                    });
                } else {
                    const p_text = arena.dupe(u8, trimmed) catch "";
                    clay.text(p_text, .{ .font_size = self.font_size, .color = theme.text });
                }
            }
        });
    }
};
