const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const Theme = @import("theme.zig").Theme;
const agent = @import("agent");
const scheduler_mod = @import("scheduler");
const ai_worker = @import("ai_worker");
const flow_core = @import("flow_core");
const textarea_mod = @import("components/mod.zig");
const chat_markdown = @import("chat_markdown");
const MarkdownView = @import("markdown_view.zig").MarkdownView;
const ui_mod = @import("mod.zig");

const log = std.log.scoped(.ai_chat);

pub const ChatMessage = struct {
    role: []const u8,
    /// Roher Text, geht so an die API und in die Zwischenablage.
    content: []const u8,
    /// Anzeige-Markdown (Tool-Calls als Codeblock) mit eigenem Renderer.
    md: MarkdownView,
};

const message_font_size: u16 = 16;
const message_text_color: clay.Color = .{ 240, 240, 240, 255 };

pub const AIChatState = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(ChatMessage),
    agent: ?*agent.LlamaAgent = null,
    scheduler: ?*scheduler_mod.Scheduler = null,

    server_path: []const u8 = "",
    model_path: []const u8 = "",

    is_loading: bool = false,
    is_downloading: bool = false,
    is_initializing: bool = false,
    download_progress: f32 = 0,
    model_exists: bool = false,
    last_copy_time: i64 = 0,

    mutex: std.Thread.Mutex = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    scroll_offset_y: f32 = 0,
    viewport_height: f32 = 0,
    content_height: f32 = 0,
    last_input_time_ms: i64 = 0,
    ui_time_ms: f32 = 0,

    width: f32 = 350.0,

    // Messages-Scrollbar Bounds (im render aus bounding_box gefüllt)
    msg_sb_track_x: f32 = 0,
    msg_sb_track_y: f32 = 0,
    msg_sb_track_h: f32 = 0,
    msg_sb_thumb_y: f32 = 0,
    msg_sb_thumb_h: f32 = 0,
    msg_sb_visible: bool = false,
    msg_sb_dragging: bool = false,
    msg_sb_drag_offset: f32 = 0,

    // Input-Editor (TextArea mit eigenem Buffer)
    input_textarea: textarea_mod.TextAreaState,
    input_buffer: *flow_core.Buffer,
    input_height: f32 = 120,
    input_splitter_dragging: bool = false,
    input_splitter_offset: f32 = 0,
    input_splitter_y: f32 = 0,
    input_splitter_h: f32 = splitter_height,
    input_bounds_valid: bool = false,
    input_bounds_x: f32 = 0,
    input_bounds_y: f32 = 0,
    input_bounds_w: f32 = 0,
    input_bounds_h: f32 = 0,

    const Self = @This();

    const model_filename = "models/gemma-4-E2B-it-Q4_K_M.gguf";

    pub fn init(allocator: std.mem.Allocator) !Self {
        var exists = false;
        if (std.fs.cwd().access(model_filename, .{})) |_| {
            exists = true;
        } else |_| {}

        const input_buf = try flow_core.Buffer.create(allocator);
        errdefer input_buf.deinit();

        var state = Self{
            .allocator = allocator,
            .messages = .empty,
            .input_textarea = textarea_mod.TextAreaState.init(allocator, input_buf),
            .input_buffer = input_buf,
            .model_exists = exists,
        };
        state.input_textarea.is_textarea = true;
        // Buffer.create liefert einen Root ohne Zeilenanfang (keine Zeile 0).
        // Erst load_from_string("") via setText macht den Puffer beschreibbar,
        // sonst verwirft der Rope-Walker jedes Zeichen nach dem ersten.
        state.input_textarea.setText("");

        return state;
    }

    pub fn setScheduler(self: *Self, sched: *scheduler_mod.Scheduler) void {
        self.scheduler = sched;
        if (self.agent != null and self.is_initializing) {
            self.submitWarmup() catch |err| log.err("deferred warmup submit failed: {}", .{err});
        }
    }

    pub fn deinit(self: *Self) void {
        self.stop_flag.store(true, .seq_cst);

        for (self.messages.items) |*msg| {
            msg.md.deinit();
            self.allocator.free(msg.content);
            self.allocator.free(msg.role);
        }
        self.messages.deinit(self.allocator);
        self.input_textarea.deinit();
        self.input_buffer.deinit();
        if (self.agent) |a| a.deinit();
    }

    pub fn initAgent(self: *Self, server_path: []const u8, model_path: []const u8) !void {
        if (self.agent) |a| {
            a.deinit();
            self.agent = null;
        }

        self.server_path = server_path;
        self.model_path = model_path;

        self.agent = agent.LlamaAgent.init(self.allocator, server_path, model_path, 11434) catch |err| {
            log.err("Failed to initialize AI Agent: {}", .{err});
            return err;
        };

        self.is_initializing = true;
        self.submitWarmup() catch |err| switch (err) {
            error.NoScheduler => {},
            else => return err,
        };
    }

    fn submitWarmup(self: *Self) !void {
        const a = self.agent orelse return error.NoAgent;
        const sched = self.scheduler orelse return error.NoScheduler;
        const params = try ai_worker.WarmupParams.init(self.allocator, a, &sched.should_stop);
        if (!sched.submit(.{ .func = ai_worker.taskWarmup, .data = params })) {
            params.deinit();
            self.is_initializing = false;
            return error.SchedulerQueueFull;
        }
    }

    pub fn handleWarmupDone(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_initializing = false;
        log.info("AI Agent is warm and ready.", .{});
    }

    pub fn handleWarmupError(self: *Self, payload: []const u8) void {
        log.err("AI warmup failed: {s}", .{payload});
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_initializing = false;
    }

    pub fn addMessage(self: *Self, role: []const u8, content: []const u8) !void {
        const dupe_role = try self.allocator.dupe(u8, role);
        errdefer self.allocator.free(dupe_role);
        const dupe_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(dupe_content);

        const display = if (std.mem.eql(u8, role, "system"))
            try chat_markdown.wrapToolResult(self.allocator, content)
        else
            try chat_markdown.toDisplayMarkdown(self.allocator, content);
        defer self.allocator.free(display);

        var md = MarkdownView.init(self.allocator, display, "");
        errdefer md.deinit();
        md.font_size = message_font_size;
        md.text_color = message_text_color;

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.messages.append(self.allocator, .{
            .role = dupe_role,
            .content = dupe_content,
            .md = md,
        });
        self.scroll_offset_y = 999999;
    }

    pub fn sendMessage(self: *Self) !void {
        const text = self.input_buffer.store_to_string_cached(self.input_buffer.root, self.input_buffer.file_eol_mode);
        std.log.debug("SEND: buffer len={d} text={s}", .{ text.len, text });
        // if (text.len == 0 or self.is_loading or self.is_initializing) return;
        // if (self.agent == null or self.scheduler == null) return error.NoAgent;

        const user_text = try self.allocator.dupe(u8, text);
        defer self.allocator.free(user_text);
        try self.addMessage("user", user_text);

        self.input_textarea.setText("");

        self.is_loading = true;
        try self.submitCompletion();
    }

    fn submitCompletion(self: *Self) !void {
        const a = self.agent orelse return error.NoAgent;
        const sched = self.scheduler orelse return error.NoScheduler;

        var api_messages: std.ArrayListUnmanaged(agent.LlamaAgent.ChatMessage) = .empty;
        defer api_messages.deinit(self.allocator);

        try api_messages.append(self.allocator, .{
            .role = "system",
            .content = "You are Gemma 4, an intelligent coding assistant in vulkan-ed. You can use tools by outputting a JSON block. " ++
                "To read a file, output exactly: {\"tool\": \"read_file\", \"path\": \"<file_path>\"}. " ++
                "To replace text in a file, output: {\"tool\": \"replace_text\", \"path\": \"<file_path>\", \"old\": \"<exact_old_text>\", \"new\": \"<new_text>\"}. " ++
                "Only output the JSON block when using a tool. Otherwise, chat normally.",
        });

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.messages.items) |m| {
                try api_messages.append(self.allocator, .{ .role = m.role, .content = m.content });
            }
        }

        const params = try ai_worker.ChatParams.initWithStop(self.allocator, a, api_messages.items, &sched.should_stop);
        if (!sched.submit(.{ .func = ai_worker.taskChatCompletion, .data = params })) {
            params.deinit();
            self.is_loading = false;
            return error.SchedulerQueueFull;
        }
    }

    pub fn handleReply(self: *Self, payload: []const u8) void {
        const tool_executed = self.tryExecuteToolCall(payload);
        if (tool_executed) {
            self.submitCompletion() catch |err| {
                log.err("submitCompletion failed after tool: {}", .{err});
                self.addMessage("assistant", "Error continuing after tool call.") catch {};
                self.is_loading = false;
            };
        } else {
            self.addMessage("assistant", payload) catch {};
            self.is_loading = false;
        }
    }

    pub fn handleError(self: *Self, payload: []const u8) void {
        log.err("AI task error: {s}", .{payload});
        self.addMessage("assistant", "Error communicating with AI agent.") catch {};
        self.is_loading = false;
    }

    fn tryExecuteToolCall(self: *Self, response: []const u8) bool {
        const json_str = chat_markdown.findToolCall(response) orelse return false;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{ .ignore_unknown_fields = true }) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;

        const tool_val = parsed.value.object.get("tool") orelse return false;
        if (tool_val != .string) return false;

        if (std.mem.eql(u8, tool_val.string, "read_file")) {
            const path_val = parsed.value.object.get("path") orelse return false;
            if (path_val != .string) return false;
            const path = path_val.string;

            self.addMessage("assistant", response) catch {};

            if (std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024)) |content| {
                defer self.allocator.free(content);
                var sys_msg: std.ArrayListUnmanaged(u8) = .empty;
                defer sys_msg.deinit(self.allocator);
                std.fmt.format(sys_msg.writer(self.allocator), "Tool read_file result for '{s}':\n{s}", .{ path, content }) catch {};
                self.addMessage("system", sys_msg.items) catch {};
            } else |_| {
                self.addMessage("system", "Tool error: File not found or cannot be read.") catch {};
            }
            return true;
        } else if (std.mem.eql(u8, tool_val.string, "replace_text")) {
            const path_val = parsed.value.object.get("path") orelse return false;
            const old_val = parsed.value.object.get("old") orelse return false;
            const new_val = parsed.value.object.get("new") orelse return false;
            if (path_val != .string or old_val != .string or new_val != .string) return false;

            const path = path_val.string;
            const old_str = old_val.string;
            const new_str = new_val.string;

            self.addMessage("assistant", response) catch {};

            if (std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024)) |content| {
                defer self.allocator.free(content);
                if (std.mem.indexOf(u8, content, old_str)) |replace_idx| {
                    var new_content: std.ArrayListUnmanaged(u8) = .empty;
                    defer new_content.deinit(self.allocator);
                    new_content.appendSlice(self.allocator, content[0..replace_idx]) catch {};
                    new_content.appendSlice(self.allocator, new_str) catch {};
                    new_content.appendSlice(self.allocator, content[replace_idx + old_str.len ..]) catch {};

                    std.fs.cwd().writeFile(.{ .sub_path = path, .data = new_content.items }) catch {};
                    self.addMessage("system", "Tool replace_text success.") catch {};
                } else {
                    self.addMessage("system", "Tool error: Old text not found in file.") catch {};
                }
            } else |_| {
                self.addMessage("system", "Tool error: File not found.") catch {};
            }
            return true;
        }

        return false;
    }

    pub fn triggerDownload(self: *Self) !void {
        if (self.is_downloading or self.model_exists) return;
        const sched = self.scheduler orelse return error.NoScheduler;

        const url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf";

        const sink: ai_worker.ProgressSink = .{
            .value = &self.download_progress,
            .mutex = &self.mutex,
            .stop_flag = &self.stop_flag,
        };
        const params = try ai_worker.DownloadParams.init(self.allocator, url, model_filename, sink);
        if (!sched.submit(.{ .func = ai_worker.taskDownload, .data = params })) {
            params.deinit();
            return error.SchedulerQueueFull;
        }
        self.is_downloading = true;
    }

    pub fn handleDownloadDone(self: *Self) void {
        self.mutex.lock();
        self.model_exists = true;
        self.is_downloading = false;

        self.mutex.unlock();

        if (self.server_path.len > 0 and self.model_path.len > 0) {
            self.initAgent(self.server_path, self.model_path) catch |err| {
                log.err("initAgent after download failed: {}", .{err});
            };
        }
        log.info("Download complete.", .{});
    }

    pub fn handleDownloadError(self: *Self, payload: []const u8) void {
        log.err("AI download failed: {s}", .{payload});
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_downloading = false;
    }

    pub fn handleKeyPress(self: *Self, key: wio.Button) bool {
        switch (key) {
            .enter => {
                self.input_textarea.handleKeyPress(key);
                self.sendMessage() catch |err| log.err("Send message failed: {}", .{err});
                return true;
            },
            .backspace => {
                self.input_textarea.handleKeyPress(key);
                return true;
            },
            else => {
                self.input_textarea.handleKeyPress(key);
                return false;
            },
        }
    }

    pub fn handleChar(self: *Self, char_code: u21) void {
        self.input_textarea.handleChar(char_code);
    }

    pub fn updateTimeMs(self: *Self, delta_ms: f32) void {
        self.ui_time_ms += delta_ms;
        self.input_textarea.time_ms += delta_ms;
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, button: wio.Button) void {
        self.input_textarea.handleMouseDown(x, y, button);
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        // Handle splitter dragging
        if (self.input_splitter_dragging) {
            const new_height = self.input_height + (self.input_splitter_y + self.input_splitter_h - y);
            self.input_height = @max(40, @min(400, new_height));
        }
        self.input_textarea.handleMouseMove(x, y);
    }

    pub fn handleMouseUp(self: *Self) void {
        self.input_splitter_dragging = false;
        self.input_textarea.handleMouseUp();
    }

    /// Messages-Scrollbar: Mouse-Down
    pub fn handleMsgSbMouseDown(self: *Self, x: f32, y: f32) bool {
        if (!self.msg_sb_visible) return false;
        const in_track_x = x >= self.msg_sb_track_x and x <= self.msg_sb_track_x + 8.0;
        const in_track_y = y >= self.msg_sb_track_y and y <= self.msg_sb_track_y + self.msg_sb_track_h;
        if (!(in_track_x and in_track_y)) return false;

        if (y >= self.msg_sb_thumb_y and y <= self.msg_sb_thumb_y + self.msg_sb_thumb_h) {
            self.msg_sb_dragging = true;
            self.msg_sb_drag_offset = y - self.msg_sb_thumb_y;
        } else {
            self.msg_sb_drag_offset = self.msg_sb_thumb_h / 2.0;
            self.msg_sb_dragging = true;
            self.scrollMsgToFraction((y - self.msg_sb_drag_offset - self.msg_sb_track_y) / @max(1.0, self.msg_sb_track_h - self.msg_sb_thumb_h));
        }
        return true;
    }

    pub fn handleMsgSbMouseMove(self: *Self, _: f32, y: f32) void {
        if (!self.msg_sb_dragging) return;
        const usable = @max(1.0, self.msg_sb_track_h - self.msg_sb_thumb_h);
        const frac = (y - self.msg_sb_drag_offset - self.msg_sb_track_y) / usable;
        self.scrollMsgToFraction(frac);
    }

    pub fn handleMsgSbMouseUp(self: *Self) void {
        self.msg_sb_dragging = false;
    }

    fn scrollMsgToFraction(self: *Self, frac: f32) void {
        const max_scroll = @max(0.0, self.content_height - self.viewport_height);
        const clamped = std.math.clamp(frac, 0.0, 1.0);
        self.scroll_offset_y = clamped * max_scroll;
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

    pub fn setWindow(self: *Self, win: ?*wio.Window) void {
        self.input_textarea.setWindow(win);
    }
};

const scrollbar_width: f32 = 8.0;
const splitter_height: f32 = 6.0;
const splitter_hit_height: f32 = 12.0;

pub fn renderAIChat(
    arena: std.mem.Allocator,
    state: *AIChatState,
    theme: Theme,
    mouse_pressed: bool,
    window: ?*wio.Window,
    ui_ptr: *ui_mod.UI,
) void {
    state.input_textarea.setWindow(window);

    clay.UI()(.{
        .id = clay.ElementId.ID("ai_chat_root"),
        .layout = .{
            .sizing = .grow,
            .direction = .top_to_bottom,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
            .child_gap = 8,
        },
        .background_color = theme.surface,
    })({
        // ── Header ──────────────────────────────────────────────────────
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .left_to_right,
                .child_gap = 8,
                .child_alignment = .{ .y = .center },
            },
        })({
            clay.text("Gemma 4 Agent", .{ .font_size = 20, .color = theme.primary });

            const status_color: clay.Color = if (state.model_exists and !state.is_initializing)
                .{ 100, 255, 100, 255 }
            else
                .{ 255, 200, 100, 255 };
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(10) } },
                .background_color = status_color,
                .corner_radius = .all(5),
            })({});

            if (state.is_initializing) {
                clay.text("Initializing...", .{ .font_size = 12, .color = .{ 150, 150, 150, 255 } });
            }
        });

        // ── Download button / progress ───────────────────────────────────
        if (!state.model_exists) {
            const btn_id = clay.ElementId.ID("ai_download_btn");
            const hovered = clay.pointerOver(btn_id);
            if (hovered and mouse_pressed and !state.is_downloading) {
                state.triggerDownload() catch {};
            }
            clay.UI()(.{
                .id = btn_id,
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
                },
                .background_color = if (state.is_downloading) .{ 100, 100, 100, 255 } else if (hovered) theme.primary else theme.border,
                .corner_radius = .all(4),
            })({
                clay.text(
                    if (state.is_downloading) "Downloading..." else "Download Model (3GB)",
                    .{ .font_size = 12, .color = .{ 255, 255, 255, 255 } },
                );
            });
        }

        if (state.is_downloading) {
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(6) } },
                .background_color = .{ 40, 40, 45, 255 },
                .corner_radius = .all(3),
            })({
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .percent(state.download_progress), .h = .grow } },
                    .background_color = theme.primary,
                    .corner_radius = .all(3),
                })({});
            });
        }

        // ── Messages area (clip + scrollbar) ────────────────────────────
        const viewport_id = clay.ElementId.ID("ai_chat_viewport");
        const content_id = clay.ElementId.ID("ai_chat_content");

        clay.UI()(.{
            .id = clay.ElementId.ID("ai_messages_row"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right,
            },
        })({
            // Clipped scroll area
            clay.UI()(.{
                .id = viewport_id,
                .layout = .{ .sizing = .grow },
                .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -state.scroll_offset_y } },
            })({
                clay.UI()(.{
                    .id = content_id,
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = 6,
                    },
                })({
                    state.mutex.lock();
                    defer state.mutex.unlock();
                    for (state.messages.items, 0..) |*msg, idx| {
                        const is_user = std.mem.eql(u8, msg.role, "user");
                        const msg_id = clay.ElementId.ID(std.fmt.allocPrint(arena, "ai_msg_{d}", .{idx}) catch "ai_msg_x");
                        const hovered = clay.pointerOver(msg_id);

                        if (hovered and mouse_pressed) {
                            if (window) |win| {
                                win.setClipboardText(msg.content);
                                state.last_copy_time = std.time.milliTimestamp();
                            }
                        }

                        const now = std.time.milliTimestamp();
                        const show_copied = !is_user and (now - state.last_copy_time < 2000);

                        const bg: clay.Color = if (is_user)
                            (if (hovered) .{ 60, 60, 105, 255 } else .{ 50, 50, 85, 255 })
                        else
                            (if (hovered) .{ 50, 50, 58, 255 } else .{ 40, 40, 48, 255 });

                        clay.UI()(.{
                            .id = msg_id,
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fit },
                                .direction = .top_to_bottom,
                                .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
                            },
                            .background_color = bg,
                            .corner_radius = .all(4),
                        })({
                            clay.text(
                                if (is_user) "You:" else if (show_copied) "Gemma (Copied!):" else "Gemma:",
                                .{ .font_size = 12, .color = if (is_user) .{ 180, 180, 255, 255 } else if (show_copied) theme.primary else .{ 150, 230, 150, 255 } },
                            );
                            msg.md.renderDocument(arena, theme, ui_ptr);
                        });
                    }

                    if (state.is_loading) {
                        clay.text("Gemma is thinking...", .{ .font_size = 14, .color = .{ 150, 150, 150, 255 } });
                    }
                });
            });

            // Scrollbar track + thumb (only when content overflows)
            const track_id = clay.ElementId.ID("ai_chat_scrollbar_track");
            const overflow = state.content_height > state.viewport_height and state.viewport_height > 0;
            state.msg_sb_visible = overflow;
            clay.UI()(.{
                .id = track_id,
                .layout = .{
                    .sizing = .{ .w = .fixed(scrollbar_width), .h = .grow },
                },
                .background_color = if (overflow) .{ 35, 35, 42, 255 } else .{ 0, 0, 0, 0 },
                .corner_radius = .all(3),
            })({
                if (overflow) {
                    const track_data = clay.getElementData(track_id);
                    if (track_data.found) {
                        const track_h = track_data.bounding_box.height;
                        const thumb_ratio = state.viewport_height / state.content_height;
                        const thumb_h = @max(20.0, track_h * thumb_ratio);
                        const max_scroll = state.content_height - state.viewport_height;
                        const scroll_frac = if (max_scroll > 0) state.scroll_offset_y / max_scroll else 0.0;
                        const thumb_y = scroll_frac * (track_h - thumb_h);

                        state.msg_sb_track_x = track_data.bounding_box.x;
                        state.msg_sb_track_y = track_data.bounding_box.y;
                        state.msg_sb_track_h = track_h;
                        state.msg_sb_thumb_y = track_data.bounding_box.y + thumb_y;
                        state.msg_sb_thumb_h = thumb_h;

                        clay.UI()(.{
                            .floating = .{
                                .attach_to = .to_parent,
                                .attach_points = .{ .element = .left_top, .parent = .left_top },
                                .offset = .{ .x = 0, .y = thumb_y },
                                .z_index = 10,
                            },
                            .layout = .{ .sizing = .{ .w = .fixed(scrollbar_width), .h = .fixed(thumb_h) } },
                            .background_color = if (state.msg_sb_dragging) .{ 130, 130, 170, 230 } else .{ 90, 90, 120, 210 },
                            .corner_radius = .all(3),
                        })({});
                    }
                }
            });
        });

        // Update scroll bounds
        const vp_data = clay.getElementData(viewport_id);
        const ct_data = clay.getElementData(content_id);
        if (vp_data.found) state.viewport_height = vp_data.bounding_box.height;
        if (ct_data.found) state.content_height = ct_data.bounding_box.height;
        const max_scroll = @max(0.0, state.content_height - state.viewport_height);
        if (state.scroll_offset_y == 999999.0) {
            state.scroll_offset_y = max_scroll;
        } else if (state.scroll_offset_y > max_scroll) {
            state.scroll_offset_y = max_scroll;
        }

        // ── Splitter (draggable) ────────────────────────────────────────
        const splitter_id = clay.ElementId.ID("ai_chat_splitter");
        const splitter_hovered = clay.pointerOver(splitter_id);

        // Splitter dragging logic
        if (state.input_splitter_dragging and mouse_pressed) {
            // Handled in mouse move
        } else if (splitter_hovered and mouse_pressed) {
            state.input_splitter_dragging = true;
        }

        clay.UI()(.{
            .id = splitter_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(splitter_height) },
            },
            .background_color = if (state.input_splitter_dragging or splitter_hovered) theme.border else .{ 20, 20, 25, 255 },
        })({});

        // Store splitter bounds for drag handling
        const splitter_data = clay.getElementData(splitter_id);
        if (splitter_data.found) {
            state.input_splitter_y = splitter_data.bounding_box.y;
            state.input_splitter_h = splitter_data.bounding_box.height;
        }

        // ── Input box (TextArea) ────────────────────────────────────────
        const input_id = clay.ElementId.IDI("ai_chat_input", @truncate(@intFromPtr(&state.input_textarea)));

        clay.UI()(.{
            .id = input_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(state.input_height) },
                .direction = .left_to_right,
            },
            .background_color = .{ 28, 28, 34, 255 },
            .border = .{ .width = .all(1), .color = theme.border },
            .corner_radius = .all(4),
        })({
            state.input_textarea.render(arena, mouse_pressed);
        });

        // Input-Bounds für Cursor-Detection speichern
        const input_box_data = clay.getElementData(input_id);
        if (input_box_data.found) {
            state.input_bounds_x = input_box_data.bounding_box.x;
            state.input_bounds_y = input_box_data.bounding_box.y;
            state.input_bounds_w = input_box_data.bounding_box.width;
            state.input_bounds_h = input_box_data.bounding_box.height;
            state.input_bounds_valid = true;
        }
    });
}
