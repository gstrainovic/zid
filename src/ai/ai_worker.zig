//! AI Task-Funktionen für den Scheduler.
//! Läuft in Worker-Threads: HTTP-Call an llama-server, JSON-Parse,
//! Ergebnis als Payload in result_queue.
//!
//! Main-Thread: UI submittet ChatParams, pollt Result per tag=.ai_chat_reply.

const std = @import("std");
const scheduler = @import("scheduler");
const agent_mod = @import("agent");

const log = std.log.scoped(.ai_worker);

pub const ChatParams = struct {
    alloc: std.mem.Allocator,
    agent: *agent_mod.LlamaAgent,
    messages: []agent_mod.LlamaAgent.ChatMessage,
    owned_strings: std.ArrayListUnmanaged([]u8),
    should_stop: ?*const std.atomic.Value(bool) = null,

    pub fn init(
        alloc: std.mem.Allocator,
        agent: *agent_mod.LlamaAgent,
        messages: []const agent_mod.LlamaAgent.ChatMessage,
    ) !*ChatParams {
        return initWithStop(alloc, agent, messages, null);
    }

    pub fn initWithStop(
        alloc: std.mem.Allocator,
        agent: *agent_mod.LlamaAgent,
        messages: []const agent_mod.LlamaAgent.ChatMessage,
        should_stop: ?*const std.atomic.Value(bool),
    ) !*ChatParams {
        const self = try alloc.create(ChatParams);
        errdefer alloc.destroy(self);

        const msg_copy = try alloc.alloc(agent_mod.LlamaAgent.ChatMessage, messages.len);
        errdefer alloc.free(msg_copy);

        var owned: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (owned.items) |s| alloc.free(s);
            owned.deinit(alloc);
        }

        for (messages, 0..) |m, i| {
            const role_dup = try alloc.dupe(u8, m.role);
            try owned.append(alloc, role_dup);
            const content_dup = try alloc.dupe(u8, m.content);
            try owned.append(alloc, content_dup);
            msg_copy[i] = .{ .role = role_dup, .content = content_dup };
        }

        self.* = .{
            .alloc = alloc,
            .agent = agent,
            .messages = msg_copy,
            .owned_strings = owned,
            .should_stop = should_stop,
        };
        return self;
    }

    pub fn deinit(self: *ChatParams) void {
        for (self.owned_strings.items) |s| self.alloc.free(s);
        self.owned_strings.deinit(self.alloc);
        self.alloc.free(self.messages);
        self.alloc.destroy(self);
    }
};

/// Worker-Thread Entry: HTTP-Call an llama-server, Reply als Payload.
pub fn taskChatCompletion(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *ChatParams = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const reply = params.agent.sendChatCompletionWithStop(params.messages, params.should_stop) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "{s}", .{@errorName(err)});
        return .{ .tag = .ai_chat_error, .payload = msg, .allocator = alloc };
    };

    return .{
        .tag = .ai_chat_reply,
        .payload = reply,
        .allocator = alloc,
    };
}

// ─── Warmup ──────────────────────────────────────────────────────────────────

pub const WarmupParams = struct {
    alloc: std.mem.Allocator,
    agent: *agent_mod.LlamaAgent,
    should_stop: ?*const std.atomic.Value(bool) = null,
    max_attempts: u32 = 30,

    pub fn init(
        alloc: std.mem.Allocator,
        agent: *agent_mod.LlamaAgent,
        should_stop: ?*const std.atomic.Value(bool),
    ) !*WarmupParams {
        const self = try alloc.create(WarmupParams);
        self.* = .{ .alloc = alloc, .agent = agent, .should_stop = should_stop };
        return self;
    }

    pub fn deinit(self: *WarmupParams) void {
        self.alloc.destroy(self);
    }
};

pub fn taskWarmup(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *WarmupParams = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const ping_msg = &[_]agent_mod.LlamaAgent.ChatMessage{
        .{ .role = "user", .content = "ping" },
    };

    var attempts: u32 = 0;
    while (attempts < params.max_attempts) : (attempts += 1) {
        if (params.should_stop) |s| if (s.load(.acquire)) return .{
            .tag = .ai_warmup_error,
            .payload = try alloc.dupe(u8, "warmup cancelled"),
            .allocator = alloc,
        };

        if (params.agent.sendChatCompletionWithStop(ping_msg, params.should_stop)) |resp| {
            alloc.free(resp);
            return .{
                .tag = .ai_warmup_done,
                .payload = try alloc.alloc(u8, 0),
                .allocator = alloc,
            };
        } else |_| {
            // 1 Sekunde in 10×100ms aufgeteilt — macht shutdown responsive
            var slept: u32 = 0;
            while (slept < 10) : (slept += 1) {
                if (params.should_stop) |s| if (s.load(.acquire)) return .{
                    .tag = .ai_warmup_error,
                    .payload = try alloc.dupe(u8, "warmup cancelled"),
                    .allocator = alloc,
                };
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
    }

    return .{
        .tag = .ai_warmup_error,
        .payload = try alloc.dupe(u8, "warmup timed out"),
        .allocator = alloc,
    };
}

// ─── Download ────────────────────────────────────────────────────────────────

/// Progress-Sink: Download-Task schreibt Fortschritt (0..1) hierüber,
/// Main-Thread liest ihn für UI-Progressbar. Mutex schützt den Schreibzugriff.
pub const ProgressSink = struct {
    value: *f32,
    mutex: *std.Thread.Mutex,
    stop_flag: *std.atomic.Value(bool),
};

pub const DownloadParams = struct {
    alloc: std.mem.Allocator,
    url: []u8,
    out_path: []u8,
    sink: ProgressSink,

    pub fn init(
        alloc: std.mem.Allocator,
        url: []const u8,
        out_path: []const u8,
        sink: ProgressSink,
    ) !*DownloadParams {
        const self = try alloc.create(DownloadParams);
        errdefer alloc.destroy(self);
        self.url = try alloc.dupe(u8, url);
        errdefer alloc.free(self.url);
        self.out_path = try alloc.dupe(u8, out_path);
        self.alloc = alloc;
        self.sink = sink;
        return self;
    }

    pub fn deinit(self: *DownloadParams) void {
        self.alloc.free(self.url);
        self.alloc.free(self.out_path);
        self.alloc.destroy(self);
    }
};

pub fn taskDownload(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *DownloadParams = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    // Use curl for reliable HTTP downloads with redirect (-L) and fail on error (-f)
    const argv = &[_][]const u8{ "curl", "-L", "-f", params.url, "-o", params.out_path };

    var child = std.process.Child.init(argv, alloc);
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        return .{
            .tag = .ai_download_error,
            .payload = try std.fmt.allocPrint(alloc, "spawn failed: {s}", .{@errorName(err)}),
            .allocator = alloc,
        };
    };

    // Read stderr for progress (curl outputs % to stderr)
    if (child.stderr) |stderr| {
        var line_buf: [1024]u8 = undefined;
        while (true) {
            const n = stderr.read(&line_buf) catch break;
            if (n == 0) break;
            if (params.sink.stop_flag.load(.seq_cst)) break;

            var it = std.mem.tokenizeAny(u8, line_buf[0..n], " \r\n");
            if (it.next()) |token| {
                if (std.fmt.parseFloat(f32, token)) |val| {
                    params.sink.mutex.lock();
                    params.sink.value.* = val / 100.0;
                    params.sink.mutex.unlock();
                } else |_| {}
            }
        }
    }

    const term = child.wait() catch |err| {
        return .{
            .tag = .ai_download_error,
            .payload = try std.fmt.allocPrint(alloc, "wait failed: {s}", .{@errorName(err)}),
            .allocator = alloc,
        };
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            return .{
                .tag = .ai_download_error,
                .payload = try std.fmt.allocPrint(alloc, "curl exit {d}", .{code}),
                .allocator = alloc,
            };
        },
        else => return .{
            .tag = .ai_download_error,
            .payload = try alloc.dupe(u8, "curl terminated abnormally"),
            .allocator = alloc,
        },
    }

    return .{
        .tag = .ai_download_done,
        .payload = try alloc.alloc(u8, 0),
        .allocator = alloc,
    };
}

pub const PullParams = struct {
    alloc: std.mem.Allocator,
    model: []u8,

    pub fn init(alloc: std.mem.Allocator, model: []const u8) !*PullParams {
        const self = try alloc.create(PullParams);
        errdefer alloc.destroy(self);
        self.model = try alloc.dupe(u8, model);
        self.alloc = alloc;
        return self;
    }

    pub fn deinit(self: *PullParams) void {
        self.alloc.free(self.model);
        self.alloc.destroy(self);
    }
};

/// `ollama pull <model>` im Hintergrund; meldet sich wie der GGUF-Download
/// über ai_download_done / ai_download_error zurück.
pub fn taskOllamaPull(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *PullParams = @ptrCast(@alignCast(data.?));
    defer params.deinit();
    agent_mod.LlamaAgent.pullModel(alloc, params.model) catch |err| {
        return .{
            .tag = .ai_download_error,
            .payload = try std.fmt.allocPrint(alloc, "ollama pull {s} failed: {s}", .{ params.model, @errorName(err) }),
            .allocator = alloc,
        };
    };
    return .{
        .tag = .ai_download_done,
        .payload = try alloc.alloc(u8, 0),
        .allocator = alloc,
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "ChatParams init/deinit owns message strings (no leaks)" {
    const alloc = std.testing.allocator;

    // Agent-Pointer wird in Params gespeichert, aber taskChatCompletion nicht aufgerufen
    // → Wert darf beliebig sein, wir testen nur den Lifecycle der Params-Struct.
    var fake_agent: agent_mod.LlamaAgent = undefined;

    const input: []const agent_mod.LlamaAgent.ChatMessage = &.{
        .{ .role = "user", .content = "hello" },
        .{ .role = "assistant", .content = "hi there" },
    };

    const params = try ChatParams.init(alloc, &fake_agent, input);
    try std.testing.expectEqual(@as(usize, 2), params.messages.len);
    try std.testing.expectEqualStrings("user", params.messages[0].role);
    try std.testing.expectEqualStrings("hello", params.messages[0].content);
    try std.testing.expectEqualStrings("hi there", params.messages[1].content);
    params.deinit();
}
