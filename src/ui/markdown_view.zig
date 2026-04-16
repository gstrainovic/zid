const std = @import("std");
const clay = @import("clay");
const zigdown = @import("zigdown");
const ui_mod = @import("mod.zig");
const Theme = ui_mod.Theme;
const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;

const Block = zigdown.Block;
const Inline = zigdown.Inline;

pub const MarkdownView = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    font_size: u16 = 20,
    base_path: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, text: []const u8, base_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .text = allocator.dupe(u8, text) catch "",
            .base_path = allocator.dupe(u8, base_path) catch "",
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.text.len > 0 and self.text.ptr != "".ptr) {
            self.allocator.free(self.text);
        }
        if (self.base_path.len > 0 and self.base_path.ptr != "".ptr) {
            self.allocator.free(self.base_path);
        }
        self.text = "";
        self.base_path = "";
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        var result = zigdown.parser.timedParse(arena, self.text, false) catch |err| {
            std.log.scoped(.markdown).err("Failed to parse markdown: {any}", .{err});
            return;
        };
        defer result.parser.deinit();

        clay.UI()(.{
            .id = clay.ElementId.ID("markdown_view"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .top_to_bottom, .padding = .all(32), .child_gap = 16 },
            .background_color = theme.bg,
            .clip = .{ .vertical = true },
        })({
            self.renderBlock(&result.parser.document, arena, theme, ui_ptr);
        });
    }

    fn renderBlock(self: *Self, block: *Block, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        switch (block.*) {
            .Container => |*container| {
                const layout_options = switch (container.content) {
                    .Document => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 16 },
                    .Quote => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .{ .left = 16, .right = 0, .top = 4, .bottom = 4 }, .child_gap = 8 },
                    .List => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .{ .left = 24, .right = 0, .top = 0, .bottom = 0 }, .child_gap = 8 },
                    .ListItem => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 4 },
                    .Table => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 0 },
                };
                clay.UI()(.{
                    .layout = layout_options,
                    .border = if (container.content == .Quote) .{ .width = .{ .left = 4 }, .color = theme.accent } else .{},
                })({
                    for (container.children.items) |*child| {
                        if (container.content == .List) {
                            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 8 } })({
                                clay.text("•", .{ .font_size = self.font_size, .color = theme.text });
                                self.renderBlock(child, arena, theme, ui_ptr);
                            });
                        } else {
                            self.renderBlock(child, arena, theme, ui_ptr);
                        }
                    }
                });
            },
            .Leaf => |*leaf| {
                switch (leaf.content) {
                    .Heading => |h| {
                        const multiplier: f32 = switch (h.level) { 1 => 2.0, 2 => 1.5, 3 => 1.2, else => 1.1 };
                        const size: u16 = @intFromFloat(@as(f32, @floatFromInt(self.font_size)) * multiplier);
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 0 } })({
                            for (leaf.inlines.items) |*inline_item| { self.renderInline(inline_item, size, theme.text, arena, ui_ptr); }
                        });
                    },
                    .Paragraph => {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 0 } })({
                            for (leaf.inlines.items) |*inline_item| { self.renderInline(inline_item, self.font_size, theme.text, arena, ui_ptr); }
                        });
                    },
                    .Code => |c| {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .all(16) }, .background_color = theme.surface, .corner_radius = .all(4) })({
                            clay.text(c.text orelse "", .{ .font_size = self.font_size - 2, .color = theme.text });
                        });
                    },
                    .Alert => |a| {
                         clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .all(16) }, .background_color = theme.surface, .border = .{ .width = .{ .left = 4 }, .color = theme.accent } })({
                            clay.text(if (a.alert) |at| at else "ALERT", .{ .font_size = self.font_size, .color = theme.accent });
                            for (leaf.inlines.items) |*inline_item| { self.renderInline(inline_item, self.font_size, theme.text, arena, ui_ptr); }
                        });
                    },
                    .Break => { clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(8) } } })({}); },
                }
            },
        }
    }

    fn renderInline(self: *Self, item: *const Inline, base_size: u16, base_color: clay.Color, arena: std.mem.Allocator, ui_ptr: *ui_mod.UI) void {
        switch (item.content) {
            .text => |t| {
                var content = arena.dupe(u8, t.text) catch "";
                while (std.mem.indexOf(u8, content, "&#x20;")) |idx| {
                    const replaced = arena.alloc(u8, content.len - 5) catch break;
                    std.mem.copyForwards(u8, replaced[0..idx], content[0..idx]);
                    replaced[idx] = ' ';
                    std.mem.copyForwards(u8, replaced[idx + 1 ..], content[idx + 6 ..]);
                    content = replaced;
                }
                clay.text(content, .{ .font_size = base_size, .color = base_color, .wrap_mode = .words });
            },
            .link => |l| {
                for (l.text.items) |t| { clay.text(t.text, .{ .font_size = base_size, .color = .{ 100, 149, 237, 255 }, .wrap_mode = .words }); }
            },
            .codespan => |c| {
                clay.text(c.text, .{ .font_size = base_size, .color = base_color, .wrap_mode = .words });
            },
            .image => |img| {
                var path: []const u8 = img.src;
                if (!std.fs.path.isAbsolute(path) and self.base_path.len > 0) {
                    const dir = std.fs.path.dirname(self.base_path) orelse "";
                    path = std.fs.path.join(arena, &[_][]const u8{ dir, img.src }) catch img.src;
                }
                if (ui_ptr.open_images.get(path)) |texture_ptr| {
                    const tex: *const ImageTexture = @ptrCast(@alignCast(texture_ptr));
                    const aspect: f32 = if (tex.height > 0) @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height)) else 1.0;
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fit },
                        },
                        .background_color = .{ 255, 255, 255, 255 }, // Ensure untinted image
                        .aspect_ratio = .{ .aspect_ratio = aspect },
                        .image = .{ .image_data = texture_ptr },
                    })({});
                    std.log.scoped(.markdown).info("Successfully rendered image: {s}", .{path});
                } else {
                    _ = ui_ptr.getOrCreateTexture(path);
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fixed(120), .h = .fixed(40) }, .child_alignment = .{ .x = .center, .y = .center } },
                        .background_color = .{ 80, 80, 80, 255 },
                        .corner_radius = .all(4),
                    })({
                        clay.text("LOADING...", .{ .font_size = 14, .color = .{ 200, 200, 200, 255 } });
                    });
                }
            },
            else => {},
        }
    }
};
