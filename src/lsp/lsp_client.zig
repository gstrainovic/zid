//! LSP Client — JSON-RPC über stdio.
//!
//! Dedicated Reader Thread für stdout → JSON-RPC parsen → result_queue.
//! Schreiben auf stdin = synchron (buffered, Main Thread oder Worker).

const std = @import("std");
const scheduler_mod = @import("scheduler");

const log = std.log.scoped(.lsp_client);

pub const ResultTag = enum {
    lsp_completion,
    lsp_diagnostics,
    lsp_hover,
    lsp_definition,
    lsp_show_message,
};

pub const LspClient = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    should_stop: std.atomic.Value(bool),
    scheduler: *scheduler_mod.Scheduler,
    thread: std.Thread,
    next_id: std.atomic.Value(i32),

    const Self = @This();

    pub fn start(
        allocator: std.mem.Allocator,
        scheduler_ptr: *scheduler_mod.Scheduler,
        cmd: []const []const u8,
        root_path: []const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .child = undefined,
            .should_stop = std.atomic.Value(bool).init(false),
            .scheduler = scheduler_ptr,
            .thread = undefined,
            .next_id = std.atomic.Value(i32).init(0),
        };

        var child = std.process.Child.init(cmd, allocator);
        child.stdout_behavior = .pipe;
        child.stdin_behavior = .pipe;
        child.stderr_behavior = .ignore;

        try child.spawn();
        self.child = child;

        self.thread = std.Thread.spawn(.{}, runLoop, .{self}) catch |err| {
            self.cleanup();
            return err;
        };

        try self.initialize(root_path);

        return self;
    }

    fn initialize(self: *Self, root_path: []const u8) !void {
        try self.sendRequest("initialize", .{
            .processId = @as(?i32, null),
            .rootUri = root_path,
            .capabilities = .{
                .textDocument = .{
                    .synchronization = .{
                        .didSave = true,
                    },
                    .completion = .{
                        .dynamicRegistration = false,
                        .completionItem = .{
                            .snippetSupport = false,
                        },
                    },
                    .hover = .{
                        .dynamicRegistration = false,
                    },
                    .definition = .{
                        .dynamicRegistration = false,
                    },
                    .diagnostic = .{
                        .dynamicRegistration = false,
                    },
                },
                .workspace = .{
                    .applyEdit = false,
                    .workspaceFolders = false,
                },
            },
        });
        try self.sendNotification("initialized", .{});
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        self.thread.join();
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.cleanup();
    }

    fn cleanup(self: *Self) void {
        _ = self.child.kill() catch {};
        self.child.wait() catch {};
        self.allocator.destroy(self);
    }

    fn sendRequest(self: *Self, method: []const u8, params: std.json.Value) !void {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const json_body = try std.json.stringifyAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = method,
            .params = params,
        }, .{});
        defer self.allocator.free(json_body);

        var header_buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{json_body.len}) catch return;

        const writer = self.child.stdin.?.writer();
        try writer.writeAll(header);
        try writer.writeAll(json_body);
        try writer.flush();
    }

    fn sendNotification(self: *Self, method: []const u8, params: std.json.Value) !void {
        const json_body = try std.json.stringifyAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        }, .{});
        defer self.allocator.free(json_body);

        var header_buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n", .{json_body.len}) catch return;

        const writer = self.child.stdin.?.writer();
        try writer.writeAll(header);
        try writer.writeAll(json_body);
        try writer.flush();
    }

    pub fn completion(self: *Self, uri: []const u8, position: Position) !void {
        try self.sendRequest("textDocument/completion", .{
            .textDocument = .{ .uri = uri },
            .position = position,
        });
    }

    pub fn hover(self: *Self, uri: []const u8, position: Position) !void {
        try self.sendRequest("textDocument/hover", .{
            .textDocument = .{ .uri = uri },
            .position = position,
        });
    }

    pub fn definition(self: *Self, uri: []const u8, position: Position) !void {
        try self.sendRequest("textDocument/definition", .{
            .textDocument = .{ .uri = uri },
            .position = position,
        });
    }

    pub fn didOpen(self: *Self, uri: []const u8, language_id: []const u8, content: []const u8) !void {
        try self.sendNotification("textDocument/didOpen", .{
            .textDocument = .{
                .uri = uri,
                .languageId = language_id,
                .text = content,
            },
        });
    }

    pub fn didChange(self: *Self, uri: []const u8, content: []const u8) !void {
        try self.sendNotification("textDocument/didChange", .{
            .textDocument = .{
                .uri = uri,
                .text = content,
            },
            .contentChanges = &[_]std.json.Value{.{ .string = content }},
        });
    }

    fn runLoop(self: *Self) void {
        var recv_buf: [8192]u8 = undefined;
        var unparsed: usize = 0;

        while (!self.should_stop.load(.acquire)) {
            const bytes_read = self.child.stdout.?.read(&recv_buf[unparsed..]) catch |err| {
                log.err("stdout read error: {}", .{err});
                break;
            };

            if (bytes_read == 0) break;

            unparsed += bytes_read;

            while (true) {
                const consumed = self.processBuffer(recv_buf[0..unparsed]) catch |err| {
                    log.err("JSON-RPC parse error: {}", .{err});
                    break;
                };
                if (consumed == 0) break;
                std.mem.copyForwards(u8, &recv_buf, recv_buf[consumed..unparsed]);
                unparsed -= consumed;
            }

            if (unparsed >= recv_buf.len) {
                log.warn("LSP receive buffer full, draining", .{});
                unparsed = 0;
            }

            std.Thread.sleep(std.time.ns_per_ms * 10);
        }
    }

    fn processBuffer(self: *Self, data: []u8) !usize {
        const sep = "\r\n\r\n";
        const headers_end = std.mem.indexOf(u8, data, sep) orelse return 0;

        var content_length: usize = 0;
        var pos: usize = 0;
        while (pos < headers_end) : (pos += 1) {
            const line_end = std.mem.indexOfScalar(u8, data[pos..], '\r') orelse break;
            const line = data[pos..pos + line_end];
            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                const len_str = line["Content-Length: ".len..];
                content_length = std.fmt.parseInt(usize, len_str, 10) catch break;
            }
            pos += line_end + 2;
        }

        const body_start = headers_end + sep.len;
        if (data.len < body_start + content_length) return 0;

        const body = data[body_start..body_start + content_length];
        try self.handleMessage(body);

        return body_start + content_length;
    }

    fn handleMessage(self: *Self, body: []u8) !void {
        var parser = std.json.Parser.init(self.allocator, .{});
        defer parser.deinit();

        const parsed = try parser.parse(body);
        defer parsed.deinit();

        const method = if (parsed.value.get("method")) |m| m.string else null;
        const id = parsed.value.get("id");
        const params = if (parsed.value.get("params")) |p| p else null;
        const result = if (parsed.value.get("result")) |r| r else null;
        const error_val = if (parsed.value.get("error")) |e| e else null;
        _ = error_val;

        if (method) |m| {
            if (std.mem.eql(u8, m, "textDocument/publishDiagnostics")) {
                try self.handlePublishDiagnostics(params.?);
            } else if (std.mem.eql(u8, m, "window/showMessage")) {
                try self.handleShowMessage(params.?);
            }
        }

        if (id != null and result != null) {
            const id_num = if (id.?.value == .number) id.?.number else return;
            try self.handleResponse(id_num, result.?, method orelse "");
        }
    }

    fn handlePublishDiagnostics(self: *Self, params: std.json.Value) !void {
        const uri = if (params.get("uri")) |u| u.string else return;
        const diagnostics = if (params.get("diagnostics")) |d| d else return;

        const payload = try std.json.stringifyAlloc(self.allocator, .{
            .uri = uri,
            .diagnostics = diagnostics,
        }, .{});
        defer self.allocator.free(payload);

        const tag: scheduler_mod.ResultTag = .lsp_diagnostics;
        const result = scheduler_mod.TaskResult{
            .tag = tag,
            .payload = payload,
            .allocator = self.allocator,
        };

        if (!self.scheduler.pushResult(result)) {
            self.allocator.free(payload);
            log.warn("result queue full", .{});
        }
    }

    fn handleShowMessage(self: *Self, params: std.json.Value) !void {
        const msg_type = if (params.get("type")) |t| t.number else return;
        const message = if (params.get("message")) |m| m.string else return;

        const payload = try std.json.stringifyAlloc(self.allocator, .{
            .type = msg_type,
            .message = message,
        }, .{});
        defer self.allocator.free(payload);

        const result = scheduler_mod.TaskResult{
            .tag = .lsp_show_message,
            .payload = payload,
            .allocator = self.allocator,
        };

        if (!self.scheduler.pushResult(result)) {
            self.allocator.free(payload);
            log.warn("result queue full", .{});
        }
    }

    fn handleResponse(self: *Self, _: f64, result: std.json.Value, method: []const u8) !void {
        const tag: scheduler_mod.ResultTag = if (std.mem.eql(u8, method, "textDocument/completion"))
            .lsp_completion
        else if (std.mem.eql(u8, method, "textDocument/hover"))
            .lsp_hover
        else if (std.mem.eql(u8, method, "textDocument/definition"))
            .lsp_definition
        else return;

        const payload = try std.json.stringifyAlloc(self.allocator, result, .{});
        defer self.allocator.free(payload);

        const task_result = scheduler_mod.TaskResult{
            .tag = tag,
            .payload = payload,
            .allocator = self.allocator,
        };

        if (!self.scheduler.pushResult(task_result)) {
            self.allocator.free(payload);
            log.warn("result queue full", .{});
        }
    }
};

pub const Position = struct {
    line: u32,
    character: u32,
};
