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
    /// Für Streaming: Deltas gehen per pushResult an den Main-Thread
    sched: ?*scheduler.Scheduler = null,
    /// Escape im Chat setzt das Flag; der Stream endet mit ai_chat_cancelled
    cancel: ?*const std.atomic.Value(bool) = null,
    /// OpenAI-`tools`-Array (owned Kopie), null = ohne Werkzeuge
    tools: ?[]u8 = null,
    /// Ergebnis-Tags der blockierenden Antwort (Commit-Nachricht nutzt eigene, damit die
    /// Antwort nicht im Chat landet)
    reply_tag: scheduler.ResultTag = .ai_chat_reply,
    error_tag: scheduler.ResultTag = .ai_chat_error,

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
            var tc_dup: ?[]const u8 = null;
            if (m.tool_calls) |tc| {
                const d = try alloc.dupe(u8, tc);
                try owned.append(alloc, d);
                tc_dup = d;
            }
            var id_dup: ?[]const u8 = null;
            if (m.tool_call_id) |id| {
                const d = try alloc.dupe(u8, id);
                try owned.append(alloc, d);
                id_dup = d;
            }
            msg_copy[i] = .{ .role = role_dup, .content = content_dup, .tool_calls = tc_dup, .tool_call_id = id_dup };
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

    /// Streaming-Variante: Deltas an `sched`, Abbruch über `cancel`.
    pub fn initStreaming(
        alloc: std.mem.Allocator,
        agent: *agent_mod.LlamaAgent,
        messages: []const agent_mod.LlamaAgent.ChatMessage,
        sched: *scheduler.Scheduler,
        should_stop: ?*const std.atomic.Value(bool),
        cancel: ?*const std.atomic.Value(bool),
        tools: ?[]const u8,
    ) !*ChatParams {
        const self = try initWithStop(alloc, agent, messages, should_stop);
        errdefer self.deinit();
        self.sched = sched;
        self.cancel = cancel;
        if (tools) |t| self.tools = try alloc.dupe(u8, t);
        return self;
    }

    pub fn deinit(self: *ChatParams) void {
        if (self.tools) |t| self.alloc.free(t);
        for (self.owned_strings.items) |s| self.alloc.free(s);
        self.owned_strings.deinit(self.alloc);
        self.alloc.free(self.messages);
        self.alloc.destroy(self);
    }
};

/// Sammelt den gestreamten Text und reicht jedes Delta an den Main-Thread weiter.
const StreamAcc = struct {
    alloc: std.mem.Allocator,
    sched: *scheduler.Scheduler,
    text: std.ArrayListUnmanaged(u8) = .empty,

    fn onDelta(ctx: *anyopaque, delta: []const u8) void {
        const self: *StreamAcc = @ptrCast(@alignCast(ctx));
        self.text.appendSlice(self.alloc, delta) catch return;
        const payload = self.alloc.dupe(u8, delta) catch return;
        // Volle Ergebnis-Queue: Delta verwerfen, die finale Antwort trägt den ganzen Text.
        if (!self.sched.pushResult(.{ .tag = .ai_chat_delta, .payload = payload, .allocator = self.alloc })) {
            self.alloc.free(payload);
        }
    }
};

/// Worker-Thread Entry: HTTP-Call an llama-server, Reply als Payload.
/// Mit `params.sched` wird gestreamt (Deltas als ai_chat_delta), sonst blockierend.
pub fn taskChatCompletion(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *ChatParams = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    if (params.sched) |sched| {
        var acc = StreamAcc{ .alloc = alloc, .sched = sched };
        defer acc.text.deinit(alloc);
        const tool_calls = params.agent.streamChatCompletion(params.messages, params.tools, params.should_stop, params.cancel, .{
            .ctx = &acc,
            .on_delta = StreamAcc.onDelta,
        }) catch |err| {
            if (err == error.Cancelled) {
                return .{ .tag = .ai_chat_cancelled, .payload = try acc.text.toOwnedSlice(alloc), .allocator = alloc };
            }
            // Kontextfenster voll: Teiltext mit Hinweis, sonst Fehlermeldung (ein abgeschnittener
            // Werkzeugaufruf wird nicht ausgeführt)
            if (err == error.ReplyTruncated and acc.text.items.len > 0) {
                try acc.text.appendSlice(alloc, "\n\n*(Antwort abgeschnitten: Kontextfenster voll.)*");
                return .{ .tag = .ai_chat_reply, .payload = try acc.text.toOwnedSlice(alloc), .allocator = alloc };
            }
            // Stream brach nach Teiltext ab: lieber den Teiltext zeigen als nur den Fehler
            if (acc.text.items.len > 0) {
                return .{ .tag = .ai_chat_reply, .payload = try acc.text.toOwnedSlice(alloc), .allocator = alloc };
            }
            const msg = try std.fmt.allocPrint(alloc, "{s}", .{@errorName(err)});
            return .{ .tag = .ai_chat_error, .payload = msg, .allocator = alloc };
        };
        if (tool_calls) |tc| {
            defer alloc.free(tc);
            // Hülle für den Main-Thread: Text + rohes tool_calls-Array
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
            try jw.beginObject();
            try jw.objectField("content");
            try jw.write(acc.text.items);
            try jw.objectField("tool_calls");
            try jw.beginWriteRaw();
            try jw.writer.writeAll(tc);
            jw.endWriteRaw();
            try jw.endObject();
            return .{ .tag = .ai_chat_tool_calls, .payload = try out.toOwnedSlice(), .allocator = alloc };
        }
        return .{ .tag = .ai_chat_reply, .payload = try acc.text.toOwnedSlice(alloc), .allocator = alloc };
    }

    const reply = params.agent.sendChatCompletionWithStop(params.messages, params.should_stop) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "{s}", .{@errorName(err)});
        return .{ .tag = params.error_tag, .payload = msg, .allocator = alloc };
    };

    return .{
        .tag = params.reply_tag,
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

        // Ein Token reicht: es geht nur darum, dass der Server das Modell lädt.
        if (params.agent.sendChatCompletionOpts(ping_msg, params.should_stop, 1)) |resp| {
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

// ─── Tests ────────────────────────────────────────────────────────────────────

test {
    // agent.zig ist kein eigenes Test-Root; seine Tests laufen über dieses hier mit.
    _ = agent_mod;
}

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
