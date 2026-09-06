const std = @import("std");
const clay = @import("clay");
const zigdown = @import("zigdown");
const word_wrap = @import("word_wrap.zig");
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
    /// Überschreibt theme.text, wenn der Inhalt auf einem Hintergrund liegt,
    /// der nicht dem Theme-Hintergrund entspricht (z.B. Chat-Bubbles).
    text_color: ?clay.Color = null,
    /// Laufende Nummer der Fließtext-Container im aktuellen Frame (für Element-IDs).
    run_counter: u32 = 0,
    /// Obergrenze für die Umbruchbreite. Nötig in horizontal scrollbaren
    /// Viewports, wo Clay dem Container die volle Inhaltsbreite meldet.
    wrap_width_hint: ?f32 = null,

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

    /// Context Menu State
    show_context_menu: bool = false,
    context_menu_x: f32 = 0,
    context_menu_y: f32 = 0,

    pending_split_v: bool = false,
    pending_split_h: bool = false,

    /// Geparster Dokumentbaum, einmal pro View erzeugt. Arena und Ergebnis
    /// liegen auf dem Heap: Views leben in ArrayLists und dürfen wandern,
    /// der Parser hält aber einen Pointer auf seinen Allocator.
    doc_arena: ?*std.heap.ArenaAllocator = null,
    parsed: ?*zigdown.parser.ParseResult = null,

    /// Code-Block-Highlighter je Sprache (Schlüssel owned). Vorher wurde bei jedem
    /// Sprachwechsel neu erzeugt: vier Blöcke in vier Sprachen = vier Tree-sitter-Parser pro Frame.
    code_highlighters: ?std.StringHashMap(*flow_core.highlight.SyntaxHighlighter) = null,

    const Self = @This();

    fn colorFromTag(fg: u32) clay.Color {
        return .{
            @floatFromInt((fg >> 16) & 0xff),
            @floatFromInt((fg >> 8) & 0xff),
            @floatFromInt(fg & 0xff),
            255,
        };
    }

    fn lessThanTag(_: void, a: flow_core.highlight.ColorTag, b: flow_core.highlight.ColorTag) bool {
        if (a.start != b.start) return a.start < b.start;
        return a.end > b.end;
    }

    pub fn init(allocator: std.mem.Allocator, text: []const u8, base_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .text = allocator.dupe(u8, text) catch "",
            .base_path = allocator.dupe(u8, base_path) catch "",
            .view = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.parsed) |pr| {
            self.allocator.destroy(pr);
            self.parsed = null;
        }
        if (self.doc_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.doc_arena = null;
        }
        if (self.code_highlighters) |*map| {
            var it = map.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.*.destroy();
                self.allocator.free(kv.key_ptr.*);
            }
            map.deinit();
            self.code_highlighters = null;
        }
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

    pub fn handleMouseDown(self: *Self, x: f32, y: f32) bool {
        if (self.show_context_menu) {
            if (clay.pointerOver(clay.getElementId("MDSplitV"))) {
                self.pending_split_v = true;
                self.show_context_menu = false;
                return true;
            }
            if (clay.pointerOver(clay.getElementId("MDSplitH"))) {
                self.pending_split_h = true;
                self.show_context_menu = false;
                return true;
            }
            self.show_context_menu = false;
        }

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

    pub fn showContextMenu(self: *Self, x: f32, y: f32) void {
        self.show_context_menu = true;
        self.context_menu_x = x;
        self.context_menu_y = y;
    }

    fn renderContextMenu(self: *Self) void {
        if (!self.show_context_menu) return;

        const font_size_f: f32 = @floatFromInt(self.font_size);

        clay.UI()(.{
            .id = clay.ElementId.ID("md-context-menu-anchor"),
            .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(0) } },
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = .{ .x = self.context_menu_x, .y = self.context_menu_y },
                .z_index = 1000,
            },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("md-context-menu-container"),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .top_to_bottom,
                    .padding = .all(8),
                    .child_gap = 4,
                },
                .background_color = .{ 45, 45, 60, 255 },
                .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
                .corner_radius = .all(4),
            })({
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(1) } }, .background_color = .{ 80, 80, 80, 255 } })({});

                self.renderContextMenuItem("Split-Vertically", "MDSplitV", font_size_f);
                self.renderContextMenuItem("Split-Horizontally", "MDSplitH", font_size_f);
            });
        });
    }

    fn renderContextMenuItem(self: *Self, label: []const u8, id: []const u8, item_font_size: f32) void {
        _ = self;
        const item_id = clay.getElementId(id);
        const is_hovered = clay.pointerOver(item_id);

        clay.UI()(.{
            .id = item_id,
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fixed(item_font_size + 12) },
                .padding = .{ .left = 8, .right = 8 },
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = if (is_hovered) .{ 80, 80, 100, 255 } else .{ 0, 0, 0, 0 },
            .corner_radius = .all(2),
        })({
            clay.text(label, .{ .font_size = @intFromFloat(item_font_size), .color = .{ 220, 220, 220, 255 } });
        });
    }

    /// Parst self.text und rendert die Blöcke ohne Root-, Scroll- oder
    /// Kontextmenü-Container. Für eingebettetes Markdown, z.B. Chat-Nachrichten.
    /// Liefert den geparsten Baum, beim ersten Aufruf wird geparst.
    fn cachedDocument(self: *Self) ?*Block {
        if (self.parsed) |pr| return &pr.parser.document;

        const arena = self.allocator.create(std.heap.ArenaAllocator) catch return null;
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        const pr = self.allocator.create(zigdown.parser.ParseResult) catch {
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        pr.* = zigdown.parser.timedParse(arena.allocator(), self.text, false) catch |err| {
            std.log.scoped(.markdown).err("Failed to parse markdown: {any}", .{err});
            self.allocator.destroy(pr);
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        std.log.scoped(.markdown).debug("parsed markdown once: {d} bytes in {d:.2} ms", .{ self.text.len, pr.time_s * 1000.0 });
        self.doc_arena = arena;
        self.parsed = pr;
        return &pr.parser.document;
    }

    pub fn renderDocument(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        const doc = self.cachedDocument() orelse return;
        var effective_theme = theme;
        if (self.text_color) |c| effective_theme.text = c;
        self.run_counter = 0;
        self.renderBlock(doc, arena, effective_theme, ui_ptr);
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        // Update layout info from previous frame
        const clip_data = clay.getElementData(clay.ElementId.ID("md_viewport"));
        const content_data = clay.getElementData(clay.ElementId.ID("md_content"));
        if (clip_data.found) {
            self.viewport_height = clip_data.bounding_box.height;
            self.scrollbar_track_x = clip_data.bounding_box.x + clip_data.bounding_box.width;
            self.scrollbar_track_y = clip_data.bounding_box.y;
            // md_content hat 24px Padding je Seite
            self.wrap_width_hint = @max(0, clip_data.bounding_box.width - 48);
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
                .clip = .{ .vertical = true, .horizontal = true, .child_offset = .{ .x = 0, .y = -self.scroll_offset_y } },
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("md_content"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .padding = .all(24),
                        .child_gap = 16,
                    },
                })({
                    self.renderDocument(arena, theme, ui_ptr);
                });
            });

            // Scrollbar
            if (self.content_height > self.viewport_height) {
                self.renderScrollbar();
            }
        });

        // Context Menu
        self.renderContextMenu();
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

    /// Highlighter für eine Sprache holen oder einmalig anlegen (null = keine Sprache / unbekannt).
    fn highlighterFor(self: *Self, lang_name: []const u8) ?*flow_core.highlight.SyntaxHighlighter {
        if (lang_name.len == 0) return null;
        if (self.code_highlighters == null) self.code_highlighters = std.StringHashMap(*flow_core.highlight.SyntaxHighlighter).init(self.allocator);
        const map = &self.code_highlighters.?;
        if (map.get(lang_name)) |hl| return hl;
        const created = flow_core.highlight.SyntaxHighlighter.create(self.allocator, lang_name) catch |err| {
            std.log.debug("md_preview: highlighter create failed for '{s}': {s}", .{ lang_name, @errorName(err) });
            return null;
        };
        const key = self.allocator.dupe(u8, lang_name) catch {
            created.destroy();
            return null;
        };
        map.put(key, created) catch {
            self.allocator.free(key);
            created.destroy();
            return null;
        };
        std.log.debug("md_preview: highlighter created for '{s}'", .{lang_name});
        return created;
    }

    fn renderCodeBlock(self: *Self, code: []const u8, lang_tag: ?[]const u8, arena: std.mem.Allocator, theme: Theme) void {
        // Determine language for highlighter
        const lang_name = lang_tag orelse "";
        std.log.debug("md_preview: renderCodeBlock lang='{s}' code_len={d}", .{ lang_name, code.len });

        const hl = self.highlighterFor(lang_name);
        if (hl) |highlighter| {
            const Ctx = struct {
                fn egc_length(_: flow_core.Buffer.Metrics, egcs: []const u8, colcount: *usize, _: usize) usize {
                    if (egcs.len == 0) return 0;
                    if (egcs[0] == '\n') { colcount.* = 1; return 1; }
                    if (egcs[0] == '\t') { colcount.* = 4; return 1; }
                    colcount.* = 1;
                    return 1;
                }
                fn egc_chunk_width(_: flow_core.Buffer.Metrics, chunk_: []const u8, _: usize) usize {
                    if (chunk_.len == 0) return 0;
                    if (chunk_[0] == '\n') return 1;
                    if (chunk_[0] == '\t') return 4;
                    return 1;
                }
                fn egc_last(_: flow_core.Buffer.Metrics, egcs: []const u8) []const u8 {
                    return egcs;
                }
            };
            const m = flow_core.Buffer.Metrics{
                .ctx = undefined,
                .egc_length = Ctx.egc_length,
                .egc_chunk_width = Ctx.egc_chunk_width,
                .egc_last = Ctx.egc_last,
                .tab_width = 4,
            };

            // Reset cached state so tags from a previous block don't leak.
            highlighter.resetTree();
            highlighter.invalidateAllLines();

            if (flow_core.Buffer.create(arena)) |buf| {
                defer buf.deinit();
                var eol_mode: flow_core.Buffer.EolMode = .lf;
                var utf8_sanitized: bool = false;
                if (buf.load_from_string(code, &eol_mode, &utf8_sanitized)) |root| {
                    highlighter.reparseFromBuffer(root, m) catch {};
                } else |_| {}
            } else |_| {}

            const line_count = std.mem.count(u8, code, "\n") + 1;
            std.log.debug("md_preview: highlighter ready, rendering {d} lines", .{line_count});
        } else {
            std.log.debug("md_preview: no highlighter, plain text rendering", .{});
        }

        // Split code into lines manually
        var start: usize = 0;
        var line_idx: usize = 0;

        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom } })({
            while (start < code.len) {
                const remaining = code[start..];
                const end_offset = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
                const end = start + end_offset;
                if (end > code.len) break;
                const line = code[start..end];
                const line_len = line.len;

                const tags_opt: ?[]flow_core.highlight.ColorTag = if (hl) |highlighter|
                    (highlighter.tagsForLine(line_idx, line_len, arena) catch null)
                else
                    null;

                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 0 } })({
                    if (tags_opt) |tags| {
                        std.sort.insertion(flow_core.highlight.ColorTag, tags, {}, lessThanTag);
                        var pos: usize = 0;
                        for (tags) |tag| {
                            if (tag.end > line_len) continue;
                            if (tag.start >= tag.end) continue;
                            const actual_start = @max(tag.start, pos);
                            if (actual_start >= tag.end) continue;
                            if (actual_start > pos) {
                                const seg = arena.dupe(u8, line[pos..actual_start]) catch "";
                                clay.text(seg, .{ .font_size = self.font_size - 2, .color = theme.text, .wrap_mode = .none });
                            }
                            const seg = arena.dupe(u8, line[actual_start..tag.end]) catch "";
                            clay.text(seg, .{ .font_size = self.font_size - 2, .color = colorFromTag(tag.fg), .wrap_mode = .none });
                            pos = tag.end;
                        }
                        if (pos < line_len) {
                            const seg = arena.dupe(u8, line[pos..]) catch "";
                            clay.text(seg, .{ .font_size = self.font_size - 2, .color = theme.text, .wrap_mode = .none });
                        }
                    } else {
                        clay.text(line, .{ .font_size = self.font_size - 2, .color = theme.text, .wrap_mode = .none });
                    }
                });

                start = end + 1;
                line_idx += 1;
            }
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
                        self.renderInlineRun(leaf.inlines.items, size, theme, arena, ui_ptr);
                    },
                    .Paragraph => {
                        self.renderInlineRun(leaf.inlines.items, self.font_size, theme, arena, ui_ptr);
                    },
                    .Code => |c| {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .all(16) }, .background_color = theme.surface, .corner_radius = .all(4) })({
                            self.renderCodeBlock(c.text orelse "", c.tag, arena, theme);
                        });
                    },
                    .Alert => |a| {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .all(16) }, .background_color = theme.surface, .border = .{ .width = .{ .left = 4 }, .color = theme.accent } })({
                            clay.text(if (a.alert) |at| at else "ALERT", .{ .font_size = self.font_size, .color = theme.accent });
                            self.renderInlineRun(leaf.inlines.items, self.font_size, theme, arena, ui_ptr);
                        });
                    },
                    .Break => {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(8) } } })({});
                    },
                }
            },
        }
    }

    const link_color: clay.Color = .{ 100, 149, 237, 255 };

    /// Ein gemessenes Textstück: Wort, Leerzeichen, Codespan oder Link-Text.
    const Piece = struct {
        text: []const u8,
        color: clay.Color,
        is_space: bool,
    };

    /// Farbe eines Text-Inlines aus seinem zigdown-Style. Es gibt nur eine
    /// Font-Face, deshalb werden Fett/Kursiv/Durchgestrichen über Farbe angezeigt.
    fn styledColor(style: anytype, base: clay.Color, theme: Theme) clay.Color {
        if (style.strike) return theme.muted;
        if (style.bold) return theme.primary;
        if (style.italic) return theme.accent;
        return base;
    }

    /// Rendert eine Inline-Folge als umbrechenden Fließtext mit Per-Wort-Farben.
    ///
    /// zigdown liefert jedes Wort und jedes Leerzeichen als eigenes Inline. Clay
    /// bricht Reihen von Elementen nicht um, also messen wir jedes Stück selbst,
    /// lassen word_wrap die Zeilen berechnen und rendern pro Zeile eine Reihe.
    /// Die verfügbare Breite stammt aus dem Bounding-Box des Containers im
    /// vorherigen Frame; im allerersten Frame fällt der Lauf auf ein einzelnes
    /// umbrechendes Textelement zurück. Nur Bilder unterbrechen den Lauf.
    fn renderInlineRun(self: *Self, inlines: []const Inline, base_size: u16, theme: Theme, arena: std.mem.Allocator, ui_ptr: *ui_mod.UI) void {
        var pieces: std.ArrayListUnmanaged(Piece) = .empty;
        for (inlines) |*item| {
            switch (item.content) {
                .text => |t| pieces.append(arena, .{
                    .text = t.text,
                    .color = styledColor(t.style, theme.text, theme),
                    .is_space = std.mem.eql(u8, t.text, " "),
                }) catch {},
                .codespan => |c| pieces.append(arena, .{ .text = c.text, .color = theme.warning, .is_space = false }) catch {},
                .link => |l| {
                    for (l.text.items) |t| pieces.append(arena, .{
                        .text = t.text,
                        .color = link_color,
                        .is_space = std.mem.eql(u8, t.text, " "),
                    }) catch {};
                },
                .image => {
                    self.flushPieces(&pieces, base_size, theme, arena);
                    self.renderInline(item, base_size, theme.text, arena, ui_ptr);
                },
                else => {},
            }
        }
        self.flushPieces(&pieces, base_size, theme, arena);
    }

    fn flushPieces(self: *Self, pieces: *std.ArrayListUnmanaged(Piece), base_size: u16, theme: Theme, arena: std.mem.Allocator) void {
        if (pieces.items.len == 0) return;
        defer pieces.clearRetainingCapacity();

        self.run_counter += 1;
        const id_str = std.fmt.allocPrint(arena, "md_run_{x}_{d}", .{ @intFromPtr(self), self.run_counter }) catch "md_run";
        const run_id = clay.ElementId.ID(id_str);
        const data = clay.getElementData(run_id);
        var avail: f32 = if (data.found) data.bounding_box.width else 0;
        if (self.wrap_width_hint) |hint| avail = @min(avail, hint);
        const size_f: f32 = @floatFromInt(base_size);

        clay.UI()(.{
            .id = run_id,
            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 2 },
        })({
            if (avail <= 0) {
                // Breite noch unbekannt (erster Frame): ein Element, Clay bricht selbst um
                var run: std.ArrayListUnmanaged(u8) = .empty;
                for (pieces.items) |p| run.appendSlice(arena, p.text) catch {};
                const text = std.mem.trim(u8, run.items, " ");
                if (text.len > 0) clay.text(text, .{ .font_size = base_size, .color = theme.text, .wrap_mode = .words });
            } else {
                const items = arena.alloc(word_wrap.Item, pieces.items.len) catch return;
                for (pieces.items, 0..) |p, i| {
                    items[i] = .{ .width = ui_mod.measureTextWidth(p.text, size_f), .is_space = p.is_space };
                }
                const lines = word_wrap.wrapLines(arena, items, avail - 2) catch return;
                for (lines) |line| {
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 0 } })({
                        for (pieces.items[line.start..line.end]) |p| {
                            clay.text(p.text, .{ .font_size = base_size, .color = p.color, .wrap_mode = .none });
                        }
                    });
                }
            }
        });
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
