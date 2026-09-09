//! Interactive Mode für zid
//!
//! Starten mit: zid --interactive
//!
//! Commands (line-based, Text statt JSON):
//!   open <path>              Öffnet Datei in neuem Tab
//!   close-tab <index>        Schließt Tab mit Index
//!   switch-tab <index>       Aktiviert Tab mit Index
//!   click <x> <y>            Mausklick an Koordinate
//!   right-click <x> <y>      Rechtsklick
//!   key <name> [ctrl]        Key senden (enter, backspace, k, etc.), optional ctrl modifier
//!   type <text>              Text eingeben
//!   screenshot               Screenshot machen -> tmp/vulkan-screenshot.ppm
//!   split <h|v>              Split horizontal oder vertikal
//!   show-menu <x> <y>        Context-Menu an Position zeigen
//!   get-state                Gibt aktuellen State zurück
//!   shutdown                 Beendet die App
//!
//! Example:
//!   zid --interactive
//!   > open ./README.md
//!   OK
//!   > key ctrl+k
//!   OK
//!   > screenshot
//!   OK /tmp/vulkan-screenshot.ppm
//!   > shutdown
//!   OK bye

const std = @import("std");
const zigjr = @import("zigjr");
const e2e_server = @import("e2e_server.zig");
const ui_mod = @import("ui/mod.zig");

const log = std.log.scoped(.interactive);

/// Interactive command handler - reuses E2EContext handlers directly
pub const InteractiveHandler = struct {
    ctx: *e2e_server.E2EContext,
    /// Per-Kommando Request-Context: Antworten und Fehlertexte landen in dc.arena()
    /// und werden vom Aufrufer nach dem Schreiben der Antwort freigegeben.
    dc: *zigjr.DispatchCtx,

    const Self = @This();

    const Tokenizer = struct {
    data: []const u8,
    pos: usize = 0,
    fn next(self: *Tokenizer) ?[]const u8 {
        while (self.pos < self.data.len and self.data[self.pos] == ' ') self.pos += 1;
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != ' ') self.pos += 1;
        return self.data[start..self.pos];
    }
};

/// Parse and execute a single command line
pub fn exec(self: *Self, line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return "OK";
    if (trimmed[0] == '#') return "";

    var tokens: [32][]const u8 = undefined;
    var count: usize = 0;

    var tok = Tokenizer{ .data = trimmed };
    while (tok.next()) |t| {
        if (count >= 32) return "ERROR too many args";
        tokens[count] = t;
        count += 1;
    }

    if (count == 0) return "OK";

    const cmd = tokens[0];
    const args = tokens[1..count];

        if (std.mem.eql(u8, cmd, "open")) {
            return self.execOpen(args);
        } else if (std.mem.eql(u8, cmd, "close-tab")) {
            return self.execCloseTab(args);
        } else if (std.mem.eql(u8, cmd, "switch-tab")) {
            return self.execSwitchTab(args);
        } else if (std.mem.eql(u8, cmd, "click")) {
            return self.execClick(args);
        } else if (std.mem.eql(u8, cmd, "right-click")) {
            return self.execRightClick(args);
        } else if (std.mem.eql(u8, cmd, "key")) {
            return self.execKey(args);
        } else if (std.mem.eql(u8, cmd, "type")) {
            return self.execType(args);
        } else if (std.mem.eql(u8, cmd, "screenshot")) {
            return self.execScreenshot(args);
        } else if (std.mem.eql(u8, cmd, "split")) {
            return self.execSplit(args);
        } else if (std.mem.eql(u8, cmd, "show-menu")) {
            return self.execShowMenu(args);
        } else if (std.mem.eql(u8, cmd, "get-state")) {
            return self.execGetState(args);
        } else if (std.mem.eql(u8, cmd, "shutdown")) {
            self.ctx.shutdown_flag.store(true, .seq_cst);
            return "OK bye";
        } else if (std.mem.eql(u8, cmd, "help")) {
            return "open <path>, close-tab <n>, switch-tab <n>, click <x> <y>, key <name> [ctrl], type <text>, screenshot, split <h|v>, get-state, shutdown";
        }

        return "ERROR unknown command";
    }

    fn execOpen(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 1) return "ERROR open <path>";
        const path = args[0];
        log.info("Interactive: open '{s}'", .{path});
        _ = e2e_server.openFile(self.ctx, self.dc, path) catch |err| {
            log.err("open failed: {}", .{err});
            return "ERROR open failed";
        };
        return "OK";
    }

    fn execCloseTab(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 1) return "ERROR close-tab <index>";
        const idx = std.fmt.parseInt(u32, args[0], 10) catch return "ERROR invalid index";
        log.info("Interactive: close-tab {d}", .{idx});
        _ = e2e_server.closeTab(self.ctx, self.dc, @intCast(idx)) catch |err| {
            log.err("close-tab failed: {}", .{err});
            return "ERROR close-tab failed";
        };
        return "OK";
    }

    fn execSwitchTab(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 1) return "ERROR switch-tab <index>";
        const idx = std.fmt.parseInt(u32, args[0], 10) catch return "ERROR invalid index";
        log.info("Interactive: switch-tab {d}", .{idx});
        _ = e2e_server.setActiveTab(self.ctx, self.dc, @intCast(idx)) catch |err| {
            log.err("switch-tab failed: {}", .{err});
            return "ERROR switch-tab failed";
        };
        return "OK";
    }

    fn execClick(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 2) return "ERROR click <x> <y>";
        const x = std.fmt.parseFloat(f32, args[0]) catch return "ERROR invalid x";
        const y = std.fmt.parseFloat(f32, args[1]) catch return "ERROR invalid y";
        log.info("Interactive: click {d} {d}", .{ x, y });
        _ = e2e_server.click(self.ctx, self.dc, x, y) catch |err| {
            log.err("click failed: {}", .{err});
            return "ERROR click failed";
        };
        return "OK";
    }

    fn execRightClick(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 2) return "ERROR right-click <x> <y>";
        const x = std.fmt.parseFloat(f32, args[0]) catch return "ERROR invalid x";
        const y = std.fmt.parseFloat(f32, args[1]) catch return "ERROR invalid y";
        log.info("Interactive: right-click {d} {d}", .{ x, y });
        _ = e2e_server.rightClick(self.ctx, self.dc, x, y) catch |err| {
            log.err("right-click failed: {}", .{err});
            return "ERROR right-click failed";
        };
        return "OK";
    }

    fn execKey(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 1) return "ERROR key <name> [ctrl]";
        const key_name = args[0];
        const is_ctrl = if (args.len > 1 and std.mem.eql(u8, args[1], "ctrl")) true else false;
        log.info("Interactive: key '{s}' ctrl={}", .{ key_name, is_ctrl });
        _ = e2e_server.keyPress(self.ctx, self.dc, key_name, is_ctrl) catch |err| {
            log.err("key failed: {}", .{err});
            return "ERROR key failed";
        };
        return "OK";
    }

    fn execType(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 1) return "ERROR type <text>";
        const text = args[0];
        log.info("Interactive: type '{s}'", .{text});
        _ = e2e_server.typeText(self.ctx, self.dc, text) catch |err| {
            log.err("type failed: {}", .{err});
            return "ERROR type failed";
        };
        return "OK";
    }

    fn execScreenshot(self: *Self, args: [][]const u8) []const u8 {
        _ = args;
        log.info("Interactive: screenshot", .{});
        _ = e2e_server.screenshot(self.ctx, self.dc) catch |err| {
            log.err("screenshot failed: {}", .{err});
            return "ERROR screenshot failed";
        };
        return "OK /tmp/vulkan-screenshot.ppm";
    }

    fn execSplit(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 1) return "ERROR split <h|v>";
        const direction = args[0];
        if (!std.mem.eql(u8, direction, "h") and !std.mem.eql(u8, direction, "v")) {
            return "ERROR split <h|v>";
        }
        log.info("Interactive: split {s}", .{direction});
        _ = e2e_server.splitPane(self.ctx, self.dc, direction) catch |err| {
            log.err("split failed: {}", .{err});
            return "ERROR split failed";
        };
        return "OK";
    }

    fn execShowMenu(self: *Self, args: [][]const u8) []const u8 {
        if (args.len < 2) return "ERROR show-menu <x> <y>";
        const x = std.fmt.parseFloat(f32, args[0]) catch return "ERROR invalid x";
        const y = std.fmt.parseFloat(f32, args[1]) catch return "ERROR invalid y";
        log.info("Interactive: show-menu {d} {d}", .{ x, y });
        _ = e2e_server.showContextMenuRpc(self.ctx, self.dc, x, y) catch |err| {
            log.err("show-menu failed: {}", .{err});
            return "ERROR show-menu failed";
        };
        return "OK";
    }

    fn execGetState(self: *Self, args: [][]const u8) []const u8 {
        _ = args;
        log.info("Interactive: get-state", .{});
        const state = e2e_server.getState(self.ctx, self.dc) catch |err| {
            log.err("get-state failed: {}", .{err});
            return "ERROR get-state failed";
        };
        return state;
    }
};

/// Main interactive loop - reads from stdin, writes to stdout
pub fn runInteractiveLoop(ctx: *e2e_server.E2EContext) void {
    var stdin_buf: [1024]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const out = &stdout_writer.interface;

    out.writeAll("=== zid interactive mode ===\n") catch return;
    out.writeAll("Commands: open, close-tab, switch-tab, click, right-click, key, type, screenshot, split, show-menu, get-state, shutdown\n") catch return;
    out.writeAll("> ") catch return;
    out.flush() catch return;

    while (true) {
        const line = stdin.takeDelimiter('\n') catch break;
        if (line) |l| {
            var trimmed = l;
            if (trimmed.len > 0 and trimmed[trimmed.len-1] == '\r') {
                trimmed = trimmed[0..trimmed.len-1];
            }

            // Arena pro Kommando: alles was Handler über dc.arena() anlegen,
            // lebt bis die Antwort geschrieben ist und wird dann freigegeben.
            var arena = std.heap.ArenaAllocator.init(ctx.allocator);
            defer arena.deinit();
            var nop_logger = zigjr.NopLogger{};
            var dc_impl = zigjr.DispatchCtxImpl{
                .arena = arena.allocator(),
                .logger = nop_logger.asLogger(),
            };
            var dc = zigjr.DispatchCtx{ .dc_impl = &dc_impl };

            var handler = InteractiveHandler{ .ctx = ctx, .dc = &dc };
            const response = handler.exec(trimmed);

            if (response.len > 0) {
                out.writeAll(response) catch return;
                out.writeAll("\n") catch return;
            }

            if (std.mem.eql(u8, trimmed, "shutdown")) {
                break;
            }

            out.writeAll("> ") catch return;
            out.flush() catch return;
        } else {
            break; // EOF
        }

        if (ctx.shutdown_flag.load(.seq_cst)) {
            break;
        }
    }
}