const std = @import("std");
const clay = @import("clay");
const Theme = @import("theme.zig").Theme;
const agent = @import("../ai/agent.zig");

const log = std.log.scoped(.ai_chat);

pub const ChatMessage = struct {
    role: []const u8, // "user", "assistant", "system"
    content: []const u8,
};

pub const AIChatState = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(ChatMessage),
    input_buffer: std.ArrayList(u8),
    agent: ?*agent.LlamaAgent = null,
    is_loading: bool = false,
    mutex: std.Thread.Mutex = .{},
    
    /// Scrolling state
    scroll_offset_y: f32 = 0,
    viewport_height: f32 = 0,
    content_height: f32 = 0,

    width: f32 = 350.0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .messages = .empty,
            .input_buffer = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
            self.allocator.free(msg.role);
        }
        self.messages.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
        if (self.agent) |a| {
            a.deinit();
        }
    }

    pub fn addMessage(self: *Self, role: []const u8, content: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.messages.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
        });
        // Scroll to bottom
        self.scroll_offset_y = 999999; // Simple way to force scroll to end
    }

    pub fn sendMessage(self: *Self) !void {
        if (self.input_buffer.items.len == 0 or self.is_loading) return;

        const user_text = try self.allocator.dupe(u8, self.input_buffer.items);
        try self.addMessage("user", user_text);
        self.allocator.free(user_text);
        
        while (self.input_buffer.pop()) |_| {}

        self.is_loading = true;

        _ = try std.Thread.spawn(.{}, workerThread, .{self});
    }

    fn workerThread(self: *Self) void {
        const response = self.getAIResponse() catch |err| blk: {
            log.err("AI Error: {}", .{err});
            break :blk "Error communicating with AI agent.";
        };
        
        self.addMessage("assistant", response) catch {};
        
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_loading = false;
    }

    fn getAIResponse(self: *Self) ![]const u8 {
        const a = self.agent orelse return error.NoAgent;
        
        var api_messages = std.ArrayList(agent.LlamaAgent.ChatMessage).empty;
        defer api_messages.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.messages.items) |m| {
                try api_messages.append(self.allocator, .{ .role = m.role, .content = m.content });
            }
        }

        return try a.sendChatCompletion(api_messages.items);
    }

    pub fn handleKeyPress(self: *Self, key: @import("wio").Button) bool {
        switch (key) {
            .enter => {
                self.sendMessage() catch |err| log.err("Send message failed: {}", .{err});
                return true;
            },
            .backspace => {
                _ = self.input_buffer.pop();
                return true;
            },
            else => return false,
        }
    }

    pub fn handleChar(self: *Self, char_code: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char_code, &buf) catch return;
        self.input_buffer.appendSlice(self.allocator, buf[0..len]) catch {};
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        const scroll_speed: f32 = 40.0;
        if (delta > 0) {
            self.scroll_offset_y = @max(0, self.scroll_offset_y - @as(f32, @floatFromInt(delta)) * scroll_speed);
        } else if (delta < 0) {
            const max_scroll = @max(0, self.content_height - self.viewport_height);
            self.scroll_offset_y = @min(max_scroll, self.scroll_offset_y + @as(f32, @floatFromInt(-delta)) * scroll_speed);
        }
    }
};

pub fn renderAIChat(
    arena: std.mem.Allocator,
    state: *AIChatState,
    theme: Theme,
) void {
    _ = arena;

    clay.UI()(.{
        .id = clay.ElementId.ID("ai_chat_sidebar"),
        .layout = .{
            .sizing = .{ .w = .fixed(state.width), .h = .grow },
            .direction = .top_to_bottom,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
            .child_gap = 12,
        },
        .background_color = theme.surface,
        .border = .{ .width = .{ .left = 1 }, .color = theme.border },
    })({
        // Title
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fit } },
        })({
            clay.text("Gemma 4 Agent", .{ .font_size = 20, .color = theme.primary });
        });

        // Chat History Viewport
        clay.UI()(.{
            .id = clay.ElementId.ID("ai_chat_viewport"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
            .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -state.scroll_offset_y } },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("ai_chat_content"),
                .layout = .{ 
                    .sizing = .{ .w = .grow, .h = .fit },
                    .direction = .top_to_bottom,
                    .child_gap = 8,
                },
            })({
                state.mutex.lock();
                defer state.mutex.unlock();
                for (state.messages.items) |msg| {
                    const is_user = std.mem.eql(u8, msg.role, "user");
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fit },
                            .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
                            .direction = .top_to_bottom,
                        },
                        .background_color = if (is_user) .{ 50, 50, 80, 255 } else .{ 40, 40, 45, 255 },
                        .corner_radius = .all(4),
                    })({
                        clay.text(if (is_user) "You:" else "Gemma:", .{ .font_size = 14, .color = if (is_user) .{ 200, 200, 255, 255 } else .{ 200, 255, 200, 255 } });
                        clay.text(msg.content, .{ .font_size = 16, .color = .{ 240, 240, 240, 255 } });
                    });
                }
                
                if (state.is_loading) {
                    clay.text("Gemma is thinking...", .{ .font_size = 14, .color = .{ 150, 150, 150, 255 } });
                }
            });
        });

        // Metrics nach dem Layout holen für Scrolling-Begrenzung im nächsten Frame
        const viewport_data = clay.getElementData(clay.ElementId.ID("ai_chat_viewport"));
        const content_data = clay.getElementData(clay.ElementId.ID("ai_chat_content"));
        if (viewport_data.found) state.viewport_height = viewport_data.bounding_box.height;
        if (content_data.found) state.content_height = content_data.bounding_box.height;

        // Begrenzung des Scrolls
        const max_scroll = @max(0, state.content_height - state.viewport_height);
        if (state.scroll_offset_y > max_scroll and state.scroll_offset_y != 999999) {
            state.scroll_offset_y = max_scroll;
        } else if (state.scroll_offset_y == 999999) {
            state.scroll_offset_y = max_scroll;
        }

        // Input Area
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(100) },
                .direction = .top_to_bottom,
                .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
            },
            .background_color = .{ 30, 30, 35, 255 },
            .border = .{ .width = .all(1), .color = theme.border },
            .corner_radius = .all(4),
        })({
            if (state.input_buffer.items.len == 0) {
                clay.text("Ask something... (Ctrl+K to toggle)", .{ .font_size = 16, .color = .{ 100, 100, 100, 255 } });
            } else {
                clay.text(state.input_buffer.items, .{ .font_size = 16, .color = .{ 255, 255, 255, 255 } });
            }
        });
    });
}
