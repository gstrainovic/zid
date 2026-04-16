const std = @import("std");
const clay = @import("clay");
const zigdown = @import("zigdown");
const ui_mod = @import("mod.zig");
const Theme = ui_mod.Theme;
const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;
const flow_core = @import("flow_core");
const Block = zigdown.Block;
const Inline = zigdown.Inline;

pub const MarkdownView = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    font_size: u16 = 20,
    base_path: []const u8 = "",

    /// View for scrolling
    view: flow_core.View,

    /// Scrollbar-Dragging State
    scrollbar_dragging: bool = false,
    scrollbar_drag_start_y: f32 = 0,
    scrollbar_scroll_offset_at_drag_start: f32 = 0,

    /// Scrollbar Bounds
    scrollbar_track_x: f32 = 0,
    scrollbar_track_y: f32 = 0,
    scrollbar_thumb_y: f32 = 0,
    scrollbar_thumb_height: f32 = 0,
    scrollbar_container_width: f32 = 0,
    scrollbar_width: f32 = 10,

    scroll_offset_y: f32 = 0,
    viewport_height: f32 = 0,
    content_height: f32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, text: []const u8, base_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .text = allocator.dupe(u8, text) catch "",
            .base_path = allocator.dupe(u8, base_path) catch "",
            .view = .{},
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

    pub fn scrollLines(self: *Self, delta: i32) void {
        const scroll_speed: f32 = 60.0;
        if (delta > 0) {
            self.scroll_offset_y = @max(0, self.scroll_offset_y - @as(f32, @floatFromInt(delta)) * scroll_speed);
        } else if (delta < 0) {
            const max_scroll = @max(0, self.content_height - self.viewport_height);
            self.scroll_offset_y = @min(max_scroll, self.scroll_offset_y + @as(f32, @floatFromInt(-delta)) * scroll_speed);
        }
    }

    pub fn handleScrollbarMouseDown(self: *Self, x: f32, y: f32) bool {
        if (self.content_height <= self.viewport_height) return false;

        if (x < self.scrollbar_track_x) return false;
        if (x > self.scrollbar_track_x + self.scrollbar_width) return false;
        if (y < self.scrollbar_track_y) return false;
        if (y > self.scrollbar_track_y + self.viewport_height) return false;

        if (y >= self.scrollbar_thumb_y and y <= self.scrollbar_thumb_y + self.scrollbar_thumb_height) {
            self.scrollbar_dragging = true;
            self.scrollbar_drag_start_y = y;
            self.scrollbar_scroll_offset_at_drag_start = self.scroll_offset_y;
            return true;
        }

        // Jump to position
        const track_height = self.viewport_height;
        const total_height = self.content_height;
        const thumb_height = self.scrollbar_thumb_height;
        const scrollable_height = track_height - thumb_height;

        if (scrollable_height > 0) {
            const click_pos_rel = (y - self.scrollbar_track_y) - (thumb_height / 2.0);
            const scroll_frac = @max(0, @min(1.0, click_pos_rel / scrollable_height));
            self.scroll_offset_y = scroll_frac * (total_height - track_height);
        }

        return true;
    }

    pub fn handleScrollbarMouseMove(self: *Self, x: f32, y: f32) void {
        _ = x;
        if (!self.scrollbar_dragging) return;
        if (self.content_height <= self.viewport_height) return;

        const track_height = self.viewport_height;
        const total_height = self.content_height;
        const thumb_height = self.scrollbar_thumb_height;
        const scrollable_height = track_height - thumb_height;

        if (scrollable_height <= 0) return;

        const delta_y = y - self.scrollbar_drag_start_y;
        const scroll_delta_frac = delta_y / scrollable_height;
        const scroll_delta_px = scroll_delta_frac * (total_height - track_height);

        var new_offset = self.scrollbar_scroll_offset_at_drag_start + scroll_delta_px;
        const max_scroll = total_height - track_height;
        new_offset = @max(0, @min(new_offset, max_scroll));

        self.scroll_offset_y = new_offset;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.scrollbar_dragging = false;
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        var result = zigdown.parser.timedParse(arena, self.text, false) catch |err| {
            std.log.scoped(.markdown).err("Failed to parse markdown: {any}", .{err});
            return;
        };

        // Update layout info from previous frame
        const clip_data = clay.getElementData(clay.ElementId.ID("md_viewport"));
        const content_data = clay.getElementData(clay.ElementId.ID("md_content"));
        if (clip_data.found) {
            self.viewport_height = clip_data.bounding_box.height;
            self.scrollbar_track_x = clip_data.bounding_box.x + clip_data.bounding_box.width;
            self.scrollbar_track_y = clip_data.bounding_box.y;
        }
        if (content_data.found) {
            self.content_height = content_data.bounding_box.height;
        }

        clay.UI()(.{
            .id = clay.ElementId.ID("markdown_view_root"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right,
            },
            .background_color = theme.bg,
        })({
            // Content area
            clay.UI()(.{
                .id = clay.ElementId.ID("md_viewport"),
                .layout = .{ .sizing = .grow },
                .clip = .{ .vertical = true, .horizontal = true },
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("md_content"),
                    .floating = .{
                        .attach_to = .to_parent,
                        .attach_points = .{ .element = .left_top, .parent = .left_top },
                        .offset = .{ .x = 0, .y = -self.scroll_offset_y },
                    },
                    .layout = .{
                        .sizing = .{ .w = .fixed(if (clip_data.found) clip_data.bounding_box.width else 800), .h = .fit },
                        .direction = .top_to_bottom,
                        .padding = .all(24),
                        .child_gap = 16,
                    },
                })({
                    self.renderBlock(&result.parser.document, arena, theme, ui_ptr);
                });
            });

            // Scrollbar
            if (self.content_height > self.viewport_height) {
                self.renderScrollbar();
            }
        });
    }

    fn renderScrollbar(self: *Self) void {
        const total = self.content_height;
        const visible = self.viewport_height;
        if (total <= visible) return;

        const track_height = visible;
        const thumb_ratio = visible / total;
        const thumb_height = @max(20.0, track_height * thumb_ratio);
        const max_scroll = total - visible;
        const scroll_frac = if (max_scroll > 0) self.scroll_offset_y / max_scroll else 0;
        const thumb_y = scroll_frac * (track_height - thumb_height);

        self.scrollbar_thumb_y = self.scrollbar_track_y + thumb_y;
        self.scrollbar_thumb_height = thumb_height;

        const track_color: clay.Color = .{ 30, 30, 46, 255 }; // Fully opaque track
        const thumb_color: clay.Color = .{ 88, 88, 120, 200 };

        clay.UI()(.{
            .id = clay.ElementId.ID("md_scrollbar_track"),
            .floating = .{
                .attach_to = .to_parent,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .z_index = 1000,
            },
            .layout = .{
                .sizing = .{ .w = .fixed(self.scrollbar_width), .h = .grow },
                .direction = .top_to_bottom,
            },
            .background_color = track_color,
        })({
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_y) } },
            })({});
            clay.UI()(.{
                .id = clay.ElementId.ID("md_scrollbar_thumb"),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_height) } },
                .background_color = thumb_color,
                .corner_radius = .all(3),
            })({});
        });
    }

    fn renderBlock(self: *Self, block: *Block, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        switch (block.*) {
            .Container => |*container| {
                const layout_options = switch (container.content) {
                    .Document => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 16 },
                    .Quote => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .{ .left = 16, .right = 0, .top = 4, .bottom = 4 }, .child_gap = 8 },
                    .List => |_| clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .{ .left = 24, .right = 0, .top = 0, .bottom = 0 }, .child_gap = 8 },
                    .ListItem => |_| clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 4 },
                    .Table => |_| clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 0 },
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
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 4 } })({
                            for (leaf.inlines.items) |*inline_item| {
                                self.renderInline(inline_item, size, theme.text, arena, ui_ptr);
                            }
                        });
                    },
                    .Paragraph => {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 4 } })({
                            for (leaf.inlines.items) |*inline_item| {
                                self.renderInline(inline_item, self.font_size, theme.text, arena, ui_ptr);
                            }
                        });
                    },
                    .Code => |c| {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .all(16) }, .background_color = theme.surface, .corner_radius = .all(4) })({
                            clay.text(c.text orelse "", .{ .font_size = self.font_size - 2, .color = theme.text });
                        });
                    },
                    .Alert => |a| {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .all(16) }, .background_color = theme.surface, .border = .{ .width = .{ .left = 4 }, .color = theme.accent } })({
                            clay.text(if (a.alert) |at| at else "ALERT", .{ .font_size = self.font_size, .color = theme.accent });
                            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 4 } })({
                                for (leaf.inlines.items) |*inline_item| {
                                    self.renderInline(inline_item, self.font_size, theme.text, arena, ui_ptr);
                                }
                            });
                        });
                    },
                    .Break => {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(8) } } })({});
                    },
                }
            },
        }
    }

    fn renderInline(self: *Self, item: *const Inline, base_size: u16, base_color: clay.Color, arena: std.mem.Allocator, ui_ptr: *ui_mod.UI) void {
        switch (item.content) {
            .text => |t| {
                clay.text(t.text, .{ .font_size = base_size, .color = base_color, .wrap_mode = .words });
            },
            .link => |l| {
                for (l.text.items) |t| {
                    clay.text(t.text, .{ .font_size = base_size, .color = .{ 100, 149, 237, 255 }, .wrap_mode = .words });
                }
            },
            .codespan => |c| {
                clay.text(c.text, .{ .font_size = base_size, .color = base_color, .wrap_mode = .words });
            },
            .image => |img| {
                var path: []const u8 = img.src;
                if (!std.fs.path.isAbsolute(path) and self.base_path.len > 0) {
                    const dir = std.fs.path.dirname(self.base_path) orelse ".";
                    path = std.fs.path.join(arena, &[_][]const u8{ dir, img.src }) catch img.src;
                }

                if (ui_ptr.open_images.get(path)) |texture_ptr| {
                    const tex: *const ImageTexture = @ptrCast(@alignCast(texture_ptr));
                    const aspect: f32 = if (tex.height > 0) @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height)) else 1.0;
                    const max_w = @as(f32, @floatFromInt(tex.width));

                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .{ .type = .grow, .size = .{ .minmax = .{ .min = 0, .max = max_w } } }, .h = .fit },
                        },
                        .background_color = .{ 255, 255, 255, 255 },
                        .aspect_ratio = .{ .aspect_ratio = aspect },
                        .image = .{ .image_data = texture_ptr },
                    })({});
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
