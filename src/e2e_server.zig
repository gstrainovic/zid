//! E2E Test JSON-RPC Server für zid
//!
//! Erlaubt programmatische Steuerung der App während sie läuft.
//! Starten mit: ./zid --e2e
//!
//! Commands:
//!   open_folder(path)  - Ordner im File Explorer öffnen (direkt, ohne UI)
//!   element_bounds(id) - Bounding-Box eines Clay-Elements per String-ID
//!   element_bounds_i(id, index) - dito für indexierte IDs (IDI)
//!   folder_picker_state() - Zustand des "Open Folder…"-Dialogs
//!   ui_state()         - Dialog/Menü/Fokus/Tabs (zuverlässig, element_bounds kann veraltet sein)
//!   click(x, y)        - Maus-Klick an Koordinate
//!   get_state()        - App-State zurückgeben
//!   shutdown()         - App beenden

const std = @import("std");
const zigjr = @import("zigjr");
const clay = @import("clay");
// const zigimg = @import("zigimg");
const ui_mod = @import("ui/mod.zig");
const explorer_ops = @import("ui/explorer_ops.zig");

const log = std.log.scoped(.e2e_server);

const PORT = 9999;

const Point = struct { x: f32, y: f32 };

/// Eingabe-Ereignis aus einem RPC. Im Fenstermodus wird es nicht im Server-Thread
/// angewendet, sondern vom Main-Thread vor dem Rendern (drainInputs), sonst
/// rennt der Handler in einen laufenden Clay-Layout-Durchgang (Absturz).
pub const InputEvent = union(enum) {
    click: Point,
    /// Klick mit gehaltenen Modifiern (Shift-Klick erweitert Auswahl, Ctrl-Klick springt zur Definition)
    click_mods: struct { x: f32, y: f32, ctrl: bool, shift: bool },
    right_click: Point,
    middle_click: Point,
    /// Drücken/Loslassen getrennt (Drag & Drop)
    press: Point,
    release: Point,
    move: Point,
    /// hold: Modifier nach der Taste gedrückt lassen (Ctrl+Tab-Umschalter), bis `mods_release`
    key: struct { btn: @import("wio").Button, ctrl: bool, shift: bool = false, alt: bool = false, hold: bool = false },
    mods_release,
    char: u21,
    /// Mausrad an Position: lines > 0 hoch, < 0 runter
    scroll: struct { x: f32, y: f32, lines: i32 },
    /// Datei in der aktiven Tab-Leiste öffnen (Pfad gehört dem Ereignis, `applyInput` gibt ihn frei)
    open_file: []const u8,
    /// Explorer-Wurzel wechseln (Pfad gehört dem Ereignis). Muss im Main-Thread laufen:
    /// `loadDirectory` leert `nodes` und `visible_entries`, ein gleichzeitiges Render
    /// fiel mit „index out of bounds“ in `renderTreeEntry` (flaky in e2e_timeline.py).
    open_folder: []const u8,
};

/// E2E Server Context - teilt State mit Main Thread
pub const E2EContext = struct {
    allocator: std.mem.Allocator,
    ui_system: *ui_mod.UI,
    shutdown_flag: std.atomic.Value(bool),
    server: std.net.Server,
    /// true im Fenstermodus: Eingaben werden gepuffert statt direkt angewendet.
    defer_input: bool = false,
    input_mutex: std.Thread.Mutex = .{},
    pending_inputs: std.ArrayListUnmanaged(InputEvent) = .empty,
    /// Fenstermodus: Screenshot wird vom Main-Thread nach dem nächsten Frame geschrieben.
    screenshot_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    screenshot_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    screenshot_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Zustand der PDF-Vorschau, vom Main-Thread pro Frame gesetzt: der
    /// Server-Thread darf weder Tabs noch die Handler-Map anfassen.
    pdf_page: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pdf_pages: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// JSON des aktiven Diff-Editors, vom Main-Thread pro Frame geschrieben (`snapshotGitViews`):
    /// die Ansicht tauscht Inhalte aus, der Server-Thread darf sie nicht direkt lesen.
    git_views_mutex: std.Thread.Mutex = .{},
    git_diff_json: std.ArrayListUnmanaged(u8) = .empty,
    /// JSON der Timeline im Explorer, ebenso vom Main-Thread gespiegelt (Schutz: git_views_mutex)
    timeline_json: std.ArrayListUnmanaged(u8) = .empty,
    /// JSON von Source Control Graph und aktivem Multi-File-Diff (Schutz: git_views_mutex)
    scm_json: std.ArrayListUnmanaged(u8) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, ui_system: *ui_mod.UI, server: std.net.Server) Self {
        return Self{
            .allocator = allocator,
            .ui_system = ui_system,
            .shutdown_flag = std.atomic.Value(bool).init(false),
            .server = server,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_inputs.deinit(self.allocator);
        self.git_diff_json.deinit(self.allocator);
        self.timeline_json.deinit(self.allocator);
        self.scm_json.deinit(self.allocator);
    }
};

/// Main-Thread: Zustand von Diff-Editor, Timeline und Source Control Graph als JSON ablegen.
pub fn snapshotGitViews(ctx: *E2EContext) void {
    var out = std.Io.Writer.Allocating.init(ctx.allocator);
    defer out.deinit();
    writeGitDiffStateJson(ctx.ui_system, &out.writer) catch return;
    var tl = std.Io.Writer.Allocating.init(ctx.allocator);
    defer tl.deinit();
    writeTimelineJson(ctx.ui_system, &tl.writer) catch return;
    var scm = std.Io.Writer.Allocating.init(ctx.allocator);
    defer scm.deinit();
    writeScmJson(ctx.ui_system, &scm.writer) catch return;
    ctx.git_views_mutex.lock();
    ctx.scm_json.clearRetainingCapacity();
    ctx.scm_json.appendSlice(ctx.allocator, scm.written()) catch {};
    defer ctx.git_views_mutex.unlock();
    ctx.git_diff_json.clearRetainingCapacity();
    ctx.git_diff_json.appendSlice(ctx.allocator, out.written()) catch {};
    ctx.timeline_json.clearRetainingCapacity();
    ctx.timeline_json.appendSlice(ctx.allocator, tl.written()) catch {};
}

fn writeTimelineJson(ui: *ui_mod.UI, w: *std.Io.Writer) !void {
    const tv_mod = @import("ui/timeline_view.zig");
    const v = &ui.timeline_view;
    const t = &v.timeline;
    var msg_buf: [300]u8 = undefined;
    try w.print("{{\"expanded\": {}, \"pinned\": {}, \"loading\": {}, \"loaded\": {}, \"file\": ", .{ t.expanded, t.pinned, t.loading, t.loaded });
    try std.json.Stringify.value(t.file, .{}, w);
    try w.writeAll(", \"repo\": ");
    try std.json.Stringify.value(t.repo, .{}, w);
    try w.writeAll(", \"message\": ");
    try std.json.Stringify.value(t.message(&msg_buf), .{}, w);
    try w.writeAll(", \"items\": [");
    for (t.items(), 0..) |it, i| {
        if (i >= 100) break;
        if (i > 0) try w.writeAll(", ");
        try w.writeAll("{\"hash\": ");
        try std.json.Stringify.value(it.hash, .{}, w);
        try w.writeAll(", \"label\": ");
        try std.json.Stringify.value(it.label, .{}, w);
        try w.writeAll(", \"author\": ");
        try std.json.Stringify.value(it.author, .{}, w);
        try w.writeAll(", \"path\": ");
        try std.json.Stringify.value(it.path, .{}, w);
        try w.writeAll(", \"previous_ref\": ");
        try std.json.Stringify.value(it.previous_ref, .{}, w);
        // Zeiten aus dem letzten Layout (Frame-Arena, gilt bis zum nächsten beginLayout)
        const label = if (i < v.last_labels.len) v.last_labels[i] else null;
        try w.writeAll(", \"time\": ");
        try std.json.Stringify.value(if (label) |l| l.text else "", .{}, w);
        try w.print(", \"time_hidden\": {}}}", .{if (label) |l| l.hidden else false});
    }
    try w.writeAll("], \"selected\": ");
    try std.json.Stringify.value(t.selected, .{}, w);
    const header = clay.getElementData(tv_mod.TimelineView.headerId()).bounding_box;
    const body = clay.getElementData(tv_mod.TimelineView.bodyId()).bounding_box;
    const hover = clay.getElementData(clay.ElementId.ID("tl_hover"));
    try w.print(", \"menu_open\": {}, \"hover_index\": ", .{v.menu != null});
    try std.json.Stringify.value(v.hover_index, .{}, w);
    try w.print(
        \\, "hover_visible": {}, "header": {{"x": {d:.1}, "y": {d:.1}, "w": {d:.1}, "h": {d:.1}}}, "body": {{"x": {d:.1}, "y": {d:.1}, "w": {d:.1}, "h": {d:.1}}}, "row_height": {d:.1}, "scroll": {d:.1}}}
    , .{ hover.found and v.hover_index != null and v.now_ms - v.hover_since_ms > 700, header.x, header.y, header.width, header.height, body.x, body.y, body.width, body.height, tv_mod.ROW_HEIGHT, t.scroll });
}

fn writeScmJson(ui: *ui_mod.UI, w: *std.Io.Writer) !void {
    const sg = @import("ui/scm_graph_view.zig");
    const git_graph = @import("git_graph");
    const v = &ui.scm_graph.view;
    try w.print("{{\"mode\": \"{s}\", \"loading\": {}, \"has_more\": {}, \"branch\": ", .{ @tagName(ui.sidebar_mode), v.loading, v.has_more });
    try std.json.Stringify.value(v.branch, .{}, w);
    try w.writeAll(", \"filter\": ");
    try std.json.Stringify.value(.{ .current = v.filter.current, .upstream = v.filter.upstream, .base = v.filter.base }, .{}, w);
    try w.writeAll(", \"error\": ");
    try std.json.Stringify.value(v.error_text, .{}, w);
    try w.writeAll(", \"commits\": [");
    for (v.commits(), 0..) |c, i| {
        if (i >= 150) break;
        if (i > 0) try w.writeAll(", ");
        try w.writeAll("{\"hash\": ");
        try std.json.Stringify.value(c.hash, .{}, w);
        try w.writeAll(", \"subject\": ");
        try std.json.Stringify.value(c.subject, .{}, w);
        try w.writeAll(", \"refs\": [");
        for (c.refs, 0..) |r, k| {
            if (k > 0) try w.writeAll(", ");
            try std.json.Stringify.value(r.name, .{}, w);
        }
        try w.writeAll("]");
        if (v.graph) |g| if (i < g.rows.len) {
            const row = g.rows[i];
            try w.print(", \"kind\": \"{s}\", \"inputs\": {d}, \"outputs\": {d}, \"circle\": {d}", .{
                @tagName(row.kind), row.input.len, row.output.len, git_graph.circleIndex(.{ .id = c.hash, .parents = c.parents }, row),
            });
        };
        try w.print(", \"expanded\": {}}}", .{v.isExpanded(i)});
    }
    try w.writeAll("], \"rows\": [");
    for (v.rows.items, 0..) |r, i| {
        if (i >= 300) break;
        if (i > 0) try w.writeAll(", ");
        try w.print("{{\"kind\": \"{s}\", \"commit\": {d}, \"path\": ", .{ @tagName(r.kind), r.commit });
        try std.json.Stringify.value(if (v.changeOf(r)) |ch| ch.path else "", .{}, w);
        try w.print(", \"status\": \"{s}\"}}", .{if (v.changeOf(r)) |ch| @as([]const u8, &.{ch.status.letter()}) else ""});
    }
    const header = clay.getElementData(sg.ScmGraphView.headerId()).bounding_box;
    const body = clay.getElementData(sg.ScmGraphView.bodyId()).bounding_box;
    try w.writeAll("], \"selected\": ");
    try std.json.Stringify.value(v.selected, .{}, w);
    try w.print(", \"menu_open\": {}, \"hover_visible\": {}, \"header\": {{\"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}}}, \"body\": {{\"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}}}, \"row_height\": {d:.1}, \"scroll\": {d:.1}", .{
        ui.scm_graph.menu != null, clay.getElementData(clay.ElementId.ID("sg_hover")).found and ui.scm_graph.hover_row != null and ui.scm_graph.now_ms - ui.scm_graph.hover_since_ms > 700,
        header.x, header.y, header.width, header.height, body.x, body.y, body.width, body.height, sg.ROW_HEIGHT, v.scroll,
    });
    try w.writeAll(", \"commit_tab\": ");
    if (ui.activeGitCommit()) |ac| {
        const cv = ac.view;
        try w.writeAll("{\"title\": ");
        try std.json.Stringify.value(cv.title_text, .{}, w);
        try w.print(", \"loading\": {}, \"all_collapsed\": {}, \"scroll\": {d:.1}, \"rendered_rows\": {d}, \"sections\": [", .{ cv.loading, cv.allCollapsed(), cv.scroll_y, cv.rendered_rows });
        for (cv.sections.items, 0..) |s, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("{\"path\": ");
            try std.json.Stringify.value(s.change.path, .{}, w);
            try w.print(", \"status\": \"{c}\", \"collapsed\": {}, \"loaded\": {}, \"collapse_unchanged\": {}, \"changes\": {d}}}", .{
                s.change.status.letter(), s.collapsed, s.view.state.loaded, s.view.state.collapse_unchanged, s.view.state.stats().changes,
            });
        }
        try w.writeAll("]}");
    } else try w.writeAll("null");
    try writeScmChangesJson(ui, w);
    try w.writeAll("}");
}

/// `"changes": {…}` im scm_state: Branch, Fokus, Eingabe, Gruppen mit Einträgen, Zeilen, Auswahl, Bounds.
fn writeScmChangesJson(ui: *ui_mod.UI, w: *std.Io.Writer) !void {
    const sc = @import("ui/scm_changes_view.zig");
    const git_changes = @import("git_changes");
    const v = &ui.scm_changes.view;
    try w.writeAll(", \"changes\": {\"branch\": ");
    try std.json.Stringify.value(v.branch(), .{}, w);
    try w.print(", \"focus\": \"{s}\", \"busy\": {}, \"generating\": {}, \"upstream\": ", .{ @tagName(ui.sidebar_focus), ui.scm_changes.busy, ui.scm_changes.generating });
    try std.json.Stringify.value(v.upstream(), .{}, w);
    var label_buf: [64]u8 = undefined;
    try w.print(", \"ahead\": {d}, \"button\": ", .{v.ahead()});
    try std.json.Stringify.value(v.buttonLabel(&label_buf), .{}, w);
    try w.print(", \"lines\": {d}, \"message\": ", .{ui.scm_changes.message.lineCount()});
    try std.json.Stringify.value(ui.scm_changes.message.text(), .{}, w);
    try w.writeAll(", \"validation\": ");
    try std.json.Stringify.value(ui.scm_changes.validation, .{}, w);
    try w.writeAll(", \"groups\": {");
    inline for ([_]git_changes.Group{ .merge, .staged, .changes }, 0..) |g, gi| {
        if (gi > 0) try w.writeAll(", ");
        try w.print("\"{s}\": [", .{@tagName(g)});
        if (v.status) |*s| for (s.entries(g), 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("{\"path\": ");
            try std.json.Stringify.value(e.path, .{}, w);
            try w.print(", \"kind\": \"{s}\", \"letter\": \"{c}\", \"color\": \"{s}\", \"strike\": {}}}", .{ @tagName(e.kind), git_changes.letter(e.kind), @tagName(git_changes.color(e.kind)), git_changes.strikeThrough(e.kind) });
        };
        try w.writeAll("]");
    }
    try w.writeAll("}, \"rows\": [");
    for (v.rows.items, 0..) |r, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{{\"kind\": \"{s}\", \"group\": \"{s}\", \"path\": ", .{ @tagName(r.kind), @tagName(r.group) });
        try std.json.Stringify.value(if (v.entry(r)) |e| e.path else "", .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("], \"selected\": ");
    try std.json.Stringify.value(v.selected, .{}, w);
    const header = clay.getElementData(sc.ScmChangesView.headerId()).bounding_box;
    const body = clay.getElementData(sc.ScmChangesView.bodyId()).bounding_box;
    const input = clay.getElementData(sc.ScmChangesView.inputId()).bounding_box;
    try w.print(", \"header\": {{\"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}}}, \"body\": {{\"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}}}, \"input\": {{\"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}}}, \"row_height\": {d:.1}, \"scroll\": {d:.1}, \"dialog\": ", .{
        header.x, header.y, header.width, header.height, body.x, body.y, body.width, body.height, input.x, input.y, input.width, input.height, sc.ROW_HEIGHT, v.scroll,
    });
    if (ui.active_dialog) |d| {
        try w.writeAll("{\"title\": ");
        try std.json.Stringify.value(d.dialog.title, .{}, w);
        try w.writeAll(", \"message\": ");
        try std.json.Stringify.value(d.dialog.message, .{}, w);
        try w.writeAll(", \"button\": ");
        try std.json.Stringify.value(d.dialog.actions[0].label, .{}, w);
        try w.writeAll("}");
    } else try w.writeAll("null");
    try w.writeAll("}");
}

fn scmState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    ctx.git_views_mutex.lock();
    defer ctx.git_views_mutex.unlock();
    if (ctx.scm_json.items.len == 0) return "{\"mode\": \"explorer\"}";
    return dc.arena().dupe(u8, ctx.scm_json.items);
}

fn timelineState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    ctx.git_views_mutex.lock();
    defer ctx.git_views_mutex.unlock();
    if (ctx.timeline_json.items.len == 0) return "{\"expanded\": false}";
    return dc.arena().dupe(u8, ctx.timeline_json.items);
}

/// RPC `git_diff_state`: Diff-Editor des aktiven Tabs, sonst `{"active": false}`.
fn writeGitDiffStateJson(ui: *ui_mod.UI, w: *std.Io.Writer) !void {
    if (ui.activeGitDiff()) |d| return writeGitDiffJson(d, w);
    try w.writeAll("{\"active\": false}");
}

/// Diff-Editor-Zustand (`view: "diff"`).
fn writeGitDiffJson(d: ui_mod.UI.ActiveDiff, w: *std.Io.Writer) !void {
    const gd_view = @import("ui/git_diff_view.zig");
    const s = &d.view.state;
    const layout = d.view.last_layout;
    const st = s.stats();
    var folds: usize = 0;
    const items = s.items(layout) catch &.{};
    for (items) |it| if (it == .fold) {
        folds += 1;
    };
    try w.writeAll("{\"active\": true, \"view\": \"diff\", \"title\": ");
    try std.json.Stringify.value(s.title_text, .{}, w);
    try w.print(", \"loaded\": {}, \"loading\": {}, \"error\": ", .{ s.loaded, s.loading });
    try std.json.Stringify.value(s.error_text, .{}, w);
    try w.print(", \"layout\": \"{s}\", \"mode\": \"{s}\", \"collapse\": {}, \"old_lines\": {d}, \"new_lines\": {d}, \"rows\": {d}, \"items\": {d}, \"folds\": {d}, \"changes\": {d}, \"added\": {d}, \"removed\": {d}, \"current_row\": ", .{
        @tagName(layout), @tagName(s.mode), s.collapse_unchanged, s.old_lines.len, s.new_lines.len, s.rows(layout).len, items.len, folds, st.changes, st.added, st.removed,
    });
    try std.json.Stringify.value(s.current_row, .{}, w);
    const kinds = s.rows(layout);
    var modified: usize = 0;
    for (kinds) |r| {
        if (r.kind == .modified) modified += 1;
    }
    const body = clay.getElementData(gd_view.GitDiffView.bodyId(d.salt)).bounding_box;
    try w.print(", \"modified_rows\": {d}, \"scroll_y\": {d:.1}, \"row_height\": {d:.1}, \"rendered_rows\": {d}, \"old_highlight\": {}, \"new_highlight\": {}, \"body\": {{\"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}}}, \"buttons\": {{", .{
        modified, s.scroll_y, d.view.row_height, d.view.rendered_rows, d.view.old_hl != null, d.view.new_hl != null, body.x, body.y, body.width, body.height,
    });
    const names = [_][]const u8{ "prev", "next", "collapse", "inline" };
    for (names, 0..) |name, i| {
        const b = clay.getElementData(clay.ElementId.IDI(switch (i) {
            0 => "gd_btn_prev",
            1 => "gd_btn_next",
            2 => "gd_btn_collapse",
            else => "gd_btn_inline",
        }, d.salt)).bounding_box;
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\": {{\"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}}}", .{ name, b.x, b.y, b.width, b.height });
    }
    // erster Faltbalken (für Klick-Tests)
    var first_fold: ?usize = null;
    for (items, 0..) |it, i| if (it == .fold and first_fold == null) {
        first_fold = i;
    };
    try w.writeAll("}, \"first_fold_item\": ");
    try std.json.Stringify.value(first_fold, .{}, w);
    try w.writeAll("}");
}

fn gitDiffState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    ctx.git_views_mutex.lock();
    defer ctx.git_views_mutex.unlock();
    if (ctx.git_diff_json.items.len == 0) return "{\"active\": false}";
    return dc.arena().dupe(u8, ctx.git_diff_json.items);
}

/// Ereignis anwenden oder (Fenstermodus) für den Main-Thread puffern.
fn dispatchInput(ctx: *E2EContext, ev: InputEvent) void {
    if (!ctx.defer_input) {
        applyInput(ctx, ev);
        return;
    }
    ctx.input_mutex.lock();
    ctx.pending_inputs.append(ctx.allocator, ev) catch {
        log.warn("input queue: out of memory, event dropped", .{});
    };
    ctx.input_mutex.unlock();
    @import("wio").cancelWait();
}

/// Vom Main-Thread pro Frame aufrufen: gepufferte Eingaben anwenden.
pub fn drainInputs(ctx: *E2EContext) void {
    var batch: [64]InputEvent = undefined;
    while (true) {
        ctx.input_mutex.lock();
        const n = @min(ctx.pending_inputs.items.len, batch.len);
        @memcpy(batch[0..n], ctx.pending_inputs.items[0..n]);
        ctx.pending_inputs.replaceRangeAssumeCapacity(0, n, &.{});
        ctx.input_mutex.unlock();
        if (n == 0) return;
        for (batch[0..n]) |ev| applyInput(ctx, ev);
    }
}

fn applyInput(ctx: *E2EContext, ev: InputEvent) void {
    const ui = ctx.ui_system;
    switch (ev) {
        .open_file => |path| {
            defer ctx.allocator.free(path);
            const tab_bar = ui.getActiveTabBar();
            tab_bar.openFile(path) catch |err| {
                log.warn("open_file('{s}'): {s}", .{ path, @errorName(err) });
                return;
            };
            // tab_bar.openFile setzt active_index, aber nur setActive stößt den Loader-Flow
            // in main.zig an (pending_switch_path).
            if (tab_bar.active_index) |idx| tab_bar.setActive(idx);
        },
        .open_folder => |path| {
            defer ctx.allocator.free(path);
            ui.file_explorer.loadDirectory(path) catch |err| log.warn("open_folder('{s}'): {s}", .{ path, @errorName(err) });
        },
        .click => |p| {
            ui.setPointerState(p.x, p.y, true);
            ui.handleMouseMove(p.x, p.y);
            ui.handleMouseDown(p.x, p.y, .mouse_left);
            ui.handleMouseUp();
            ui.setPointerState(p.x, p.y, false);
        },
        .right_click => |p| {
            ui.setPointerState(p.x, p.y, true);
            ui.handleMouseDown(p.x, p.y, .mouse_right);
            ui.handleMouseUp();
            ui.setPointerState(p.x, p.y, false);
        },
        .click_mods => |p| {
            ui.setCtrlState(p.ctrl);
            ui.setShiftState(p.shift);
            ui.setPointerState(p.x, p.y, true);
            ui.handleMouseMove(p.x, p.y);
            ui.handleMouseDown(p.x, p.y, .mouse_left);
            ui.handleMouseUp();
            ui.setPointerState(p.x, p.y, false);
            ui.setCtrlState(false);
            ui.setShiftState(false);
        },
        .middle_click => |p| {
            ui.setPointerState(p.x, p.y, true);
            ui.handleMouseDown(p.x, p.y, .mouse_middle);
            ui.handleMouseUp();
            ui.setPointerState(p.x, p.y, false);
        },
        .press => |p| {
            ui.setPointerState(p.x, p.y, true);
            ui.handleMouseMove(p.x, p.y);
            ui.handleMouseDown(p.x, p.y, .mouse_left);
        },
        .release => |p| {
            ui.handleMouseMove(p.x, p.y);
            ui.handleMouseUp();
            ui.setPointerState(p.x, p.y, false);
        },
        .move => |p| {
            // Gedrückte Taste (mouse_down) bleibt beim Bewegen gedrückt: Drag & Drop
            ui.setPointerState(p.x, p.y, ui.is_mouse_down);
            ui.handleMouseMove(p.x, p.y);
        },
        .key => |k| {
            ui.setCtrlState(k.ctrl);
            ui.setShiftState(k.shift);
            ui.setAltState(k.alt);
            ui.handleKeyPress(k.btn);
            if (!k.hold) {
                ui.setCtrlState(false);
                ui.setShiftState(false);
                ui.setAltState(false);
            }
        },
        .mods_release => {
            ui.setCtrlState(false);
            ui.setShiftState(false);
            ui.setAltState(false);
        },
        .char => |cp| ui.handleChar(cp),
        .scroll => |sc| {
            ui.setPointerState(sc.x, sc.y, false);
            ui.handleMouseMove(sc.x, sc.y);
            ui.handleScroll(sc.lines);
        },
    }
}

/// Dispatcher mit allen E2E-Handlern erstellen
pub fn createDispatcher(alloc: std.mem.Allocator, ctx: *E2EContext) !*zigjr.RpcDispatcher {
    var rpc_dispatcher = try alloc.create(zigjr.RpcDispatcher);
    rpc_dispatcher.* = try zigjr.RpcDispatcher.init(alloc);

    try rpc_dispatcher.addWithCtx("open_folder", ctx, openFolder);
    try rpc_dispatcher.addWithCtx("open_project", ctx, openProject);
    try rpc_dispatcher.addWithCtx("open_file", ctx, openFile);
    try rpc_dispatcher.addWithCtx("tab_bounds", ctx, tabBounds);
    try rpc_dispatcher.addWithCtx("picker_state", ctx, pickerState);
    try rpc_dispatcher.addWithCtx("middle_click", ctx, middleClick);
    try rpc_dispatcher.addWithCtx("click_mods", ctx, clickMods);
    try rpc_dispatcher.addWithCtx("mouse_down", ctx, mouseDown);
    try rpc_dispatcher.addWithCtx("mouse_up", ctx, mouseUp);
    try rpc_dispatcher.addWithCtx("close_tab", ctx, closeTab);
    try rpc_dispatcher.addWithCtx("setActiveTab", ctx, setActiveTab);
    try rpc_dispatcher.addWithCtx("click", ctx, click);
    try rpc_dispatcher.addWithCtx("right_click", ctx, rightClick);
    try rpc_dispatcher.addWithCtx("scroll", ctx, scrollAt);
    try rpc_dispatcher.addWithCtx("move_mouse", ctx, moveMouse);
    try rpc_dispatcher.addWithCtx("type_text", ctx, typeText);
    try rpc_dispatcher.addWithCtx("key_press", ctx, keyPress);
    try rpc_dispatcher.addWithCtx("key_press_mods", ctx, keyPressMods);
    try rpc_dispatcher.addWithCtx("key_press_alt", ctx, keyPressAlt);
    try rpc_dispatcher.addWithCtx("key_press_hold", ctx, keyPressHold);
    try rpc_dispatcher.addWithCtx("mods_release", ctx, modsRelease);
    try rpc_dispatcher.addWithCtx("open_terminal", ctx, openTerminalRpc);
    try rpc_dispatcher.addWithCtx("open_chat", ctx, openChatRpc);
    try rpc_dispatcher.addWithCtx("get_chat_input", ctx, getChatInput);
    try rpc_dispatcher.addWithCtx("chat_state", ctx, chatState);
    try rpc_dispatcher.addWithCtx("focus_chat", ctx, focusChat);
    try rpc_dispatcher.addWithCtx("file_text", ctx, fileText);
    try rpc_dispatcher.addWithCtx("get_active_tab", ctx, getActiveTabDebug);
    try rpc_dispatcher.addWithCtx("explorer_open", ctx, explorerOpen);
    try rpc_dispatcher.addWithCtx("explorer_entries", ctx, explorerEntries);
    try rpc_dispatcher.addWithCtx("element_bounds", ctx, elementBounds);
    try rpc_dispatcher.addWithCtx("element_bounds_i", ctx, elementBoundsIndexed);
    try rpc_dispatcher.addWithCtx("folder_picker_state", ctx, folderPickerState);
    try rpc_dispatcher.addWithCtx("slide_state", ctx, slideState);
    try rpc_dispatcher.addWithCtx("pdf_state", ctx, pdfState);
    try rpc_dispatcher.addWithCtx("git_diff_state", ctx, gitDiffState);
    try rpc_dispatcher.addWithCtx("timeline_state", ctx, timelineState);
    try rpc_dispatcher.addWithCtx("scm_state", ctx, scmState);
    try rpc_dispatcher.addWithCtx("ui_state", ctx, uiState);
    try rpc_dispatcher.addWithCtx("editor_lines", ctx, editorLines);
    try rpc_dispatcher.addWithCtx("editor_state", ctx, editorState);
    try rpc_dispatcher.addWithCtx("md_selection", ctx, mdSelection);
    try rpc_dispatcher.addWithCtx("chat_line_bounds", ctx, chatLineBounds);
    try rpc_dispatcher.addWithCtx("save_file", ctx, saveFile);
    try rpc_dispatcher.addWithCtx("get_state", ctx, getState);
    try rpc_dispatcher.addWithCtx("benchmark_open_file", ctx, benchmarkOpenFile);
    try rpc_dispatcher.addWithCtx("benchmark_load_file", ctx, benchmarkLoadFile);
    try rpc_dispatcher.addWithCtx("split_pane", ctx, splitPane);
    try rpc_dispatcher.addWithCtx("show_context_menu", ctx, showContextMenuRpc);
    try rpc_dispatcher.addWithCtx("close_active_tab", ctx, closeActiveTabRpc);
    try rpc_dispatcher.addWithCtx("shutdown", ctx, shutdown);
    try rpc_dispatcher.addWithCtx("screenshot", ctx, screenshot);

    return rpc_dispatcher;
}

/// Server starten (Thread, blockiert nicht)
pub fn start(ctx: *E2EContext) !std.Thread {
    log.info("E2E RPC server listening on 127.0.0.1:{d}", .{PORT});
    return try std.Thread.spawn(.{}, serverLoop, .{ctx});
}

fn serverLoop(ctx: *E2EContext) void {
    defer ctx.server.deinit();

    while (!ctx.shutdown_flag.load(.seq_cst)) {
        const connection = ctx.server.accept() catch |err| {
            if (ctx.shutdown_flag.load(.seq_cst)) break;
            log.err("Accept failed: {}", .{err});
            continue;
        };

        // Pro Connection ein Thread
        _ = std.Thread.spawn(.{}, handleConnection, .{ ctx, connection }) catch |err| {
            log.err("Spawn thread failed: {}", .{err});
            connection.stream.close();
        };
    }
}

fn handleConnection(ctx: *E2EContext, connection: std.net.Server.Connection) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var s_reader = connection.stream.reader(&rbuf);
    var s_writer = connection.stream.writer(&wbuf);
    const reader = s_reader.interface();
    const writer = &s_writer.interface;
    var dbg_logger = zigjr.DbgLogger{};

    const rpc_dispatcher = createDispatcher(alloc, ctx) catch {
        connection.stream.close();
        return;
    };
    defer {
        rpc_dispatcher.deinit();
        alloc.destroy(rpc_dispatcher);
    }
    const dispatcher = zigjr.RequestDispatcher.implBy(rpc_dispatcher);

    zigjr.stream.requestsByDelimiter(alloc, reader, writer, dispatcher, .{
        .logger = dbg_logger.asLogger(),
    }) catch |err| {
        if (err != error.ReadFailed) {
            log.err("RPC stream error: {}", .{err});
        }
    };

    connection.stream.close();
    log.debug("E2E connection closed", .{});
}

// =============================================================================
// RPC Handlers
// =============================================================================

/// Ordner im File Explorer öffnen
fn openFolder(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8) ![]const u8 {
    log.info("RPC: open_folder('{s}')", .{path});
    // Gepuffert wie open_file: der Main-Thread lädt zwischen zwei Frames (siehe InputEvent).
    const owned = ctx.allocator.dupe(u8, path) catch |err| return try std.fmt.allocPrint(dc.arena(), "error: {}", .{err});
    dispatchInput(ctx, .{ .open_folder = owned });
    return "ok";
}

/// Projektordner wechseln wie über den Dialog: main.zig holt den Pfad per takePendingOpenFolder
/// und lädt Explorer, Watcher, Branch und git status neu (`open_folder` lädt nur den Explorer).
fn openProject(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8) ![]const u8 {
    log.info("RPC: open_project('{s}')", .{path});
    const ui = ctx.ui_system;
    const owned = ui.allocator.dupe(u8, path) catch |err| return try std.fmt.allocPrint(dc.arena(), "error: {}", .{err});
    if (ui.pending_open_folder) |old| ui.allocator.free(old);
    ui.pending_open_folder = owned;
    return "ok";
}

/// Datei speichern
fn saveFile(ctx: *E2EContext, dc: *zigjr.DispatchCtx, params: []const u8) ![]const u8 {
    _ = params;
    log.info("RPC: save_file()", .{});
    ctx.ui_system.getActiveEditor().save() catch |err| {
        const msg = try std.fmt.allocPrint(dc.arena(), "error: {}", .{err});
        return msg;
    };
    return "ok";
}

/// Datei im Editor öffnen (oder Bild-Vorschau)
/// Datei öffnen. Die Prüfung auf ein Verzeichnis (error.IsDir) bleibt synchron, damit der
/// Aufrufer die Antwort bekommt; der Tab selbst entsteht gepuffert im Main-Thread, denn ein
/// `tabs.append` aus dem Server-Thread hat `renderTabBar` mitten in der Iteration gestört.
pub fn openFile(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8) ![]const u8 {
    log.info("RPC: open_file('{s}')", .{path});
    if (explorer_ops.isDirectory(path)) {
        return try std.fmt.allocPrint(dc.arena(), "error: {}", .{error.IsDir});
    }
    const owned = try ctx.allocator.dupe(u8, path);
    dispatchInput(ctx, .{ .open_file = owned });
    return "ok";
}

/// Tab schließen (nach Index)
pub fn closeTab(ctx: *E2EContext, dc: *zigjr.DispatchCtx, index: i64) ![]const u8 {
    log.info("RPC: close_tab({d})", .{index});

    if (index < 0 or @as(usize, @intCast(index)) >= ctx.ui_system.getActiveTabBar().count()) {
        const msg = try std.fmt.allocPrint(dc.arena(), "error: tab index {d} out of range (only {d} tabs)", .{ index, ctx.ui_system.getActiveTabBar().count() });
        return msg;
    }

    ctx.ui_system.getActiveTabBar().closeTab(@intCast(index));
    @import("wio").cancelWait();

    return "ok";
}

/// Aktiven Tab wechseln (setzt pending_switch_path)
pub fn setActiveTab(ctx: *E2EContext, dc: *zigjr.DispatchCtx, index: i64) ![]const u8 {
    log.info("RPC: set_active_tab({d})", .{index});

    if (index < 0 or @as(usize, @intCast(index)) >= ctx.ui_system.getActiveTabBar().count()) {
        const msg = try std.fmt.allocPrint(dc.arena(), "error: tab index {d} out of range (only {d} tabs)", .{ index, ctx.ui_system.getActiveTabBar().count() });
        return msg;
    }

    ctx.ui_system.getActiveTabBar().setActive(@intCast(index));
    @import("wio").cancelWait();

    return "ok";
}

/// Maus-Klick an Koordinate (simuliert)
pub fn click(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    log.info("RPC: click({d}, {d})", .{ x, y });
    dispatchInput(ctx, .{ .click = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    return "ok";
}

/// Maus-Rechtsklick an Koordinate
pub fn rightClick(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    log.info("RPC: right_click({d}, {d})", .{ x, y });
    dispatchInput(ctx, .{ .right_click = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    return "ok";
}

/// Mausrad an Koordinate: lines > 0 hoch, < 0 runter
fn scrollAt(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64, lines: i64) ![]const u8 {
    log.info("RPC: scroll({d}, {d}, {d})", .{ x, y, lines });
    dispatchInput(ctx, .{ .scroll = .{ .x = @floatCast(x), .y = @floatCast(y), .lines = @intCast(lines) } });
    return "ok";
}

/// Maus-Bewegung zu Koordinate (simuliert)
fn moveMouse(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    log.info("RPC: move_mouse({d}, {d})", .{ x, y });
    dispatchInput(ctx, .{ .move = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    return "ok";
}

pub fn keyPress(ctx: *E2EContext, dc: *zigjr.DispatchCtx, key_name: []const u8, is_ctrl: bool) ![]const u8 {
    return keyPressMods(ctx, dc, key_name, is_ctrl, false);
}

/// key_press_mods(name, ctrl, shift): Taste mit Modifiern, z.B. Ctrl+Shift+Tab.
pub fn keyPressMods(ctx: *E2EContext, _: *zigjr.DispatchCtx, key_name: []const u8, is_ctrl: bool, is_shift: bool) ![]const u8 {
    log.info("RPC: key_press('{s}', ctrl={}, shift={})", .{ key_name, is_ctrl, is_shift });
    const b = buttonFromName(key_name) orelse return "error: unknown key";
    dispatchInput(ctx, .{ .key = .{ .btn = b, .ctrl = is_ctrl, .shift = is_shift } });
    return "ok";
}

/// Wie key_press_mods, zusätzlich Alt (Alt+↑/↓ Zeile verschieben, Alt+Enter Ersetze alle).
pub fn keyPressAlt(ctx: *E2EContext, _: *zigjr.DispatchCtx, key_name: []const u8, is_ctrl: bool, is_shift: bool, is_alt: bool) ![]const u8 {
    const b = buttonFromName(key_name) orelse return "error: unknown key";
    dispatchInput(ctx, .{ .key = .{ .btn = b, .ctrl = is_ctrl, .shift = is_shift, .alt = is_alt } });
    return "ok";
}

/// Wie key_press_alt, aber die Modifier bleiben gedrückt (bis mods_release).
pub fn keyPressHold(ctx: *E2EContext, _: *zigjr.DispatchCtx, key_name: []const u8, is_ctrl: bool, is_shift: bool, is_alt: bool) ![]const u8 {
    const b = buttonFromName(key_name) orelse return "error: unknown key";
    dispatchInput(ctx, .{ .key = .{ .btn = b, .ctrl = is_ctrl, .shift = is_shift, .alt = is_alt, .hold = true } });
    return "ok";
}

pub fn modsRelease(ctx: *E2EContext, _: *zigjr.DispatchCtx) ![]const u8 {
    dispatchInput(ctx, .mods_release);
    return "ok";
}

fn buttonFromName(name: []const u8) ?@import("wio").Button {
    const Button = @import("wio").Button;
    const named = [_]struct { []const u8, Button }{
        .{ "enter", .enter },         .{ "backspace", .backspace }, .{ "escape", .escape },
        .{ "delete", .delete },       .{ "tab", .tab },             .{ "grave", .grave },
        .{ "up", .up },               .{ "down", .down },           .{ "left", .left },
        .{ "right", .right },         .{ "home", .home },           .{ "end", .end },
        .{ "page_up", .page_up },     .{ "page_down", .page_down }, .{ "f1", .f1 },
        .{ "f2", .f2 },               .{ "f5", .f5 },               .{ "space", .space },
        .{ "1", .@"1" },              .{ "2", .@"2" },              .{ "3", .@"3" },
        .{ "4", .@"4" },              .{ "5", .@"5" },              .{ "9", .@"9" },
        .{ "backslash", .backslash }, .{ "slash", .slash },         .{ "f12", .f12 },
        .{ "dot", .dot },             .{ "equals", .equals },       .{ "minus", .minus },
        .{ "0", .@"0" },
    };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    // Einzelne Buchstaben a–z
    if (name.len == 1 and name[0] >= 'a' and name[0] <= 'z') {
        inline for (@typeInfo(Button).@"enum".fields) |field| {
            if (field.name.len == 1 and field.name[0] == name[0]) return @field(Button, field.name);
        }
    }
    return null;
}

pub fn typeText(ctx: *E2EContext, _: *zigjr.DispatchCtx, text: []const u8) ![]const u8 {
    log.info("RPC: type_text('{s}')", .{text});
    var view = std.unicode.Utf8View.init(text) catch return "error: invalid utf8";
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        dispatchInput(ctx, .{ .char = cp });
    }
    return "ok";
}

/// Terminal öffnen
fn openTerminalRpc(ctx: *E2EContext, _: *zigjr.DispatchCtx) ![]const u8 {
    log.info("RPC: open_terminal", .{});
    ctx.ui_system.getActiveTabBar().openTerminal();

    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();

    return "ok";
}

/// AI Chat öffnen
fn openChatRpc(ctx: *E2EContext, _: *zigjr.DispatchCtx) ![]const u8 {
    log.info("RPC: open_chat", .{});
    ctx.ui_system.getActiveTabBar().openChat();

    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();

    return "ok";
}

/// Chat Input Content abfragen
fn getChatInput(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    log.info("RPC: get_chat_input", .{});
    const buf = ctx.ui_system.ai_chat.input_buffer;
    const text = buf.store_to_string_cached(buf.root, buf.file_eol_mode);
    return dc.arena().dupe(u8, text) catch "error: out of memory";
}

/// KI-Chat-Zustand: Verbindungsstatus, Lade-/Init-Flags und alle Nachrichten.
fn chatState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const chat = &ctx.ui_system.ai_chat;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.print(
        \\{{"status": "{s}", "detail":
    , .{@tagName(chat.agent_status)});
    try std.json.Stringify.value(chat.statusDetail(), .{}, &buf.writer);
    try buf.writer.print(
        \\, "loading": {}, "initializing": {}, "downloading": {}, "model_exists": {}, "streaming_len": {d}, "tool_rounds": {d}, "pending_tools": {d}, "title":
    , .{ chat.is_loading, chat.is_initializing, chat.is_downloading, chat.model_exists, chat.stream_text.items.len, chat.tool_rounds, chat.pending_tools.items.len });
    try std.json.Stringify.value(chat.agentTitle(), .{}, &buf.writer);
    try buf.writer.print(", \"input_bounds\": [{d:.1}, {d:.1}, {d:.1}, {d:.1}], \"input_cursor\": [{d}, {d}]", .{ chat.input_bounds_x, chat.input_bounds_y, chat.input_bounds_w, chat.input_bounds_h, chat.input_editor.cursor.row, chat.input_editor.cursor.col });
    try buf.writer.writeAll(", \"messages\": [");
    chat.mutex.lock();
    defer chat.mutex.unlock();
    for (chat.messages.items, 0..) |m, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.writeAll("{\"role\": ");
        try std.json.Stringify.value(m.role, .{}, &buf.writer);
        try buf.writer.writeAll(", \"content\": ");
        try std.json.Stringify.value(m.content, .{}, &buf.writer);
        if (m.tool_calls_json) |tc| {
            try buf.writer.writeAll(", \"tool_calls\": ");
            try buf.writer.writeAll(tc);
        }
        if (m.tool_call_id) |id| {
            try buf.writer.writeAll(", \"tool_call_id\": ");
            try std.json.Stringify.value(id, .{}, &buf.writer);
        }
        try buf.writer.writeAll("}");
    }
    try buf.writer.writeAll("]}");
    return buf.written();
}

/// Debug: Active Tab Info
fn getActiveTabDebug(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const tab_bar = ctx.ui_system.getActiveTabBar();
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    const active_idx = if (tab_bar.active_index) |i| @as(i64, @intCast(i)) else -1;
    try buf.writer.print(
        \\{{"active_index": {},
        \\"tab_count": {},
        \\"is_chat_active": {},
        \\"tabs": [
    , .{
        active_idx,
        tab_bar.tabs.items.len,
        ctx.ui_system.isChatTabActive(),
    });

    for (tab_bar.tabs.items, 0..) |tab, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.print(
            \\{{"index": {d}, "kind": "{s}", "name": {f}, "is_active": {}, "modified": {}, "pinned": {}}}
        , .{ i, @tagName(tab.kind), std.json.fmt(tab.display_name, .{}), tab.is_active, tab.modified, tab.pinned });
    }
    const ed = ctx.ui_system.getActiveEditor();
    // Pfade immer über std.json.fmt: Windows-Backslashes wären sonst ungültiges JSON.
    try buf.writer.print("], \"editor_modified\": {}, \"editor_file\": {f}}}", .{ ed.is_modified, std.json.fmt(ed.buffer.get_file_path(), .{}) });
    return buf.written();
}

/// Sichtbare Explorer-Einträge mit Viewport-Bounds, damit Tests Zeilen anklicken können.
fn explorerEntries(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const fx = &ctx.ui_system.file_explorer;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.print(
        \\{{"viewport": {{"x": {d:.1}, "y": {d:.1}, "w": {d:.1}, "h": {d:.1}}}, "row_height": {d:.1}, "scroll": {d:.1}, "renaming": {}, "creating": {}, "show_hidden": {}, "filter_active": {}, "filter": {f}, "width": {d:.1}, "menu_open": {}, "menu_x": {d:.1}, "menu_y": {d:.1}, "entries": [
    , .{
        fx.viewport_x,                                 fx.viewport_y,
        fx.viewport_width,                             fx.viewport_height,
        @import("ui/file_explorer.zig").ROW_HEIGHT,    fx.scroll_offset_y,
        fx.isRenaming(),                               fx.isCreating(),
        fx.show_hidden,                                fx.filter_active,
        std.json.fmt(fx.filter.text(), .{}),           fx.width,
        fx.context_menu != null,                       if (fx.context_menu) |m| m.x else @as(f32, 0),
        if (fx.context_menu) |m| m.y else @as(f32, 0),
    });
    for (fx.visible_entries.items, 0..) |e, i| {
        const node = fx.nodes.items[e.node_index];
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.print(
            \\{{"index": {d}, "name": {f}, "path": {f}, "is_folder": {}, "expanded": {}, "depth": {d}, "selected": {}, "cursor": {}, "ignored": {}}}
        , .{ i, std.json.fmt(node.name, .{}), std.json.fmt(node.path, .{}), node.is_folder, e.is_expanded, e.depth, fx.isNodeSelected(e.node_index), fx.selected_index == i, fx.isIgnored(node.path) });
    }
    try buf.writer.writeAll("]}");
    return buf.written();
}

/// Schnellöffner / Command Palette: offen, Modus, Anfrage, Trefferzahl, markierter Eintrag.
fn pickerState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const pk = &ctx.ui_system.picker;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.print("{{\"open\": {}, \"scanning\": {}, \"mode\": \"{s}\", \"query\": ", .{ pk.visible, pk.scanning, @tagName(pk.mode) });
    try std.json.Stringify.value(pk.query(), .{}, &buf.writer);
    try buf.writer.print(", \"matches\": {d}, \"items\": {d}, \"selected\": {d}, \"selected_label\": ", .{ pk.matchCount(), pk.items.items.len, pk.selected });
    try std.json.Stringify.value(pk.selectedLabel(), .{}, &buf.writer);
    // Der Ordner so, wie die Zeile ihn zeichnet — gekürzt, mit Auslassungszeichen.
    var dir_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    try buf.writer.writeAll(", \"selected_dir_shown\": ");
    try std.json.Stringify.value(pk.selectedDirShown(&dir_buf), .{}, &buf.writer);
    try buf.writer.writeAll("}");
    return buf.written();
}

/// Bounding-Box des Tab-Kopfs `index` im aktiven Pane (für Klicks/Mittelklick/Rechtsklick).
fn tabBounds(ctx: *E2EContext, dc: *zigjr.DispatchCtx, index: i64) ![]const u8 {
    const tb = ctx.ui_system.getActiveTabBar();
    return boundsJson(dc, clay.getElementData(@import("ui/tab_bar.zig").tabId(tb, @intCast(index))));
}

/// Klick mit Modifiern (gepuffert wie click)
fn clickMods(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64, is_ctrl: bool, is_shift: bool) ![]const u8 {
    dispatchInput(ctx, .{ .click_mods = .{ .x = @floatCast(x), .y = @floatCast(y), .ctrl = is_ctrl, .shift = is_shift } });
    return "ok";
}

/// Mittelklick (gepuffert wie click)
fn middleClick(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    dispatchInput(ctx, .{ .middle_click = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    return "ok";
}

/// Linke Taste drücken ohne loslassen (Drag-Tests), Gegenstück mouse_up
fn mouseDown(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    dispatchInput(ctx, .{ .press = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    return "ok";
}

fn mouseUp(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    dispatchInput(ctx, .{ .release = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    return "ok";
}

/// Bounding-Box eines Clay-Elements aus dem letzten Layout (String-ID). Nicht global gefunden →
/// gesalzene ID des aktiven Editors (`CodeEditor.idi`: editor_scroll, scrollbar_track, …).
fn elementBounds(ctx: *E2EContext, dc: *zigjr.DispatchCtx, id: []const u8) ![]const u8 {
    return boundsJson(dc, lookupElement(ctx, id, 0));
}

/// Bounding-Box eines indexierten Clay-Elements (IDI, z.B. fp_entry + 3, code + zeile).
fn elementBoundsIndexed(ctx: *E2EContext, dc: *zigjr.DispatchCtx, id: []const u8, index: i64) ![]const u8 {
    return boundsJson(dc, lookupElement(ctx, id, @intCast(index)));
}

fn lookupElement(ctx: *E2EContext, id: []const u8, index: u32) clay.ElementData {
    const global = clay.getElementData(clay.ElementId.IDI(id, index));
    if (global.found) return global;
    if (ctx.ui_system.activeMarkdownView()) |v| {
        const md = clay.getElementData(v.idi(id, index));
        if (md.found) return md;
    }
    return clay.getElementData(ctx.ui_system.getActiveEditor().idi(id, index));
}

fn boundsJson(dc: *zigjr.DispatchCtx, data: clay.ElementData) ![]const u8 {
    const bb = data.bounding_box;
    return std.fmt.allocPrint(dc.arena(),
        \\{{"found": {}, "x": {d:.1}, "y": {d:.1}, "w": {d:.1}, "h": {d:.1}}}
    , .{ data.found, bb.x, bb.y, bb.width, bb.height });
}

/// Zeilenzahl des aktiven Editors (für Editier-Kürzel wie Delete Line).
fn editorLines(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    return std.fmt.allocPrint(dc.arena(), "{d}", .{ctx.ui_system.getActiveEditor().lineCount()});
}

/// Editor-Zustand: Zeilen, Cursor und der gesamte Text (JSON-escaped).
fn editorState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const ed = ctx.ui_system.getActiveEditor();
    const lines = ed.lineCount();
    const last: usize = if (lines > 0) lines - 1 else 0;
    const text = ed.getTextInRange(.{
        .begin = .{ .row = 0, .col = 0 },
        .end = .{ .row = last, .col = 100_000 },
    }) catch "";
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.print("{{\"lines\": {d}, \"row\": {d}, \"col\": {d}, \"view_row\": {d}, \"view_col\": {d}, \"view_cols\": {d}, \"find_open\": {}, \"find_not_found\": {}, \"find_query\": ", .{ lines, ed.cursor.row, ed.cursor.col, ed.view.row, ed.view.col, ed.view.cols, ed.find.active, ed.find.not_found });
    try std.json.Stringify.value(ed.find.text(), .{}, &buf.writer);
    try buf.writer.print(", \"extra_cursors\": {d}", .{ed.extra_cursors.items.len});
    try buf.writer.print(", \"visual_rows\": {d}", .{ed.visualRowsOf(ed.cursor.row)});
    // Bounding-Box-Höhe des Editors (Clay, Vorframe): muss über Frames konstant bleiben.
    try buf.writer.print(", \"height\": {d:.1}, \"visible_rows\": {d}", .{ ed.height, ed.visibleLineCount() });
    try buf.writer.print(", \"minimap\": {}, \"word_wrap\": {}, \"whitespace\": {}, \"indent_guides\": {}, \"find_case\": {}, \"find_word\": {}, \"find_regex\": {}, \"bracket_pair\": ", .{ ed.show_minimap, ed.word_wrap, ed.show_whitespace, ed.show_indent_guides, ed.find.case_sensitive, ed.find.whole_word, ed.find.use_regex });
    if (ed.bracket_pair) |bp| {
        try buf.writer.print("[[{d}, {d}], [{d}, {d}]]", .{ bp[0].row, bp[0].col, bp[1].row, bp[1].col });
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll(", \"selection\": ");
    if (ed.selectionRange()) |r| {
        try buf.writer.print("{{\"begin\": [{d}, {d}], \"end\": [{d}, {d}]}}", .{ r.begin.row, r.begin.col, r.end.row, r.end.col });
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll(", \"text\": ");
    try std.json.Stringify.value(text, .{}, &buf.writer);
    try buf.writer.writeAll("}");
    return buf.written();
}

/// Textauswahl der aktiven Markdown-Vorschau: `text` (null ohne Auswahl) und die Zahl der im
/// letzten Frame gezeichneten Zeilen (`md_line`-IDs 0..lines-1).
fn mdSelection(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    const text: ?[]u8 = if (ctx.ui_system.activeMarkdownView()) |v| blk: {
        try buf.writer.print("{{\"open\": true, \"lines\": {d}, \"text\": ", .{v.frame_lines.items.len});
        break :blk v.selectedText(dc.arena());
    } else if (ctx.ui_system.isChatTabActive()) blk: {
        try buf.writer.writeAll("{\"open\": true, \"lines\": null, \"text\": ");
        break :blk ctx.ui_system.ai_chat.selectedText(dc.arena());
    } else return "{\"open\": false}";
    if (text) |t| {
        try std.json.Stringify.value(t, .{}, &buf.writer);
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll("}");
    return buf.written();
}

/// Clay-Box einer Textzeile (`md_line`) in der Bubble der Chat-Nachricht `msg`.
fn chatLineBounds(ctx: *E2EContext, dc: *zigjr.DispatchCtx, msg: i64, line: i64) ![]const u8 {
    const chat = &ctx.ui_system.ai_chat;
    chat.mutex.lock();
    defer chat.mutex.unlock();
    if (msg < 0 or @as(usize, @intCast(msg)) >= chat.messages.items.len) return boundsJson(dc, .{ .found = false, .bounding_box = .{ .x = 0, .y = 0, .width = 0, .height = 0 } });
    const v = &chat.messages.items[@intCast(msg)].md;
    return boundsJson(dc, clay.getElementData(v.idi("md_line", @intCast(line))));
}

/// Inhalt des offenen Buffers zu `path` (wie ihn der Editor zeigt), oder open=false.
fn fileText(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    if (ctx.ui_system.open_buffers.get(path)) |b| {
        const text = b.store_to_string_cached(b.root, b.file_eol_mode);
        try buf.writer.writeAll("{\"open\": true, \"text\": ");
        try std.json.Stringify.value(text, .{}, &buf.writer);
        try buf.writer.writeAll("}");
    } else {
        try buf.writer.writeAll("{\"open\": false}");
    }
    return buf.written();
}

/// Chat-Tab in irgendeinem Pane aktivieren (Pane + Tab), damit Eingaben dort landen.
fn focusChat(ctx: *E2EContext, _: *zigjr.DispatchCtx) ![]const u8 {
    const ui = ctx.ui_system;
    if (findChatLeaf(ui.root_pane)) |leaf| {
        const tb = &leaf.data.leaf.tab_bar;
        for (tb.tabs.items, 0..) |tab, i| {
            if (tab.kind == .chat) {
                ui.active_pane = leaf;
                tb.setActive(i);
                return "ok";
            }
        }
    }
    return "error: no chat tab";
}

fn findChatLeaf(pane: *@import("ui/pane.zig").Pane) ?*@import("ui/pane.zig").Pane {
    switch (pane.data) {
        .leaf => |leaf| {
            for (leaf.tab_bar.tabs.items) |tab| if (tab.kind == .chat) return pane;
            return null;
        },
        .split => |s| {
            if (findChatLeaf(s.children[0])) |p| return p;
            return findChatLeaf(s.children[1]);
        },
    }
}

fn writeAllTabs(pane: *const @import("ui/pane.zig").Pane, w: *std.Io.Writer, first: *bool) !void {
    switch (pane.data) {
        .leaf => |leaf| for (leaf.tab_bar.tabs.items) |tab| {
            if (!first.*) try w.writeAll(", ");
            first.* = false;
            try std.json.Stringify.value(tab.path, .{}, w);
        },
        .split => |s| {
            try writeAllTabs(s.children[0], w, first);
            try writeAllTabs(s.children[1], w, first);
        },
    }
}

/// Index des aktiven Leaf-Panes in Baumreihenfolge (links/oben zuerst)
fn activePaneIndex(ui: *ui_mod.UI) usize {
    var idx: usize = 0;
    var found: usize = 0;
    leafIndexOf(ui.root_pane, ui.active_pane, &idx, &found);
    return found;
}

fn leafIndexOf(pane: *const @import("ui/pane.zig").Pane, target: *const @import("ui/pane.zig").Pane, idx: *usize, found: *usize) void {
    switch (pane.data) {
        .leaf => {
            if (pane == target) found.* = idx.*;
            idx.* += 1;
        },
        .split => |s| {
            leafIndexOf(s.children[0], target, idx, found);
            leafIndexOf(s.children[1], target, idx, found);
        },
    }
}

fn countLeaves(pane: *const @import("ui/pane.zig").Pane) usize {
    return switch (pane.data) {
        .leaf => 1,
        .split => |s| countLeaves(s.children[0]) + countLeaves(s.children[1]),
    };
}

/// UI-Zustand für Tests: Dialog, Header-Menü, Explorer-Fokus, aktiver Tab.
/// Anders als element_bounds liest das den echten Zustand; Clay behält
/// Element-Daten verschwundener Elemente noch eine Weile im Hash.
fn uiState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const ui = ctx.ui_system;
    const tb = ui.getActiveTabBar();
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.writeAll("{\"dialog\": ");
    if (ui.active_dialog) |ad| {
        try std.json.Stringify.value(ad.dialog.title, .{}, &buf.writer);
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll(", \"open_menu\": ");
    if (ui.open_menu) |mi| {
        try buf.writer.print("\"{s}\"", .{@import("shortcuts").menus[mi].title});
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.print(
        \\, "explorer_focused": {}, "show_file_explorer": {}, "picker_open": {}, "shortcuts_open": {}, "tab_count": {d}, "active_tab":
    , .{ ui.explorer_focused, ui.show_file_explorer, ui.folder_picker.visible, ui.shortcuts_dialog_open, tb.count() });
    if (tb.active_index) |idx| {
        try buf.writer.print("{d}", .{idx});
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.print(", \"pane_count\": {d}, \"agent_confirm_pending\": {}", .{ countLeaves(ui.root_pane), ui.agent_confirm != null });
    try buf.writer.print(", \"clipboard_text\": {f}, \"explorer_selection_count\": {d}, \"dialog_focused\": {d}", .{
        std.json.fmt(ui.last_clipboard_text orelse "", .{}), ui.file_explorer.selectionCount(), if (ui.active_dialog) |ad| ad.focused else 0,
    });
    try buf.writer.print(", \"last_frame_ms\": {d:.2}, \"max_frame_ms\": {d:.2}, \"lsp\": \"{s}\", \"tab_switcher\": {d}", .{ ui.last_frame_ms, ui.takeMaxFrameMs(), ui.lspStatus(), if (ui.tab_switcher) |p| @as(i64, @intCast(p)) else @as(i64, -1) });
    // Glyph-Cache-Diagnose: gerasterte Glyphen und komplette Leerungen seit Start.
    const glyph_stats = if (@import("rendering/mod.zig").Renderer.g_text_renderer) |tr| tr.ts_ptr.cache.getStats() else null;
    try buf.writer.print(", \"glyph_rasterized\": {d}, \"glyph_cache_clears\": {d}, \"glyph_cache_entries\": {d}", .{
        if (glyph_stats) |s| s.rasterized else 0, if (glyph_stats) |s| s.clears else 0, if (glyph_stats) |s| s.entries else 0,
    });
    try buf.writer.print(", \"active_pane_index\": {d}, \"light_theme\": {}, \"font_size\": {d}, \"autosave\": {}, \"menu_highlight\": {d}, \"shortcuts_scroll\": {d:.0}, \"toast\": ", .{
        activePaneIndex(ui), ui.isLightTheme(), ui.getActiveEditor().font_size, ui.autosave, ui.menu_highlight orelse 999, ui.shortcuts_scroll_y,
    });
    try std.json.Stringify.value(ui.lastToast(), .{}, &buf.writer);
    // Tooltip des letzten Frames (Icon-Schaltflächen nach 700 ms Hover)
    try buf.writer.writeAll(", \"tooltip\": ");
    try std.json.Stringify.value(@import("ui/components/tooltip.zig").currentText(), .{}, &buf.writer);
    try buf.writer.writeAll(", \"status_text\": ");
    try std.json.Stringify.value(ui.statusText(dc.arena()), .{}, &buf.writer);
    try buf.writer.writeAll(", \"all_tabs\": [");
    var first_tab = true;
    try writeAllTabs(ui.root_pane, &buf.writer, &first_tab);
    try buf.writer.writeAll("]");
    try buf.writer.writeAll(", \"tabs\": [");
    for (tb.tabs.items, 0..) |tab, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        // Pfad escapen: Diff-Tabs trennen ihre Felder mit 0x1f, Windows-Pfade enthalten
        // Backslashes — beides ist in JSON ungültig.
        try buf.writer.print("{{\"path\": {f}, \"kind\": \"{s}\", \"modified\": {}}}", .{ std.json.fmt(tab.path, .{}), @tagName(tab.kind), tab.modified });
    }
    try buf.writer.writeAll("]}");
    return buf.written();
}

/// Zustand des "Open Folder…"-Dialogs: offen, Pfadfeld, Fehlermeldung, Unterordner.
/// Zustand der Folienvorschau des aktiven Tabs. `deck` ist false, wenn der Tab
/// keine Vorschau ist oder der Text kein Marp-Deck.
fn slideState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    if (ctx.ui_system.activeSlideDeckView()) |v| {
        try buf.writer.print(
            \\{{"deck": true, "slides": {d}, "current": {d}, "scale": {d:.4}, "font_size": {d}, "overflow": {}}}
        , .{ v.slideCount(), v.current_slide, v.slide_scale, v.slideFontSize(), v.slide_overflow });
    } else {
        try buf.writer.writeAll("{\"deck\": false, \"slides\": 0, \"current\": 0}");
    }
    return buf.written();
}

/// pdf_state: Seite und Seitenzahl der PDF-Vorschau, aus den vom Main-Thread
/// gesetzten Feldern.
fn pdfState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    const pages = ctx.pdf_pages.load(.seq_cst);
    try buf.writer.print(
        \\{{"pdf": {}, "page": {d}, "pages": {d}}}
    , .{ pages > 0, ctx.pdf_page.load(.seq_cst), pages });
    return buf.written();
}

fn folderPickerState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const fp = &ctx.ui_system.folder_picker;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.print(
        \\{{"open": {}, "path": {f}, "error":
    , .{ fp.visible, std.json.fmt(fp.model.edit.text(), .{}) });
    if (fp.model.error_msg) |m| {
        try std.json.Stringify.value(m, .{}, &buf.writer);
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll(", \"entries\": [");
    for (fp.model.entries, 0..) |name, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try std.json.Stringify.value(name, .{}, &buf.writer);
    }
    try buf.writer.writeAll("]}");
    return buf.written();
}

/// Simuliert einen Klick im File-Explorer (setzt file_to_open, wie ein echter Klick).
/// Anders als open_file läuft das durch den Explorer-Pfad in main.zig.
var explorer_open_buf: [std.fs.max_path_bytes]u8 = undefined;
fn explorerOpen(ctx: *E2EContext, _: *zigjr.DispatchCtx, path: []const u8) ![]const u8 {
    log.info("RPC: explorer_open('{s}')", .{path});
    if (path.len > explorer_open_buf.len) return "error: path too long";
    @memcpy(explorer_open_buf[0..path.len], path);
    ctx.ui_system.file_explorer.file_to_open = explorer_open_buf[0..path.len];
    @import("wio").cancelWait();
    return "ok";
}

/// App-State zurückgeben (JSON)
pub fn getState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const explorer = &ctx.ui_system.file_explorer;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    const root = if (explorer.nodes.items.len > 0) explorer.nodes.items[0].path else "";
    try buf.writer.print(
        \\{{"root": {f}, "visible_entries": {d}, "nodes": {d}, "selected":
    , .{ std.json.fmt(root, .{}), explorer.visible_entries.items.len, explorer.nodes.items.len });
    if (explorer.selected_index) |idx| {
        try buf.writer.print("{d}", .{idx});
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll("}");
    return buf.written();
}

/// Pane teilen
pub fn splitPane(ctx: *E2EContext, _: *zigjr.DispatchCtx, direction: []const u8) ![]const u8 {
    log.info("RPC: split_pane('{s}')", .{direction});
    if (std.mem.eql(u8, direction, "h")) {
        ctx.ui_system.pending_split = .horizontal;
    } else {
        ctx.ui_system.pending_split = .vertical;
    }

    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();

    return "ok";
}

pub fn showContextMenuRpc(ctx: *E2EContext, _: *zigjr.DispatchCtx, x: f64, y: f64) !void {
    log.info("RPC: show_context_menu({d}, {d})", .{ x, y });
    const ed = ctx.ui_system.getActiveEditor();
    ed.show_context_menu = true;
    ed.context_menu_x = @floatCast(x);
    ed.context_menu_y = @floatCast(y);
}

fn closeActiveTabRpc(ctx: *E2EContext, _: *zigjr.DispatchCtx) !void {
    log.info("RPC: close_active_tab()", .{});
    const tb = ctx.ui_system.getActiveTabBar();
    if (tb.active_index) |idx| {
        // Nicht direkt schließen: im Fenstermodus rendert der Main-Thread gerade
        // mit dieser Tab-Liste. Wie das UI selbst über pending_tab_closes gehen.
        try ctx.ui_system.pending_tab_closes.append(ctx.ui_system.allocator, .{
            .pane = ctx.ui_system.active_pane,
            .index = idx,
        });
    }
    @import("wio").cancelWait();
}

/// Screenshot: rendert aktuellen Frame und speichert als PPM nach ./tmp/vulkan-screenshot.ppm
const screenshot_path = "./tmp/vulkan-screenshot.ppm";

pub fn screenshot(ctx: *E2EContext, _: *zigjr.DispatchCtx) ![]const u8 {
    log.info("=== SCREENSHOT RPC CALLED ===", .{});

    if (ctx.defer_input) {
        // Fenstermodus: nicht hier rendern (Main-Thread rendert gerade), sondern
        // anfordern und auf den nächsten Frame warten.
        ctx.screenshot_done.store(false, .seq_cst);
        ctx.screenshot_failed.store(false, .seq_cst);
        ctx.screenshot_requested.store(true, .seq_cst);
        @import("wio").cancelWait();
        var waited_ms: u32 = 0;
        while (!ctx.screenshot_done.load(.seq_cst)) : (waited_ms += 10) {
            if (waited_ms > 5000) return "error: screenshot timeout";
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return if (ctx.screenshot_failed.load(.seq_cst)) "error: screenshot failed" else screenshot_path;
    }

    // Headless: UI hier rendern, es gibt keinen konkurrierenden Frame.
    const commands = ctx.ui_system.renderExample(null);
    return writeScreenshot(ctx, commands);
}

/// Vom Main-Thread nach renderExample() aufrufen: schreibt den angeforderten Screenshot
/// aus den Render-Commands des aktuellen Frames.
pub fn serviceScreenshot(ctx: *E2EContext, commands: []clay.RenderCommand) void {
    if (!ctx.screenshot_requested.swap(false, .seq_cst)) return;
    _ = writeScreenshot(ctx, commands) catch |err| {
        log.err("screenshot failed: {}", .{err});
        ctx.screenshot_failed.store(true, .seq_cst);
    };
    ctx.screenshot_done.store(true, .seq_cst);
}

fn writeScreenshot(ctx: *E2EContext, commands: []clay.RenderCommand) ![]const u8 {
    const renderer_ptr = @import("rendering/mod.zig").Renderer.g_renderer_ptr orelse return "error: no renderer";
    const renderer = renderer_ptr;
    const mod = @import("rendering/mod.zig").Renderer;
    const path = screenshot_path;
    log.info("screenshot: got {d} commands", .{commands.len});

    // Debug: count command types
    var rect_count: usize = 0;
    var text_count: usize = 0;
    var image_count: usize = 0;
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .rectangle => rect_count += 1,
            .text => text_count += 1,
            .image => image_count += 1,
            else => {},
        }
    }
    log.debug("screenshot: rects={d} texts={d} images={d}", .{ rect_count, text_count, image_count });
    // ZID_DEBUG=1: jeden Command mit Typ, Box und Textanfang ausgeben (Diagnose wachsender Layouts).
    for (commands, 0..) |cmd, ci| {
        const bb = cmd.bounding_box;
        if (cmd.command_type == .text) {
            const sc = cmd.render_data.text.string_contents;
            const len: usize = @intCast(@max(sc.length, 0));
            const shown = sc.chars[0..@min(len, 40)];
            log.debug("cmd[{d}] text id={d} box=({d:.0},{d:.0} {d:.0}x{d:.0}) len={d} \"{s}\"", .{ ci, cmd.id, bb.x, bb.y, bb.width, bb.height, len, shown });
        } else {
            log.debug("cmd[{d}] {s} id={d} box=({d:.0},{d:.0} {d:.0}x{d:.0})", .{ ci, @tagName(cmd.command_type), cmd.id, bb.x, bb.y, bb.width, bb.height });
        }
    }
    const w = if (renderer.width == 0) mod.g_viewport_width else renderer.width;
    const h = if (renderer.height == 0) mod.g_viewport_height else renderer.height;
    log.info("screenshot: rendering {d}x{d}", .{ w, h });
    const rgba = renderer.headlessRenderToBuffer(
        ctx.allocator,
        w,
        h,
        mod.g_clay_rdr,
        mod.g_text_gpu,
        mod.g_text_renderer,
        mod.g_image_rdr,
        mod.g_svg_gpu,
        mod.g_svg_atlas,
        commands,
    ) catch |err| {
        log.err("headlessRenderToBuffer failed: {}, using clear color", .{err});
        // Fallback: just render clear color
        try renderer.headlessScreenshot(ctx.allocator, path);
        return path;
    };
    defer ctx.allocator.free(rgba);

    // Write PPM (funktioniert!)
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var header: [256]u8 = undefined;
    const header_slice = std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ w, h }) catch unreachable;
    try file.writeAll(header_slice);

    // WGPU liefert RGBA -> PPM braucht R,G,B. Erst komplett in den Speicher,
    // dann ein writeAll: pro Pixel ein Syscall dauerte bei 2M Pixeln Sekunden.
    const pixel_total: usize = @as(usize, w) * @as(usize, h);
    const rgb = try ctx.allocator.alloc(u8, pixel_total * 3);
    defer ctx.allocator.free(rgb);
    var i: usize = 0;
    while (i < pixel_total) : (i += 1) {
        rgb[i * 3 + 0] = rgba[i * 4 + 0];
        rgb[i * 3 + 1] = rgba[i * 4 + 1];
        rgb[i * 3 + 2] = rgba[i * 4 + 2];
    }
    try file.writeAll(rgb);
    try file.sync();
    log.info("screenshot: wrote PPM to {s}", .{path});

    return path;
}

/// App beenden
fn shutdown(ctx: *E2EContext) zigjr.DispatchResult {
    log.info("RPC: shutdown", .{});
    ctx.shutdown_flag.store(true, .seq_cst);
    return zigjr.DispatchResult.asEndStream();
}

/// Benchmark: Datei öffnen mit Zeitmessung (mehrere Iterationen)
/// Parameter: path (string), iterations (i64, default 10)
/// Rückgabe: JSON mit min, max, avg, total Zeiten in Millisekunden
fn benchmarkOpenFile(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8, iterations_i64: i64) ![]const u8 {
    const iterations: usize = @intCast(@max(1, @min(iterations_i64, 100)));
    log.info("RPC: benchmark_open_file('{s}', {d} iterations)", .{ path, iterations });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const bench_alloc = gpa.allocator();

    var total_ms: u128 = 0;
    var min_ms: u128 = std.math.maxInt(u128);
    var max_ms: u128 = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Schließe alle bestehenden Tabs für sauberen Benchmark
        while (ctx.ui_system.getActiveTabBar().count() > 0) {
            ctx.ui_system.getActiveTabBar().closeTab(0);
        }

        const t_start = std.time.microTimestamp();
        ctx.ui_system.getActiveTabBar().openFile(path) catch |err| {
            const err_msg = try std.fmt.allocPrint(dc.arena(),
                \\{{"error": "openFile failed: {}", "iterations_completed": {d}}}
            , .{ err, i });
            return err_msg;
        };
        const t_end = std.time.microTimestamp();

        const elapsed_us: u128 = @intCast(t_end - t_start);
        const elapsed_ms: u128 = elapsed_us / 1000;
        const remainder_us: u128 = elapsed_us % 1000;
        // Sub-ms Genauigkeit als Dezimalzahl speichern (für spätere Formatierung)
        const precise_ms_x100 = (elapsed_ms * 100) + (remainder_us * 100 / 1000);

        total_ms += precise_ms_x100;
        if (precise_ms_x100 < min_ms) min_ms = precise_ms_x100;
        if (precise_ms_x100 > max_ms) max_ms = precise_ms_x100;
    }

    const avg_ms_x100 = total_ms / iterations;
    const min_ms_str = formatMsX100(bench_alloc, min_ms) catch "error";
    const max_ms_str = formatMsX100(bench_alloc, max_ms) catch "error";
    const avg_ms_str = formatMsX100(bench_alloc, avg_ms_x100) catch "error";
    const total_ms_str = formatMsX100(bench_alloc, total_ms) catch "error";

    const json = try std.fmt.allocPrint(dc.arena(),
        \\{{"path": {f}, "iterations": {d}, "min_ms": {s}, "max_ms": {s}, "avg_ms": {s}, "total_ms": {s}}}
    , .{ std.json.fmt(path, .{}), iterations, min_ms_str, max_ms_str, avg_ms_str, total_ms_str });

    return json;
}

/// Hilfsfunktion: Formatiere Millisekunden * 100 als "X.XXX" String
fn formatMsX100(alloc: std.mem.Allocator, ms_x100: u128) ![]const u8 {
    const whole = ms_x100 / 100;
    const frac = ms_x100 % 100;
    return std.fmt.allocPrint(alloc, "{d}.{d:0>2}", .{ whole, frac });
}

/// Benchmark: Datei komplett laden (readFileAlloc + setText) — misst echten I/O + Parsing Overhead
fn benchmarkLoadFile(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8, iterations_i64: i64) ![]const u8 {
    const iterations: usize = @intCast(@max(1, @min(iterations_i64, 100)));
    log.info("RPC: benchmark_load_file('{s}', {d} iterations)", .{ path, iterations });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const bench_alloc = gpa.allocator();

    var total_ms: u128 = 0;
    var min_ms: u128 = std.math.maxInt(u128);
    var max_ms: u128 = 0;
    var first_load_ms: u128 = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const t_start = std.time.microTimestamp();

        // Phase 1: File lesen (I/O)
        const t_io_start = std.time.microTimestamp();
        const content = std.fs.cwd().readFileAlloc(bench_alloc, path, 64 * 1024 * 1024) catch |err| {
            const err_msg = try std.fmt.allocPrint(dc.arena(),
                \\{{"error": "readFileAlloc failed: {}", "iterations_completed": {d}}}
            , .{ err, i });
            return err_msg;
        };
        defer bench_alloc.free(content);
        const t_io_end = std.time.microTimestamp();

        // Phase 2: Text parsen + tokenisieren (CPU)
        const t_parse_start = std.time.microTimestamp();
        ctx.ui_system.getActiveEditor().setText(content);
        const t_parse_end = std.time.microTimestamp();

        const t_end = std.time.microTimestamp();

        const elapsed_us: u128 = @intCast(t_end - t_start);
        const io_us: u128 = @intCast(t_io_end - t_io_start);
        const parse_us: u128 = @intCast(t_parse_end - t_parse_start);

        const elapsed_ms: u128 = elapsed_us / 1000;
        const remainder_us: u128 = elapsed_us % 1000;
        const precise_ms_x100 = (elapsed_ms * 100) + (remainder_us * 100 / 1000);

        if (i == 0) {
            first_load_ms = precise_ms_x100;
            log.info("  [iter 0] I/O={d}us, parse={d}us, total={d}us", .{ io_us, parse_us, elapsed_us });
        }

        total_ms += precise_ms_x100;
        if (precise_ms_x100 < min_ms) min_ms = precise_ms_x100;
        if (precise_ms_x100 > max_ms) max_ms = precise_ms_x100;
    }

    const avg_ms_x100 = total_ms / iterations;
    const min_ms_str = formatMsX100(bench_alloc, min_ms) catch "error";
    const max_ms_str = formatMsX100(bench_alloc, max_ms) catch "error";
    const avg_ms_str = formatMsX100(bench_alloc, avg_ms_x100) catch "error";
    const total_ms_str = formatMsX100(bench_alloc, total_ms) catch "error";

    // Datei-Größe ermitteln für Kontext
    const file_stat = std.fs.cwd().statFile(path) catch null;
    const file_size = if (file_stat) |s| s.size else 0;

    const json = try std.fmt.allocPrint(dc.arena(),
        \\{{"path": {f}, "file_size_bytes": {d}, "iterations": {d}, "first_load_ms": {s}, "min_ms": {s}, "max_ms": {s}, "avg_ms": {s}, "total_ms": {s}}}
    , .{ std.json.fmt(path, .{}), file_size, iterations, formatMsX100(bench_alloc, first_load_ms) catch "error", min_ms_str, max_ms_str, avg_ms_str, total_ms_str });

    return json;
}
