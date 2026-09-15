//! Timeline-Abschnitt unten in der Explorer-Sidebar wie in VS Code: Kopfzeile „TIMELINE“ mit
//! Auf-/Zuklappen, Pin und Refresh; Einträge mit Commit-Icon, Betreff, Autor und relativer
//! Zeit; Hover mit Commit-Details; Klick öffnet den Diff-Editor, Rechtsklick das Menü.
//! Logik in `git_timeline.Timeline`, hier nur Zeichnen und Eingaben.

const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const git_timeline = @import("git_timeline");
const git_history = @import("git_history");
const shortcuts = @import("shortcuts");
const ctx_menu = @import("context_menu");
const svg = @import("components/svg.zig");

pub const HEADER_HEIGHT: f32 = 30;
pub const ROW_HEIGHT: f32 = 30;
/// Anteil der Sidebar-Höhe für die aufgeklappte Liste
const BODY_SHARE: f32 = 0.38;
const HOVER_DELAY_MS: f32 = 700;
const TOOLTIP_WIDTH: f32 = 420;

pub const Action = union(enum) {
    none,
    /// Klick lag in der Timeline, sonst nichts zu tun
    consumed,
    /// Eintrag geöffnet (Klick): Diff-Editor zum vorigen Datei-Commit
    open_changes: usize,
    /// Menüeintrag für Eintrag `index`
    command: struct { cmd: shortcuts.Command, index: usize },
    /// Auf-/Zugeklappt: Zustand merken
    toggled,
};

pub const TimelineView = struct {
    timeline: git_timeline.Timeline,
    hover_index: ?usize = null,
    hover_since_ms: f32 = 0,
    now_ms: f32 = 0,
    menu: ?struct { x: f32, y: f32, index: usize } = null,
    /// Relative Zeiten des letzten Frames (für E2E), in der Frame-Arena
    last_labels: []const git_timeline.Label = &.{},

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .timeline = git_timeline.Timeline.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.timeline.deinit();
    }

    pub fn headerId() clay.ElementId {
        return clay.ElementId.ID("tl_header");
    }

    pub fn bodyId() clay.ElementId {
        return clay.ElementId.ID("tl_body");
    }

    fn buttonId(comptime name: []const u8) clay.ElementId {
        return clay.ElementId.ID("tl_btn_" ++ name);
    }

    fn box(id: clay.ElementId) ?clay.BoundingBox {
        const d = clay.getElementData(id);
        return if (d.found) d.bounding_box else null;
    }

    fn inside(b: clay.BoundingBox, x: f32, y: f32) bool {
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    fn rowAt(self: *const Self, x: f32, y: f32) ?usize {
        if (!self.timeline.expanded) return null;
        const b = box(bodyId()) orelse return null;
        if (!inside(b, x, y)) return null;
        const i: usize = @intFromFloat(@max(0, (y - b.y + self.timeline.scroll) / ROW_HEIGHT));
        return if (i < self.timeline.items().len) i else null;
    }

    /// Liegt (x, y) in Kopf oder Liste? Dann gehören Klick und Mausrad der Timeline.
    pub fn contains(self: *const Self, x: f32, y: f32) bool {
        if (box(headerId())) |b| if (inside(b, x, y)) return true;
        if (self.timeline.expanded) if (box(bodyId())) |b| if (inside(b, x, y)) return true;
        return false;
    }

    pub fn update(self: *Self, delta_ms: f32) void {
        self.now_ms += delta_ms;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        const row = self.rowAt(x, y);
        if (row != self.hover_index) {
            self.hover_index = row;
            self.hover_since_ms = self.now_ms;
        }
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, right: bool) Action {
        if (self.menu) |m| {
            self.menu = null;
            if (!right) {
                if (ctx_menu.hit("tl_menu", &shortcuts.timeline_menu_items, ctx_menu.none)) |cmd| return .{ .command = .{ .cmd = cmd, .index = m.index } };
            }
            if (!self.contains(x, y)) return .consumed;
        }
        if (box(buttonId("pin"))) |b| if (inside(b, x, y)) {
            self.timeline.togglePin();
            return .consumed;
        };
        if (box(buttonId("refresh"))) |b| if (inside(b, x, y)) {
            self.timeline.refresh();
            return .consumed;
        };
        if (box(headerId())) |b| if (inside(b, x, y)) {
            if (right) return .consumed;
            self.timeline.setExpanded(!self.timeline.expanded);
            return .toggled;
        };
        if (self.rowAt(x, y)) |i| {
            self.timeline.selected = i;
            self.hover_index = null;
            if (right) {
                self.menu = .{ .x = x, .y = y, .index = i };
                return .consumed;
            }
            return .{ .open_changes = i };
        }
        return if (self.contains(x, y)) .consumed else .none;
    }

    /// Mausrad über der Liste (positiv = hoch).
    pub fn scrollLines(self: *Self, delta: i32) void {
        const vp = if (box(bodyId())) |b| b.height else 0;
        const t = &self.timeline;
        t.scroll = git_history.clampScroll(t.scroll - @as(f32, @floatFromInt(delta * 3)) * ROW_HEIGHT, vp, ROW_HEIGHT, t.items().len);
        self.hover_index = null;
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, mouse_x: f32, mouse_y: f32) void {
        const t = &self.timeline;
        const header_hover = if (box(headerId())) |b| inside(b, mouse_x, mouse_y) else false;
        const body_hover = t.expanded and (if (box(bodyId())) |b| inside(b, mouse_x, mouse_y) else false);

        clay.UI()(.{
            .id = headerId(),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(HEADER_HEIGHT) },
                .direction = .left_to_right,
                .child_alignment = .{ .y = .center },
                .child_gap = 4,
                .padding = .{ .left = 6, .right = 6 },
            },
            .background_color = theme.surface,
            .border = .{ .width = .{ .top = 1, .right = 1 }, .color = theme.border },
        })({
            svg.Svg(arena, "tl_chevron", if (t.expanded) svg.Lucide.chevron_down else svg.Lucide.chevron_right, 16, theme.subtext);
            clay.text("TIMELINE", .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            // Titelaktionen wie VS Code nur beim Überfahren sichtbar
            if (t.expanded and (header_hover or body_hover)) {
                headerButton(arena, theme, "pin", if (t.pinned) svg.Lucide.pin_off else svg.Lucide.pin, t.pinned, mouse_x, mouse_y);
                headerButton(arena, theme, "refresh", svg.Lucide.refresh_cw, false, mouse_x, mouse_y);
            }
        });

        if (!t.expanded) return;

        const now = std.time.timestamp();
        const items = t.items();
        const labels = git_timeline.relativeLabels(arena, items, now) catch &.{};
        self.last_labels = labels;
        const vp = if (box(bodyId())) |b| b.height else 0;
        t.scroll = git_history.clampScroll(t.scroll, vp, ROW_HEIGHT, items.len);
        const range = git_history.visibleRange(t.scroll, if (vp > 0) vp else 400, ROW_HEIGHT, items.len, 5);

        clay.UI()(.{
            .id = bodyId(),
            .layout = .{ .sizing = .{ .w = .grow, .h = .percent(BODY_SHARE) }, .direction = .top_to_bottom },
            .background_color = theme.surface,
            .border = .{ .width = .{ .right = 1 }, .color = theme.border },
            .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -t.scroll } },
        })({
            var msg_buf: [300]u8 = undefined;
            if (t.message(&msg_buf)) |msg| {
                // Wie VS Code: gedämpfter Hinweis mit Einzug
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow }, .padding = .{ .left = 22, .right = 12, .top = 10 } } })({
                    clay.text(msg, .{ .font_size = 16, .color = theme.muted, .wrap_mode = .words });
                });
            } else {
                spacer(@as(f32, @floatFromInt(range.first)) * ROW_HEIGHT);
                for (range.first..range.end) |i| self.renderRow(arena, theme, width, i, labels);
                spacer(@as(f32, @floatFromInt(items.len - range.end)) * ROW_HEIGHT);
            }
        });

        if (self.menu) |m| {
            _ = ctx_menu.render("tl_menu", &shortcuts.timeline_menu_items, m.x, m.y, ctx_menu.none, ctx_menu.Colors.fromTheme(theme));
        }
    }

    fn renderRow(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, i: usize, labels: []const git_timeline.Label) void {
        const t = &self.timeline;
        const it = t.items()[i];
        const selected = t.selected == i;
        const hovered = self.hover_index == i and self.menu == null;
        const time = if (i < labels.len and !labels[i].hidden) labels[i].text else "";
        const fg = if (selected) theme.text_on_primary else theme.text;
        const dim = if (selected) theme.text_on_primary else theme.muted;

        // Budget: Betreff zuerst, Autor im Rest, Zeit rechts fest (VS Code: Label + Beschreibung mit Ellipse)
        const time_w = ui.measureTextWidth(time, 15);
        const room = width - 8 - 16 - 6 - 6 - time_w - 12 - 8;
        const label = fitText(arena, it.label, room, 18);
        const label_w = ui.measureTextWidth(label, 18);
        const author = fitText(arena, it.author, room - label_w - 8, 15);

        const row_id = clay.ElementId.IDI("tl_row", @intCast(i));
        clay.UI()(.{
            .id = row_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) },
                .direction = .left_to_right,
                .child_alignment = .{ .y = .center },
                .child_gap = 6,
                .padding = .{ .left = 8, .right = 8 },
            },
            .background_color = if (selected) theme.primary else if (hovered) tint(theme.text, 20) else .{ 0, 0, 0, 0 },
        })({
            svg.Svg(arena, std.fmt.allocPrint(arena, "tl_icon_{d}", .{i}) catch "tl_icon", svg.Lucide.git_commit_horizontal, 16, dim);
            clay.text(label, .{ .font_size = 18, .color = fg, .wrap_mode = .none });
            if (author.len > 0 and room - label_w > 30) clay.text(author, .{ .font_size = 15, .color = dim, .wrap_mode = .none });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            clay.text(time, .{ .font_size = 15, .color = dim, .wrap_mode = .none });
        });

        if (hovered and self.now_ms - self.hover_since_ms > HOVER_DELAY_MS) self.renderHover(arena, theme, row_id, i, it);
    }

    /// Hover wie VS Code `getCommitHover`: Autor und Zeit, Nachricht, Trenner, Statistik, Hash.
    /// Die Timeline sitzt unten im Fenster: Einträge in der unteren Hälfte der Liste bekommen den
    /// Hover nach oben wachsend, sonst läge er unter dem Fensterrand.
    fn renderHover(self: *Self, arena: std.mem.Allocator, theme: Theme, row_id: clay.ElementId, index: usize, it: git_timeline.Item) void {
        const h = git_timeline.hoverText(arena, it, std.time.timestamp()) catch return;
        const upward = blk: {
            const b = box(bodyId()) orelse break :blk false;
            const sidebar = box(clay.ElementId.ID("sidebar")) orelse break :blk false;
            const row_center = b.y + @as(f32, @floatFromInt(index)) * ROW_HEIGHT - self.timeline.scroll + ROW_HEIGHT / 2;
            break :blk row_center > sidebar.y + sidebar.height / 2;
        };
        clay.UI()(.{
            .id = clay.ElementId.ID("tl_hover"),
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = row_id.id,
                .attach_points = if (upward) .{ .element = .left_bottom, .parent = .right_bottom } else .{ .element = .left_top, .parent = .right_top },
                .offset = .{ .x = 6, .y = 0 },
                .z_index = 1500,
            },
            .layout = .{ .sizing = .{ .w = .fixed(TOOLTIP_WIDTH) }, .direction = .top_to_bottom, .padding = .all(10), .child_gap = 8 },
            .background_color = theme.overlay,
            .border = .{ .width = .all(1), .color = theme.border },
            .corner_radius = .all(4),
        })({
            clay.text(h.header, .{ .font_size = 16, .color = theme.text, .wrap_mode = .words });
            clay.text(h.message, .{ .font_size = 16, .color = theme.text, .wrap_mode = .words });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(1) } }, .background_color = theme.border })({});
            clay.UI()(.{ .layout = .{ .direction = .left_to_right } })({
                // Einfügungen grün, Löschungen rot wie scmGraph.historyItemHoverAdditions/Deletions
                const files_end = std.mem.indexOf(u8, h.stats, " changed").? + " changed".len;
                clay.text(h.stats[0..files_end], .{ .font_size = 15, .color = theme.subtext, .wrap_mode = .none });
                const rest = h.stats[files_end..];
                const del = std.mem.indexOf(u8, rest, "deletion");
                const split = if (del) |d| (std.mem.lastIndexOf(u8, rest[0..d], ", ") orelse 0) else rest.len;
                if (split > 0) clay.text(rest[0..split], .{ .font_size = 15, .color = theme.success, .wrap_mode = .none });
                if (split < rest.len) clay.text(rest[split..], .{ .font_size = 15, .color = theme.danger, .wrap_mode = .none });
            });
            clay.text(it.hash[0..@min(it.hash.len, 7)], .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
        });
    }
};

fn headerButton(arena: std.mem.Allocator, theme: Theme, comptime name: []const u8, icon: []const u8, toggled: bool, mouse_x: f32, mouse_y: f32) void {
    const id = TimelineView.buttonId(name);
    const hovered = if (TimelineView.box(id)) |b| TimelineView.inside(b, mouse_x, mouse_y) else false;
    clay.UI()(.{
        .id = id,
        .layout = .{ .sizing = .{ .w = .fixed(24), .h = .fixed(24) }, .child_alignment = .{ .x = .center, .y = .center } },
        .background_color = if (hovered) tint(theme.text, 30) else if (toggled) tint(theme.primary, 50) else .{ 0, 0, 0, 0 },
        .corner_radius = .all(4),
    })({
        svg.Svg(arena, "tl_icon_btn_" ++ name, icon, 16, theme.text);
    });
}

fn tint(c: clay.Color, alpha: f32) clay.Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn spacer(height: f32) void {
    if (height <= 0) return;
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(height) } } })({});
}

/// Text auf `max_width` Pixel kürzen (Monospace: Zeichenbudget aus der Breite von "W"), mit „…“.
fn fitText(arena: std.mem.Allocator, text: []const u8, max_width: f32, font: u16) []const u8 {
    const size: f32 = @floatFromInt(font);
    if (max_width <= 0) return "";
    if (ui.measureTextWidth(text, size) <= max_width) return text;
    const char_w = ui.measureTextWidth("W", size);
    if (char_w <= 0 or max_width <= 2 * char_w) return "";
    const budget: usize = @intFromFloat(max_width / char_w - 1);
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    while (n < budget) : (n += 1) {
        if (it.nextCodepointSlice() == null) return text;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{text[0..it.i]}) catch text;
}
