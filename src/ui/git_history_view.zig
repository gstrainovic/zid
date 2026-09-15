//! Git-History-Tab: Commit-Liste links, Diff des gewählten Commits rechts.
//! Zustand und Logik (Auswahl, Anfragen, Parsing) stehen in `git_history.State`,
//! hier nur Zeichnen und Eingaben. Beide Listen haben feste Zeilenhöhen und sind
//! virtualisiert (siehe Skill clay-layout).

const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const git_history = @import("git_history");

pub const ROW_HEIGHT: f32 = 50;
pub const DIFF_ROW_HEIGHT: f32 = 22;
const ROW_PADDING_X: f32 = 10;
const LIST_FONT: u16 = 17;
const META_FONT: u16 = 14;
const DIFF_FONT: u16 = 15;
const HEADER_HEIGHT: f32 = 34;
/// Zeilen außerhalb des Sichtbereichs, die trotzdem gezeichnet werden (je Richtung)
const OVERSCAN: usize = 10;
/// Anzeige-Grenze je Diff-Zeile; der Shaper liefert Runs über 2048 Bytes leer
const MAX_LINE_BYTES: usize = 400;

pub const GitHistoryView = struct {
    state: git_history.State,
    /// Im letzten Frame gezeichnete Diff-Zeilen (E2E prüft die Virtualisierung)
    rendered_diff_rows: usize = 0,

    const Self = @This();

    pub fn create(alloc: std.mem.Allocator, tab_path: []const u8) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        self.* = .{ .state = try git_history.State.init(alloc, tab_path) };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const alloc = self.state.alloc;
        self.state.deinit();
        alloc.destroy(self);
    }

    // ─── IDs: je Pane gesalzen, derselbe Tab kann nach einem Split zweimal stehen ───

    pub fn listId(salt: u32) clay.ElementId {
        return clay.ElementId.IDI("gh_list", salt);
    }

    pub fn diffId(salt: u32) clay.ElementId {
        return clay.ElementId.IDI("gh_diff", salt);
    }

    fn rowId(salt: u32, index: usize) clay.ElementId {
        return clay.ElementId.IDI("gh_row", salt +% @as(u32, @truncate(index)));
    }

    fn box(id: clay.ElementId) ?clay.BoundingBox {
        const data = clay.getElementData(id);
        return if (data.found) data.bounding_box else null;
    }

    fn inside(b: clay.BoundingBox, x: f32, y: f32) bool {
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    fn listViewport(salt: u32) f32 {
        return if (box(listId(salt))) |b| b.height else 0;
    }

    fn diffViewport(salt: u32) f32 {
        return if (box(diffId(salt))) |b| b.height else 0;
    }

    // ─── Eingaben ───

    pub const Key = enum { up, down, page_up, page_down, home, end, reload };

    pub fn handleKey(self: *Self, key: Key, salt: u32) void {
        const s = &self.state;
        const page: isize = @max(1, @as(isize, @intFromFloat(listViewport(salt) / ROW_HEIGHT)) - 1);
        switch (key) {
            .up => s.move(-1),
            .down => s.move(1),
            .page_up => s.move(-page),
            .page_down => s.move(page),
            .home => s.move(-@as(isize, @intCast(s.commits().len))),
            .end => s.move(@intCast(s.commits().len)),
            .reload => s.reload(),
        }
        self.revealSelected(salt);
    }

    fn revealSelected(self: *Self, salt: u32) void {
        const s = &self.state;
        const i = s.selected orelse return;
        const vp = listViewport(salt);
        if (vp <= 0) return;
        s.list_scroll = git_history.clampScroll(git_history.scrollToShow(s.list_scroll, vp, ROW_HEIGHT, i), vp, ROW_HEIGHT, s.commits().len);
    }

    /// Linksklick: Zeile der Commit-Liste wählen. true = Klick lag in der Ansicht.
    pub fn handleMouseDown(self: *Self, x: f32, y: f32, salt: u32) bool {
        const s = &self.state;
        if (box(listId(salt))) |b| {
            if (inside(b, x, y)) {
                const row: usize = @intFromFloat(@max(0, (y - b.y + s.list_scroll) / ROW_HEIGHT));
                if (row < s.commits().len) s.select(row);
                return true;
            }
        }
        if (box(diffId(salt))) |b| return inside(b, x, y);
        return false;
    }

    /// Mausrad (positiv = hoch): scrollt die Liste oder den Diff, je nachdem wo die Maus steht.
    pub fn scrollLines(self: *Self, delta: i32, x: f32, y: f32, salt: u32) void {
        const s = &self.state;
        const lines: f32 = @floatFromInt(delta * 3);
        if (box(listId(salt))) |b| {
            if (inside(b, x, y)) {
                s.list_scroll = git_history.clampScroll(s.list_scroll - lines * ROW_HEIGHT, b.height, ROW_HEIGHT, s.commits().len);
                return;
            }
        }
        const vp = diffViewport(salt);
        s.diff_scroll = git_history.clampScroll(s.diff_scroll - lines * DIFF_ROW_HEIGHT, vp, DIFF_ROW_HEIGHT, s.diff_lines.len);
    }

    // ─── Zeichnen ───

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, mouse_x: f32, mouse_y: f32) void {
        clay.UI()(.{
            .id = clay.ElementId.IDI("gh_container", salt),
            .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
            .background_color = theme.bg,
        })({
            self.renderHeader(arena, theme, salt);
            clay.UI()(.{
                .layout = .{ .sizing = .grow, .direction = .left_to_right },
            })({
                self.renderList(arena, theme, salt, mouse_x, mouse_y);
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fixed(1), .h = .grow } },
                    .background_color = theme.border,
                })({});
                self.renderDiff(arena, theme, salt);
            });
        });
    }

    fn renderHeader(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32) void {
        const s = &self.state;
        const status: []const u8 = if (s.loading_log)
            "loading…"
        else if (s.log_error != null)
            "git failed"
        else
            std.fmt.allocPrint(arena, "{d} commits", .{s.commits().len}) catch "";
        const hint = "↑↓ select   F5 reload";
        // Der Tab trägt schon den Namen, hier steht der volle Pfad, gekürzt auf den Rest der Zeile
        const total = if (box(clay.ElementId.IDI("gh_container", salt))) |b| b.width else 800;
        const room = total - ui.measureTextWidth(status, 15) - ui.measureTextWidth(hint, 14) - 24 - 3 * 16;
        const title = fitText(arena, s.target().path(), room, 15);
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(HEADER_HEIGHT) },
                .direction = .left_to_right,
                .child_alignment = .{ .y = .center },
                .child_gap = 16,
                .padding = .{ .left = 12, .right = 12 },
            },
            .background_color = theme.surface,
            .border = .{ .width = .{ .bottom = 1 }, .color = theme.border },
        })({
            clay.text(title, .{ .font_size = 15, .color = theme.subtext, .wrap_mode = .none });
            clay.text(status, .{ .font_size = 15, .color = theme.muted, .wrap_mode = .none });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            clay.text(hint, .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
        });
    }

    fn renderList(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, mouse_x: f32, mouse_y: f32) void {
        const s = &self.state;
        const commits = s.commits();
        const vp = listViewport(salt);
        s.list_scroll = git_history.clampScroll(s.list_scroll, vp, ROW_HEIGHT, commits.len);
        const range = git_history.visibleRange(s.list_scroll, if (vp > 0) vp else 800, ROW_HEIGHT, commits.len, OVERSCAN);
        const width = if (box(listId(salt))) |b| b.width else 400;

        clay.UI()(.{
            .id = listId(salt),
            .layout = .{ .sizing = .{ .w = .percent(0.38), .h = .grow }, .direction = .top_to_bottom },
            .clip = .{ .vertical = true, .horizontal = true, .child_offset = .{ .x = 0, .y = -s.list_scroll } },
        })({
            // Kein `return` in Clay-Kinderblöcken: das Element würde nie geschlossen (Absturz in Clay_EndLayout)
            if (commits.len == 0) {
                const msg: []const u8 = if (s.loading_log)
                    "Loading history…"
                else if (s.log_error) |e|
                    std.fmt.allocPrint(arena, "git: {s}", .{e}) catch "git failed"
                else
                    emptyText(s.target());
                message(msg, theme);
            } else self.renderRows(arena, theme, salt, mouse_x, mouse_y, range.first, range.end, width);
        });
    }

    fn renderRows(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, mouse_x: f32, mouse_y: f32, first: usize, end: usize, width: f32) void {
        const s = &self.state;
        const commits = s.commits();
        spacer(@as(f32, @floatFromInt(first)) * ROW_HEIGHT);
        const hovered_row: ?usize = if (box(listId(salt))) |b|
            (if (inside(b, mouse_x, mouse_y)) @as(usize, @intFromFloat(@max(0, (mouse_y - b.y + s.list_scroll) / ROW_HEIGHT))) else null)
        else
            null;
        for (first..end) |i| {
            const c = commits[i];
            const selected = s.selected == i;
            const bg: clay.Color = if (selected) theme.primary else if (hovered_row == i) tint(theme.text, 20) else theme.bg;
            const fg = if (selected) theme.text_on_primary else theme.text;
            const dim = if (selected) theme.text_on_primary else theme.muted;
            // Zwei Zeilen: Betreff oben, Hash · Autor · Datum darunter. Beide gekürzt, denn Text
            // ohne Umbruch ist in Clay eine Mindestbreite und sprengte sonst die Liste.
            const room = width - 2 * ROW_PADDING_X;
            const meta = std.fmt.allocPrint(arena, "{s} · {s} · {s}", .{ c.short, c.author, c.date }) catch c.short;
            clay.UI()(.{
                .id = rowId(salt, i),
                .layout = .{
                    .sizing = .{ .w = .growMinMax(.{ .min = 0, .max = width }), .h = .fixed(ROW_HEIGHT) },
                    .direction = .top_to_bottom,
                    .child_alignment = .{ .y = .center },
                    .child_gap = 2,
                    .padding = .{ .left = ROW_PADDING_X, .right = ROW_PADDING_X },
                },
                .background_color = bg,
            })({
                clay.text(fitText(arena, c.subject, room, LIST_FONT), .{ .font_size = LIST_FONT, .color = fg, .wrap_mode = .none });
                clay.text(fitText(arena, meta, room, META_FONT), .{ .font_size = META_FONT, .color = dim, .wrap_mode = .none });
            });
        }
        spacer(@as(f32, @floatFromInt(commits.len - end)) * ROW_HEIGHT);
    }

    fn renderDiff(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32) void {
        const s = &self.state;
        const vp = diffViewport(salt);
        s.diff_scroll = git_history.clampScroll(s.diff_scroll, vp, DIFF_ROW_HEIGHT, s.diff_lines.len);
        const range = git_history.visibleRange(s.diff_scroll, if (vp > 0) vp else 800, DIFF_ROW_HEIGHT, s.diff_lines.len, OVERSCAN);
        self.rendered_diff_rows = 0;

        clay.UI()(.{
            .id = diffId(salt),
            .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
            .clip = .{ .vertical = true, .horizontal = true, .child_offset = .{ .x = 0, .y = -s.diff_scroll } },
        })({
            if (s.diff_lines.len == 0 or s.selectedCommit() == null) {
                const msg: []const u8 = if (s.selectedCommit() == null)
                    (if (s.commits().len == 0) " " else "Select a commit")
                else if (s.loading_diff) "Loading diff…" else "Empty diff";
                message(msg, theme);
            } else self.renderDiffRows(arena, theme, range.first, range.end);
        });
    }

    fn renderDiffRows(self: *Self, arena: std.mem.Allocator, theme: Theme, first: usize, end: usize) void {
        const s = &self.state;
        // Veralteter Diff (neuer ist unterwegs) bleibt stehen, aber gedämpft
        const stale = !s.diffShowsSelected();
        spacer(@as(f32, @floatFromInt(first)) * DIFF_ROW_HEIGHT);
        for (first..end) |i| {
            const line = s.diff_lines[i];
            const text = displayLine(arena, git_history.lineText(s.diff_text, line));
            const fg: clay.Color = if (stale or s.diff_failed) theme.muted else switch (line.kind) {
                .meta => theme.subtext,
                .file_header => theme.primary,
                .hunk => theme.accent,
                .added => theme.success,
                .removed => theme.danger,
                .context => theme.text,
            };
            const bg: clay.Color = switch (line.kind) {
                .added => tint(theme.success, 28),
                .removed => tint(theme.danger, 28),
                .file_header => tint(theme.primary, 16),
                else => .{ 0, 0, 0, 0 },
            };
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(DIFF_ROW_HEIGHT) },
                    .child_alignment = .{ .y = .center },
                    .padding = .{ .left = 10, .right = 10 },
                },
                .background_color = bg,
            })({
                clay.text(text, .{ .font_size = DIFF_FONT, .color = fg, .wrap_mode = .none });
            });
            self.rendered_diff_rows += 1;
        }
        spacer(@as(f32, @floatFromInt(s.diff_lines.len - end)) * DIFF_ROW_HEIGHT);
    }
};

fn message(text: []const u8, theme: Theme) void {
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow }, .padding = .all(16) } })({
        clay.text(text, .{ .font_size = LIST_FONT, .color = theme.muted, .wrap_mode = .words });
    });
}

/// Hinweis, wenn git keinen Commit liefert (z. B. Datei noch nie committet). Kurz halten:
/// die Liste ist schmal, und Clay bricht in der clippenden Liste nicht zuverlässig um.
pub fn emptyText(target: git_history.Target) []const u8 {
    return switch (target) {
        .repo => "No commits yet",
        .file => "Not committed yet",
    };
}

fn spacer(height: f32) void {
    if (height <= 0) return;
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(height) } } })({});
}

fn tint(c: clay.Color, alpha: f32) clay.Color {
    return .{ c[0], c[1], c[2], alpha };
}

/// Diff-Zeile für die Anzeige: gekürzt, Tabs als vier Leerzeichen, leer als ein Leerzeichen.
fn displayLine(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    const line = git_history.displaySlice(raw, MAX_LINE_BYTES);
    if (line.len == 0) return " ";
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return line;
    return std.mem.replaceOwned(u8, arena, line, "\t", "    ") catch line;
}

/// Text auf `max_width` Pixel kürzen (Monospace-Schrift: Zeichenbudget aus der Breite von "W").
fn fitText(arena: std.mem.Allocator, text: []const u8, max_width: f32, font: u16) []const u8 {
    const size: f32 = @floatFromInt(font);
    if (ui.measureTextWidth(text, size) <= max_width) return text;
    const char_w = ui.measureTextWidth("W", size);
    if (char_w <= 0 or max_width <= char_w) return "…";
    const budget: usize = @intFromFloat(max_width / char_w - 1);
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var n: usize = 0;
    while (n < budget) : (n += 1) {
        if (it.nextCodepointSlice() == null) return text;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{text[0..it.i]}) catch text;
}
