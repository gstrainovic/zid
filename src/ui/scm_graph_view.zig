//! Source Control Graph in der Sidebar wie VS Code (Ctrl+Shift+G): Kopf „SOURCE CONTROL GRAPH“
//! mit Filter „Auto“ und Refresh, Commit-Zeilen mit Graph, Betreff, Autor und Referenz-Badges,
//! aufklappbare Dateien, Hover mit Details, Inline-Aktion und Kontextmenü „Open Changes“,
//! automatisches Nachladen am Listenende (scm.graph.pageOnScroll).
//! Daten in `git_scm.View`, Geometrie in `git_graph`.

const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const git_scm = @import("git_scm");
const git_graph = @import("git_graph");
const git_timeline = @import("git_timeline");
const git_list = @import("git_list");
const shortcuts = @import("shortcuts");
const ctx_menu = @import("context_menu");
const svg = @import("components/svg.zig");
const tooltip = @import("components/tooltip.zig");
const git_commit_view = @import("git_commit_view.zig");

pub const HEADER_HEIGHT: f32 = 30;
pub const ROW_HEIGHT: f32 = 30;
const HOVER_DELAY_MS: f32 = 700;
const TOOLTIP_WIDTH: f32 = 440;
/// VS Code zeichnet 22 px hohe Zeilen; zid-Zeilen sind höher, der Graph wird skaliert
const SCALE: f32 = ROW_HEIGHT / git_graph.SWIMLANE_HEIGHT;

pub const Action = union(enum) {
    none,
    consumed,
    open_diff: git_scm.ViewRow,
    open_commit: usize,
    command: struct { cmd: shortcuts.Command, commit: usize },
};

pub const ScmGraphView = struct {
    view: git_scm.View,
    /// Zählt Refreshes: Ergebnisse älterer Anfragen werden verworfen
    generation: u32 = 0,
    hover_row: ?usize = null,
    hover_since_ms: f32 = 0,
    now_ms: f32 = 0,
    menu: ?struct { x: f32, y: f32, commit: usize } = null,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .view = git_scm.View.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.view.deinit();
    }

    pub fn refresh(self: *Self) void {
        self.generation +%= 1;
        self.view.refresh();
        self.menu = null;
        self.hover_row = null;
    }

    pub fn headerId() clay.ElementId {
        return clay.ElementId.ID("sg_header");
    }

    pub fn bodyId() clay.ElementId {
        return clay.ElementId.ID("sg_body");
    }

    fn box(id: clay.ElementId) ?clay.BoundingBox {
        const d = clay.getElementData(id);
        return if (d.found) d.bounding_box else null;
    }

    fn inside(b: clay.BoundingBox, x: f32, y: f32) bool {
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    fn rowAt(self: *const Self, x: f32, y: f32) ?usize {
        const b = box(bodyId()) orelse return null;
        if (!inside(b, x, y)) return null;
        const i: usize = @intFromFloat(@max(0, (y - b.y + self.view.scroll) / ROW_HEIGHT));
        return if (i < self.view.rows.items.len) i else null;
    }

    pub fn update(self: *Self, delta_ms: f32) void {
        self.now_ms += delta_ms;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        const row = self.rowAt(x, y);
        if (row != self.hover_row) {
            self.hover_row = row;
            self.hover_since_ms = self.now_ms;
        }
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        const vp = if (box(bodyId())) |b| b.height else 0;
        const v = &self.view;
        v.scroll = git_list.clampScroll(v.scroll - @as(f32, @floatFromInt(delta * 3)) * ROW_HEIGHT, vp, ROW_HEIGHT, v.rows.items.len);
        self.hover_row = null;
    }

    pub const Key = enum { up, down, page_up, page_down, home, end, enter, left, right, reload };

    /// Tastatur mit Fokus in der Sidebar: Pfeile/Bild/Pos1/Ende wählen Zeilen, Enter klappt
    /// Commits auf bzw. öffnet die Datei, ←/→ klappen zu/auf, F5 lädt neu.
    pub fn handleKey(self: *Self, key: Key) Action {
        const v = &self.view;
        const vp = if (box(bodyId())) |b| b.height else 0;
        const page: isize = @max(1, @as(isize, @intFromFloat(vp / ROW_HEIGHT)) - 1);
        const count: isize = @intCast(v.rows.items.len);
        var action: Action = .consumed;
        switch (key) {
            .up => _ = v.moveSelection(-1),
            .down => _ = v.moveSelection(1),
            .page_up => _ = v.moveSelection(-page),
            .page_down => _ = v.moveSelection(page),
            .home => _ = v.moveSelection(-count),
            .end => _ = v.moveSelection(count),
            .left => _ = v.collapseSelected(),
            .right => v.expandSelected(),
            .enter => switch (v.activateSelected()) {
                .open_diff => |row| action = .{ .open_diff = row },
                else => {},
            },
            .reload => self.refresh(),
        }
        self.hover_row = null;
        self.menu = null;
        if (v.selected) |i| if (vp > 0) {
            v.scroll = git_list.clampScroll(git_list.scrollToShow(v.scroll, vp, ROW_HEIGHT, i), vp, ROW_HEIGHT, v.rows.items.len);
        };
        return action;
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, right: bool) Action {
        if (self.menu) |m| {
            self.menu = null;
            if (!right) {
                if (ctx_menu.hit("sg_menu", &shortcuts.graph_menu_items, ctx_menu.none)) |cmd| return .{ .command = .{ .cmd = cmd, .commit = m.commit } };
            }
            return .consumed;
        }
        if (box(clay.ElementId.ID("sg_btn_refresh"))) |b| if (inside(b, x, y)) {
            self.refresh();
            return .consumed;
        };
        const i = self.rowAt(x, y) orelse return .none;
        const row = self.view.rows.items[i];
        self.view.selected = i;
        switch (row.kind) {
            .commit => {
                if (right) {
                    self.menu = .{ .x = x, .y = y, .commit = row.commit };
                    return .consumed;
                }
                // Inline-Aktion „Open Changes“ rechts in der überfahrenen Zeile
                if (box(clay.ElementId.IDI("sg_open_changes", @intCast(i)))) |b| if (self.hover_row == i and inside(b, x, y)) return .{ .open_commit = row.commit };
                self.view.toggleExpanded(row.commit);
                return .consumed;
            },
            .change => return if (right) .consumed else .{ .open_diff = row },
            .load_more => return .consumed,
        }
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, mouse_x: f32, mouse_y: f32) void {
        const v = &self.view;
        const header_hover = if (box(clay.ElementId.ID("sg_section"))) |b| inside(b, mouse_x, mouse_y) else false;
        clay.UI()(.{
            .id = clay.ElementId.ID("sg_section"),
            .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
            .background_color = theme.surface,
            .border = .{ .width = .{ .right = 1 }, .color = theme.border },
        })({
            clay.UI()(.{
                .id = headerId(),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(HEADER_HEIGHT) }, .direction = .left_to_right, .child_alignment = .{ .y = .center }, .child_gap = 6, .padding = .{ .left = 8, .right = 6 } },
            })({
                svg.Svg(arena, "sg_chevron", svg.Lucide.chevron_down, 16, theme.subtext);
                // Titel kürzen: Text ohne Umbruch ist eine Mindestbreite und schöbe die
                // Aktionen aus der Sidebar heraus (Skill clay-layout)
                const actions_w: f32 = if (header_hover) 24 + 14 + ui.measureTextWidth("Auto", 14) + 18 else 0;
                clay.text(fitText(arena, "SOURCE CONTROL GRAPH", width - 16 - actions_w - 26, 14), .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                if (header_hover) {
                    // Filter „Auto“ (VS Code History Item Ref Picker) und Refresh
                    svg.SvgStroke(arena, "sg_icon_branch", svg.Lucide.git_branch, 14, theme.subtext);
                    clay.text("Auto", .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
                    tooltip.iconButton(arena, theme, clay.ElementId.ID("sg_btn_refresh"), "sg_icon_refresh", svg.Lucide.refresh_cw, "Refresh", .{});
                }
            });

            const vp = if (box(bodyId())) |b| b.height else 0;
            const count = v.rows.items.len;
            v.scroll = git_list.clampScroll(v.scroll, vp, ROW_HEIGHT, count);
            const range = git_list.visibleRange(v.scroll, if (vp > 0) vp else 600, ROW_HEIGHT, count, 5);
            clay.UI()(.{
                .id = bodyId(),
                .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
                .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -v.scroll } },
            })({
                if (v.error_text) |e| {
                    message(std.fmt.allocPrint(arena, "git: {s}", .{e}) catch "git failed", theme);
                } else if (count == 0) {
                    message(if (v.loading or v.want_log != null) "Loading..." else "No history information was provided.", theme);
                } else {
                    spacer(@as(f32, @floatFromInt(range.first)) * ROW_HEIGHT);
                    for (range.first..range.end) |i| self.renderRow(arena, theme, width, i, mouse_x, mouse_y);
                    spacer(@as(f32, @floatFromInt(count - range.end)) * ROW_HEIGHT);
                }
            });
        });

        if (self.menu) |m| {
            _ = ctx_menu.render("sg_menu", &shortcuts.graph_menu_items, m.x, m.y, ctx_menu.none, ctx_menu.Colors.fromTheme(theme));
        }
    }

    fn renderRow(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, i: usize, mouse_x: f32, mouse_y: f32) void {
        _ = mouse_x;
        _ = mouse_y;
        const v = &self.view;
        const row = v.rows.items[i];
        const selected = v.selected == i;
        const hovered = self.hover_row == i and self.menu == null;
        const bg: clay.Color = if (selected) theme.primary else if (hovered) mix(theme.surface, theme.text, 0.08) else theme.surface;
        const fg = if (selected) theme.text_on_primary else theme.text;
        const dim = if (selected) theme.text_on_primary else theme.muted;
        const graph_rows = if (v.graph) |g| g.rows else &.{};

        clay.UI()(.{
            .id = clay.ElementId.IDI("sg_row", @intCast(i)),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) }, .direction = .left_to_right, .child_alignment = .{ .y = .center }, .child_gap = 6, .padding = .{ .right = 6 } },
            .background_color = bg,
        })({
            switch (row.kind) {
                .commit => {
                    const c = v.commits()[row.commit];
                    const gc = git_graph.Commit{ .id = c.hash, .parents = c.parents, .label_color = c.label_color };
                    const grow = graph_rows[row.commit];
                    const gw = git_graph.width(grow) * SCALE;
                    graphCell(arena, theme, i, gc, grow, gw, bg);
                    const badges_w = badgesWidth(c, v.filter);
                    const room = width - gw - 6 - badges_w - 12 - (if (hovered) @as(f32, 30) else 0);
                    const label = fitText(arena, c.subject, room, 17);
                    clay.text(label, .{ .font_size = 17, .color = fg, .wrap_mode = .none });
                    const author = fitText(arena, c.author, room - ui.measureTextWidth(label, 17) - 6, 14);
                    if (author.len > 0) clay.text(author, .{ .font_size = 14, .color = dim, .wrap_mode = .none });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                    renderBadges(arena, theme, i, c, v.filter);
                    if (hovered) {
                        const oc_id = clay.ElementId.IDI("sg_open_changes", @intCast(i));
                        clay.UI()(.{ .id = oc_id, .layout = .{ .sizing = .{ .w = .fixed(24), .h = .fixed(24) }, .child_alignment = .{ .x = .center, .y = .center } } })({
                            svg.SvgStroke(arena, std.fmt.allocPrint(arena, "sg_icon_changes_{d}", .{i}) catch "sg_icon_changes", svg.Lucide.git_compare, 16, fg);
                            tooltip.attach(theme, oc_id, "Open Changes");
                        });
                    }
                    if (hovered and self.now_ms - self.hover_since_ms > HOVER_DELAY_MS) renderHover(arena, theme, i, c, v.filter);
                },
                // Kein `return` im Kinderblock (Skill clay-layout)
                .change => if (v.changeOf(row)) |change| {
                    const grow = graph_rows[row.commit];
                    placeholderCell(theme, grow.output, git_graph.circleIndex(.{ .id = v.commits()[row.commit].hash, .parents = &.{} }, grow));
                    const name = std.fs.path.basename(change.path);
                    const dir = std.fs.path.dirname(change.path) orelse "";
                    clay.text(name, .{ .font_size = 16, .color = fg, .wrap_mode = .none });
                    const dir_room = width - git_graph.placeholderWidth(grow.output.len) * SCALE - ui.measureTextWidth(name, 16) - 40;
                    if (dir.len > 0) clay.text(fitText(arena, dir, dir_room, 14), .{ .font_size = 14, .color = dim, .wrap_mode = .none });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                    var letter: [1]u8 = .{change.status.letter()};
                    clay.text(arena.dupe(u8, &letter) catch "", .{ .font_size = 15, .color = if (selected) fg else git_commit_view.statusColor(theme, change.status), .wrap_mode = .none });
                },
                .load_more => {
                    if (graph_rows.len > 0) placeholderCell(theme, graph_rows[graph_rows.len - 1].output, null);
                    clay.text("Loading...", .{ .font_size = 15, .color = dim, .wrap_mode = .none });
                    // scm.graph.pageOnScroll: am Listenende automatisch nachladen
                    _ = v.loadMore();
                },
            }
        });
    }
};

/// Graph-Zelle einer Commit-Zeile: Linien als Rechtecke, Bögen und Kreise als SVG (je Form ein Bild,
/// damit der Even-Odd-Füller keine Löcher schneidet und der Atlas sie wiederverwendet).
fn graphCell(arena: std.mem.Allocator, theme: Theme, row_index: usize, c: git_graph.Commit, row: git_graph.Row, gw: f32, bg: clay.Color) void {
    const shapes = git_graph.shapes(arena, c, row) catch &.{};
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(gw), .h = .fixed(ROW_HEIGHT) } } })({
        for (shapes, 0..) |shape, k| {
            switch (shape) {
                .vline => |l| rect(l.x * SCALE - lineWidth() / 2, l.y0 * SCALE, lineWidth(), (l.y1 - l.y0) * SCALE, laneColor(theme, l.color)),
                .hline => |l| rect(l.x0 * SCALE, l.y * SCALE - lineWidth() / 2, (l.x1 - l.x0) * SCALE, lineWidth(), laneColor(theme, l.color)),
                .arc => |a| {
                    var buf: [256]u8 = undefined;
                    const sw: f32 = lineWidth() / SCALE;
                    const path = arena.dupe(u8, git_graph.arcPath(&buf, a.r, sw, a.quadrant)) catch continue;
                    const outer = a.r + sw / 2;
                    const ox: f32 = switch (a.quadrant) {
                        .bottom_right, .top_right => a.cx,
                        .bottom_left, .top_left => a.cx - outer,
                    };
                    const oy: f32 = switch (a.quadrant) {
                        .bottom_right, .bottom_left => a.cy,
                        .top_right, .top_left => a.cy - outer,
                    };
                    image(arena, row_index, k, path, outer, ox * SCALE, oy * SCALE, outer * SCALE, laneColor(theme, a.color));
                },
                .disc => |d| {
                    var buf: [128]u8 = undefined;
                    const path = arena.dupe(u8, git_graph.discPath(&buf, d.r)) catch continue;
                    const color = switch (d.fill) {
                        .lane => |col| laneColor(theme, col),
                        .background => bg,
                    };
                    image(arena, row_index, k, path, 2 * d.r, (d.cx - d.r) * SCALE, (d.cy - d.r) * SCALE, 2 * d.r * SCALE, color);
                },
            }
        }
    });
}

/// Dateizeile unter einem Commit: senkrechte Bahnen, die Bahn des Commits dicker (VS Code Breite 3).
fn placeholderCell(theme: Theme, lanes: []const git_graph.Lane, highlight: ?usize) void {
    const gw = git_graph.placeholderWidth(lanes.len) * SCALE;
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(gw), .h = .fixed(ROW_HEIGHT) } } })({
        for (lanes, 0..) |lane, k| {
            const w: f32 = if (highlight == k) 3 * lineWidth() else lineWidth();
            const x = git_graph.SWIMLANE_WIDTH * @as(f32, @floatFromInt(k + 1)) * SCALE;
            rect(x - w / 2, 0, w, ROW_HEIGHT, laneColor(theme, lane.color));
        }
    });
}

fn lineWidth() f32 {
    return @max(1, @round(SCALE));
}

fn rect(x: f32, y: f32, w: f32, h: f32, color: clay.Color) void {
    if (w <= 0 or h <= 0) return;
    clay.UI()(.{
        .floating = .{ .attach_to = .to_parent, .offset = .{ .x = x, .y = y }, .clip_to = .to_attached_parent, .pointer_capture_mode = .passthrough },
        .layout = .{ .sizing = .{ .w = .fixed(w), .h = .fixed(h) } },
        .background_color = color,
    })({});
}

fn image(arena: std.mem.Allocator, row_index: usize, k: usize, path: []const u8, viewbox: f32, x: f32, y: f32, size: f32, color: clay.Color) void {
    const info = arena.create(@import("../svg/mod.zig").SvgRenderInfo) catch return;
    info.* = .{ .path_data = path, .viewbox = viewbox, .color = color };
    clay.UI()(.{
        .id = clay.ElementId.IDI("sg_shape", @intCast(row_index * 64 + k)),
        .floating = .{ .attach_to = .to_parent, .offset = .{ .x = x, .y = y }, .clip_to = .to_attached_parent, .pointer_capture_mode = .passthrough },
        .layout = .{ .sizing = .{ .w = .fixed(size), .h = .fixed(size) } },
        .image = .{ .image_data = info },
    })({});
}

/// Farben aus VS Code scmHistory.ts: scmGraph.foreground1..5, Referenzfarben (charts.blue,
/// charts.purple, #EA5C00).
pub fn laneColor(theme: Theme, color: git_graph.Color) clay.Color {
    const light = theme.bg[0] > 128;
    return switch (color) {
        .palette => |i| switch (i % git_graph.palette_len) {
            0 => .{ 0xFF, 0xB0, 0x00, 255 },
            1 => .{ 0xDC, 0x26, 0x7F, 255 },
            2 => .{ 0x99, 0x4F, 0x00, 255 },
            3 => .{ 0x40, 0xB0, 0xA6, 255 },
            else => .{ 0xB6, 0x6D, 0xFF, 255 },
        },
        .ref_current => if (light) .{ 0x1a, 0x85, 0xff, 255 } else .{ 0x37, 0x94, 0xFF, 255 },
        .ref_remote => if (light) .{ 0x65, 0x2D, 0x90, 255 } else .{ 0xB1, 0x80, 0xD7, 255 },
        .ref_base => .{ 0xEA, 0x5C, 0x00, 255 },
    };
}

fn refIcon(kind: git_scm.RefKind) []const u8 {
    return switch (kind) {
        .head => svg.Lucide.target,
        .branch => svg.Lucide.git_branch,
        .remote => svg.Lucide.cloud,
        .tag => svg.Lucide.tag,
    };
}

fn badgesWidth(c: git_scm.Commit, filter: git_scm.AutoFilter) f32 {
    var w: f32 = 0;
    var first = true;
    for (c.refs) |r| {
        if (filter.colorOf(r.id) == null) continue;
        w += if (first) ui.measureTextWidth(r.name, 13) + 36 else 26;
        first = false;
    }
    return w;
}

/// Badges wie VS Code (scm.graph.badges = filter): nur Referenzen aus dem Filter, die erste mit Namen.
fn renderBadges(arena: std.mem.Allocator, theme: Theme, row_index: usize, c: git_scm.Commit, filter: git_scm.AutoFilter) void {
    var first = true;
    for (c.refs, 0..) |r, k| {
        const color = filter.colorOf(r.id) orelse continue;
        const bg = laneColor(theme, color);
        clay.UI()(.{
            .layout = .{ .sizing = .{ .h = .fixed(20) }, .direction = .left_to_right, .child_alignment = .{ .y = .center }, .child_gap = 4, .padding = .{ .left = 5, .right = 6 } },
            .background_color = bg,
            .corner_radius = .all(10),
        })({
            svg.Svg(arena, std.fmt.allocPrint(arena, "sg_badge_{d}_{d}", .{ row_index, k }) catch "sg_badge", refIcon(r.kind), 13, theme.surface);
            if (first) clay.text(r.name, .{ .font_size = 13, .color = theme.surface, .wrap_mode = .none });
        });
        first = false;
    }
}

fn renderHover(arena: std.mem.Allocator, theme: Theme, row_index: usize, c: git_scm.Commit, filter: git_scm.AutoFilter) void {
    // Gleicher Aufbau wie der Timeline-Hover (VS Code getHistoryItemHover)
    const item = git_timeline.Item{ .hash = c.hash, .timestamp = c.timestamp, .author = c.author, .message = c.message, .stat = .{ .files = c.stat.files, .insertions = c.stat.insertions, .deletions = c.stat.deletions } };
    const h = git_timeline.hoverText(arena, item, std.time.timestamp()) catch return;
    const upward = blk: {
        const b = GBox.of(clay.ElementId.IDI("sg_row", @intCast(row_index))) orelse break :blk false;
        const sidebar = GBox.of(clay.ElementId.ID("sidebar")) orelse break :blk false;
        break :blk b.y + ROW_HEIGHT / 2 > sidebar.y + sidebar.height / 2;
    };
    clay.UI()(.{
        .id = clay.ElementId.ID("sg_hover"),
        .floating = .{
            .attach_to = .to_element_with_id,
            .parentId = clay.ElementId.IDI("sg_row", @intCast(row_index)).id,
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
        clay.text(h.stats, .{ .font_size = 15, .color = theme.subtext, .wrap_mode = .words });
        clay.UI()(.{ .layout = .{ .direction = .left_to_right, .child_gap = 6 } })({
            for (c.refs, 0..) |r, k| {
                const color = filter.colorOf(r.id);
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .h = .fixed(20) }, .direction = .left_to_right, .child_alignment = .{ .y = .center }, .child_gap = 4, .padding = .{ .left = 5, .right = 6 } },
                    .background_color = if (color) |col| laneColor(theme, col) else theme.surface,
                    .corner_radius = .all(10),
                })({
                    const fg = if (color != null) theme.surface else theme.text;
                    svg.Svg(arena, std.fmt.allocPrint(arena, "sg_hover_ref_{d}", .{k}) catch "sg_hover_ref", refIcon(r.kind), 13, fg);
                    clay.text(r.name, .{ .font_size = 13, .color = fg, .wrap_mode = .none });
                });
            }
        });
        clay.text(c.hash[0..@min(c.hash.len, 7)], .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
    });
}

const GBox = struct {
    fn of(id: clay.ElementId) ?clay.BoundingBox {
        const d = clay.getElementData(id);
        return if (d.found) d.bounding_box else null;
    }
};

fn mix(a: clay.Color, b: clay.Color, t: f32) clay.Color {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, 255 };
}

fn tint(c: clay.Color, alpha: f32) clay.Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn spacer(height: f32) void {
    if (height <= 0) return;
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(height) } } })({});
}

fn message(text: []const u8, theme: Theme) void {
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow }, .padding = .{ .left = 22, .right = 12, .top = 10 } } })({
        clay.text(text, .{ .font_size = 16, .color = theme.muted, .wrap_mode = .words });
    });
}

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
