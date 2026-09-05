//! E2E Test JSON-RPC Server für vulkan-ed
//!
//! Erlaubt programmatische Steuerung der App während sie läuft.
//! Starten mit: ./vulkan-ed --e2e
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

const log = std.log.scoped(.e2e_server);

const PORT = 9999;

const Point = struct { x: f32, y: f32 };

/// Eingabe-Ereignis aus einem RPC. Im Fenstermodus wird es nicht im Server-Thread
/// angewendet, sondern vom Main-Thread vor dem Rendern (drainInputs), sonst
/// rennt der Handler in einen laufenden Clay-Layout-Durchgang (Absturz).
pub const InputEvent = union(enum) {
    click: Point,
    right_click: Point,
    move: Point,
    key: struct { btn: @import("wio").Button, ctrl: bool, shift: bool = false },
    char: u21,
    /// Mausrad an Position: lines > 0 hoch, < 0 runter
    scroll: struct { x: f32, y: f32, lines: i32 },
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
    }
};

/// Ereignis anwenden oder (Fenstermodus) für den Main-Thread puffern.
fn dispatchInput(ctx: *E2EContext, ev: InputEvent) void {
    if (!ctx.defer_input) {
        applyInput(ctx.ui_system, ev);
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
        for (batch[0..n]) |ev| applyInput(ctx.ui_system, ev);
    }
}

fn applyInput(ui: *ui_mod.UI, ev: InputEvent) void {
    switch (ev) {
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
        .move => |p| {
            ui.setPointerState(p.x, p.y, false);
            ui.handleMouseMove(p.x, p.y);
        },
        .key => |k| {
            ui.setCtrlState(k.ctrl);
            ui.setShiftState(k.shift);
            ui.handleKeyPress(k.btn);
            ui.setCtrlState(false);
            ui.setShiftState(false);
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
    try rpc_dispatcher.addWithCtx("open_file", ctx, openFile);
    try rpc_dispatcher.addWithCtx("close_tab", ctx, closeTab);
    try rpc_dispatcher.addWithCtx("setActiveTab", ctx, setActiveTab);
    try rpc_dispatcher.addWithCtx("click", ctx, click);
    try rpc_dispatcher.addWithCtx("right_click", ctx, rightClick);
    try rpc_dispatcher.addWithCtx("scroll", ctx, scrollAt);
    try rpc_dispatcher.addWithCtx("move_mouse", ctx, moveMouse);
    try rpc_dispatcher.addWithCtx("type_text", ctx, typeText);
    try rpc_dispatcher.addWithCtx("key_press", ctx, keyPress);
    try rpc_dispatcher.addWithCtx("key_press_mods", ctx, keyPressMods);
    try rpc_dispatcher.addWithCtx("open_terminal", ctx, openTerminalRpc);
    try rpc_dispatcher.addWithCtx("open_chat", ctx, openChatRpc);
    try rpc_dispatcher.addWithCtx("get_chat_input", ctx, getChatInput);
    try rpc_dispatcher.addWithCtx("get_active_tab", ctx, getActiveTabDebug);
    try rpc_dispatcher.addWithCtx("explorer_open", ctx, explorerOpen);
    try rpc_dispatcher.addWithCtx("explorer_entries", ctx, explorerEntries);
    try rpc_dispatcher.addWithCtx("element_bounds", ctx, elementBounds);
    try rpc_dispatcher.addWithCtx("element_bounds_i", ctx, elementBoundsIndexed);
    try rpc_dispatcher.addWithCtx("folder_picker_state", ctx, folderPickerState);
    try rpc_dispatcher.addWithCtx("ui_state", ctx, uiState);
    try rpc_dispatcher.addWithCtx("editor_lines", ctx, editorLines);
    try rpc_dispatcher.addWithCtx("editor_state", ctx, editorState);
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

    ctx.ui_system.file_explorer.loadDirectory(path) catch |err| {
        const msg = try std.fmt.allocPrint(dc.arena(), "error: {}", .{err});
        return msg;
    };

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
pub fn openFile(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8) ![]const u8 {
    log.info("RPC: open_file('{s}')", .{path});

    ctx.ui_system.getActiveTabBar().openFile(path) catch |err| {
        const msg = try std.fmt.allocPrint(dc.arena(), "error: {}", .{err});
        return msg;
    };

    // Wichtig: In main.zig wird pending_switch_path abgefragt, um den Editor-Inhalt zu setzen.
    // tab_bar.openFile setzt active_index, aber nicht automatisch pending_switch_path (außer in setActive).
    // Wir rufen setActive auf, um den Loader-Flow in main.zig zu triggern.
    if (ctx.ui_system.getActiveTabBar().active_index) |idx| {
        ctx.ui_system.getActiveTabBar().setActive(idx);
    }

    // Event Loop aufwecken, damit render_commands sofort generiert und geladen werden!
    const wio = @import("wio");
    wio.cancelWait();

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

fn buttonFromName(name: []const u8) ?@import("wio").Button {
    const Button = @import("wio").Button;
    const named = [_]struct { []const u8, Button }{
        .{ "enter", .enter },       .{ "backspace", .backspace }, .{ "escape", .escape },
        .{ "delete", .delete },     .{ "tab", .tab },             .{ "grave", .grave },
        .{ "up", .up },             .{ "down", .down },           .{ "left", .left },
        .{ "right", .right },       .{ "home", .home },           .{ "end", .end },
        .{ "page_up", .page_up },   .{ "page_down", .page_down }, .{ "f1", .f1 },
        .{ "f2", .f2 },
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
            \\{{"index": {d}, "kind": "{s}", "name": "{s}", "is_active": {}, "modified": {}}}
        , .{ i, @tagName(tab.kind), tab.display_name, tab.is_active, tab.modified });
    }
    const ed = ctx.ui_system.getActiveEditor();
    try buf.writer.print("], \"editor_modified\": {}, \"editor_file\": \"{s}\"}}", .{ ed.is_modified, ed.buffer.get_file_path() });
    return buf.written();
}

/// Sichtbare Explorer-Einträge mit Viewport-Bounds, damit Tests Zeilen anklicken können.
fn explorerEntries(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const fx = &ctx.ui_system.file_explorer;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.print(
        \\{{"viewport": {{"x": {d:.1}, "y": {d:.1}, "w": {d:.1}, "h": {d:.1}}}, "row_height": {d:.1}, "scroll": {d:.1}, "renaming": {}, "menu_open": {}, "menu_x": {d:.1}, "menu_y": {d:.1}, "entries": [
    , .{
        fx.viewport_x,                                     fx.viewport_y,
        fx.viewport_width,                                 fx.viewport_height,
        @import("ui/file_explorer.zig").ROW_HEIGHT,        fx.scroll_offset_y,
        fx.isRenaming(),                                   fx.context_menu != null,
        if (fx.context_menu) |m| m.x else @as(f32, 0),     if (fx.context_menu) |m| m.y else @as(f32, 0),
    });
    for (fx.visible_entries.items, 0..) |e, i| {
        const node = fx.nodes.items[e.node_index];
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.print(
            \\{{"index": {d}, "name": "{s}", "path": "{s}", "is_folder": {}, "expanded": {}, "depth": {d}}}
        , .{ i, node.name, node.path, node.is_folder, e.is_expanded, e.depth });
    }
    try buf.writer.writeAll("]}");
    return buf.written();
}

/// Bounding-Box eines Clay-Elements aus dem letzten Layout (String-ID).
fn elementBounds(_: *E2EContext, dc: *zigjr.DispatchCtx, id: []const u8) ![]const u8 {
    return boundsJson(dc, clay.getElementData(clay.ElementId.ID(id)));
}

/// Bounding-Box eines indexierten Clay-Elements (IDI, z.B. fp_entry + 3).
fn elementBoundsIndexed(_: *E2EContext, dc: *zigjr.DispatchCtx, id: []const u8, index: i64) ![]const u8 {
    return boundsJson(dc, clay.getElementData(clay.ElementId.IDI(id, @intCast(index))));
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
    try buf.writer.print("{{\"lines\": {d}, \"row\": {d}, \"col\": {d}, \"text\": ", .{ lines, ed.cursor.row, ed.cursor.col });
    try std.json.Stringify.value(text, .{}, &buf.writer);
    try buf.writer.writeAll("}");
    return buf.written();
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
        try buf.writer.print("\"{s}\"", .{ad.dialog.title});
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.print(
        \\, "file_menu_open": {}, "explorer_focused": {}, "show_file_explorer": {}, "picker_open": {}, "tab_count": {d}, "active_tab":
    , .{ ui.file_menu_open, ui.explorer_focused, ui.show_file_explorer, ui.folder_picker.visible, tb.count() });
    if (tb.active_index) |idx| {
        try buf.writer.print("{d}", .{idx});
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll(", \"tabs\": [");
    for (tb.tabs.items, 0..) |tab, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.print("{{\"path\": \"{s}\", \"kind\": \"{s}\", \"modified\": {}}}", .{ tab.path, @tagName(tab.kind), tab.modified });
    }
    try buf.writer.writeAll("]}");
    return buf.written();
}

/// Zustand des "Open Folder…"-Dialogs: offen, Pfadfeld, Fehlermeldung, Unterordner.
fn folderPickerState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const fp = &ctx.ui_system.folder_picker;
    var buf = std.Io.Writer.Allocating.init(dc.arena());
    try buf.writer.print(
        \\{{"open": {}, "path": "{s}", "error": 
    , .{ fp.visible, fp.model.edit.text() });
    if (fp.model.error_msg) |m| {
        try buf.writer.print("\"{s}\"", .{m});
    } else {
        try buf.writer.writeAll("null");
    }
    try buf.writer.writeAll(", \"entries\": [");
    for (fp.model.entries, 0..) |name, i| {
        if (i > 0) try buf.writer.writeAll(", ");
        try buf.writer.print("\"{s}\"", .{name});
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
        \\{{"root": "{s}", "visible_entries": {d}, "nodes": {d}, "selected": 
    , .{ root, explorer.visible_entries.items.len, explorer.nodes.items.len });
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
        \\{{"path": "{s}", "iterations": {d}, "min_ms": {s}, "max_ms": {s}, "avg_ms": {s}, "total_ms": {s}}}
    , .{ path, iterations, min_ms_str, max_ms_str, avg_ms_str, total_ms_str });

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
        \\{{"path": "{s}", "file_size_bytes": {d}, "iterations": {d}, "first_load_ms": {s}, "min_ms": {s}, "max_ms": {s}, "avg_ms": {s}, "total_ms": {s}}}
    , .{ path, file_size, iterations, formatMsX100(bench_alloc, first_load_ms) catch "error", min_ms_str, max_ms_str, avg_ms_str, total_ms_str });

    return json;
}
