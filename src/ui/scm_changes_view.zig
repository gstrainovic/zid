//! Source Control „Changes“ in der Sidebar wie VS Code (scmViewPane.ts, scm.css): Kopf
//! „SOURCE CONTROL“ mit Commit und Refresh, einzeiliges Eingabefeld mit Platzhalter, Commit-
//! Knopf, Gruppen „Merge Changes“/„Staged Changes“/„Changes“ mit Badge und Aktionen beim
//! Überfahren, Zeilen mit Name, gedimmtem Ordner und farbigem Status-Buchstaben (gelöscht
//! durchgestrichen). Daten und Logik in `git_changes.View`, hier nur Zeichnen und Eingaben.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const git_changes = @import("git_changes");
const git_list = @import("git_list");
const line_edit = @import("line_edit.zig");
const explorer_ops = @import("explorer_ops.zig");
const svg = @import("components/svg.zig");

pub const HEADER_HEIGHT: f32 = 30;
pub const ROW_HEIGHT: f32 = 26;
pub const INPUT_HEIGHT: f32 = 36;
const BUTTON_HEIGHT: f32 = 28;
const ACTION_SIZE: f32 = 22;
const NAME_FONT: u16 = 16;
const DIM_FONT: u16 = 13;
/// Anteil der Sidebar-Höhe, den die Liste höchstens einnimmt (Rest: Graph)
const BODY_SHARE: f32 = 0.45;
const BODY_MIN: f32 = 80;

pub const MessageEdit = explorer_ops.EditBuffer(2048);
pub const input_field: line_edit.Config = .{ .id = "sc_input_text", .font_size = 16 };

/// Aktionen beim Überfahren, in der Reihenfolge von VS Code package.json (inline@1 openFile,
/// inline@2 stage/unstage/clean). Gruppenköpfe: Staged = unstage all; Changes = stage all, discard all.
pub const RowAction = enum { open_file, stage, unstage, discard, stage_all, unstage_all, discard_all };

pub const Action = union(enum) {
    none,
    consumed,
    /// Klick ins Eingabefeld
    focus_input,
    open_diff: git_changes.Row,
    open_file: git_changes.Row,
    stage: git_changes.Row,
    unstage: git_changes.Row,
    discard: git_changes.Row,
    stage_all,
    unstage_all,
    discard_all,
    commit,
    refresh,
};

pub const ScmChangesView = struct {
    view: git_changes.View,
    message: MessageEdit = .{},
    hover_row: ?usize = null,
    /// Hinweis unter dem Feld (VS Code inputValidation), z. B. bei leerer Nachricht
    validation: ?[]const u8 = null,
    /// Commit läuft: Knopf und Kopf-Aktion gesperrt
    busy: bool = false,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .view = git_changes.View.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.view.deinit();
    }

    pub fn headerId() clay.ElementId {
        return clay.ElementId.ID("sc_header");
    }

    pub fn bodyId() clay.ElementId {
        return clay.ElementId.ID("sc_body");
    }

    pub fn inputId() clay.ElementId {
        return clay.ElementId.ID("sc_input_box");
    }

    pub fn sectionId() clay.ElementId {
        return clay.ElementId.ID("sc_section");
    }

    fn actionId(row: usize, k: RowAction) clay.ElementId {
        return clay.ElementId.IDI("sc_act", @intCast(row * 8 + @intFromEnum(k)));
    }

    fn box(id: clay.ElementId) ?clay.BoundingBox {
        const d = clay.getElementData(id);
        return if (d.found) d.bounding_box else null;
    }

    fn inside(b: clay.BoundingBox, x: f32, y: f32) bool {
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    /// Liegt (x, y) im Changes-Bereich (Kopf bis Liste)?
    pub fn contains(self: *const Self, x: f32, y: f32) bool {
        _ = self;
        if (box(sectionId())) |b| return inside(b, x, y);
        return false;
    }

    pub fn inBody(self: *const Self, x: f32, y: f32) bool {
        _ = self;
        if (box(bodyId())) |b| return inside(b, x, y);
        return false;
    }

    fn rowAt(self: *const Self, x: f32, y: f32) ?usize {
        const b = box(bodyId()) orelse return null;
        if (!inside(b, x, y)) return null;
        const i: usize = @intFromFloat(@max(0, (y - b.y + self.view.scroll) / ROW_HEIGHT));
        return if (i < self.view.rows.items.len) i else null;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        self.hover_row = self.rowAt(x, y);
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        const vp = if (box(bodyId())) |b| b.height else 0;
        const v = &self.view;
        v.scroll = git_list.clampScroll(v.scroll - @as(f32, @floatFromInt(delta * 3)) * ROW_HEIGHT, vp, ROW_HEIGHT, v.rows.items.len);
    }

    /// Aktionen, die eine Zeile beim Überfahren zeigt (VS Code package.json `scm/resourceState/context`).
    fn rowActions(self: *const Self, row: git_changes.Row) []const RowAction {
        _ = self;
        return switch (row.kind) {
            .group => switch (row.group) {
                .staged => &.{.unstage_all},
                .changes => &.{ .stage_all, .discard_all },
                .merge => &.{.stage_all},
            },
            .entry => switch (row.group) {
                .staged => &.{ .open_file, .unstage },
                .changes, .merge => &.{ .open_file, .discard, .stage },
            },
        };
    }

    fn actionIcon(k: RowAction) []const u8 {
        return switch (k) {
            .open_file => svg.Lucide.file,
            .stage, .stage_all => svg.Lucide.plus,
            .unstage, .unstage_all => svg.Lucide.minus,
            .discard, .discard_all => svg.Lucide.undo_2,
        };
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, right: bool) Action {
        if (!self.contains(x, y)) return .none;
        if (right) return .consumed;
        if (box(clay.ElementId.ID("sc_btn_refresh"))) |b| if (inside(b, x, y)) return .refresh;
        if (box(clay.ElementId.ID("sc_btn_commit"))) |b| if (inside(b, x, y)) return .commit;
        if (box(clay.ElementId.ID("sc_btn_commit_big"))) |b| if (inside(b, x, y)) return .commit;
        if (box(inputId())) |b| if (inside(b, x, y)) {
            if (!line_edit.handleClick(&self.message, input_field, x)) self.message.moveEnd();
            return .focus_input;
        };
        const i = self.rowAt(x, y) orelse return .consumed;
        const row = self.view.rows.items[i];
        // Aktionen beim Überfahren: nur in der überfahrenen Zeile gezeichnet
        if (self.hover_row == i) for (self.rowActions(row)) |k| {
            if (box(actionId(i, k))) |b| if (inside(b, x, y)) {
                return switch (k) {
                    .open_file => .{ .open_file = row },
                    .stage => .{ .stage = row },
                    .unstage => .{ .unstage = row },
                    .discard => .{ .discard = row },
                    .stage_all => .stage_all,
                    .unstage_all => .unstage_all,
                    .discard_all => .discard_all,
                };
            };
        };
        self.view.selected = i;
        return switch (row.kind) {
            .group => blk: {
                self.view.toggleGroup(row.group);
                break :blk .consumed;
            },
            .entry => .{ .open_diff = row },
        };
    }

    pub const Key = enum { up, down, page_up, page_down, home, end, enter, delete, reload };

    /// Tastatur mit Fokus in der Liste: wählen, Enter öffnet/klappt, Entf = Discard, F5 lädt neu.
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
            .enter => switch (v.activateSelected()) {
                .open_diff => |row| action = .{ .open_diff = row },
                else => {},
            },
            .delete => if (v.selected) |i| if (i < v.rows.items.len and v.rows.items[i].kind == .entry) {
                action = .{ .discard = v.rows.items[i] };
            },
            .reload => action = .refresh,
        }
        self.hover_row = null;
        if (v.selected) |i| if (vp > 0) {
            v.scroll = git_list.clampScroll(git_list.scrollToShow(v.scroll, vp, ROW_HEIGHT, i), vp, ROW_HEIGHT, v.rows.items.len);
        };
        return action;
    }

    /// Tasten im Eingabefeld: Ctrl+Enter = Commit, sonst Cursor/Backspace/Entf über line_edit.
    pub fn handleInputKey(self: *Self, key: wio.Button, ctrl: bool) Action {
        if ((key == .enter or key == .kp_enter) and ctrl) return .commit;
        if (line_edit.handleKey(&self.message, key) == .edited) self.validation = null;
        return .consumed;
    }

    pub fn handleInputChar(self: *Self, cp: u21) void {
        if (cp < 0x20) return;
        self.message.insertCodepoint(cp);
        self.validation = null;
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, mouse_x: f32, mouse_y: f32, input_focused: bool) void {
        const v = &self.view;
        const header_hover = if (box(headerId())) |b| inside(b, mouse_x, mouse_y) else false;
        const sidebar_h = if (box(clay.ElementId.ID("sidebar"))) |b| b.height else 600;
        const rows_h = @as(f32, @floatFromInt(v.rows.items.len)) * ROW_HEIGHT;
        const body_h = @min(rows_h, @max(BODY_MIN, sidebar_h * BODY_SHARE));

        clay.UI()(.{
            .id = sectionId(),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom },
            .background_color = theme.surface,
            .border = .{ .width = .{ .right = 1, .bottom = 1 }, .color = theme.border },
        })({
            // Kopf
            clay.UI()(.{
                .id = headerId(),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(HEADER_HEIGHT) }, .direction = .left_to_right, .child_alignment = .{ .y = .center }, .child_gap = 6, .padding = .{ .left = 8, .right = 6 } },
            })({
                svg.Svg(arena, "sc_chevron", svg.Lucide.chevron_down, 16, theme.subtext);
                const actions_w: f32 = if (header_hover) 2 * 24 + 6 else 0;
                clay.text(fitText(arena, "SOURCE CONTROL", width - 16 - actions_w - 26, 14), .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                if (header_hover) {
                    headerButton(arena, theme, "sc_btn_commit", svg.Lucide.check, mouse_x, mouse_y);
                    headerButton(arena, theme, "sc_btn_refresh", svg.Lucide.refresh_cw, mouse_x, mouse_y);
                }
            });

            // Eingabefeld (26 px + 10 px Rand wie scm.css)
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(INPUT_HEIGHT) }, .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 } } })({
                clay.UI()(.{
                    .id = inputId(),
                    .layout = .{ .sizing = .grow, .child_alignment = .{ .y = .center }, .padding = .{ .left = 6, .right = 6 } },
                    .background_color = theme.bg,
                    .border = .{ .width = .all(1), .color = if (input_focused) theme.border_focus else theme.border },
                    .corner_radius = .all(4),
                })({
                    if (self.message.len == 0 and !input_focused) {
                        var buf: [128]u8 = undefined;
                        clay.text(fitText(arena, v.placeholder(&buf), width - 32, 16), .{ .font_size = 16, .color = theme.muted, .wrap_mode = .none });
                    } else {
                        if (self.message.len == 0) {
                            var buf: [128]u8 = undefined;
                            clay.UI()(.{ .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_center, .parent = .left_center }, .offset = .{ .x = 6, .y = 0 }, .pointer_capture_mode = .passthrough }, .layout = .{ .sizing = .{ .w = .fit, .h = .fit } } })({
                                clay.text(fitText(arena, v.placeholder(&buf), width - 32, 16), .{ .font_size = 16, .color = theme.muted, .wrap_mode = .none });
                            });
                        }
                        line_edit.render(&self.message, input_field, theme.text, input_focused, theme);
                    }
                });
            });
            if (self.validation) |text| {
                clay.UI()(.{ .id = clay.ElementId.ID("sc_validation"), .layout = .{ .sizing = .{ .w = .grow }, .padding = .{ .left = 8, .right = 8, .bottom = 4 } } })({
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow }, .padding = .all(4) }, .background_color = tint(theme.warning, 60), .border = .{ .width = .all(1), .color = theme.warning } })({
                        clay.text(text, .{ .font_size = 13, .color = theme.text, .wrap_mode = .words });
                    });
                });
            }

            // Commit-Knopf über die volle Breite (scm.showActionButton)
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(BUTTON_HEIGHT + 8) }, .padding = .{ .left = 8, .right = 8, .bottom = 8 } } })({
                const id = clay.ElementId.ID("sc_btn_commit_big");
                const hovered = if (box(id)) |b| inside(b, mouse_x, mouse_y) else false;
                clay.UI()(.{
                    .id = id,
                    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(BUTTON_HEIGHT) }, .child_alignment = .{ .x = .center, .y = .center }, .child_gap = 6 },
                    .background_color = if (self.busy) theme.overlay else if (hovered) mix(theme.primary, theme.text, 0.12) else theme.primary,
                    .corner_radius = .all(4),
                })({
                    svg.Svg(arena, "sc_icon_commit", svg.Lucide.check, 16, theme.text_on_primary);
                    clay.text(if (self.busy) "Committing..." else "Commit", .{ .font_size = 15, .color = theme.text_on_primary, .wrap_mode = .none });
                });
            });

            // Liste
            const count = v.rows.items.len;
            v.scroll = git_list.clampScroll(v.scroll, body_h, ROW_HEIGHT, count);
            const range = git_list.visibleRange(v.scroll, body_h, ROW_HEIGHT, count, 4);
            clay.UI()(.{
                .id = bodyId(),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(body_h) }, .direction = .top_to_bottom },
                .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -v.scroll } },
            })({
                spacer(@as(f32, @floatFromInt(range.first)) * ROW_HEIGHT);
                for (range.first..range.end) |i| self.renderRow(arena, theme, width, i);
                spacer(@as(f32, @floatFromInt(count - range.end)) * ROW_HEIGHT);
            });
        });
    }

    fn renderRow(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, i: usize) void {
        const v = &self.view;
        const row = v.rows.items[i];
        const selected = v.selected == i;
        const hovered = self.hover_row == i;
        const bg: clay.Color = if (selected) theme.primary else if (hovered) mix(theme.surface, theme.text, 0.08) else theme.surface;
        const fg = if (selected) theme.text_on_primary else theme.text;
        const dim = if (selected) theme.text_on_primary else theme.muted;
        const actions = self.rowActions(row);
        const actions_w: f32 = if (hovered) @as(f32, @floatFromInt(actions.len)) * (ACTION_SIZE + 2) else 0;

        clay.UI()(.{
            .id = clay.ElementId.IDI("sc_row", @intCast(i)),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) }, .direction = .left_to_right, .child_alignment = .{ .y = .center }, .child_gap = 4, .padding = .{ .left = if (row.kind == .group) 6 else 22, .right = 8 } },
            .background_color = bg,
        })({
            switch (row.kind) {
                .group => {
                    const collapsed = v.collapsed[@intFromEnum(row.group)];
                    svg.Svg(arena, std.fmt.allocPrint(arena, "sc_gchev_{d}", .{i}) catch "sc_gchev", if (collapsed) svg.Lucide.chevron_right else svg.Lucide.chevron_down, 16, fg);
                    clay.text(git_changes.groupTitle(row.group), .{ .font_size = 14, .color = fg, .wrap_mode = .none });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                    if (hovered) self.renderActions(arena, theme, i, actions, fg);
                    // Badge = Anzahl (VS Code count badge)
                    const n = std.fmt.allocPrint(arena, "{d}", .{v.count(row.group)}) catch "0";
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fit, .h = .fixed(18) }, .child_alignment = .{ .x = .center, .y = .center }, .padding = .{ .left = 6, .right = 6 } }, .background_color = if (selected) theme.text_on_primary else theme.overlay, .corner_radius = .all(9) })({
                        clay.text(n, .{ .font_size = 12, .color = if (selected) theme.primary else theme.text, .wrap_mode = .none });
                    });
                },
                .entry => {
                    const e = v.entry(row) orelse return;
                    const name = std.fs.path.basename(e.path);
                    const dir = std.fs.path.dirname(e.path) orelse "";
                    const letter_w: f32 = 18;
                    const room = width - 22 - 8 - letter_w - actions_w - 12;
                    const label = fitText(arena, name, room, NAME_FONT);
                    const label_w = ui.measureTextWidth(label, @floatFromInt(NAME_FONT));
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fit, .h = .fit } } })({
                        clay.text(label, .{ .font_size = NAME_FONT, .color = fg, .wrap_mode = .none });
                        // Durchgestrichen (gelöscht): Linie über dem Namen, Clay kennt keinen Textstil
                        if (git_changes.strikeThrough(e.kind)) {
                            clay.UI()(.{
                                .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_center, .parent = .left_center }, .offset = .{ .x = 0, .y = 0 }, .pointer_capture_mode = .passthrough },
                                .layout = .{ .sizing = .{ .w = .fixed(label_w), .h = .fixed(1) } },
                                .background_color = fg,
                            })({});
                        }
                    });
                    if (dir.len > 0) clay.text(fitText(arena, dir, room - label_w - 8, DIM_FONT), .{ .font_size = DIM_FONT, .color = dim, .wrap_mode = .none });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                    if (hovered) self.renderActions(arena, theme, i, actions, fg);
                    var letter_buf: [1]u8 = .{git_changes.letter(e.kind)};
                    const letter_color: clay.Color = if (selected) theme.text_on_primary else statusColor(theme, git_changes.color(e.kind));
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(letter_w) }, .child_alignment = .{ .x = .center } } })({
                        clay.text(arena.dupe(u8, &letter_buf) catch "", .{ .font_size = 15, .color = letter_color, .wrap_mode = .none });
                    });
                },
            }
        });
    }

    fn renderActions(self: *Self, arena: std.mem.Allocator, theme: Theme, i: usize, actions: []const RowAction, fg: clay.Color) void {
        _ = self;
        _ = theme;
        for (actions) |k| {
            clay.UI()(.{ .id = actionId(i, k), .layout = .{ .sizing = .{ .w = .fixed(ACTION_SIZE), .h = .fixed(ACTION_SIZE) }, .child_alignment = .{ .x = .center, .y = .center } } })({
                svg.Svg(arena, std.fmt.allocPrint(arena, "sc_aicon_{d}_{d}", .{ i, @intFromEnum(k) }) catch "sc_aicon", actionIcon(k), 15, fg);
            });
        }
    }
};

pub fn statusColor(theme: Theme, c: git_changes.Color) clay.Color {
    return switch (c) {
        .added => theme.git_added,
        .modified => theme.git_modified,
        .deleted => theme.git_deleted,
        .untracked => theme.git_untracked,
        .renamed => theme.git_renamed,
        .ignored => theme.git_ignored,
        .conflict => theme.git_conflict,
    };
}

fn headerButton(arena: std.mem.Allocator, theme: Theme, comptime id_name: []const u8, icon: []const u8, mouse_x: f32, mouse_y: f32) void {
    const id = clay.ElementId.ID(id_name);
    const d = clay.getElementData(id);
    const hovered = d.found and mouse_x >= d.bounding_box.x and mouse_x < d.bounding_box.x + d.bounding_box.width and mouse_y >= d.bounding_box.y and mouse_y < d.bounding_box.y + d.bounding_box.height;
    clay.UI()(.{ .id = id, .layout = .{ .sizing = .{ .w = .fixed(24), .h = .fixed(24) }, .child_alignment = .{ .x = .center, .y = .center } }, .background_color = if (hovered) tint(theme.text, 30) else .{ 0, 0, 0, 0 }, .corner_radius = .all(4) })({
        svg.Svg(arena, id_name ++ "_icon", icon, 16, theme.text);
    });
}

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
