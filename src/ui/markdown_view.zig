const std = @import("std");
const clay = @import("clay");
const zigdown = @import("zigdown");
const ui = @import("mod.zig");
const Theme = ui.Theme;

const Block = zigdown.Block;
const Container = zigdown.Container;
const Leaf = zigdown.Leaf;
const Inline = zigdown.Inline;
const Text = zigdown.Text;

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
        std.log.scoped(.markdown).debug("Rendering MarkdownView (len={d})", .{self.text.len});
        
        // Parse the markdown
        var result = zigdown.parser.timedParse(arena, self.text, false) catch |err| {
            std.log.scoped(.markdown).err("Failed to parse markdown: {any}", .{err});
            return;
        };
        defer result.parser.deinit();

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
            self.renderBlock(&result.parser.document, arena, theme);
        });
    }

    fn renderBlock(self: *Self, block: *Block, arena: std.mem.Allocator, theme: Theme) void {
        switch (block.*) {
            .Container => |*container| {
                const layout_options = switch (container.content) {
                    .Document => clay.LayoutConfig{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = 16,
                    },
                    .Quote => clay.LayoutConfig{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .padding = .{ .left = 16, .right = 0, .top = 4, .bottom = 4 },
                        .child_gap = 8,
                    },
                    .List => clay.LayoutConfig{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .padding = .{ .left = 24, .right = 0, .top = 0, .bottom = 0 },
                        .child_gap = 8,
                    },
                    .ListItem => clay.LayoutConfig{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom, // Content of list item
                        .child_gap = 4,
                    },
                    .Table => clay.LayoutConfig{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom, // Rows
                        .child_gap = 0,
                    },
                };

                clay.UI()(.{
                    .layout = layout_options,
                    .border = if (container.content == .Quote) .{ .width = .{ .left = 4 }, .color = theme.accent } else .{},
                })({
                    for (container.children.items) |*child| {
                        if (container.content == .List) {
                            // Wrapper for list item to show bullet
                            clay.UI()(.{
                                .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 8 },
                            })({
                                clay.text("•", .{ .font_size = self.font_size, .color = theme.text });
                                self.renderBlock(child, arena, theme);
                            });
                        } else {
                            self.renderBlock(child, arena, theme);
                        }
                    }
                });
            },
            .Leaf => |*leaf| {
                switch (leaf.content) {
                    .Heading => |h| {
                        const multiplier: f32 = switch (h.level) {
                            1 => 2.0,
                            2 => 1.7,
                            3 => 1.5,
                            4 => 1.3,
                            else => 1.1,
                        };
                        const size: u16 = @intFromFloat(@as(f32, @floatFromInt(self.font_size)) * multiplier);
                        
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 2 },
                        })({
                            for (leaf.inlines.items) |inline_item| {
                                self.renderInline(&inline_item, size, theme.accent, arena);
                            }
                        });
                    },
                    .Paragraph => {
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 0 },
                        })({
                            for (leaf.inlines.items) |inline_item| {
                                self.renderInline(&inline_item, self.font_size, theme.text, arena);
                            }
                        });
                    },
                    .Code => |c| {
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .all(12) },
                            .background_color = theme.bg, // Should be slightly different from bg
                            .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = theme.accent },
                        })({
                             const code_text = if (c.text) |ct| arena.dupe(u8, ct) catch "" else "";
                             clay.text(code_text, .{ .font_size = self.font_size, .color = theme.text }); // Use monospace font if available
                        });
                    },
                    .Alert => {
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .all(12) },
                            .background_color = theme.accent, // Highlight alert
                        })({
                             for (leaf.inlines.items) |inline_item| {
                                self.renderInline(&inline_item, self.font_size, theme.bg, arena);
                            }
                        });
                    },
                    .Break => {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(8) } } })({});
                    },
                }
            },
        }
    }

    fn renderInline(self: *Self, item: *const Inline, base_size: u16, base_color: clay.Color, arena: std.mem.Allocator) void {
        _ = self;
        switch (item.content) {
            .text => |t| {
                const color = base_color;
                if (t.style.bold) {
                    // How to do bold in clay? Usually different font.
                }
                if (t.style.italic) {
                    // Same.
                }

                // Basic entity decoding for &#x20;
                var content = arena.dupe(u8, t.text) catch "";
                while (std.mem.indexOf(u8, content, "&#x20;")) |idx| {
                    const replaced = arena.alloc(u8, content.len - 5) catch break;
                    std.mem.copyForwards(u8, replaced[0..idx], content[0..idx]);
                    replaced[idx] = ' ';
                    std.mem.copyForwards(u8, replaced[idx + 1 ..], content[idx + 6 ..]);
                    content = replaced;
                }

                clay.text(content, .{ .font_size = base_size, .color = color });
            },
            .link => |l| {
                for (l.text.items) |t| {
                    const content = arena.dupe(u8, t.text) catch "";
                    clay.text(content, .{ .font_size = base_size, .color = .{ 100, 149, 237, 255 } }); // Blueish for links
                }
            },
            .codespan => |c| {
                const content = arena.dupe(u8, c.text) catch "";
                clay.text(content, .{ .font_size = base_size, .color = base_color }); // Monospace style?
            },
            .linebreak => {
                 // Should be handled by layout?
            },
            else => {
                // TODO: handle images, etc.
            },
        }
    }
};
