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
    try rpc_dispatcher.addWithCtx("benchmark_open_file", ctx, benchmarkOpenFile);
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

/// Benchmark: Datei öffnen mit Zeitmessung (mehrere Iterationen)
/// Parameter: path (string), iterations (i64, default 10)
/// Rückgabe: JSON mit min, max, avg, total Zeiten in Millisekunden
fn benchmarkOpenFile(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8, iterations_i64: i64) ![]const u8 {
    _ = dc;
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
        while (ctx.ui_system.tab_bar.count() > 0) {
            ctx.ui_system.tab_bar.closeTab(0);
        }

        const t_start = std.time.microTimestamp();
        ctx.ui_system.tab_bar.openFile(path) catch |err| {
            const err_msg = try std.fmt.allocPrint(ctx.allocator,
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

    const json = try std.fmt.allocPrint(ctx.allocator,
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
