//! Diff-Editor-Tab im Stil von VS Code: ganze Datei alt gegen neu, nebeneinander ab 900 px,
//! sonst untereinander; Zeilennummern, +/−-Markierung, Syntax-Highlighting, geänderte Zeichen
//! hervorgehoben, eingeklappte unveränderte Bereiche. Zustand in `git_diff.DiffState`.
//! Beide Seiten scrollen gemeinsam; horizontal über Spaltenausschnitte statt Clipping.

const std = @import("std");
const clay = @import("clay");
const flow_core = @import("flow_core");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const git_diff = @import("git_diff");
const svg = @import("components/svg.zig");

const TOOLBAR_HEIGHT: f32 = 34;
const OVERSCAN: usize = 10;
/// Anzeige-Grenze je Zeile in Spalten (der Shaper liefert Runs über 2048 Bytes leer)
const MAX_COLS: usize = 400;

pub const GitDiffView = struct {
    state: git_diff.DiffState,
    old_hl: ?*flow_core.highlight.SyntaxHighlighter = null,
    new_hl: ?*flow_core.highlight.SyntaxHighlighter = null,
    /// Aus dem letzten Frame: Layout und Zeilenhöhe für Klicks und Tasten
    last_layout: git_diff.Layout = .side_by_side,
    row_height: f32 = 24,
    /// Im letzten Frame gezeichnete Zeilen (E2E prüft die Virtualisierung)
    rendered_rows: usize = 0,

    const Self = @This();

    pub fn create(alloc: std.mem.Allocator, tab_path: []const u8) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        self.* = .{ .state = try git_diff.DiffState.init(alloc, tab_path) };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const alloc = self.state.alloc;
        self.destroyHighlighters();
        self.state.deinit();
        alloc.destroy(self);
    }

    fn destroyHighlighters(self: *Self) void {
        if (self.old_hl) |h| h.destroy();
        if (self.new_hl) |h| h.destroy();
        self.old_hl = null;
        self.new_hl = null;
    }

    /// Ergebnis anwenden und beide Seiten einmal parsen (Main-Thread, vor dem Layout).
    pub fn apply(self: *Self, ok: bool, payload: []const u8) !void {
        try self.state.apply(ok, payload);
        if (!self.state.loaded) return;
        self.destroyHighlighters();
        const c = git_diff.decodeContents(self.state.body).?;
        self.old_hl = buildHighlighter(self.state.alloc, self.state.spec.previous_path, c.old);
        self.new_hl = buildHighlighter(self.state.alloc, self.state.spec.path, c.new);
    }

    fn buildHighlighter(alloc: std.mem.Allocator, path: []const u8, content: []const u8) ?*flow_core.highlight.SyntaxHighlighter {
        if (content.len == 0) return null;
        const hl = flow_core.highlight.SyntaxHighlighter.createByPath(alloc, path, content) catch return null;
        const buf = flow_core.Buffer.create(alloc) catch return hl;
        defer buf.deinit();
        var eol_mode: flow_core.Buffer.EolMode = .lf;
        var sanitized = false;
        const root = buf.load_from_string(content, &eol_mode, &sanitized) catch return hl;
        hl.reparseFromBuffer(root, metrics) catch {};
        return hl;
    }

    // ─── IDs (je Pane gesalzen) ───

    pub fn bodyId(salt: u32) clay.ElementId {
        return clay.ElementId.IDI("gd_body", salt);
    }

    fn buttonId(comptime name: []const u8, salt: u32) clay.ElementId {
        return clay.ElementId.IDI("gd_btn_" ++ name, salt);
    }

    fn foldId(salt: u32, item: usize) clay.ElementId {
        return clay.ElementId.IDI("gd_fold", salt +% @as(u32, @truncate(item)));
    }

    fn box(id: clay.ElementId) ?clay.BoundingBox {
        const d = clay.getElementData(id);
        return if (d.found) d.bounding_box else null;
    }

    fn inside(b: clay.BoundingBox, x: f32, y: f32) bool {
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    fn viewport(salt: u32) f32 {
        return if (box(bodyId(salt))) |b| b.height else 0;
    }

    // ─── Eingaben ───

    pub fn nextChange(self: *Self, salt: u32) void {
        const idx = (self.state.goNext(self.last_layout) catch null) orelse return;
        self.revealItem(idx, salt);
    }

    pub fn prevChange(self: *Self, salt: u32) void {
        const idx = (self.state.goPrev(self.last_layout) catch null) orelse return;
        self.revealItem(idx, salt);
    }

    /// Wie VS Code: die angesprungene Änderung steht im oberen Drittel.
    fn revealItem(self: *Self, item: usize, salt: u32) void {
        const vp = viewport(salt);
        self.state.scroll_y = @max(0, @as(f32, @floatFromInt(item)) * self.row_height - vp / 3);
    }

    pub fn toggleInline(self: *Self) void {
        self.state.mode = switch (self.last_layout) {
            .side_by_side => .inline_,
            .inline_ => .side_by_side,
        };
    }

    pub const Key = enum { up, down, page_up, page_down, home, end, left, right };

    pub fn handleKey(self: *Self, key: Key, salt: u32) void {
        const s = &self.state;
        const page = @max(self.row_height, viewport(salt) - self.row_height);
        switch (key) {
            .up => s.scroll_y -= self.row_height,
            .down => s.scroll_y += self.row_height,
            .page_up => s.scroll_y -= page,
            .page_down => s.scroll_y += page,
            .home => s.scroll_y = 0,
            .end => s.scroll_y = std.math.floatMax(f32),
            .left => s.scroll_x = @max(0, s.scroll_x - 4),
            .right => s.scroll_x += 4,
        }
    }

    /// Mausrad (positiv = hoch), `horizontal` mit Shift: Spalten.
    pub fn scrollLines(self: *Self, delta: i32, horizontal: bool) void {
        const s = &self.state;
        if (horizontal) {
            s.scroll_x = @max(0, s.scroll_x - @as(f32, @floatFromInt(delta * 4)));
        } else {
            s.scroll_y -= @as(f32, @floatFromInt(delta * 3)) * self.row_height;
        }
    }

    /// Klick auf Werkzeugleiste oder Faltbalken. true = Klick lag in der Ansicht.
    pub fn handleMouseDown(self: *Self, x: f32, y: f32, salt: u32) bool {
        if (box(buttonId("prev", salt))) |b| if (inside(b, x, y)) {
            self.prevChange(salt);
            return true;
        };
        if (box(buttonId("next", salt))) |b| if (inside(b, x, y)) {
            self.nextChange(salt);
            return true;
        };
        if (box(buttonId("collapse", salt))) |b| if (inside(b, x, y)) {
            self.state.toggleCollapse();
            return true;
        };
        if (box(buttonId("inline", salt))) |b| if (inside(b, x, y)) {
            self.toggleInline();
            return true;
        };
        const items = self.state.items(self.last_layout) catch return false;
        for (items, 0..) |it, i| switch (it) {
            .fold => |f| if (box(foldId(salt, i))) |b| if (inside(b, x, y)) {
                self.state.revealFold(self.last_layout, f.first, f.count) catch {};
                return true;
            },
            .row => {},
        };
        return if (box(clay.ElementId.IDI("gd_container", salt))) |b| inside(b, x, y) else false;
    }

    // ─── Zeichnen ───

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, font_size: u16, mouse_x: f32, mouse_y: f32) void {
        const s = &self.state;
        const fs: f32 = @floatFromInt(font_size);
        self.row_height = @ceil(fs * 1.45);
        const width = if (box(clay.ElementId.IDI("gd_container", salt))) |b| b.width else 1200;
        const layout = s.layoutFor(width);
        self.last_layout = layout;
        self.rendered_rows = 0;

        clay.UI()(.{
            .id = clay.ElementId.IDI("gd_container", salt),
            .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
            .background_color = theme.bg,
        })({
            self.renderToolbar(arena, theme, salt, layout, mouse_x, mouse_y);
            clay.UI()(.{
                .id = bodyId(salt),
                .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
                .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -s.scroll_y } },
            })({
                if (s.error_text) |e| {
                    message(std.fmt.allocPrint(arena, "git: {s}", .{e}) catch "git failed", theme);
                } else if (!s.loaded) {
                    message("Loading…", theme);
                } else {
                    self.renderRows(arena, theme, salt, layout, width, fs);
                }
            });
        });
    }

    fn renderToolbar(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, layout: git_diff.Layout, mouse_x: f32, mouse_y: f32) void {
        const s = &self.state;
        const st = s.stats();
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(TOOLBAR_HEIGHT) },
                .direction = .left_to_right,
                .child_alignment = .{ .y = .center },
                .child_gap = 4,
                .padding = .{ .left = 12, .right = 8 },
            },
            .background_color = theme.bg,
            .border = .{ .width = .{ .bottom = 1 }, .color = theme.border },
        })({
            // Wie VS Codes Breadcrumb unter dem Tab: Pfad im Repo
            clay.text(s.spec.path, .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
            if (s.loaded) {
                clay.text(std.fmt.allocPrint(arena, "  +{d} \u{2212}{d}", .{ st.added, st.removed }) catch "", .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
            }
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            // Reihenfolge wie VS Codes Editor-Titelleiste: Previous, Next, Collapse, Inline
            iconButton(arena, theme, "prev", salt, svg.Lucide.arrow_up, false, mouse_x, mouse_y);
            iconButton(arena, theme, "next", salt, svg.Lucide.arrow_down, false, mouse_x, mouse_y);
            iconButton(arena, theme, "collapse", salt, svg.Lucide.map, s.collapse_unchanged, mouse_x, mouse_y);
            iconButton(arena, theme, "inline", salt, if (layout == .side_by_side) svg.Lucide.rows_2 else svg.Lucide.columns_2, false, mouse_x, mouse_y);
        });
    }

    fn renderRows(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, layout: git_diff.Layout, width: f32, fs: f32) void {
        const s = &self.state;
        const items = s.items(layout) catch return;
        const vp = viewport(salt);
        const content_h = @as(f32, @floatFromInt(items.len)) * self.row_height;
        s.scroll_y = std.math.clamp(s.scroll_y, 0, @max(0, content_h - vp));
        const range = visibleRange(s.scroll_y, if (vp > 0) vp else 800, self.row_height, items.len);
        spacer(@as(f32, @floatFromInt(range.first)) * self.row_height);
        self.renderItems(arena, theme, salt, layout, width, fs, range.first, range.end);
        spacer(@as(f32, @floatFromInt(items.len - range.end)) * self.row_height);
    }

    /// Anzahl der Anzeigeeinträge (Zeilen und Faltbalken) im Layout; 0 solange nicht geladen.
    pub fn itemCount(self: *Self, layout: git_diff.Layout) usize {
        if (!self.state.loaded) return 0;
        return (self.state.items(layout) catch return 0).len;
    }

    /// Einträge [first, end) ohne Abstandhalter zeichnen (auch vom Multi-File-Diff benutzt).
    pub fn renderItems(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, layout: git_diff.Layout, width: f32, fs: f32, first: usize, end: usize) void {
        const s = &self.state;
        self.row_height = @ceil(fs * 1.45);
        self.last_layout = layout;
        const items = s.items(layout) catch return;
        const range = .{ .first = @min(first, items.len), .end = @min(end, items.len) };

        const char_w = @max(1, ui.measureTextWidth("W", fs));
        const digits = digitCount(@max(s.old_lines.len, s.new_lines.len));
        const number_w = @as(f32, @floatFromInt(digits)) * char_w + 20;
        const indicator_w = char_w + 12;
        const gutter_w = switch (layout) {
            .side_by_side => number_w + indicator_w,
            .inline_ => 2 * number_w + indicator_w,
        };
        const half_w = switch (layout) {
            .side_by_side => (width - 1) / 2,
            .inline_ => width,
        };
        const cols: usize = @intFromFloat(@max(1, (half_w - gutter_w - 8) / char_w));
        const first_col: usize = @intFromFloat(@max(0, s.scroll_x));

        for (range.first..range.end) |i| {
            switch (items[i]) {
                .fold => |f| self.renderFold(arena, theme, salt, i, f.count),
                .row => |r| {
                    const row = s.rows(layout)[r];
                    const ctx = RowCtx{ .arena = arena, .theme = theme, .fs = fs, .row_h = self.row_height, .number_w = number_w, .indicator_w = indicator_w, .first_col = first_col, .cols = @min(cols, MAX_COLS) };
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(self.row_height) }, .direction = .left_to_right },
                    })({
                        switch (layout) {
                            .side_by_side => {
                                const inner = if (row.kind == .modified) git_diff.innerChange(s.old_lines[row.old.?], s.new_lines[row.new.?]) else null;
                                self.renderSide(ctx, .old, row, inner);
                                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(1), .h = .grow } }, .background_color = theme.border })({});
                                self.renderSide(ctx, .new, row, inner);
                            },
                            .inline_ => self.renderInline(ctx, row),
                        }
                    });
                    self.rendered_rows += 1;
                },
            }
        }
    }

    const RowCtx = struct {
        arena: std.mem.Allocator,
        theme: Theme,
        fs: f32,
        row_h: f32,
        number_w: f32,
        indicator_w: f32,
        first_col: usize,
        cols: usize,
    };

    const Side = enum { old, new };

    fn renderSide(self: *Self, c: RowCtx, side: Side, row: git_diff.Row, inner: ?git_diff.InnerChange) void {
        const s = &self.state;
        const line_index = if (side == .old) row.old else row.new;
        const changed = row.kind != .equal;
        const bg: clay.Color = if (line_index == null)
            tint(c.theme.text, 10) // Lücke (VS Code: schraffiert)
        else if (changed)
            (if (side == .old) tint(c.theme.danger, 40) else tint(c.theme.success, 40))
        else
            .{ 0, 0, 0, 0 };
        // Prozent statt fester Breite aus dem Vorframe: sonst zieht ein zu breiter Messwert
        // (neues Pane) den Container mit und bleibt stehen (Rückkopplung, Skill clay-layout)
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .percent(0.5), .h = .fixed(c.row_h) }, .direction = .left_to_right, .child_alignment = .{ .y = .center } },
            .background_color = bg,
        })({
            // Kein `return` im Kinderblock (Skill clay-layout)
            if (line_index) |idx| {
                lineNumber(c, idx + 1);
                indicator(c, if (!changed) " " else if (side == .old) "\u{2212}" else "+", if (side == .old) c.theme.danger else c.theme.success);
                const lines = if (side == .old) s.old_lines else s.new_lines;
                const hl = if (side == .old) self.old_hl else self.new_hl;
                const range: ?git_diff.ByteRange = if (inner) |in| (if (side == .old) .{ .start = in.old_start, .end = in.old_end } else .{ .start = in.new_start, .end = in.new_end }) else null;
                codeText(c, lines[idx], idx, hl, range, if (side == .old) c.theme.danger else c.theme.success);
            }
        });
    }

    fn renderInline(self: *Self, c: RowCtx, row: git_diff.Row) void {
        const s = &self.state;
        const bg: clay.Color = switch (row.kind) {
            .removed => tint(c.theme.danger, 40),
            .added => tint(c.theme.success, 40),
            else => .{ 0, 0, 0, 0 },
        };
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(c.row_h) }, .direction = .left_to_right, .child_alignment = .{ .y = .center } },
            .background_color = bg,
        })({
            if (row.old) |o| lineNumber(c, o + 1) else spacerW(c.number_w);
            if (row.new) |n| lineNumber(c, n + 1) else spacerW(c.number_w);
            switch (row.kind) {
                .removed => {
                    indicator(c, "\u{2212}", c.theme.danger);
                    codeText(c, s.old_lines[row.old.?], row.old.?, self.old_hl, null, c.theme.danger);
                },
                .added => {
                    indicator(c, "+", c.theme.success);
                    codeText(c, s.new_lines[row.new.?], row.new.?, self.new_hl, null, c.theme.success);
                },
                else => {
                    indicator(c, " ", c.theme.muted);
                    codeText(c, s.new_lines[row.new.?], row.new.?, self.new_hl, null, c.theme.muted);
                },
            }
        });
    }

    fn renderFold(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, item: usize, count: usize) void {
        clay.UI()(.{
            .id = foldId(salt, item),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(self.row_height) },
                .child_alignment = .{ .x = .center, .y = .center },
                .child_gap = 8,
            },
            .background_color = theme.surface,
        })({
            svg.Svg(arena, std.fmt.allocPrint(arena, "gd_fold_icon_{d}_{d}", .{ salt, item }) catch "gd_fold_icon", svg.Lucide.unfold_vertical, 16, theme.muted);
            clay.text(std.fmt.allocPrint(arena, "{d} hidden lines", .{count}) catch "", .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
        });
    }
};

fn iconButton(arena: std.mem.Allocator, theme: Theme, comptime name: []const u8, salt: u32, icon: []const u8, toggled: bool, mouse_x: f32, mouse_y: f32) void {
    const id = GitDiffView.buttonId(name, salt);
    const hovered = if (GitDiffView.box(id)) |b| GitDiffView.inside(b, mouse_x, mouse_y) else false;
    clay.UI()(.{
        .id = id,
        .layout = .{ .sizing = .{ .w = .fixed(28), .h = .fixed(28) }, .child_alignment = .{ .x = .center, .y = .center } },
        .background_color = if (toggled) tint(theme.primary, 60) else if (hovered) tint(theme.text, 30) else .{ 0, 0, 0, 0 },
        .corner_radius = .all(4),
    })({
        svg.Svg(arena, std.fmt.allocPrint(arena, "gd_icon_" ++ name ++ "_{d}", .{salt}) catch "gd_icon", icon, 16, theme.text);
    });
}

fn lineNumber(c: GitDiffView.RowCtx, number: usize) void {
    clay.UI()(.{
        .layout = .{ .sizing = .{ .w = .fixed(c.number_w), .h = .grow }, .child_alignment = .{ .x = .right, .y = .center }, .padding = .{ .right = 8 } },
    })({
        clay.text(std.fmt.allocPrint(c.arena, "{d}", .{number}) catch "", .{ .font_size = @intFromFloat(c.fs), .color = c.theme.muted, .wrap_mode = .none });
    });
}

fn indicator(c: GitDiffView.RowCtx, text: []const u8, color: clay.Color) void {
    clay.UI()(.{
        .layout = .{ .sizing = .{ .w = .fixed(c.indicator_w), .h = .grow }, .child_alignment = .{ .x = .center, .y = .center } },
    })({
        clay.text(text, .{ .font_size = @intFromFloat(c.fs), .color = color, .wrap_mode = .none });
    });
}

/// Zeilentext im sichtbaren Spaltenausschnitt: Farben aus dem Highlighter, der geänderte
/// Zeichenbereich (`inner`) mit stärkerem Hintergrund wie VS Codes removed/insertedTextBackground.
fn codeText(c: GitDiffView.RowCtx, line: []const u8, line_index: usize, hl: ?*flow_core.highlight.SyntaxHighlighter, inner: ?git_diff.ByteRange, change_color: clay.Color) void {
    const vis = git_diff.columnSlice(line, c.first_col, c.cols);
    if (vis.start >= vis.end) return;
    // Farbe je Byte: Highlighter-Tags nacheinander (spätere überschreiben frühere)
    const colors = c.arena.alloc(u32, vis.end - vis.start) catch return;
    @memset(colors, rgb(c.theme.text));
    if (hl) |h| {
        if (h.tagsForLine(line_index, line.len, c.arena)) |tags| {
            for (tags) |t| {
                const from = @max(t.start, vis.start);
                const to = @min(t.end, vis.end);
                if (from < to) @memset(colors[from - vis.start .. to - vis.start], t.fg);
            }
        } else |_| {}
    }
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .left_to_right, .child_alignment = .{ .y = .center } } })({
        var pos = vis.start;
        while (pos < vis.end) {
            const color = colors[pos - vis.start];
            const in_change = if (inner) |r| pos >= r.start and pos < r.end else false;
            var end = pos + 1;
            while (end < vis.end and colors[end - vis.start] == color and (if (inner) |r| (end >= r.start and end < r.end) == in_change else true)) end += 1;
            // nicht mitten in einem UTF-8-Zeichen trennen
            while (end < vis.end and line[end] & 0xC0 == 0x80) end += 1;
            const seg = displayText(c.arena, line[pos..end]);
            if (in_change) {
                clay.UI()(.{ .layout = .{ .sizing = .{ .h = .grow }, .child_alignment = .{ .y = .center } }, .background_color = tint(change_color, 90) })({
                    clay.text(seg, .{ .font_size = @intFromFloat(c.fs), .color = fromRgb(color), .wrap_mode = .none });
                });
            } else {
                clay.text(seg, .{ .font_size = @intFromFloat(c.fs), .color = fromRgb(color), .wrap_mode = .none });
            }
            pos = end;
        }
    });
}

fn displayText(arena: std.mem.Allocator, text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
    return std.mem.replaceOwned(u8, arena, text, "\t", "    ") catch text;
}

fn rgb(c: clay.Color) u32 {
    return (@as(u32, @intFromFloat(c[0])) << 16) | (@as(u32, @intFromFloat(c[1])) << 8) | @as(u32, @intFromFloat(c[2]));
}

fn fromRgb(v: u32) clay.Color {
    return .{ @floatFromInt((v >> 16) & 0xff), @floatFromInt((v >> 8) & 0xff), @floatFromInt(v & 0xff), 255 };
}

fn tint(c: clay.Color, alpha: f32) clay.Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn digitCount(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn visibleRange(scroll: f32, vp: f32, row_h: f32, count: usize) struct { first: usize, end: usize } {
    const first: usize = @intFromFloat(@max(0, @floor(scroll / row_h)));
    const last: usize = @intFromFloat(@max(0, @ceil((scroll + vp) / row_h)));
    const end = @min(count, last + OVERSCAN);
    return .{ .first = @min(first -| OVERSCAN, end), .end = end };
}

fn spacer(height: f32) void {
    if (height <= 0) return;
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(height) } } })({});
}

fn spacerW(width: f32) void {
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(width), .h = .grow } } })({});
}

fn message(text: []const u8, theme: Theme) void {
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow }, .padding = .all(16) } })({
        clay.text(text, .{ .font_size = 16, .color = theme.muted, .wrap_mode = .words });
    });
}

/// Metrik für den Highlighter-Parse (Monospace, Tab = 4), wie MarkdownView.renderCodeBlock.
const metrics = flow_core.Buffer.Metrics{
    .ctx = undefined,
    .egc_length = struct {
        fn f(_: flow_core.Buffer.Metrics, egcs: []const u8, colcount: *usize, _: usize) usize {
            if (egcs.len == 0) return 0;
            colcount.* = if (egcs[0] == '\t') 4 else 1;
            return 1;
        }
    }.f,
    .egc_chunk_width = struct {
        fn f(_: flow_core.Buffer.Metrics, chunk: []const u8, _: usize) usize {
            if (chunk.len == 0) return 0;
            return if (chunk[0] == '\t') 4 else 1;
        }
    }.f,
    .egc_last = struct {
        fn f(_: flow_core.Buffer.Metrics, egcs: []const u8) []const u8 {
            return egcs;
        }
    }.f,
    .tab_width = 4,
};
