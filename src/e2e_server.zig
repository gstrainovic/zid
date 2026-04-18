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
    try rpc_dispatcher.addWithCtx("open_file", ctx, openFile);
    try rpc_dispatcher.addWithCtx("close_tab", ctx, closeTab);
    try rpc_dispatcher.addWithCtx("setActiveTab", ctx, setActiveTab);
    try rpc_dispatcher.addWithCtx("click", ctx, click);
    try rpc_dispatcher.addWithCtx("move_mouse", ctx, moveMouse);
    try rpc_dispatcher.addWithCtx("type_text", ctx, typeText);
    try rpc_dispatcher.addWithCtx("key_press", ctx, keyPress);
    try rpc_dispatcher.addWithCtx("open_terminal", ctx, openTerminalRpc);
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
fn openFolder(ctx: *E2EContext, path: []const u8) ![]const u8 {
    log.info("RPC: open_folder('{s}')", .{path});

    ctx.ui_system.file_explorer.loadDirectory(path) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "error: {}", .{err});
        return msg;
    };

    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Datei speichern
fn saveFile(ctx: *E2EContext, params: []const u8) ![]const u8 {
    _ = params;
    log.info("RPC: save_file()", .{});
    ctx.ui_system.getActiveEditor().save() catch |err| {
         const msg = try std.fmt.allocPrint(ctx.allocator, "error: {}", .{err});
         return msg;
    };
    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Datei im Editor öffnen (oder Bild-Vorschau)
fn openFile(ctx: *E2EContext, path: []const u8) ![]const u8 {
    log.info("RPC: open_file('{s}')", .{path});

    ctx.ui_system.getActiveTabBar().openFile(path) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "error: {}", .{err});
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

    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Tab schließen (nach Index)
fn closeTab(ctx: *E2EContext, index: i64) ![]const u8 {
    log.info("RPC: close_tab({d})", .{index});

    if (index < 0 or @as(usize, @intCast(index)) >= ctx.ui_system.getActiveTabBar().count()) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "error: tab index {d} out of range (only {d} tabs)", .{ index, ctx.ui_system.getActiveTabBar().count() });
        return msg;
    }

    ctx.ui_system.getActiveTabBar().closeTab(@intCast(index));
    @import("wio").cancelWait();

    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Aktiven Tab wechseln (setzt pending_switch_path)
fn setActiveTab(ctx: *E2EContext, index: i64) ![]const u8 {
    log.info("RPC: set_active_tab({d})", .{index});

    if (index < 0 or @as(usize, @intCast(index)) >= ctx.ui_system.getActiveTabBar().count()) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "error: tab index {d} out of range (only {d} tabs)", .{ index, ctx.ui_system.getActiveTabBar().count() });
        return msg;
    }

    ctx.ui_system.getActiveTabBar().setActive(@intCast(index));
    @import("wio").cancelWait();

    return ctx.allocator.dupe(u8, "ok") catch "error: out of memory";
}

/// Maus-Klick an Koordinate (simuliert)
fn click(ctx: *E2EContext, dc: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    log.info("RPC: click({d}, {d})", .{ x, y });

    // Pointer State für Clay setzen (Hover/Press)
    ctx.ui_system.setPointerState(@floatCast(x), @floatCast(y), true);
    
    // Legacy Handler (für Editor-Interna)
    ctx.ui_system.handleMouseMove(@floatCast(x), @floatCast(y));
    ctx.ui_system.handleMouseDown(@floatCast(x), @floatCast(y), .mouse_left);
    ctx.ui_system.handleMouseUp();
    
    // Pointer State zurücksetzen
    ctx.ui_system.setPointerState(@floatCast(x), @floatCast(y), false);

    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();

    return dc.arena().dupe(u8, "ok") catch "error: out of memory";
}

/// Maus-Rechtsklick an Koordinate
fn rightClick(ctx: *E2EContext, dc: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    log.info("RPC: right_click({d}, {d})", .{ x, y });

    // Pointer position setzen
    ctx.ui_system.setPointerState(@floatCast(x), @floatCast(y), true);
    ctx.ui_system.handleMouseDown(@floatCast(x), @floatCast(y), .mouse_right);
    ctx.ui_system.handleMouseUp();
    ctx.ui_system.setPointerState(@floatCast(x), @floatCast(y), false);

    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();

    return dc.arena().dupe(u8, "ok") catch "error: out of memory";
}

/// Maus-Bewegung zu Koordinate (simuliert)
fn moveMouse(ctx: *E2EContext, dc: *zigjr.DispatchCtx, x: f64, y: f64) ![]const u8 {
    log.info("RPC: move_mouse({d}, {d})", .{ x, y });

    // Pointer State für Clay setzen (Hover)
    ctx.ui_system.setPointerState(@floatCast(x), @floatCast(y), false);
    ctx.ui_system.handleMouseMove(@floatCast(x), @floatCast(y));

    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();

    return dc.arena().dupe(u8, "ok") catch "error: out of memory";
}

fn keyPress(ctx: *E2EContext, dc: *zigjr.DispatchCtx, key_name: []const u8, is_ctrl: bool) ![]const u8 {
    log.info("RPC: key_press('{s}', ctrl={})", .{ key_name, is_ctrl });
    
    ctx.ui_system.is_ctrl_down = is_ctrl;

    var btn: ?@import("wio").Button = null;
    if (std.mem.eql(u8, key_name, "enter")) btn = .enter
    else if (std.mem.eql(u8, key_name, "backspace")) btn = .backspace
    else if (std.mem.eql(u8, key_name, "k")) btn = .k
    else if (std.mem.eql(u8, key_name, "y")) btn = .y
    else if (std.mem.eql(u8, key_name, "n")) btn = .n;

    if (btn) |b| {
        ctx.ui_system.handleKeyPress(b);
        @import("wio").cancelWait();
        return dc.arena().dupe(u8, "ok") catch "error: out of memory";
    }
    
    return dc.arena().dupe(u8, "error: unknown key") catch "error: out of memory";
}

/// Text eintippen (simuliert)
fn typeText(ctx: *E2EContext, dc: *zigjr.DispatchCtx, text: []const u8) ![]const u8 {
    log.info("RPC: type_text('{s}')", .{text});

    // Wir iterieren über UTF-8 Zeichen
    var view = std.unicode.Utf8View.init(text) catch return "error: invalid utf8";
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        ctx.ui_system.handleChar(cp);
        // Kurze Pause simulieren (optional, aber realistischer)
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    @import("wio").cancelWait();

    return dc.arena().dupe(u8, "ok") catch "error: out of memory";
}

/// Terminal öffnen
fn openTerminalRpc(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    log.info("RPC: open_terminal", .{});
    ctx.ui_system.getActiveTabBar().openTerminal();
    
    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();

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

/// Pane teilen
fn splitPane(ctx: *E2EContext, dc: *zigjr.DispatchCtx, direction: []const u8) ![]const u8 {
    log.info("RPC: split_pane('{s}')", .{direction});
    if (std.mem.eql(u8, direction, "h")) {
        ctx.ui_system.pending_split = .horizontal;
    } else {
        ctx.ui_system.pending_split = .vertical;
    }
    
    // Event Loop aufwecken
    const wio = @import("wio");
    wio.cancelWait();
    
    return dc.arena().dupe(u8, "ok") catch "error: out of memory";
}

fn showContextMenuRpc(ctx: *E2EContext, dc: *zigjr.DispatchCtx, x: f64, y: f64) !void {
    _ = dc;
    log.info("RPC: show_context_menu({d}, {d})", .{ x, y });
    const ed = ctx.ui_system.getActiveEditor();
    ed.show_context_menu = true;
    ed.context_menu_x = @floatCast(x);
    ed.context_menu_y = @floatCast(y);
}

fn closeActiveTabRpc(ctx: *E2EContext, dc: *zigjr.DispatchCtx) !void {
    _ = dc;
    log.info("RPC: close_active_tab()", .{});
    const tb = ctx.ui_system.getActiveTabBar();
    if (tb.active_index) |idx| {
        tb.closeTab(idx);
    }
    @import("wio").cancelWait();
}

/// Screenshot: rendert aktuellen Frame und speichert als PPM nach /tmp/vulkan-screenshot.ppm
fn screenshot(ctx: *E2EContext, dc: *zigjr.DispatchCtx) ![]const u8 {
    _ = dc;
    log.info("=== SCREENSHOT RPC CALLED ===", .{});

    const renderer_ptr = @import("rendering/mod.zig").Renderer.g_renderer_ptr orelse return "error: no renderer";
    const renderer = renderer_ptr;
    const mod = @import("rendering/mod.zig").Renderer;

    const path = "/tmp/vulkan-screenshot.ppm";

    // Headless: UI rendern mit Clay
    const commands = ctx.ui_system.renderExample(null);
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
        return try ctx.allocator.dupe(u8, path);
    };
    defer ctx.allocator.free(rgba);

    // Write PPM
    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    var header: [256]u8 = undefined;
    const header_slice = std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ w, h }) catch unreachable;
    try file.writeAll(header_slice);

    // Textur ist bgra8_unorm → Bytes sind B,G,R,A → PPM braucht R,G,B
    var src_idx: usize = 0;
    var pixel_count: usize = 0;
    var rgb_pixel: [3]u8 = undefined;
    while (pixel_count < w * h) : (pixel_count += 1) {
        rgb_pixel[0] = rgba[src_idx + 2]; // R = BGRA[2]
        rgb_pixel[1] = rgba[src_idx + 1]; // G = BGRA[1]
        rgb_pixel[2] = rgba[src_idx + 0]; // B = BGRA[0]
        try file.writeAll(&rgb_pixel);
        src_idx += 4;
    }

    return try ctx.allocator.dupe(u8, path);
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
        while (ctx.ui_system.getActiveTabBar().count() > 0) {
            ctx.ui_system.getActiveTabBar().closeTab(0);
        }

        const t_start = std.time.microTimestamp();
        ctx.ui_system.getActiveTabBar().openFile(path) catch |err| {
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

/// Benchmark: Datei komplett laden (readFileAlloc + setText) — misst echten I/O + Parsing Overhead
fn benchmarkLoadFile(ctx: *E2EContext, dc: *zigjr.DispatchCtx, path: []const u8, iterations_i64: i64) ![]const u8 {
    _ = dc;
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
            const err_msg = try std.fmt.allocPrint(ctx.allocator,
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

    const json = try std.fmt.allocPrint(ctx.allocator,
        \\{{"path": "{s}", "file_size_bytes": {d}, "iterations": {d}, "first_load_ms": {s}, "min_ms": {s}, "max_ms": {s}, "avg_ms": {s}, "total_ms": {s}}}
    , .{ path, file_size, iterations, formatMsX100(bench_alloc, first_load_ms) catch "error", min_ms_str, max_ms_str, avg_ms_str, total_ms_str });

    return json;
}
