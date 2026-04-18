//! AI Task-Funktionen für den Scheduler.
//! Läuft in Worker-Threads: HTTP-Call an llama-server, JSON-Parse,
//! Ergebnis als Payload in result_queue.
//!
//! Main-Thread: UI submittet ChatParams, pollt Result per tag=.ai_chat_reply.

const std = @import("std");
const scheduler = @import("scheduler");
const agent_mod = @import("agent.zig");

const log = std.log.scoped(.ai_worker);

pub const ChatParams = struct {
    alloc: std.mem.Allocator,
    agent: *agent_mod.LlamaAgent,
    messages: []agent_mod.LlamaAgent.ChatMessage,
    owned_strings: std.ArrayListUnmanaged([]u8),

    pub fn init(
        alloc: std.mem.Allocator,
        agent: *agent_mod.LlamaAgent,
        messages: []const agent_mod.LlamaAgent.ChatMessage,
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

    const reply = params.agent.sendChatCompletion(params.messages) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "{s}", .{@errorName(err)});
        return .{ .tag = .ai_chat_error, .payload = msg, .allocator = alloc };
    };

    return .{
        .tag = .ai_chat_reply,
        .payload = reply,
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
