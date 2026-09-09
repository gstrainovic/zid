const std = @import("std");
const clay = @import("clay");
const zigdown = @import("zigdown");
const word_wrap = @import("word_wrap.zig");
const ui_mod = @import("mod.zig");
const shortcuts = @import("shortcuts");
const marp = @import("marp");
const marp_pdf = @import("../rendering/marp_pdf.zig");
const ctx_menu = @import("context_menu");
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

    /// Marp-Deck, falls `text` eines ist (`marp: true` im Front-Matter). Dann
    /// zeigt die Vorschau Folien statt eines durchgehenden Dokuments.
    deck: ?marp.Deck = null,
    current_slide: usize = 0,
    /// Maßstab Rahmen zu Foliengröße aus dem letzten Frame (1.0 = unbekannt).
    slide_scale: f32 = 1.0,
    /// Inhalt der gezeigten Folie ragt über den Rahmen hinaus (wird im PDF abgeschnitten).
    slide_overflow: bool = false,
    /// Parse-Ergebnis der gezeigten Folie. Eigene Arena, wird beim Folienwechsel
    /// verworfen — es ist immer nur eine Folie im Blick.
    slide_arena: ?*std.heap.ArenaAllocator = null,
    slide_parsed: ?*zigdown.parser.ParseResult = null,

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
    pending_export_pdf: bool = false,

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
            // Kein Deck ist der Normalfall, nicht der Fehlerfall.
            .deck = marp.parse(allocator, text) catch null,
            .view = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.dropSlideDocument();
        if (self.deck) |*d| {
            d.deinit();
            self.deck = null;
        }
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
        // Im Deck blättert das Rad, es gibt nichts zu scrollen.
        if (self.deck != null) {
            if (delta < 0) self.nextSlide() else if (delta > 0) self.prevSlide();
            return;
        }
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
            self.show_context_menu = false;
            if (ctx_menu.hit("md_menu", &shortcuts.markdown_menu_items, ctx_menu.none)) |cmd| {
                switch (cmd) {
                    .split_vertical => self.pending_split_v = true,
                    .split_horizontal => self.pending_split_h = true,
                    .md_export_pdf => self.pending_export_pdf = true,
                    else => {},
                }
                return true;
            }
        }

        if (self.deck != null) {
            if (hitElement("md_slide_prev", x, y)) {
                self.prevSlide();
                return true;
            }
            if (hitElement("md_slide_next", x, y)) {
                self.nextSlide();
                return true;
            }
            return false;
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

    /// Liegt (x, y) in der Bounding-Box des Elements aus dem letzten Frame?
    fn hitElement(id: []const u8, x: f32, y: f32) bool {
        const data = clay.getElementData(clay.ElementId.ID(id));
        if (!data.found) return false;
        const b = data.bounding_box;
        return x >= b.x and x <= b.x + b.width and y >= b.y and y <= b.y + b.height;
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

    /// Kontextmenü (`shortcuts.markdown_menu_items`, IDs `md_menu_<command>`) im gemeinsamen Stil.
    fn renderContextMenu(self: *Self, theme: Theme) void {
        if (!self.show_context_menu) return;
        _ = ctx_menu.render("md_menu", &shortcuts.markdown_menu_items, self.context_menu_x, self.context_menu_y, ctx_menu.none, ctx_menu.Colors.fromTheme(theme));
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

    /// Anzahl Folien; 0 wenn der Text kein Marp-Deck ist.
    pub fn slideCount(self: *const Self) usize {
        const d = self.deck orelse return 0;
        return d.slides.len;
    }

    fn dropSlideDocument(self: *Self) void {
        if (self.slide_parsed) |pr| {
            self.allocator.destroy(pr);
            self.slide_parsed = null;
        }
        if (self.slide_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.slide_arena = null;
        }
    }

    /// Blättert zur Folie `index` (geklemmt) und wirft den alten Parse weg.
    pub fn showSlide(self: *Self, index: usize) void {
        const count = self.slideCount();
        if (count == 0) return;
        const clamped = @min(index, count - 1);
        if (clamped == self.current_slide and self.slide_parsed != null) return;
        self.current_slide = clamped;
        self.slide_overflow = false;
        self.dropSlideDocument();
        self.scroll_offset_y = 0;
    }

    pub fn nextSlide(self: *Self) void {
        if (self.current_slide + 1 < self.slideCount()) self.showSlide(self.current_slide + 1);
    }

    pub fn prevSlide(self: *Self) void {
        if (self.current_slide > 0) self.showSlide(self.current_slide - 1);
    }

    /// Wie `cachedDocument`, nur für die gerade gezeigte Folie.
    fn cachedSlideDocument(self: *Self) ?*Block {
        if (self.slide_parsed) |pr| return &pr.parser.document;
        const d = self.deck orelse return null;
        if (self.current_slide >= d.slides.len) return null;

        const arena = self.allocator.create(std.heap.ArenaAllocator) catch return null;
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        const pr = self.allocator.create(zigdown.parser.ParseResult) catch {
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        pr.* = zigdown.parser.timedParse(arena.allocator(), d.slides[self.current_slide].markdown, false) catch |err| {
            std.log.scoped(.markdown).err("Failed to parse slide: {any}", .{err});
            self.allocator.destroy(pr);
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        self.slide_arena = arena;
        self.slide_parsed = pr;
        // Ob die Folie aufs Blatt passt, beantwortet die Story-Engine des
        // Exports — Clay kann es nicht, weil der Rahmen den Inhalt abschneidet
        // und die gemessene Höhe damit nie über die Innenhöhe geht.
        self.slide_overflow = !marp_pdf.slideFits(self.allocator, d, self.current_slide);
        return &pr.parser.document;
    }

    pub fn renderDocument(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        const doc = self.cachedDocument() orelse return;
        var effective_theme = theme;
        if (self.text_color) |c| effective_theme.text = c;
        self.run_counter = 0;
        self.renderBlock(doc, arena, effective_theme, ui_ptr);
    }

    /// Folienvorschau: eine Folie im 16:9-Rahmen plus Blätterleiste. Der Rahmen
    /// hat die Seitenverhältnisse des Decks, damit man sieht, was ins PDF passt.
    fn renderDeck(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        const d = self.deck.?;
        const deck_w: f32 = @floatFromInt(d.global.size.w);
        const aspect: f32 = if (d.global.size.h > 0)
            deck_w / @as(f32, @floatFromInt(d.global.size.h))
        else
            16.0 / 9.0;

        // Rahmengröße selbst rechnen statt Clays Aspect-Ratio zu überlassen:
        // mit `.w = .grow` blieb der Rahmen auf Inhaltsgröße stehen, also winzig.
        // Grundlage ist die Fläche des Wurzelelements aus dem letzten Frame; das
        // Wurzelelement clippt, sonst wüchse es mit dem Rahmen mit und der
        // nächste Frame rechnete daraus einen noch größeren Rahmen.
        const root = clay.getElementData(clay.ElementId.ID("markdown_view_root"));
        const bar = clay.getElementData(clay.ElementId.ID("md_slide_bar"));
        const reserve: f32 = if (bar.found) bar.bounding_box.height + 16 else chrome_reserve;
        const avail_w = if (root.found) @max(120.0, root.bounding_box.width - 2 * root_padding) else deck_w;
        const avail_h = if (root.found)
            @max(80.0, root.bounding_box.height - 2 * root_padding - reserve)
        else
            deck_w / aspect;
        const frame_w = @min(avail_w, avail_h * aspect);
        const frame_h = frame_w / aspect;

        const scale: f32 = frame_w / deck_w;
        self.slide_scale = scale;

        clay.UI()(.{
            .id = clay.ElementId.ID("markdown_view_root"),
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .padding = .all(root_padding),
                .child_gap = 16,
                .child_alignment = .{ .x = .center, .y = .center },
            },
            // Clippt, damit der Rahmen das Wurzelelement nicht aufblähen kann.
            .clip = .{ .vertical = true, .horizontal = true },
            .background_color = theme.bg,
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("md_slide"),
                .layout = .{
                    .sizing = .{ .w = .fixed(frame_w), .h = .fixed(frame_h) },
                    .direction = .top_to_bottom,
                    // Dieselben Ränder wie im PDF, nur im Maßstab des Rahmens.
                    .padding = .{
                        .left = scaled(pdf_margin_x, scale),
                        .right = scaled(pdf_margin_x, scale),
                        .top = scaled(pdf_margin_y, scale),
                        .bottom = scaled(pdf_margin_y, scale),
                    },
                    .child_gap = scaled(10, scale),
                },
                .clip = .{ .vertical = true, .horizontal = true },
                .background_color = theme.surface,
                .border = .{ .color = theme.border, .width = .all(1) },
                .corner_radius = .all(theme.radius_sm),
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("md_slide_content"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = scaled(10, scale),
                    },
                })({
                const doc = self.cachedSlideDocument();
                if (doc) |block| {
                    var effective_theme = theme;
                    if (self.text_color) |cc| effective_theme.text = cc;
                    self.run_counter = 0;
                    // Grundschrift wie im Export, skaliert auf den Rahmen. Die
                    // Überschriften-Faktoren in renderBlock (2.0 / 1.5 / 1.2)
                    // sind dieselben wie im Export-CSS.
                    const outer = self.font_size;
                    self.font_size = @max(6, scaled(pdf_content_em, scale));
                    self.wrap_width_hint = @max(0, frame_w - 2 * @as(f32, @floatFromInt(scaled(pdf_margin_x, scale))));
                    self.renderBlock(block, arena, effective_theme, ui_ptr);
                    self.font_size = outer;
                }
                });
            });

            // Blätterleiste: ‹ Folie / Gesamt ›
            clay.UI()(.{
                .id = clay.ElementId.ID("md_slide_bar"),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .child_gap = 16,
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            })({
                self.renderSlideButton("md_slide_prev", "<", self.current_slide > 0, theme);
                var buf: [48]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{d} / {d}", .{ self.current_slide + 1, d.slides.len }) catch "";
                clay.UI()(.{
                    .id = clay.ElementId.ID("md_slide_counter"),
                    .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
                })({
                    clay.text(arena.dupe(u8, label) catch "", .{
                        .font_size = self.font_size,
                        .color = theme.subtext,
                    });
                });
                self.renderSlideButton("md_slide_next", ">", self.current_slide + 1 < d.slides.len, theme);
            });

            if (self.slide_overflow) {
                clay.UI()(.{
                    .id = clay.ElementId.ID("md_slide_overflow"),
                    .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
                })({
                    clay.text("Inhalt passt nicht auf die Folie", .{
                        .font_size = self.font_size - 4,
                        .color = theme.warning,
                    });
                });
            }

            // Die Fußzeile der Folie steht bewusst nicht unter dem Rahmen: sie
            // gehört ins PDF, nicht in die Bedienleiste der Vorschau.
        });

        self.renderContextMenu(theme);
    }

    /// Ränder und Schriftgrößen des Exports (`rendering/marp_pdf.zig`), damit
    /// Vorschau und PDF denselben Umbruch zeigen.
    const pdf_margin_x: f32 = 70;
    const pdf_margin_y: f32 = 78;
    const pdf_content_em: f32 = 26;

    /// Rand um die Folie und Platz für Blätterleiste, Warnung und Fußzeile.
    const root_padding: u16 = 24;
    const chrome_reserve: f32 = 110;

    /// Grundschriftgröße, in der die Folie gezeichnet wird (E2E-Sicht).
    pub fn slideFontSize(self: *const Self) u16 {
        return @max(6, scaled(pdf_content_em, self.slide_scale));
    }

    fn scaled(value: f32, scale: f32) u16 {
        const px = @round(value * scale);
        if (px <= 0) return 0;
        return @intFromFloat(@min(px, 4000));
    }

    fn renderSlideButton(self: *Self, id: []const u8, label: []const u8, enabled: bool, theme: Theme) void {
        _ = self;
        clay.UI()(.{
            .id = clay.ElementId.ID(id),
            .layout = .{
                .sizing = .{ .w = .fixed(36), .h = .fixed(28) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = if (enabled) theme.overlay else theme.bg,
            .corner_radius = .all(theme.radius_sm),
        })({
            clay.text(label, .{
                .font_size = 20,
                .color = if (enabled) theme.text else theme.muted,
            });
        });
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        if (self.deck != null) return self.renderDeck(arena, theme, ui_ptr);

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

        self.renderContextMenu(theme);
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
