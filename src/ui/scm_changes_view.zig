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
const tooltip = @import("components/tooltip.zig");

pub const HEADER_HEIGHT: f32 = 30;
pub const ROW_HEIGHT: f32 = 26;
/// Zeilenhöhe im Eingabefeld; es wächst bis `INPUT_MAX_LINES` (VS Code scm.inputMaxLineCount)
pub const INPUT_LINE_HEIGHT: f32 = 22;
pub const INPUT_MAX_LINES: usize = 6;
const INPUT_PAD: f32 = 5;
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
    /// Publish Branch (ohne Upstream) bzw. Push
    push,
    refresh,
    /// Sparkle im Feld: Commit-Nachricht vom Modell (VS Code Copilot / Zed)
    generate_message,
};

pub const ScmChangesView = struct {
    view: git_changes.View,
    message: MessageEdit = .{},
    hover_row: ?usize = null,
    /// Hinweis unter dem Feld (VS Code inputValidation), z. B. bei leerer Nachricht
    validation: ?[]const u8 = null,
    /// Commit oder Push läuft: Knopf und Kopf-Aktion gesperrt
    busy: bool = false,
    /// Erste sichtbare Zeile des Eingabefelds, wenn es mehr als INPUT_MAX_LINES Zeilen hat
    input_first_line: usize = 0,
    /// Commit-Nachricht wird gerade vom Modell erzeugt (Sparkle dreht, Platzhalter „Generating…“)
    generating: bool = false,

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
        if (box(clay.ElementId.ID("sc_btn_push"))) |b| if (inside(b, x, y)) return .push;
        if (box(clay.ElementId.ID("sc_btn_generate"))) |b| if (inside(b, x, y)) return .generate_message;
        if (box(clay.ElementId.ID("sc_btn_commit"))) |b| if (inside(b, x, y)) return .commit;
        if (box(clay.ElementId.ID("sc_btn_commit_big"))) |b| if (inside(b, x, y)) {
            return if (self.view.actionButton() == .commit) .commit else .push;
        };
        if (box(inputId())) |b| if (inside(b, x, y)) {
            // Zeile aus y, Spalte aus x (Codepoints der Zeile messen)
            const rel_line: usize = @intFromFloat(@max(0, (y - b.y - INPUT_PAD) / INPUT_LINE_HEIGHT));
            const line_idx = @min(self.input_first_line + rel_line, self.message.lineCount() - 1);
            const text = self.message.line(line_idx);
            const rel_x = x - b.x - 6;
            var col: usize = 0;
            var left: f32 = 0;
            var it = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (it.nextCodepointSlice()) |cp| {
                const w = ui.measureTextWidth(cp, input_field.font_size);
                if (rel_x < left + w / 2) break;
                left += w;
                col += 1;
            }
            self.message.setCursorAtLine(line_idx, col);
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

    /// Tasten im Eingabefeld: Ctrl+Enter = Commit, Enter = neue Zeile, ↑↓ zwischen Zeilen,
    /// Pos1/Ende in der Zeile, sonst Cursor/Backspace/Entf über line_edit.
    pub fn handleInputKey(self: *Self, key: wio.Button, ctrl: bool) Action {
        switch (key) {
            .enter, .kp_enter => {
                if (ctrl) return .commit;
                self.message.insertCodepoint('\n');
                self.validation = null;
            },
            .up => self.message.moveUp(),
            .down => self.message.moveDown(),
            .home => self.message.moveLineHome(),
            .end => self.message.moveLineEnd(),
            else => if (line_edit.handleKey(&self.message, key) == .edited) {
                self.validation = null;
            },
        }
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
                // drei Knöpfe à 24 px plus Abstände; sonst ragen sie über die Sidebar hinaus
                const actions_w: f32 = if (header_hover) 3 * 24 + 3 * 6 else 0;
                clay.text(fitText(arena, "SOURCE CONTROL", width - 16 - actions_w - 26, 14), .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                if (header_hover) {
                    tooltip.iconButton(arena, theme, clay.ElementId.ID("sc_btn_commit"), "sc_btn_commit_icon", svg.Lucide.check, "Commit", .{});
                    tooltip.iconButton(arena, theme, clay.ElementId.ID("sc_btn_push"), "sc_btn_push_icon", svg.Lucide.upload, "Push", .{});
                    tooltip.iconButton(arena, theme, clay.ElementId.ID("sc_btn_refresh"), "sc_btn_refresh_icon", svg.Lucide.refresh_cw, "Refresh", .{});
                }
            });

            // Eingabefeld: wächst mit den Zeilen bis INPUT_MAX_LINES, danach scrollt es zur Cursorzeile
            const line_count = self.message.lineCount();
            const shown = @min(line_count, INPUT_MAX_LINES);
            const cur_line = self.message.cursorLine();
            if (cur_line < self.input_first_line) self.input_first_line = cur_line;
            if (cur_line >= self.input_first_line + shown) self.input_first_line = cur_line + 1 - shown;
            if (self.input_first_line + shown > line_count) self.input_first_line = line_count - shown;
            const input_h = @as(f32, @floatFromInt(shown)) * INPUT_LINE_HEIGHT + 2 * INPUT_PAD;
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(input_h + 10) }, .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 } } })({
                clay.UI()(.{
                    .id = inputId(),
                    .layout = .{ .sizing = .grow, .direction = .top_to_bottom, .padding = .{ .left = 6, .right = 6, .top = INPUT_PAD, .bottom = INPUT_PAD } },
                    .background_color = theme.bg,
                    .border = .{ .width = .all(1), .color = if (input_focused) theme.border_focus else theme.border },
                    .corner_radius = .all(4),
                })({
                    if (self.message.len == 0) {
                        // In der Arena, nicht auf dem Stack: Clay hält den Zeiger bis zum Zeichnen
                        // nach `render`. Ein Stack-Puffer wurde bis dahin überschrieben (Debug: 0xAA),
                        // der Shaper meldete InvalidUtf8 und der ganze Frame fiel aus (Zittern).
                        const buf = arena.alloc(u8, 128) catch @as([]u8, &.{});
                        const ph = if (self.generating) "Generating commit message..." else v.placeholder(buf);
                        clay.UI()(.{ .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = 6, .y = INPUT_PAD }, .pointer_capture_mode = .passthrough }, .layout = .{ .sizing = .{ .w = .fit, .h = .fixed(INPUT_LINE_HEIGHT) }, .child_alignment = .{ .y = .center } } })({
                            clay.text(fitText(arena, ph, width - 60, 16), .{ .font_size = 16, .color = theme.muted, .wrap_mode = .none });
                        });
                    }
                    // Sparkle rechts oben im Feld wie VS Code Copilot: Nachricht vom Modell
                    clay.UI()(.{ .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .right_top, .parent = .right_top }, .offset = .{ .x = -3, .y = 3 }, .z_index = 5 }, .layout = .{ .sizing = .{ .w = .fit, .h = .fit } } })({
                        tooltip.iconButton(arena, theme, clay.ElementId.ID("sc_btn_generate"), "sc_btn_generate_icon", if (self.generating) svg.Lucide.loader_circle else svg.Lucide.sparkles, if (self.generating) "Generating commit message..." else "Generate Commit Message", .{ .size = 20, .icon_size = 14 });
                    });
                    for (self.input_first_line..self.input_first_line + shown) |li| {
                        const text = self.message.line(li);
                        clay.UI()(.{
                            .id = clay.ElementId.IDI("sc_input_line", @intCast(li)),
                            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(INPUT_LINE_HEIGHT) }, .child_alignment = .{ .y = .center } },
                        })({
                            clay.text(text, .{ .font_size = 16, .color = theme.text, .wrap_mode = .none });
                            if (input_focused and li == cur_line) {
                                const before = self.message.textBeforeCursor();
                                const ls = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;
                                clay.UI()(.{
                                    .id = clay.ElementId.ID("sc_input_caret"),
                                    .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_center, .parent = .left_center }, .offset = .{ .x = ui.measureTextWidth(before[ls..], 16), .y = 0 }, .z_index = 10, .pointer_capture_mode = .passthrough },
                                    .layout = .{ .sizing = .{ .w = .fixed(2), .h = .fixed(16) } },
                                    .background_color = theme.text,
                                })({});
                            }
                        });
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
                    const kind = v.actionButton();
                    var label_buf: [64]u8 = undefined;
                    svg.Svg(arena, "sc_icon_commit", if (kind == .commit) svg.Lucide.check else svg.Lucide.upload, 16, theme.text_on_primary);
                    const label: []const u8 = if (self.busy) (if (kind == .commit) "Committing..." else "Pushing...") else v.buttonLabel(&label_buf);
                    clay.text(arena.dupe(u8, label) catch "", .{ .font_size = 15, .color = theme.text_on_primary, .wrap_mode = .none });
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
        for (actions) |k| {
            const id = actionId(i, k);
            clay.UI()(.{ .id = id, .layout = .{ .sizing = .{ .w = .fixed(ACTION_SIZE), .h = .fixed(ACTION_SIZE) }, .child_alignment = .{ .x = .center, .y = .center } } })({
                svg.Svg(arena, std.fmt.allocPrint(arena, "sc_aicon_{d}_{d}", .{ i, @intFromEnum(k) }) catch "sc_aicon", actionIcon(k), 16, fg);
                tooltip.attach(theme, id, actionLabel(k));
            });
        }
    }

    /// Beschriftungen wie VS Code package.json (`git.stage`, `git.unstage`, `git.clean`, …).
    fn actionLabel(k: RowAction) []const u8 {
        return switch (k) {
            .open_file => "Open File",
            .stage => "Stage Changes",
            .unstage => "Unstage Changes",
            .discard => "Discard Changes",
            .stage_all => "Stage All Changes",
            .unstage_all => "Unstage All Changes",
            .discard_all => "Discard All Changes",
        };
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
