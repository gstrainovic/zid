//! Suche im Projekt in der Sidebar wie VS Code (searchView.ts): Kopf „SEARCH“ mit Refresh,
//! Clear und Collapse, Suchfeld mit den Umschaltern Aa / ab / .*, aufklappbares
//! Ersetzen-Feld, Meldung („5 results in 2 files“) und die Trefferliste je Datei.
//! Suchen, Gruppieren und Ersetzen auf Byte-Ebene liegen in `project_search.zig`; hier nur
//! Zustand der Felder, Eingaben und Zeichnen. Datei-Zugriffe (Öffnen, Ersetzen) macht die UI
//! über die zurückgegebene `Action`.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const ps = @import("project_search.zig");
const explorer_ops = @import("explorer_ops.zig");
const line_edit = @import("line_edit.zig");
const scrollbar = @import("scrollbar");
const git_list = @import("git_list");
const svg = @import("components/svg.zig");
const tooltip = @import("components/tooltip.zig");

pub const HEADER_HEIGHT: f32 = 30;
pub const ROW_HEIGHT: f32 = 22;
const INPUT_HEIGHT: f32 = 26;
const FONT: f32 = 15;
const DIM_FONT: f32 = 13;
const ACTION_SIZE: f32 = 20;
const SCROLLBAR_W: f32 = 10;
/// Einrückung der Trefferzeilen unter dem Dateikopf
const MATCH_INDENT: f32 = 28;
/// Zeichen vor dem Treffer in der Vorschau, „…“ mitgezählt (VS Code zeigt ähnlich viel)
const PREVIEW_BEFORE: usize = 26;
/// Suche beim Tippen erst nach dieser Pause (VS Code search.searchOnTypeDebouncePeriod)
pub const DEBOUNCE_MS: f32 = 300;

const query_field: line_edit.Config = .{ .id = "ps_query", .font_size = FONT };
const replace_field: line_edit.Config = .{ .id = "ps_replace", .font_size = FONT };

pub const Focus = enum { none, query, replace, list };

/// Aktionen beim Überfahren einer Zeile (Reihenfolge = Index in der Clay-ID `ps_act`).
pub const RowAction = enum { replace, dismiss };

pub const Action = union(enum) {
    none,
    consumed,
    /// Escape: Fokus zurück an den Editor
    leave,
    /// Suche jetzt starten (Enter, Umschalter, Refresh)
    search_now,
    open: ps.MatchRef,
    replace_match: ps.MatchRef,
    replace_file: u32,
    /// UI fragt vorher nach (VS Code: „Replace N occurrences across M files?“)
    replace_all,
};

pub const Mods = struct { ctrl: bool = false, shift: bool = false, alt: bool = false };

pub const SearchView = struct {
    alloc: std.mem.Allocator,
    query: explorer_ops.EditBuffer(512) = .{},
    replace: explorer_ops.EditBuffer(512) = .{},
    replace_open: bool = false,
    opts: ps.Options = .{},
    focus: Focus = .none,
    results: ps.Results,
    runner: ps.Runner,
    selected: ?usize = null,
    hover_row: ?usize = null,
    scroll: f32 = 0,
    scrollbar_drag: ?scrollbar.Drag = null,
    /// Suche fällig ab diesem Zeitpunkt (UI-Uhr), gesetzt beim Tippen
    due_ms: ?f32 = null,
    /// Neue Suche läuft: alte Treffer bleiben stehen, bis die ersten neuen da sind (kein Flackern)
    pending_clear: bool = false,
    /// Lauf gestartet, Ende noch nicht in `results` übernommen
    running: bool = false,
    /// Es wurde gesucht (sonst keine Meldung „No results found.“)
    searched: bool = false,
    /// Ersatztext der laufenden Suche lag vor (Vorschau zeigt den Ersatz)
    searched_with_replace: bool = false,
    /// Lage der Liste im letzten Frame (Treffertest, Scrollbalken)
    body: ?clay.BoundingBox = null,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc, .results = ps.Results.init(alloc), .runner = ps.Runner.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        self.runner.deinit();
        self.results.deinit();
    }

    // ───────────────────────── Suche ─────────────────────────

    pub fn queryText(self: *const Self) []const u8 {
        return self.query.text();
    }

    pub fn replaceText(self: *const Self) []const u8 {
        return self.replace.text();
    }

    /// Ctrl+Shift+F / Ctrl+Shift+H: Panel zeigen, Fokus ins Feld. `seed` ist die Auswahl im
    /// Editor (VS Code search.seedWithNearestWord / seedOnFocus), ersetzt den Suchbegriff.
    pub fn focusQuery(self: *Self, seed: ?[]const u8, now_ms: f32) void {
        if (seed) |s| if (s.len > 0 and std.mem.indexOfScalar(u8, s, '\n') == null and !std.mem.eql(u8, s, self.queryText())) {
            self.query.set(s);
            self.requestSearch(now_ms, 0);
        };
        self.query.selectAll();
        self.focus = .query;
    }

    pub fn focusReplace(self: *Self, seed: ?[]const u8, now_ms: f32) void {
        self.focusQuery(seed, now_ms);
        if (!self.replace_open) {
            self.replace_open = true;
            if (self.replaceText().len > 0) self.requestSearch(now_ms, 0);
        }
        self.replace.selectAll();
        self.focus = .replace;
    }

    fn requestSearch(self: *Self, now_ms: f32, delay: f32) void {
        self.due_ms = now_ms + delay;
    }

    /// Ist eine Suche fällig? Die UI ruft dann `start` mit Ordner, rg und offenen Buffern.
    pub fn searchDue(self: *Self, now_ms: f32) bool {
        const due = self.due_ms orelse return false;
        if (now_ms < due) return false;
        self.due_ms = null;
        return true;
    }

    pub fn start(self: *Self, rg: []const u8, root: []const u8, dirty: []const ps.DirtyBuffer) void {
        self.due_ms = null;
        if (self.queryText().len == 0) {
            self.runner.cancel();
            self.results.clear();
            self.selected = null;
            self.searched = false;
            self.pending_clear = false;
            self.running = false;
            return;
        }
        const with_replace = self.replace_open and self.replaceText().len > 0;
        self.runner.start(.{
            .rg = rg,
            .root = root,
            .text = self.queryText(),
            .replace = if (with_replace) self.replaceText() else null,
            .opts = self.opts,
            .dirty = dirty,
        }) catch {
            self.results.clear();
            return;
        };
        self.searched = true;
        self.searched_with_replace = with_replace;
        self.pending_clear = true;
        self.running = true;
    }

    /// Pro Frame: neue Treffer übernehmen.
    pub fn update(self: *Self) void {
        if (self.pending_clear) {
            if (!self.runner.hasOutput()) return;
            self.results.clear();
            self.pending_clear = false;
            self.scroll = 0;
            self.hover_row = null;
            // Auswahl bleibt als Index stehen, wenn die Liste neu kommt (nach Ersetzen weiter unten)
        }
        const p = self.runner.poll(&self.results);
        if (p.changed or p.finished) self.results.rebuildRows() catch {};
        if (p.finished) self.running = false;
        self.clampSelection();
    }

    /// Sucht, bis `update` das Ende des Laufs samt letztem Stapel übernommen hat. Nur auf
    /// `Runner.running` zu schauen, meldete „fertig“, während der letzte Stapel noch im Runner
    /// lag (ein RPC im selben Frame sah dann 16 820 statt 20 000 Treffer).
    pub fn searching(self: *Self) bool {
        return self.due_ms != null or self.running;
    }

    pub fn clear(self: *Self) void {
        self.query.set("");
        self.replace.set("");
        self.runner.cancel();
        self.results.clear();
        self.selected = null;
        self.searched = false;
        self.pending_clear = false;
        self.running = false;
        self.due_ms = null;
        self.scroll = 0;
    }

    fn clampSelection(self: *Self) void {
        const n = self.results.rows.items.len;
        if (self.selected) |s| {
            if (n == 0) self.selected = null else if (s >= n) self.selected = n - 1;
        }
    }

    /// Meldung unter den Feldern (VS Code searchView: „N results in M files“).
    pub fn message(self: *Self, buf: []u8) []const u8 {
        if (self.runner.errorText()) |e| return e;
        const n = self.results.match_count;
        const files = self.results.files.items.len;
        if (n == 0) {
            if (self.searched and !self.searching()) return "No results found.";
            return "";
        }
        const text = std.fmt.bufPrint(buf, "{d} {s} in {d} {s}{s}", .{
            n,
            if (n == 1) "result" else "results",
            files,
            if (files == 1) "file" else "files",
            if (self.runner.limitHit()) " - The result set only contains a subset of all matches." else "",
        }) catch "";
        return text;
    }

    pub fn selectedRow(self: *const Self) ?ps.Row {
        const s = self.selected orelse return null;
        if (s >= self.results.rows.items.len) return null;
        return self.results.rows.items[s];
    }

    fn fileOfRow(row: ps.Row) u32 {
        return switch (row) {
            .file => |f| f,
            .match => |m| m.file,
        };
    }

    fn rowIndexOfFile(self: *const Self, file: u32) ?usize {
        for (self.results.rows.items, 0..) |r, i| if (r == .file and r.file == file) return i;
        return null;
    }

    // ───────────────────────── Tastatur ─────────────────────────

    pub fn handleKey(self: *Self, key: wio.Button, mods: Mods, clip: ?line_edit.Clipboard, now_ms: f32) Action {
        if (key == .escape) return .leave;
        // Umschalter wie VS Code: Alt+C Groß/Klein, Alt+W ganzes Wort, Alt+R Regex
        if (mods.alt and !mods.ctrl) switch (key) {
            .c => return self.toggleOption(.case),
            .w => return self.toggleOption(.word),
            .r => return self.toggleOption(.regex),
            else => {},
        };
        // Ctrl+Alt+Enter: alle ersetzen (VS Code search.action.replaceAll)
        if (mods.ctrl and mods.alt and (key == .enter or key == .kp_enter)) {
            return if (self.replace_open and self.results.match_count > 0) .replace_all else .consumed;
        }
        return switch (self.focus) {
            .query, .replace => self.handleFieldKey(key, mods, clip, now_ms),
            .list => self.handleListKey(key, mods),
            .none => .none,
        };
    }

    const Option = enum { case, word, regex };

    fn toggleOption(self: *Self, o: Option) Action {
        switch (o) {
            .case => self.opts.case_sensitive = !self.opts.case_sensitive,
            .word => self.opts.whole_word = !self.opts.whole_word,
            .regex => self.opts.regex = !self.opts.regex,
        }
        return .search_now;
    }

    fn handleFieldKey(self: *Self, key: wio.Button, mods: Mods, clip: ?line_edit.Clipboard, now_ms: f32) Action {
        const in_query = self.focus == .query;
        switch (key) {
            .enter, .kp_enter => return .search_now,
            .tab => {
                self.focus = if (mods.shift)
                    (if (in_query) .list else .query)
                else if (in_query and self.replace_open) .replace else .list;
                if (self.focus == .list) self.selectFirstMatch();
                return .consumed;
            },
            .down => {
                if (self.results.rows.items.len == 0) return .consumed;
                self.focus = .list;
                self.selectFirstMatch();
                return .consumed;
            },
            .up => {
                if (!in_query) self.focus = .query;
                return .consumed;
            },
            else => {},
        }
        const edit_mods: line_edit.Mods = .{ .ctrl = mods.ctrl, .shift = mods.shift };
        const res = if (in_query)
            line_edit.handleKey(&self.query, key, edit_mods, clip)
        else
            line_edit.handleKey(&self.replace, key, edit_mods, clip);
        if (res == .edited) self.requestSearch(now_ms, DEBOUNCE_MS);
        return if (res == .ignored) .none else .consumed;
    }

    fn selectFirstMatch(self: *Self) void {
        for (self.results.rows.items, 0..) |r, i| if (r == .match) {
            self.select(i);
            return;
        };
        if (self.results.rows.items.len > 0) self.select(0);
    }

    fn select(self: *Self, i: usize) void {
        self.selected = i;
        self.ensureVisible(i);
    }

    fn ensureVisible(self: *Self, i: usize) void {
        const vp = if (self.body) |b| b.height else return;
        self.scroll = git_list.clampScroll(git_list.scrollToShow(self.scroll, vp, ROW_HEIGHT, i), vp, ROW_HEIGHT, self.results.rows.items.len);
    }

    fn pageRows(self: *const Self) usize {
        const vp = if (self.body) |b| b.height else 10 * ROW_HEIGHT;
        return @max(1, @as(usize, @intFromFloat(vp / ROW_HEIGHT)) -| 1);
    }

    fn handleListKey(self: *Self, key: wio.Button, mods: Mods) Action {
        const n = self.results.rows.items.len;
        if (key == .tab) {
            self.focus = if (mods.shift and self.replace_open) .replace else .query;
            return .consumed;
        }
        if (n == 0) return .consumed;
        const cur = self.selected orelse 0;
        // Ctrl+Shift+1: ersetzen (VS Code search.action.replace / replaceAllInFile)
        if (mods.ctrl and mods.shift and key == .@"1") {
            if (!self.replace_open) return .consumed;
            const row = self.selectedRow() orelse return .consumed;
            return switch (row) {
                .file => |f| .{ .replace_file = f },
                .match => |m| .{ .replace_match = m },
            };
        }
        if (mods.ctrl or mods.alt) return .consumed;
        switch (key) {
            .up => {
                if (cur == 0) {
                    self.focus = .query;
                    return .consumed;
                }
                self.select(cur - 1);
            },
            .down => self.select(@min(cur + 1, n - 1)),
            .page_up => self.select(cur -| self.pageRows()),
            .page_down => self.select(@min(cur + self.pageRows(), n - 1)),
            .home => self.select(0),
            .end => self.select(n - 1),
            .enter, .kp_enter, .space => {
                const row = self.selectedRow() orelse return .consumed;
                switch (row) {
                    .file => |f| self.toggleFile(f),
                    .match => |m| return .{ .open = m },
                }
            },
            .left => {
                const row = self.selectedRow() orelse return .consumed;
                const f = fileOfRow(row);
                if (!self.results.files.items[f].collapsed) self.results.toggleCollapsed(f) catch {};
                if (self.rowIndexOfFile(f)) |i| self.select(i);
            },
            .right => {
                const row = self.selectedRow() orelse return .consumed;
                if (row == .file and self.results.files.items[row.file].collapsed) self.results.toggleCollapsed(row.file) catch {};
            },
            .delete, .backspace => self.dismissSelected(),
            else => return .none,
        }
        return .consumed;
    }

    fn toggleFile(self: *Self, f: u32) void {
        self.results.toggleCollapsed(f) catch {};
        if (self.rowIndexOfFile(f)) |i| self.select(i);
    }

    fn dismissSelected(self: *Self) void {
        const row = self.selectedRow() orelse return;
        switch (row) {
            .file => |f| self.results.dismissFile(f) catch {},
            .match => |m| self.results.dismissMatch(m) catch {},
        }
        self.clampSelection();
    }

    pub fn handleChar(self: *Self, cp: u21, now_ms: f32) void {
        if (cp < 0x20 or cp == 0x7f) return;
        switch (self.focus) {
            .query => self.query.insertCodepoint(cp),
            .replace => self.replace.insertCodepoint(cp),
            else => return,
        }
        self.requestSearch(now_ms, DEBOUNCE_MS);
    }

    // ───────────────────────── Maus ─────────────────────────

    fn box(id: clay.ElementId) ?clay.BoundingBox {
        const d = clay.getElementData(id);
        return if (d.found) d.bounding_box else null;
    }

    fn inside(b: clay.BoundingBox, x: f32, y: f32) bool {
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    fn hit(id: clay.ElementId, x: f32, y: f32) bool {
        return if (box(id)) |b| inside(b, x, y) else false;
    }

    fn actionId(row: usize, a: RowAction) clay.ElementId {
        return clay.ElementId.IDI("ps_act", @intCast(row * 4 + @intFromEnum(a)));
    }

    fn rowAt(self: *const Self, x: f32, y: f32) ?usize {
        const b = self.body orelse return null;
        if (!inside(b, x, y)) return null;
        const i: usize = @intFromFloat(@max(0, (y - b.y + self.scroll) / ROW_HEIGHT));
        return if (i < self.results.rows.items.len) i else null;
    }

    /// Aktionen einer Zeile beim Überfahren: Ersetzen nur mit offenem Ersetzen-Feld.
    fn rowActions(self: *const Self) []const RowAction {
        return if (self.replace_open) &.{ .replace, .dismiss } else &.{.dismiss};
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, shift: bool, now_ms: f32) Action {
        if (hit(clay.ElementId.ID("ps_btn_refresh"), x, y)) return .search_now;
        if (hit(clay.ElementId.ID("ps_btn_clear"), x, y)) {
            self.clear();
            self.focus = .query;
            return .consumed;
        }
        if (hit(clay.ElementId.ID("ps_btn_collapse"), x, y)) {
            self.results.setAllCollapsed(!self.allCollapsed()) catch {};
            self.clampSelection();
            return .consumed;
        }
        if (hit(clay.ElementId.ID("ps_btn_toggle_replace"), x, y)) {
            self.replace_open = !self.replace_open;
            self.focus = if (self.replace_open) .replace else .query;
            if (self.replaceText().len > 0) self.requestSearch(now_ms, 0);
            return .consumed;
        }
        if (hit(clay.ElementId.ID("ps_opt_case"), x, y)) return self.toggleOption(.case);
        if (hit(clay.ElementId.ID("ps_opt_word"), x, y)) return self.toggleOption(.word);
        if (hit(clay.ElementId.ID("ps_opt_regex"), x, y)) return self.toggleOption(.regex);
        if (hit(clay.ElementId.ID("ps_btn_replace_all"), x, y)) {
            return if (self.results.match_count > 0) .replace_all else .consumed;
        }
        if (hit(clay.ElementId.ID("ps_query_box"), x, y)) {
            self.focus = .query;
            _ = line_edit.handleClick(&self.query, query_field, x, shift);
            return .consumed;
        }
        if (hit(clay.ElementId.ID("ps_replace_box"), x, y)) {
            self.focus = .replace;
            _ = line_edit.handleClick(&self.replace, replace_field, x, shift);
            return .consumed;
        }
        if (self.scrollModel()) |m| switch (scrollbar.hitTest(m, x, y)) {
            .none => {},
            .thumb => |d| {
                self.scrollbar_drag = d;
                return .consumed;
            },
            else => |h| {
                self.scroll = @floatFromInt(scrollbar.pageOffset(m, h));
                return .consumed;
            },
        };
        const i = self.rowAt(x, y) orelse return .consumed;
        self.focus = .list;
        const row = self.results.rows.items[i];
        if (self.hover_row == i) for (self.rowActions()) |a| {
            if (!hit(actionId(i, a), x, y)) continue;
            return switch (a) {
                .dismiss => blk: {
                    self.selected = i;
                    self.dismissSelected();
                    break :blk .consumed;
                },
                .replace => switch (row) {
                    .file => |f| .{ .replace_file = f },
                    .match => |m| .{ .replace_match = m },
                },
            };
        };
        self.selected = i;
        return switch (row) {
            .file => |f| blk: {
                self.toggleFile(f);
                break :blk .consumed;
            },
            .match => |m| .{ .open = m },
        };
    }

    fn allCollapsed(self: *const Self) bool {
        for (self.results.files.items) |f| if (!f.collapsed) return false;
        return self.results.files.items.len > 0;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        self.hover_row = self.rowAt(x, y);
        line_edit.handleDrag(&self.query, query_field, x);
        line_edit.handleDrag(&self.replace, replace_field, x);
        if (self.scrollbar_drag) |d| if (self.scrollModel()) |m| {
            self.scroll = @floatFromInt(scrollbar.dragOffset(m, d, x, y));
        };
    }

    pub fn handleMouseUp(self: *Self) void {
        self.scrollbar_drag = null;
        line_edit.handleRelease(&self.query);
        line_edit.handleRelease(&self.replace);
    }

    pub fn contains(self: *const Self, x: f32, y: f32) bool {
        _ = self;
        return hit(clay.ElementId.ID("ps_section"), x, y);
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        const vp = if (self.body) |b| b.height else return;
        self.scroll = git_list.clampScroll(self.scroll - @as(f32, @floatFromInt(delta * 3)) * ROW_HEIGHT, vp, ROW_HEIGHT, self.results.rows.items.len);
    }

    /// Balken in Pixeln rechts an der Liste; null ohne Scrollbedarf.
    fn scrollModel(self: *const Self) ?scrollbar.Model {
        const b = self.body orelse return null;
        const content = @as(f32, @floatFromInt(self.results.rows.items.len)) * ROW_HEIGHT;
        const over = content - b.height;
        if (over <= 0.5 or b.height <= 0) return null;
        return .{
            .axis = .vertical,
            .x = b.x + b.width - SCROLLBAR_W,
            .y = b.y,
            .len = b.height,
            .thickness = SCROLLBAR_W,
            .total = @intFromFloat(@round(content)),
            .visible = @intFromFloat(@round(b.height)),
            .offset = @intFromFloat(@round(@max(0, self.scroll))),
            .max_offset = @intFromFloat(@round(over)),
        };
    }

    // ───────────────────────── Zeichnen ─────────────────────────

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, mouse_x: f32, mouse_y: f32, focused: bool) void {
        const header_hover = hit(clay.ElementId.ID("ps_header"), mouse_x, mouse_y);
        clay.UI()(.{
            .id = clay.ElementId.ID("ps_section"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .top_to_bottom },
            .background_color = theme.surface,
            .border = .{ .width = .{ .right = 1 }, .color = theme.border },
        })({
            self.renderHeader(arena, theme, width, header_hover);
            self.renderInputs(arena, theme, focused);
            var msg_buf: [160]u8 = undefined;
            const msg = self.message(&msg_buf);
            clay.UI()(.{ .id = clay.ElementId.ID("ps_message"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(if (msg.len > 0) 22 else 4) }, .padding = .{ .left = 12, .right = 8 }, .child_alignment = .{ .y = .center } } })({
                if (msg.len > 0) {
                    const is_err = self.runner.errorText() != null;
                    clay.text(fitText(arena, arena.dupe(u8, msg) catch "", width - 20, DIM_FONT), .{ .font_size = @intFromFloat(DIM_FONT), .color = if (is_err) theme.warning else theme.subtext, .wrap_mode = .none });
                }
            });
            self.renderList(arena, theme, width, focused);
        });
    }

    fn renderHeader(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, hover: bool) void {
        clay.UI()(.{
            .id = clay.ElementId.ID("ps_header"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(HEADER_HEIGHT) }, .child_alignment = .{ .y = .center }, .child_gap = 4, .padding = .{ .left = 12, .right = 6 } },
        })({
            const actions_w: f32 = if (hover) 3 * 24 + 3 * 4 else 0;
            clay.text(fitText(arena, "SEARCH", width - 18 - actions_w, 14), .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            if (hover) {
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_btn_refresh"), "ps_btn_refresh_icon", svg.Lucide.refresh_cw, "Refresh", .{});
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_btn_clear"), "ps_btn_clear_icon", svg.Lucide.list_x, "Clear Search Results", .{});
                const collapsed = self.allCollapsed();
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_btn_collapse"), "ps_btn_collapse_icon", if (collapsed) svg.Lucide.chevrons_up_down else svg.Lucide.chevrons_down_up, if (collapsed) "Expand All" else "Collapse All", .{});
            }
        });
    }

    fn renderInputs(self: *Self, arena: std.mem.Allocator, theme: Theme, focused: bool) void {
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .{ .left = 4, .right = 10, .bottom = 4 }, .child_gap = 2 } })({
            // Chevron links klappt das Ersetzen-Feld auf (VS Code „Toggle Replace“)
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(18), .h = .fit }, .direction = .top_to_bottom } })({
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_btn_toggle_replace"), "ps_btn_toggle_replace_icon", if (self.replace_open) svg.Lucide.chevron_down else svg.Lucide.chevron_right, "Toggle Replace", .{ .size = 18, .icon_size = 14 });
            });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 4 } })({
                self.renderField(arena, theme, .query, focused);
                if (self.replace_open) self.renderField(arena, theme, .replace, focused);
            });
        });
    }

    fn renderField(self: *Self, arena: std.mem.Allocator, theme: Theme, which: Focus, focused: bool) void {
        const is_query = which == .query;
        const active = focused and self.focus == which;
        const id = clay.ElementId.ID(if (is_query) "ps_query_box" else "ps_replace_box");
        clay.UI()(.{
            .id = id,
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(INPUT_HEIGHT) }, .padding = .{ .left = 6, .right = 2 }, .child_alignment = .{ .y = .center }, .child_gap = 2 },
            .clip = .{ .horizontal = true },
            .background_color = theme.bg,
            .border = .{ .width = .all(1), .color = if (active) theme.border_focus else theme.border },
            .corner_radius = .all(3),
        })({
            const empty = if (is_query) self.queryText().len == 0 else self.replaceText().len == 0;
            if (empty and !active) {
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({
                    clay.text(if (is_query) "Search" else "Replace", .{ .font_size = @intFromFloat(FONT), .color = theme.muted, .wrap_mode = .none });
                });
            } else if (is_query) {
                line_edit.render(&self.query, query_field, theme.text, active, theme);
            } else {
                line_edit.render(&self.replace, replace_field, theme.text, active, theme);
            }
            const o: tooltip.Options = .{ .size = 20, .icon_size = 14 };
            if (is_query) {
                var t = o;
                t.toggled = self.opts.case_sensitive;
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_opt_case"), "ps_opt_case_icon", svg.Lucide.case_sensitive, "Match Case (Alt+C)", t);
                t.toggled = self.opts.whole_word;
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_opt_word"), "ps_opt_word_icon", svg.Lucide.whole_word, "Match Whole Word (Alt+W)", t);
                t.toggled = self.opts.regex;
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_opt_regex"), "ps_opt_regex_icon", svg.Lucide.regex, "Use Regular Expression (Alt+R)", t);
            } else {
                tooltip.iconButton(arena, theme, clay.ElementId.ID("ps_btn_replace_all"), "ps_btn_replace_all_icon", svg.Lucide.replace_all, "Replace All (Ctrl+Alt+Enter)", o);
            }
        });
    }

    fn renderList(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, focused: bool) void {
        const count = self.results.rows.items.len;
        const vp = if (self.body) |b| b.height else 0;
        self.scroll = git_list.clampScroll(self.scroll, vp, ROW_HEIGHT, count);
        const range = git_list.visibleRange(self.scroll, @max(vp, 400), ROW_HEIGHT, count, 4);
        const body_id = clay.ElementId.ID("ps_body");
        clay.UI()(.{
            .id = body_id,
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .top_to_bottom },
            .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -self.scroll } },
        })({
            spacer(@as(f32, @floatFromInt(range.first)) * ROW_HEIGHT);
            for (range.first..range.end) |i| self.renderRow(arena, theme, width, i, focused);
            spacer(@as(f32, @floatFromInt(count - range.end)) * ROW_HEIGHT);
            if (self.scrollModel()) |m| {
                _ = scrollbar.render(m, .{ .track = clay.ElementId.ID("ps_scrollbar_track"), .thumb = clay.ElementId.ID("ps_scrollbar_thumb") });
            }
        });
        self.body = box(body_id);
    }

    fn renderRow(self: *Self, arena: std.mem.Allocator, theme: Theme, width: f32, i: usize, focused: bool) void {
        const row = self.results.rows.items[i];
        const selected = self.selected == i;
        const hovered = self.hover_row == i;
        const strong = selected and focused and self.focus == .list;
        const bg: clay.Color = if (strong) theme.primary else if (selected) mix(theme.surface, theme.primary, 0.35) else if (hovered) mix(theme.surface, theme.text, 0.08) else theme.surface;
        const fg = if (strong) theme.text_on_primary else theme.text;
        const dim = if (strong) theme.text_on_primary else theme.muted;
        const actions = self.rowActions();
        const actions_w: f32 = if (hovered) @as(f32, @floatFromInt(actions.len)) * (ACTION_SIZE + 2) else 0;
        const scroll_w: f32 = if (self.scrollModel() != null) SCROLLBAR_W else 0;
        const indent: f32 = if (row == .file) 4 else MATCH_INDENT;
        const inner = width - indent - 8 - actions_w - scroll_w;

        clay.UI()(.{
            .id = clay.ElementId.IDI("ps_row", @intCast(i)),
            .layout = .{
                // Obergrenze: Text ohne Umbruch meldet sonst seine volle Breite als Mindestmaß
                .sizing = .{ .w = .growMinMax(.{ .min = 0, .max = @max(0, width - scroll_w) }), .h = .fixed(ROW_HEIGHT) },
                .child_alignment = .{ .y = .center },
                // Trefferzeilen setzen Vorlauf, Treffer und Rest lückenlos aneinander
                .child_gap = if (row == .file) 4 else 0,
                .padding = .{ .left = @intFromFloat(indent), .right = @intFromFloat(8 + scroll_w) },
            },
            .background_color = bg,
        })({
            switch (row) {
                .file => |f| {
                    const file = self.results.files.items[f];
                    svg.Svg(arena, std.fmt.allocPrint(arena, "ps_chev_{d}", .{i}) catch "ps_chev", if (file.collapsed) svg.Lucide.chevron_right else svg.Lucide.chevron_down, 16, fg);
                    const name = std.fs.path.basename(file.path);
                    const dir = std.fs.path.dirname(file.path) orelse "";
                    const badge = std.fmt.allocPrint(arena, "{d}", .{file.count}) catch "";
                    const badge_w = ui.measureTextWidth(badge, 12) + 12;
                    const room = inner - 20 - badge_w - 8;
                    const label = fitText(arena, name, room, FONT);
                    clay.text(label, .{ .font_size = @intFromFloat(FONT), .color = fg, .wrap_mode = .none });
                    if (dir.len > 0) clay.text(fitText(arena, dir, room - ui.measureTextWidth(label, FONT) - 6, DIM_FONT), .{ .font_size = @intFromFloat(DIM_FONT), .color = dim, .wrap_mode = .none });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                    if (hovered) self.renderActions(arena, theme, i, actions, fg, true);
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fit, .h = .fixed(16) }, .child_alignment = .{ .x = .center, .y = .center }, .padding = .{ .left = 6, .right = 6 } }, .background_color = if (strong) theme.text_on_primary else theme.overlay, .corner_radius = .all(8) })({
                        clay.text(badge, .{ .font_size = 12, .color = if (strong) theme.primary else theme.text, .wrap_mode = .none });
                    });
                },
                .match => |m| {
                    const line = self.results.files.items[m.file].lines.items[m.line];
                    const sub = line.subs[m.sub];
                    const p = ps.preview(line.line, sub, PREVIEW_BEFORE);
                    const rep: ?[]const u8 = if (self.searched_with_replace and self.replace_open) (sub.replacement orelse self.replaceText()) else null;
                    var room = inner;
                    if (p.elided) {
                        clay.text("…", .{ .font_size = @intFromFloat(FONT), .color = dim, .wrap_mode = .none });
                        room -= ui.measureTextWidth("…", FONT);
                    }
                    const before = fitText(arena, p.before, room, FONT);
                    if (before.len > 0) clay.text(before, .{ .font_size = @intFromFloat(FONT), .color = fg, .wrap_mode = .none });
                    room -= ui.measureTextWidth(before, FONT);
                    // Treffer hinterlegt; mit Ersatz: alt rot und durchgestrichen, neu grün
                    const hl: clay.Color = if (rep != null) tint(theme.git_deleted, 70) else tint(theme.primary, if (strong) 120 else 80);
                    const shown_match = fitText(arena, p.match, room, FONT);
                    const match_w = ui.measureTextWidth(shown_match, FONT);
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fit, .h = .fixed(ROW_HEIGHT - 4) }, .child_alignment = .{ .y = .center } }, .background_color = hl, .corner_radius = .all(2) })({
                        clay.text(shown_match, .{ .font_size = @intFromFloat(FONT), .color = fg, .wrap_mode = .none });
                        if (rep != null) {
                            clay.UI()(.{
                                .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_center, .parent = .left_center }, .pointer_capture_mode = .passthrough },
                                .layout = .{ .sizing = .{ .w = .fixed(match_w), .h = .fixed(1) } },
                                .background_color = fg,
                            })({});
                        }
                    });
                    room -= match_w;
                    if (rep) |r| {
                        const shown_rep = fitText(arena, r, room, FONT);
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fit, .h = .fixed(ROW_HEIGHT - 4) }, .child_alignment = .{ .y = .center } }, .background_color = tint(theme.git_added, 70), .corner_radius = .all(2) })({
                            clay.text(shown_rep, .{ .font_size = @intFromFloat(FONT), .color = fg, .wrap_mode = .none });
                        });
                        room -= ui.measureTextWidth(shown_rep, FONT);
                    }
                    const after = fitText(arena, p.after, room, FONT);
                    if (after.len > 0) clay.text(after, .{ .font_size = @intFromFloat(FONT), .color = fg, .wrap_mode = .none });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                    if (hovered) self.renderActions(arena, theme, i, actions, fg, false);
                },
            }
        });
    }

    fn renderActions(self: *Self, arena: std.mem.Allocator, theme: Theme, i: usize, actions: []const RowAction, fg: clay.Color, file_row: bool) void {
        _ = self;
        for (actions) |a| {
            const id = actionId(i, a);
            clay.UI()(.{ .id = id, .layout = .{ .sizing = .{ .w = .fixed(ACTION_SIZE), .h = .fixed(ACTION_SIZE) }, .child_alignment = .{ .x = .center, .y = .center } } })({
                const icon = switch (a) {
                    .replace => if (file_row) svg.Lucide.replace_all else svg.Lucide.replace,
                    .dismiss => svg.Lucide.x,
                };
                svg.SvgStroke(arena, std.fmt.allocPrint(arena, "ps_aicon_{d}_{d}", .{ i, @intFromEnum(a) }) catch "ps_aicon", icon, 14, fg);
                tooltip.attach(theme, id, switch (a) {
                    .replace => if (file_row) "Replace All (Ctrl+Shift+1)" else "Replace (Ctrl+Shift+1)",
                    .dismiss => "Dismiss (Delete)",
                });
            });
        }
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

/// Text auf `max_width` kürzen (gemessen, „…“ am Ende). Kopie in der Arena nur beim Kürzen.
fn fitText(arena: std.mem.Allocator, text: []const u8, max_width: f32, size: f32) []const u8 {
    if (max_width <= 0) return "";
    if (ui.measureTextWidth(text, size) <= max_width) return text;
    const ell = "…";
    var lo: usize = 0;
    var hi: usize = text.len;
    // Binärsuche über Bytegrenzen, danach auf den Zeichenanfang zurück
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        var cut = mid;
        while (cut > 0 and cut < text.len and (text[cut] & 0xC0) == 0x80) cut -= 1;
        const w = ui.measureTextWidth(text[0..cut], size) + ui.measureTextWidth(ell, size);
        if (w <= max_width) lo = mid else hi = mid - 1;
    }
    var cut = lo;
    while (cut > 0 and cut < text.len and (text[cut] & 0xC0) == 0x80) cut -= 1;
    if (cut == 0) return "";
    return std.fmt.allocPrint(arena, "{s}{s}", .{ text[0..cut], ell }) catch text[0..cut];
}
