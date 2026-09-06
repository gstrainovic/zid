//! LSP-Client: JSON-RPC über stdio zu einem Language Server (zls).
//!
//! Schreiben passiert synchron auf dem Main-Thread (kleine Nachrichten, gepufferte Pipe).
//! Ein Reader-Thread liest stdout, zerlegt die Rahmen (`lsp_proto`) und schiebt Antworten
//! als `TaskResult` in die Scheduler-Ergebnisschlange; Server-Requests bekommen sofort
//! `result: null`, damit der Server nie auf uns wartet. Dokumente werden vor jeder Anfrage
//! komplett synchronisiert (didOpen/didChange Full) — kein Verkehr pro Tastendruck.
const std = @import("std");
const scheduler_mod = @import("scheduler");
const proto = @import("lsp_proto");

const log = std.log.scoped(.lsp_client);

pub const Method = enum { initialize, definition, hover, completion, other };

pub const LspClient = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    scheduler: *scheduler_mod.Scheduler,
    thread: ?std.Thread = null,
    next_id: i64 = 1,
    /// id → Methode, damit die Antwort dem richtigen Tag zugeordnet wird
    pending: std.AutoHashMapUnmanaged(i64, Method) = .empty,
    pending_mutex: std.Thread.Mutex = .{},
    write_mutex: std.Thread.Mutex = .{},
    /// Geöffnete Dokumente (URI, owned) → Version
    opened: std.StringHashMapUnmanaged(i64) = .empty,
    initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    /// Server starten (`cmd`, z. B. {"zls"}) und `initialize` für `root_path` schicken.
    pub fn start(allocator: std.mem.Allocator, sched: *scheduler_mod.Scheduler, cmd: []const []const u8, root_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .child = std.process.Child.init(cmd, allocator), .scheduler = sched };
        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Ignore;
        try self.child.spawn();
        errdefer {
            _ = self.child.kill() catch {};
        }
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});

        const root_uri = try proto.pathToUri(allocator, root_path);
        defer allocator.free(root_uri);
        const params = try proto.initializeParams(allocator, root_uri);
        defer allocator.free(params);
        try self.sendRequest(.initialize, "initialize", params);
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Prozess zuerst beenden: dann liefert read() 0 und der Thread endet
        _ = self.child.kill() catch {};
        if (self.thread) |t| t.join();
        _ = self.child.wait() catch {};
        var it = self.opened.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.opened.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn isReady(self: *const Self) bool {
        return self.initialized.load(.acquire);
    }

    /// Dokument dem Server bekannt machen bzw. seinen Text aktualisieren (Full Sync).
    pub fn syncDocument(self: *Self, path: []const u8, language_id: []const u8, text: []const u8) !void {
        const uri = try proto.pathToUri(self.allocator, path);
        defer self.allocator.free(uri);
        if (self.opened.getPtr(uri)) |version| {
            version.* += 1;
            const params = try proto.didChangeParams(self.allocator, uri, version.*, text);
            defer self.allocator.free(params);
            try self.sendNotification("textDocument/didChange", params);
        } else {
            const params = try proto.didOpenParams(self.allocator, uri, language_id, text);
            defer self.allocator.free(params);
            try self.sendNotification("textDocument/didOpen", params);
            try self.opened.put(self.allocator, try self.allocator.dupe(u8, uri), 1);
        }
    }

    /// `textDocument/definition`; die Antwort kommt als `lsp_definition`-Ergebnis (Payload = JSON).
    pub fn definition(self: *Self, path: []const u8, line: u32, character: u32) !void {
        const uri = try proto.pathToUri(self.allocator, path);
        defer self.allocator.free(uri);
        const params = try proto.definitionParams(self.allocator, uri, line, character);
        defer self.allocator.free(params);
        try self.sendRequest(.definition, "textDocument/definition", params);
    }

    fn sendRequest(self: *Self, method: Method, name: []const u8, params: []const u8) !void {
        const id = self.next_id;
        self.next_id += 1;
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            try self.pending.put(self.allocator, id, method);
        }
        const body = try proto.request(self.allocator, id, name, params);
        defer self.allocator.free(body);
        try self.write(body);
    }

    fn sendNotification(self: *Self, name: []const u8, params: []const u8) !void {
        const body = try proto.notification(self.allocator, name, params);
        defer self.allocator.free(body);
        try self.write(body);
    }

    fn write(self: *Self, body: []const u8) !void {
        const framed = try proto.frame(self.allocator, body);
        defer self.allocator.free(framed);
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        const stdin = self.child.stdin orelse return error.NoStdin;
        try stdin.writeAll(framed);
    }

    fn runLoop(self: *Self) void {
        const stdout = self.child.stdout orelse return;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = stdout.read(&chunk) catch |err| {
                log.debug("stdout read ended: {}", .{err});
                return;
            };
            if (n == 0) return;
            buf.appendSlice(self.allocator, chunk[0..n]) catch return;
            while (proto.parseFrame(buf.items)) |f| {
                self.handleBody(f.body);
                const rest = buf.items.len - f.consumed;
                std.mem.copyForwards(u8, buf.items[0..rest], buf.items[f.consumed..]);
                buf.items.len = rest;
            }
        }
    }

    fn handleBody(self: *Self, body: []const u8) void {
        const msg = (proto.parseMessage(self.allocator, body) catch return) orelse return;
        defer msg.deinit(self.allocator);
        if (msg.method) |m| {
            if (msg.id) |id| {
                // Server-Request: mit null beantworten, wir bieten keine dieser Fähigkeiten an
                log.debug("server request {s} → null", .{m});
                const resp = proto.nullResponse(self.allocator, id) catch return;
                defer self.allocator.free(resp);
                self.write(resp) catch {};
            }
            return;
        }
        const id = msg.id orelse return;
        const method = blk: {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            const kv = self.pending.fetchRemove(id) orelse break :blk Method.other;
            break :blk kv.value;
        };
        switch (method) {
            .initialize => {
                self.initialized.store(true, .release);
                self.sendNotification("initialized", "{}") catch {};
            },
            .definition => self.push(.lsp_definition, msg.result orelse "null"),
            .hover => self.push(.lsp_hover, msg.result orelse "null"),
            .completion => self.push(.lsp_completion, msg.result orelse "null"),
            .other => {},
        }
    }

    fn push(self: *Self, tag: scheduler_mod.ResultTag, json: []const u8) void {
        const payload = self.allocator.dupe(u8, json) catch return;
        if (!self.scheduler.pushResult(.{ .tag = tag, .payload = payload, .allocator = self.allocator })) {
            self.allocator.free(payload);
        }
    }
};
