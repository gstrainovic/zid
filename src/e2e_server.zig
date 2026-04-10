//! E2E Test JSON-RPC Server für vulkan-ed
//!
//! Erlaubt programmatische Steuerung der App während sie läuft.
//! Starten mit: ./vulkan-ed --e2e
//!
//! Commands:
//!   open_folder(path)  - Ordner im File Explorer öffnen
//!   click(x, y)        - Maus-Klick an Koordinate
//!   get_state()        - App-State zurückgeben
//!   shutdown()         - App beenden

const std = @import("std");
const zigjr = @import("zigjr");
const ui_mod = @import("ui/mod.zig");

const log = std.log.scoped(.e2e_server);

const PORT = 9999;

/// E2E Server Context - teilt State mit Main Thread
pub const E2EContext = struct {
    allocator: std.mem.Allocator,
    ui_system: *ui_mod.UI,
    shutdown_flag: std.atomic.Value(bool),
    server: std.net.Server,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, ui_system: *ui_mod.UI, server: std.net.Server) Self {
        return Self{
            .allocator = allocator,
            .ui_system = ui_system,
            .shutdown_flag = std.atomic.Value(bool).init(false),
            .server = server,
        };
    }
};

/// Dispatcher mit allen E2E-Handlern erstellen
pub fn createDispatcher(alloc: std.mem.Allocator, ctx: *E2EContext) !*zigjr.RpcDispatcher {
    var rpc_dispatcher = try alloc.create(zigjr.RpcDispatcher);
    rpc_dispatcher.* = try zigjr.RpcDispatcher.init(alloc);

    try rpc_dispatcher.addWithCtx("open_folder", ctx, openFolder);
    try rpc_dispatcher.addWithCtx("close_tab", ctx, closeTab);
    try rpc_dispatcher.addWithCtx("set_active_tab", ctx, setActiveTab);
    try rpc_dispatcher.addWithCtx("click", ctx, click);
    try rpc_dispatcher.addWithCtx("get_state", ctx, getState);
    try rpc_dispatcher.addWithCtx("shutdown", ctx, shutdown);

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
fn openFolder(ctx: *E2EContext, path: []const u8) ![]const u8 {
    log.info("RPC: open_folder('{s}')", .{path});

    ctx.ui_system.file_explorer.loadDirectory(path) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "error: {}", .{err});
        return msg;
    };

    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Tab schließen (nach Index)
fn closeTab(ctx: *E2EContext, index: i64) ![]const u8 {
    log.info("RPC: close_tab({d})", .{index});

    if (index < 0 or @as(usize, @intCast(index)) >= ctx.ui_system.tab_bar.count()) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "error: tab index {d} out of range (only {d} tabs)", .{ index, ctx.ui_system.tab_bar.count() });
        return msg;
    }

    ctx.ui_system.tab_bar.closeTab(@intCast(index));

    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Aktiven Tab wechseln (setzt pending_switch_path)
fn setActiveTab(ctx: *E2EContext, index: i64) ![]const u8 {
    log.info("RPC: set_active_tab({d})", .{index});

    if (index < 0 or @as(usize, @intCast(index)) >= ctx.ui_system.tab_bar.count()) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "error: tab index {d} out of range (only {d} tabs)", .{ index, ctx.ui_system.tab_bar.count() });
        return msg;
    }

    ctx.ui_system.tab_bar.setActive(@intCast(index));

    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Maus-Klick an Koordinate (simuliert)
fn click(ctx: *E2EContext, dc: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    log.info("RPC: click({d}, {d})", .{ x, y });

    // Mouse move + down + up simulieren
    ctx.ui_system.handleMouseMove(@floatCast(x), @floatCast(y));
    ctx.ui_system.handleMouseDown(@floatCast(x), @floatCast(y));
    ctx.ui_system.handleMouseUp();

    return dc.arena().dupe(u8, "ok") catch "error: out of memory";
}

/// App-State zurückgeben (JSON)
fn getState(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    const explorer = &ctx.ui_system.file_explorer;
    var buf = std.Io.Writer.Allocating.init(dc.arena());

    try buf.writer.print(
        \\{{"visible_entries": {d}, "nodes": {d}, "selected":
    , .{
            explorer.visible_entries.items.len,
            explorer.nodes.items.len,
        });

    if (explorer.selected_index) |idx| {
        try buf.writer.print("{d}", .{idx});
    } else {
        try buf.writer.writeAll("null");
    }

    try buf.writer.writeAll("}");
    return buf.written();
}

/// App beenden
fn shutdown(ctx: *E2EContext) zigjr.DispatchResult {
    log.info("RPC: shutdown", .{});
    ctx.shutdown_flag.store(true, .seq_cst);
    return zigjr.DispatchResult.asEndStream();
}
