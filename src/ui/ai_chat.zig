const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
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
    
    server_path: ?[]const u8 = null,
    model_path: ?[]const u8 = null,

    is_loading: bool = false,
    is_downloading: bool = false,
    is_initializing: bool = false,
    download_progress: f32 = 0,
    model_exists: bool = false,
    last_copy_time: i64 = 0,
    
    mutex: std.Thread.Mutex = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    
    // Handles for cleanup
    active_thread: ?std.Thread = null,
    
    /// Scrolling state
    scroll_offset_y: f32 = 0,
    viewport_height: f32 = 0,
    content_height: f32 = 0,

    width: f32 = 350.0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const model_name = "gemma-4-E2B-it-Q4_K_M.gguf";
        var exists = false;
        if (std.fs.cwd().access(model_name, .{})) |_| {
            exists = true;
        } else |_| {}

        return Self{
            .allocator = allocator,
            .messages = .empty,
            .input_buffer = .empty,
            .model_exists = exists,
        };
    }

    pub fn deinit(self: *Self) void {
        // Signal threads to stop
        self.stop_flag.store(true, .seq_cst);
        
        // Wait for active thread if any
        if (self.active_thread) |t| {
            t.join();
            self.active_thread = null;
        }

        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
            self.allocator.free(msg.role);
        }
        self.messages.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
        if (self.agent) |a| {
            a.deinit();
        }
        if (self.server_path) |p| self.allocator.free(p);
        if (self.model_path) |p| self.allocator.free(p);
    }

    pub fn initAgent(self: *Self, server_path: []const u8, model_path: []const u8) !void {
        // Old agent clean up if exists
        if (self.agent) |a| {
            a.deinit();
            self.agent = null;
        }
        
        // Store paths for potential restart
        if (self.server_path) |p| self.allocator.free(p);
        if (self.model_path) |p| self.allocator.free(p);
        self.server_path = try self.allocator.dupe(u8, server_path);
        self.model_path = try self.allocator.dupe(u8, model_path);

        self.agent = agent.LlamaAgent.init(self.allocator, server_path, model_path, 8080) catch |err| {
            log.err("Failed to initialize AI Agent: {}", .{err});
            return err;
        };

        // Start warmup check
        self.is_initializing = true;
        if (self.active_thread) |t| {
            t.join();
            self.active_thread = null;
        }
        self.active_thread = try std.Thread.spawn(.{}, warmupWorker, .{self});
    }

    fn warmupWorker(self: *Self) void {
        const a = self.agent orelse return;
        const ping_msg = &[_]agent.LlamaAgent.ChatMessage{
            .{ .role = "user", .content = "ping" },
        };
        
        var attempts: u32 = 0;
        while (attempts < 30 and !self.stop_flag.load(.seq_cst)) : (attempts += 1) {
            if (a.sendChatCompletion(ping_msg)) |resp| {
                self.allocator.free(resp);
                break;
            } else |_| {
                std.Thread.sleep(1 * std.time.ns_per_s);
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_initializing = false;
        log.info("AI Agent is warm and ready.", .{});
    }

    pub fn addMessage(self: *Self, role: []const u8, content: []const u8) !void {
        const dupe_role = try self.allocator.dupe(u8, role);
        errdefer self.allocator.free(dupe_role);
        const dupe_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(dupe_content);

        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.messages.append(self.allocator, .{
            .role = dupe_role,
            .content = dupe_content,
        });
        // Scroll to bottom
        self.scroll_offset_y = 999999; 
    }

    pub fn sendMessage(self: *Self) !void {
        if (self.input_buffer.items.len == 0 or self.is_loading or self.is_initializing) return;

        const user_text = try self.allocator.dupe(u8, self.input_buffer.items);
        defer self.allocator.free(user_text);
        try self.addMessage("user", user_text);
        
        while (self.input_buffer.pop()) |_| {}

        self.is_loading = true;

        if (self.active_thread) |t| {
            t.join();
            self.active_thread = null;
        }
        self.active_thread = try std.Thread.spawn(.{}, workerThread, .{self});
    }

    fn workerThread(self: *Self) void {
        while (!self.stop_flag.load(.seq_cst)) {
            const response = self.getAIResponse() catch |err| {
                log.err("AI Error: {}", .{err});
                self.addMessage("assistant", "Error communicating with AI agent.") catch {};
                break;
            };
            
            var tool_executed = false;
            
            // Check for JSON tool call
            if (std.mem.indexOf(u8, response, "{") != null and std.mem.indexOf(u8, response, "\"tool\"") != null) {
                const start_idx = std.mem.indexOf(u8, response, "{").?;
                const end_idx = std.mem.lastIndexOf(u8, response, "}");
                
                if (end_idx != null and end_idx.? > start_idx) {
                    const json_str = response[start_idx .. end_idx.? + 1];
                    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{ .ignore_unknown_fields = true }) catch null;
                    if (parsed) |*p| {
                        defer p.deinit();
                        if (p.value == .object) {
                            if (p.value.object.get("tool")) |tool_val| {
                                if (std.mem.eql(u8, tool_val.string, "read_file")) {
                                    if (p.value.object.get("path")) |path_val| {
                                        const path = path_val.string;
                                        self.addMessage("assistant", response) catch {};
                                        
                                        if (std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024)) |content| {
                                            defer self.allocator.free(content);
                                            var sys_msg = std.ArrayList(u8).empty;
                                            defer sys_msg.deinit(self.allocator);
                                            std.fmt.format(sys_msg.writer(self.allocator), "Tool read_file result for '{s}':\n{s}", .{path, content}) catch {};
                                            self.addMessage("system", sys_msg.items) catch {};
                                        } else |_| {
                                            self.addMessage("system", "Tool error: File not found or cannot be read.") catch {};
                                        }
                                        tool_executed = true;
                                    }
                                } else if (std.mem.eql(u8, tool_val.string, "replace_text")) {
                                    if (p.value.object.get("path")) |path_val| {
                                        if (p.value.object.get("old")) |old_val| {
                                            if (p.value.object.get("new")) |new_val| {
                                                const path = path_val.string;
                                                const old_str = old_val.string;
                                                const new_str = new_val.string;
                                                
                                                self.addMessage("assistant", response) catch {};
                                                
                                                if (std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024)) |content| {
                                                    defer self.allocator.free(content);
                                                    if (std.mem.indexOf(u8, content, old_str)) |replace_idx| {
                                                        var new_content = std.ArrayList(u8).empty;
                                                        defer new_content.deinit(self.allocator);
                                                        new_content.appendSlice(self.allocator, content[0..replace_idx]) catch {};
                                                        new_content.appendSlice(self.allocator, new_str) catch {};
                                                        new_content.appendSlice(self.allocator, content[replace_idx + old_str.len..]) catch {};
                                                        
                                                        std.fs.cwd().writeFile(.{ .sub_path = path, .data = new_content.items }) catch {};
                                                        self.addMessage("system", "Tool replace_text success.") catch {};
                                                    } else {
                                                        self.addMessage("system", "Tool error: Old text not found in file.") catch {};
                                                    }
                                                } else |_| {
                                                    self.addMessage("system", "Tool error: File not found.") catch {};
                                                }
                                                tool_executed = true;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            if (!tool_executed) {
                self.addMessage("assistant", response) catch {};
                self.allocator.free(response);
                break;
            } else {
                self.allocator.free(response);
            }
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_loading = false;
    }

    fn getAIResponse(self: *Self) ![]const u8 {
        const a = self.agent orelse return error.NoAgent;
        
        var api_messages = std.ArrayList(agent.LlamaAgent.ChatMessage).empty;
        defer api_messages.deinit(self.allocator);

        try api_messages.append(self.allocator, .{ 
            .role = "system", 
            .content = "You are Gemma 4, an intelligent coding assistant in vulkan-ed. You can use tools by outputting a JSON block. " ++
                       "To read a file, output exactly: {\"tool\": \"read_file\", \"path\": \"<file_path>\"}. " ++
                       "To replace text in a file, output: {\"tool\": \"replace_text\", \"path\": \"<file_path>\", \"old\": \"<exact_old_text>\", \"new\": \"<new_text>\"}. " ++
                       "Only output the JSON block when using a tool. Otherwise, chat normally." 
        });

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.messages.items) |m| {
                try api_messages.append(self.allocator, .{ .role = m.role, .content = m.content });
            }
        }

        return try a.sendChatCompletion(api_messages.items);
    }

    pub fn triggerDownload(self: *Self) !void {
        if (self.is_downloading or self.model_exists) return;
        self.is_downloading = true;
        if (self.active_thread) |t| {
            t.join();
            self.active_thread = null;
        }
        self.active_thread = try std.Thread.spawn(.{}, downloadWorker, .{self});
    }

    fn downloadWorker(self: *Self) void {
        const model_name = "gemma-4-E2B-it-Q4_K_M.gguf";
        const url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf";
        
        const argv = &[_][]const u8{
            "curl", "-L", url, "-o", model_name,
        };

        var child = std.process.Child.init(argv, self.allocator);
        child.stderr_behavior = .Pipe;
        child.spawn() catch |err| {
            log.err("Download failed to spawn: {}", .{err});
            self.mutex.lock();
            self.is_downloading = false;
            self.mutex.unlock();
            return;
        };

        if (child.stderr) |stderr| {
            var line_buf: [1024]u8 = undefined;
            while (true) {
                const n = stderr.read(&line_buf) catch break;
                if (n == 0) break;
                if (self.stop_flag.load(.seq_cst)) break;
                
                const line = line_buf[0..n];
                var it = std.mem.tokenizeAny(u8, line, " \r\n");
                if (it.next()) |token| {
                    if (std.fmt.parseFloat(f32, token)) |val| {
                        self.mutex.lock();
                        self.download_progress = val / 100.0;
                        self.mutex.unlock();
                    } else |_| {}
                }
            }
        }

        const term = child.wait() catch |err| {
            log.err("Download failed during wait: {}", .{err});
            self.mutex.lock();
            self.is_downloading = false;
            self.mutex.unlock();
            return;
        };

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    log.err("Download failed with exit code: {d}", .{code});
                    self.mutex.lock();
                    self.is_downloading = false;
                    self.mutex.unlock();
                    return;
                }
            },
            else => {
                log.err("Download failed with term: {}", .{term});
                self.mutex.lock();
                self.is_downloading = false;
                self.mutex.unlock();
                return;
            },
        }

        self.mutex.lock();
        self.model_exists = true;
        self.is_downloading = false;
        self.mutex.unlock();
        
        if (self.server_path != null and self.model_path != null) {
            self.initAgent(self.server_path.?, self.model_path.?) catch {};
        }
        
        log.info("Download complete: {s}", .{model_name});
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
    mouse_pressed: bool,
    window: ?*wio.Window,
) void {
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
            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 8 },
        })({
            clay.text("Gemma 4 Agent", .{ .font_size = 20, .color = theme.primary });

            // Status Lamp
            const status_color: clay.Color = if (state.model_exists and !state.is_initializing) .{ 100, 255, 100, 255 } else .{ 255, 200, 100, 255 };
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(10) } },
                .background_color = status_color,
                .corner_radius = .all(5),
            })({});
            
            if (state.is_initializing) {
                clay.text("Initializing GPU...", .{ .font_size = 12, .color = .{ 150, 150, 150, 255 } });
            }
            
            if (!state.model_exists) {
                const btn_id = clay.ElementId.ID("ai_download_btn");
                const hovered = clay.pointerOver(btn_id);
                if (hovered and mouse_pressed and !state.is_downloading) {
                    state.triggerDownload() catch {};
                }

                clay.UI()(.{
                    .id = btn_id,
                    .layout = .{ .sizing = .{ .w = .fit, .h = .fit }, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 } },
                    .background_color = if (state.is_downloading) .{ 100, 100, 100, 255 } else if (hovered) theme.primary else theme.border,
                    .corner_radius = .all(4),
                })({
                    clay.text(if (state.is_downloading) "Downloading..." else "Download Model (3GB)", .{ .font_size = 12, .color = .{ 255, 255, 255, 255 } });
                });
            }
        });

        if (state.is_downloading) {
            clay.UI()(.{
                .id = clay.ElementId.ID("ai_download_progress_track"),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(6) } },
                .background_color = .{ 40, 40, 45, 255 },
                .corner_radius = .all(3),
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("ai_download_progress_bar"),
                    .layout = .{ .sizing = .{ .w = .percent(state.download_progress), .h = .grow } },
                    .background_color = theme.primary,
                    .corner_radius = .all(3),
                })({});
            });
        }

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
                for (state.messages.items, 0..) |msg, idx| {
                    const is_user = std.mem.eql(u8, msg.role, "user");
                    
                    const msg_id_str = std.fmt.allocPrint(arena, "ai_msg_{d}", .{idx}) catch "ai_msg_err";
                    const msg_id = clay.ElementId.ID(msg_id_str);
                    const hovered = clay.pointerOver(msg_id);

                    if (hovered and mouse_pressed) {
                        if (window) |win| {
                            win.setClipboardText(msg.content);
                            state.last_copy_time = std.time.milliTimestamp();
                        }
                    }

                    const bg_color: clay.Color = if (is_user) 
                        (if (hovered) .{ 60, 60, 100, 255 } else .{ 50, 50, 80, 255 })
                    else 
                        (if (hovered) .{ 50, 50, 55, 255 } else .{ 40, 40, 45, 255 });

                    clay.UI()(.{
                        .id = msg_id,
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fit },
                            .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
                            .direction = .top_to_bottom,
                        },
                        .background_color = bg_color,
                        .corner_radius = .all(4),
                    })({
                        const now = std.time.milliTimestamp();
                        const show_copied = !is_user and (now - state.last_copy_time < 2000);
                        
                        clay.text(if (is_user) "You:" else if (show_copied) "Gemma (Copied!)" else "Gemma (Click to copy):", .{ 
                            .font_size = 14, 
                            .color = if (is_user) .{ 200, 200, 255, 255 } else if (show_copied) theme.primary else .{ 200, 255, 200, 255 } 
                        });
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
            if (state.is_downloading or state.is_initializing) {
                clay.text("Model is initializing...", .{ .font_size = 16, .color = .{ 80, 80, 85, 255 } });
            } else if (state.input_buffer.items.len == 0) {
                clay.text("Ask something... (Ctrl+K to toggle)", .{ .font_size = 16, .color = .{ 100, 100, 100, 255 } });
            } else {
                clay.text(state.input_buffer.items, .{ .font_size = 16, .color = .{ 255, 255, 255, 255 } });
            }
        });
    });
}
