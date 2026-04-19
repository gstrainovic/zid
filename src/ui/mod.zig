//! UI Modul für vulkan-ed
//!
//! Verwendet Clay für Layout und migrierte Gooey Components.

const std = @import("std");
const clay = @import("clay");
pub const Theme = @import("theme.zig").Theme;
const animation = @import("animation.zig");
const Animation = animation.Animation;
const AnimationType = animation.AnimationType;
const AnimationManager = animation.AnimationManager;
const PdfHandler = @import("../rendering/pdf_handler.zig").PdfHandler;
const PdfViewState = @import("pdf_view.zig").PdfViewState;
const editor_mod = @import("../editor/mod.zig");
const wio = @import("wio");
const tab_bar_mod = @import("tab_bar.zig");
const file_explorer_mod = @import("file_explorer.zig");
const image_view_mod = @import("image_view.zig");
const file_types = @import("file_types.zig");
const markdown_view_mod = @import("markdown_view.zig");
const pane_mod = @import("pane.zig");
const dialog_mod = @import("dialog.zig");
const ai_chat_mod = @import("ai_chat.zig");
const agent_mod = @import("agent");
const textarea_mod = @import("components/textarea.zig");
const TextAreaState = textarea_mod.TextAreaState;


const log = std.log.scoped(.ui);

/// Globaler Measure-Context (thread-local) — wird von CodeEditor.colFromX genutzt
var g_text_renderer: ?*@import("../text/mod.zig").TextRenderer = null;
var g_font_size: f32 = 0;

/// C-kompatibler Callback: misst Text-Breite in px
fn cMeasureText(ptr: [*c]const u8, len: usize) f32 {
    const tr = g_text_renderer orelse return 0;
    return tr.measureTextAtSize(ptr[0..len], g_font_size);
}

/// Public helper: misst Text-Breite bei beliebiger Font-Size.
/// Wird von UI-Komponenten (z.B. tab_bar) benötigt, die explizite Breiten
/// berechnen müssen, weil Clay's .fit Sizing für Text + fixed children unzuverlässig ist.
pub fn measureTextWidth(text: []const u8, font_size: f32) f32 {
    const tr = g_text_renderer orelse return 0;
    return tr.measureTextAtSize(text, font_size);
}

/// UI Konfiguration
pub const UIConfig = struct {
    font_size: f32 = 24.0,
    padding: f32 = 12.0,
    gap: f32 = 8.0,
    ai_disabled: bool = false,
};

/// UI Hauptstruktur
pub const components = @import("components/mod.zig");

pub const UI = struct {
    pub const TabCloseRequest = struct { pane: *pane_mod.Pane, index: usize };
    pub const PdfPageChange = struct { path: []const u8, delta: i16 };
    pub const ActiveDialog = struct {
        dialog: dialog_mod.Dialog,
        context_usize: usize = 0,
        context_ptr: ?*anyopaque = null,
        callback: *const fn (*UI, dialog_mod.DialogResult, usize, ?*anyopaque) void,
        message_needs_free: bool = false,
    };

    allocator: std.mem.Allocator,
    config: UIConfig,
    theme: Theme,
    initialized: bool,

    clay_memory: []u8,
    anim_manager: AnimationManager,
    frame_arena: std.heap.ArenaAllocator,

    root_pane: *pane_mod.Pane,
    active_pane: *pane_mod.Pane,

    text_renderer: ?*@import("../text/mod.zig").TextRenderer,
    window: ?*wio.Window,

    file_explorer: file_explorer_mod.FileExplorerState,
    show_file_explorer: bool,

    ai_chat: ai_chat_mod.AIChatState,
    show_ai_chat: bool,

    current_directory: ?[]const u8,
    pending_tab_switch: ?[]const u8,
    pending_pdf_page_change: ?PdfPageChange,
    pending_split: ?pane_mod.PaneDirection,

    active_dialog: ?ActiveDialog,
    pending_tab_closes: std.ArrayListUnmanaged(TabCloseRequest),

    open_buffers: std.StringHashMap(*@import("flow_core").Buffer),
    open_images: std.StringHashMap(*anyopaque),
    open_pdfs: std.StringHashMap(*anyopaque),
    open_markdown_views: std.StringHashMap(*markdown_view_mod.MarkdownView),
    pending_md_preview: ?[]const u8,

    image_renderer: ?*@import("../clay_renderer/image_renderer.zig").ImageRenderer,

    mouse_pressed_this_frame: bool,
    mouse_x: f32,
    mouse_y: f32,
    is_mouse_down: bool,
    is_ctrl_down: bool,
    is_shift_down: bool,
    is_alt_down: bool,

    /// Git-Branch Name (leer = unbekannt)
    git_branch: []const u8,

    const Self = @This();

    /// UI initialisieren
    pub fn init(allocator: std.mem.Allocator, config: UIConfig, default_file_path: ?[]const u8) !Self {
        log.debug("Initializing UI system", .{});

        // Clay Memory allozieren
        const min_memory = clay.minMemorySize();
        const generous_memory = @max(min_memory, 10 * 1024 * 1024);
        const clay_memory = try allocator.alloc(u8, generous_memory);

        // File Explorer initialisieren
        const file_explorer = file_explorer_mod.FileExplorerState.init(allocator);

        var open_buffers = std.StringHashMap(*@import("flow_core").Buffer).init(allocator);
        const initial_buf = try @import("flow_core").Buffer.create(allocator);
        
        // Content laden
        if (default_file_path) |path| {
            if (std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024)) |file_content| {
                defer allocator.free(file_content);
                initial_buf.root = try initial_buf.load_from_string(file_content, &initial_buf.file_eol_mode, &initial_buf.file_utf8_sanitized);
                initial_buf.set_file_path(path);
                initial_buf.last_save = initial_buf.root;
                log.info("Loaded default file: {s} ({d} bytes)", .{ path, file_content.len });
                try open_buffers.put(try allocator.dupe(u8, path), initial_buf);
            } else |err| {
                log.err("Failed to load default file '{s}': {}. Using fallback.", .{ path, err });
                initial_buf.root = try initial_buf.load_from_string("// Error loading file", &initial_buf.file_eol_mode, &initial_buf.file_utf8_sanitized);
                try open_buffers.put(try allocator.dupe(u8, "error"), initial_buf);
            }
        } else {
            const default_text = "pub fn main() !void {\n    std.log.info(\"Hello World\", .{});\n}\n";
            initial_buf.root = try initial_buf.load_from_string(default_text, &initial_buf.file_eol_mode, &initial_buf.file_utf8_sanitized);
            try open_buffers.put(try allocator.dupe(u8, "scratchpad"), initial_buf);
        }

        const root_pane = try pane_mod.Pane.createLeaf(allocator, initial_buf);
        const active_pane = root_pane;
        if (default_file_path) |path| active_pane.data.leaf.code_editor.setLanguageFromPath(path);

        // AI Chat initialisieren (falls nicht deaktiviert)
        const ai_chat = ai_chat_mod.AIChatState.init(allocator) catch |err| @panic(@errorName(err));
        // AI:暂时禁用，快速测试文本输入
        // if (!config.ai_disabled) {
        //     const llama_server_path = std.process.getEnvVarOwned(allocator, "LLAMA_SERVER_PATH") catch |err| blk: {
        //         if (err == error.EnvironmentVariableNotFound) {
        //             break :blk try allocator.dupe(u8, "ollama");
        //         }
        //         return err;
        //     };
        //     defer allocator.free(llama_server_path);
        //     const model_path = std.process.getEnvVarOwned(allocator, "LLAMA_MODEL_PATH") catch |err| blk: {
        //         if (err == error.EnvironmentVariableNotFound) {
        //             break :blk try allocator.dupe(u8, "gemma4:e2b");
        //         }
        //         return err;
        //     };
        //     defer allocator.free(model_path);
        //
        //     ai_chat.initAgent(llama_server_path, model_path) catch |err| {
        //         log.err("Failed to initialize AI Agent: {}. AI Chat will be disabled.", .{err});
        //     };
        // }

        return Self{
            .allocator = allocator,
            .config = config,
            .theme = Theme.dark(),
            .initialized = false,
            .clay_memory = clay_memory,
            .anim_manager = AnimationManager.init(allocator),
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .root_pane = root_pane,
            .active_pane = active_pane,
            .text_renderer = null,
            .window = null,
            .file_explorer = file_explorer,
            .show_file_explorer = true,
            .ai_chat = ai_chat,
            .show_ai_chat = false,
            .current_directory = null,
            .pending_tab_switch = null,
            .pending_pdf_page_change = null,
            .pending_split = null,
            .active_dialog = null,
            .pending_tab_closes = std.ArrayListUnmanaged(TabCloseRequest).empty,
            .open_buffers = open_buffers,
            .open_images = std.StringHashMap(*anyopaque).init(allocator),
            .open_pdfs = std.StringHashMap(*anyopaque).init(allocator),
            .open_markdown_views = std.StringHashMap(*markdown_view_mod.MarkdownView).init(allocator),
            .pending_md_preview = null,
            .image_renderer = null,
            .mouse_pressed_this_frame = false,
            .mouse_x = 0.0,
            .mouse_y = 0.0,
            .is_mouse_down = false,
            .is_ctrl_down = false,
            .is_shift_down = false,
            .is_alt_down = false,
            .git_branch = "",
        };
    }

    /// UI aufräumen
    pub fn deinit(self: *Self) void {
        log.debug("UI.deinit: start", .{});

        if (self.active_dialog) |ad| {
            if (ad.message_needs_free) {
                self.allocator.free(ad.dialog.message);
            }
            self.active_dialog = null;
        }

        self.anim_manager.deinit();
        log.debug("UI.deinit: anim_manager done", .{});
        self.frame_arena.deinit();
        log.debug("UI.deinit: frame_arena done", .{});
        self.allocator.free(self.clay_memory);
        log.debug("UI.deinit: clay_memory freed", .{});

        self.root_pane.deinit();
        log.debug("UI.deinit: root_pane done", .{});

        self.file_explorer.deinit();
        log.debug("UI.deinit: file_explorer done", .{});

        self.ai_chat.deinit();
        log.debug("UI.deinit: ai_chat done", .{});

        // Buffer aufräumen (Zentrales Ownership)
        log.debug("UI.deinit: cleaning buffers", .{});
        var buf_iter = self.open_buffers.iterator();
        while (buf_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.open_buffers.deinit();

        // Bilder aufräumen
        var iter = self.open_images.iterator();
        while (iter.next()) |entry| {
            const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;
            const tex_ptr: *ImageTexture = @ptrCast(@alignCast(entry.value_ptr.*));
            tex_ptr.deinit();
            self.allocator.destroy(tex_ptr);
            self.allocator.free(entry.key_ptr.*); // Key freigeben
        }
        self.open_images.deinit();
        
        // PDFs aufräumen
        var pdf_iter = self.open_pdfs.iterator();
        while (pdf_iter.next()) |entry| {
            const handler: *PdfHandler = @ptrCast(@alignCast(entry.value_ptr.*));
            handler.deinit();
        }
        self.open_pdfs.deinit();

        // Markdown Previews aufräumen
        var md_iter = self.open_markdown_views.iterator();
        while (md_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.open_markdown_views.deinit();

        if (self.current_directory) |dir| self.allocator.free(dir);
        if (self.git_branch.len > 0) self.allocator.free(self.git_branch);
        self.pending_tab_closes.deinit(self.allocator);

        log.debug("UI.deinit: finished", .{});
    }

    pub fn setAIScheduler(self: *Self, sched: *@import("scheduler").Scheduler) void {
        self.ai_chat.setScheduler(sched);
    }

    pub fn handleAIReply(self: *Self, payload: []const u8) void {
        self.ai_chat.handleReply(payload);
    }

    pub fn handleAIError(self: *Self, payload: []const u8) void {
        self.ai_chat.handleError(payload);
    }

    pub fn handleAIWarmupDone(self: *Self) void {
        self.ai_chat.handleWarmupDone();
    }

    pub fn handleAIWarmupError(self: *Self, payload: []const u8) void {
        self.ai_chat.handleWarmupError(payload);
    }

    pub fn handleAIDownloadDone(self: *Self) void {
        self.ai_chat.handleDownloadDone();
    }

    pub fn handleAIDownloadError(self: *Self, payload: []const u8) void {
        self.ai_chat.handleDownloadError(payload);
    }

    /// Clay initialisieren (nach Window Creation)
    pub fn setupClay(self: *Self, window: ?*wio.Window, width: u32, height: u32, text_renderer: *@import("../text/mod.zig").TextRenderer) !void {
        log.debug("Setting up Clay layout: {}x{}", .{ width, height });
        self.text_renderer = text_renderer;
        self.window = window;
        self.getActiveEditor().window = window;
        self.ai_chat.setWindow(window);
        self.ai_chat.input_editor.measure_fn = cMeasureText;
        g_font_size = @floatFromInt(self.ai_chat.input_editor.font_size);

        // Globalen Measure-Context setzen (für Maus→Spalte)
        g_text_renderer = text_renderer;
        g_font_size = @floatFromInt(self.getActiveEditor().font_size);
        self.getActiveEditor().measure_fn = cMeasureText;

        const arena = clay.createArenaWithCapacityAndMemory(self.clay_memory);

        _ = clay.initialize(arena, .{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, .{});

        // Measure Text Function setzen
        clay.setMeasureTextFunction(*Self, self, clayMeasureText);

        self.initialized = true;
        log.debug("Clay initialized", .{});
    }

    /// Clay Measure Text Callback
    fn clayMeasureText(text_str: []const u8, config: *clay.TextElementConfig, user_data: *Self) clay.Dimensions {
        const renderer = user_data.text_renderer orelse return .{ .w = 0, .h = 0 };

        // Text messen (mit korrekter Font-Size)
        // Wir fügen einen kleinen Puffer hinzu (1.0px) um Floating-Point Rundungsfehler
        // und Clipping-Probleme in Clay zu vermeiden.
        const width = (renderer.ts_ptr.measureTextAtSize(text_str, @floatFromInt(config.font_size)) catch 0) + 1.0;
        
        var height: f32 = @floatFromInt(config.font_size);
        if (renderer.ts_ptr.getMetrics()) |metrics| {
            const scale = @as(f32, @floatFromInt(config.font_size)) / metrics.point_size;
            height = metrics.line_height * scale;
        }
        
        return .{
            .w = width,
            .h = height,
        };
    }

    /// Keyboard Input verarbeiten
    pub fn handleKeyPress(self: *Self, key: @import("wio").Button) void {
        // If a chat tab is active, handle chat input
        if (self.isChatTabActive()) {
            if (self.ai_chat.handleKeyPress(key)) return;
        }

        // If a textarea tab is active, handle textarea input
        if (self.isTextAreaTabActive()) {
            if (self.getActiveTextArea()) |textarea| {
                textarea.handleKeyPress(key);
                return;
            }
        }

        // If a terminal tab is active, forward input to the terminal
        if (self.getActiveTerminal()) |term| {
            // Convert key to terminal input sequence
            var data: ?[]const u8 = switch (key) {
                .enter => "\r",
                .backspace => "\x7f",
                .tab => "\t",
                .escape => "\x1b",
                .up => "\x1b[A",
                .down => "\x1b[B",
                .right => "\x1b[C",
                .left => "\x1b[D",
                .home => "\x1b[H",
                .end => "\x1b[F",
                .delete => "\x1b[3~",
                .page_up => "\x1b[5~",
                .page_down => "\x1b[6~",
                else => null,
            };

            if (self.getActiveEditor().mods.ctrl) {
                data = switch (key) {
                    .a => "\x01",
                    .b => "\x02",
                    .c => "\x03",
                    .d => "\x04",
                    .e => "\x05",
                    .f => "\x06",
                    .g => "\x07",
                    .h => "\x08",
                    .i => "\x09",
                    .j => "\x0A",
                    .k => "\x0B",
                    .l => "\x0C",
                    .m => "\x0D",
                    .n => "\x0E",
                    .o => "\x0F",
                    .p => "\x10",
                    .q => "\x11",
                    .r => "\x12",
                    .s => "\x13",
                    .t => "\x14",
                    .u => "\x15",
                    .v => "\x16",
                    .w => "\x17",
                    .x => "\x18",
                    .y => "\x19",
                    .z => "\x1A",
                    else => data,
                };
            }

            if (data) |d| {
                term.sendInput(d) catch {};
            }
            return;
        }
        self.getActiveEditor().handleKeyPress(key);
    }

    /// Text Input verarbeiten
    pub fn handleChar(self: *Self, char_code: u21) void {
        // Forward to chat tab if active
        if (self.isChatTabActive()) {
            self.ai_chat.handleChar(char_code);
            return;
        }

        // Forward to textarea tab if active
        if (self.isTextAreaTabActive()) {
            if (self.getActiveTextArea()) |textarea| {
                textarea.handleChar(char_code);
            }
            return;
        }

        // Forward to terminal if active
        if (self.getActiveTerminal()) |term| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(char_code, &buf) catch return;
            term.sendInput(buf[0..len]) catch {};
            return;
        }
        self.getActiveEditor().handleChar(char_code);
    }

    /// Modifier-State aktualisieren
    pub fn setShiftState(self: *Self, pressed: bool) void {
        self.is_shift_down = pressed;
        if (self.isTextAreaTabActive()) {
            if (self.getActiveTextArea()) |textarea| {
                textarea.setShiftState(pressed);
            }
        } else {
            self.getActiveEditor().setShiftState(pressed);
        }
    }

    pub fn setCtrlState(self: *Self, pressed: bool) void {
        self.is_ctrl_down = pressed;
        if (self.isTextAreaTabActive()) {
            if (self.getActiveTextArea()) |textarea| {
                textarea.setCtrlState(pressed);
            }
        } else {
            self.getActiveEditor().setCtrlState(pressed);
        }
    }

    pub fn setAltState(self: *Self, pressed: bool) void {
        self.is_alt_down = pressed;
        if (self.isTextAreaTabActive()) {
            if (self.getActiveTextArea()) |textarea| {
                textarea.setAltState(pressed);
            }
        } else {
            self.getActiveEditor().setAltState(pressed);
        }
    }

    fn findPaneAt(self: *Self, pane: *pane_mod.Pane, x: f32, y: f32) ?*pane_mod.Pane {
        switch (pane.data) {
            .leaf => {
                const id = clay.ElementId.IDI("Pane", @truncate(@intFromPtr(pane)));
                const data = clay.getElementData(id);
                if (data.found) {
                    const bb = data.bounding_box;
                    if (x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height) {
                        return pane;
                    }
                }
            },
            .split => |split| {
                if (self.findPaneAt(split.children[0], x, y)) |p| return p;
                if (self.findPaneAt(split.children[1], x, y)) |p| return p;
            },
        }
        return null;
    }

    /// Maus-Events an Editor oder Terminal weiterleiten
    pub fn handleMouseDown(self: *Self, x: f32, y: f32, button: wio.Button) void {
        log.debug("handleMouseDown: x={} y={} button={}", .{ x, y, button });
        self.mouse_pressed_this_frame = true;
        self.is_mouse_down = true;

        if (self.show_file_explorer) {
            if (self.file_explorer.handleMouseDown(x, y)) return;
        }

        // Priority: If a context menu is open, it must handle the click first (to either trigger an action or close)
        const current_editor = self.getActiveEditor();
        if (!current_editor.show_context_menu) {
            if (self.findPaneAt(self.root_pane, x, y)) |pane| {
                self.active_pane = pane;
            }
        }

        const tab_bar = self.getActiveTabBar();
        const editor = self.getActiveEditor();
        
        if (tab_bar.getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (tab_bar.terminal_instances.get(tab.path)) |term| {
                    if (button == .mouse_right) {
                        term.showContextMenu(x, y);
                        return;
                    }
                    const char_w = measureTextWidth("W", 16.0);
                    const line_h: f32 = 24.0;
                    if (term.handleMouseDown(x, y, char_w, line_h, term.terminal_content_x, term.terminal_content_y)) return;
                }
                return;
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    if (button == .mouse_right) {
                        v.showContextMenu(x, y);
                        return;
                    }
                    _ = v.handleMouseDown(x, y);
                }
                return;
            } else if (tab.kind == .chat) {
                self.ai_chat.handleMouseDown(x, y, button);
                return;
            } else if (tab.kind == .textarea) {
                if (self.getActiveTextArea()) |textarea| {
                    if (button == .mouse_right) {
                        textarea.show_context_menu = true;
                        textarea.context_menu_x = x;
                        textarea.context_menu_y = y;
                        return;
                    }
                    textarea.handleMouseDown(x, y, button);
                    return;
                }
            }
        }

        // Nur an Editor weitergeben wenn Klick innerhalb der code_editor-BBox
        // oder wenn Menü offen ist (damit Klicks auf das Menü ankommen)
        const editor_id = clay.ElementId.IDI("code_editor", @truncate(@intFromPtr(editor)));
        const editor_data = clay.getElementData(editor_id);
        if (editor_data.found) {
            const bb = editor_data.bounding_box;
            if (editor.show_context_menu or (x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height)) {
                editor.handleMouseDown(x, y, button);
            }
        }
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;

        if (self.show_file_explorer) {
            self.file_explorer.handleMouseMove(x, y);
        }

        if (self.getActiveTabBar().getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.getActiveTabBar().terminal_instances.get(tab.path)) |term| {
                    const char_w = measureTextWidth("W", 16.0);
                    const line_h: f32 = 24.0;
                    term.handleMouseMove(x, y, char_w, line_h, term.terminal_content_x, term.terminal_content_y);
                }
                return;
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    v.handleScrollbarMouseMove(x, y);
                }
                return;
            } else if (tab.kind == .chat) {
                self.ai_chat.handleMouseMove(x, y);
                return;
            } else if (tab.kind == .textarea) {
                if (self.getActiveTextArea()) |textarea| {
                    textarea.handleMouseMove(x, y);
                }
                return;
            }
        }
        self.getActiveEditor().handleMouseMove(x, y);
        self.getActiveEditor().desired_cursor = if (self.getActiveEditor().last_frame_hovered) .text else .arrow;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.is_mouse_down = false;

        if (self.show_file_explorer) {
            self.file_explorer.handleMouseUp();
        }

        if (self.getActiveTabBar().getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.getActiveTabBar().terminal_instances.get(tab.path)) |term| {
                    term.handleMouseUp();
                }
                // No return here, might want to clear other states too
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    v.handleMouseUp();
                }
                return;
            } else if (tab.kind == .chat) {
                self.ai_chat.handleMouseUp();
                return;
            } else if (tab.kind == .textarea) {
                if (self.getActiveTextArea()) |textarea| {
                    textarea.handleMouseUp();
                }
                return;
            }
        }
        self.getActiveEditor().handleMouseUp();
    }

    /// Scroll-Events an Editor oder Terminal weiterleiten
    pub fn handleScroll(self: *Self, delta: i32) void {
        if (self.show_file_explorer and clay.pointerOver(clay.ElementId.ID("file_explorer"))) {
            self.file_explorer.scrollLines(delta);
            return;
        }

        if (self.getActiveTabBar().getActiveTab()) |tab| {
            if (tab.kind == .chat) {
                self.ai_chat.scrollLines(delta);
                return;
            }
            if (tab.kind == .textarea) {
                if (self.getActiveTextArea()) |textarea| {
                    textarea.scrollLines(delta);
                }
                return;
            }
            if (tab.kind == .terminal) {
                if (self.getActiveTabBar().terminal_instances.get(tab.path)) |term| {
                    term.scrollLines(delta);
                }
                return;
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    v.scrollLines(delta);
                }
                return;
            }
        }
        self.getActiveEditor().scrollLines(delta);
    }

    /// UI updaten (pro Frame)
    pub fn update(self: *Self, delta_ms: f32) void {
        self.anim_manager.update(delta_ms);
        self.getActiveEditor().time_ms += delta_ms;
        self.ai_chat.updateTimeMs(delta_ms);
    }

    /// Layout beginnen
    pub fn beginLayout(self: *Self) void {
        _ = self.frame_arena.reset(.retain_capacity);
        clay.beginLayout();
        if (self.mouse_pressed_this_frame) {
            const hovered = clay.getPointerOverIds();
            log.debug("beginLayout click: mouse=({d:.0},{d:.0}) hovered_count={d}", .{ self.mouse_x, self.mouse_y, hovered.len });
        }
    }

    /// Layout beenden und Render Commands holen
    pub fn endLayout(self: *Self) []clay.RenderCommand {
        const commands = clay.endLayout();
        self.mouse_pressed_this_frame = false;
        return commands;
    }

    /// Window Resize behandeln
    pub fn resize(self: *Self, width: u32, height: u32) void {
        clay.setLayoutDimensions(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) });
        // Editor-Höhe aktualisieren für korrekte visibleLineCount-Berechnung
        self.getActiveEditor().height = @floatFromInt(height);
    }

    /// Maus-Position und Button-Status an Clay weiterleiten
    pub fn setPointerState(self: *Self, x: f32, y: f32, is_down: bool) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.is_mouse_down = is_down;
        if (is_down) log.debug("setPointerState click: ({d:.0}, {d:.0})", .{ x, y });
        clay.setPointerState(.{ .x = x, .y = y }, is_down);
    }

    /// Scroll-Events an Clay weiterleiten
    pub fn updateScroll(self: *Self, delta_x: f32, delta_y: f32, delta_time_ms: f32) void {
        _ = self;
        // Clay erwartet Scroll-Delta als Vector2 und delta_time in Sekunden
        clay.updateScrollContainers(false, .{ .x = delta_x, .y = delta_y }, delta_time_ms / 1000.0);
    }

    pub fn getOrCreateTexture(self: *Self, path: []const u8) ?*anyopaque {
        if (self.open_images.get(path)) |tex| return tex;
        const ir = self.image_renderer orelse return null;
        const tex = ir.createTextureFromPath(self.allocator, path) catch return null;
        const tex_ptr = self.allocator.create(@import("../clay_renderer/image_renderer.zig").ImageTexture) catch return null;
        tex_ptr.* = tex;
        const path_copy = self.allocator.dupe(u8, path) catch path;
        self.open_images.put(path_copy, tex_ptr) catch {};
        wio.cancelWait();
        return tex_ptr;
    }

    /// UI Beispiel rendern
    pub fn renderExample(self: *Self, image_data: ?*const anyopaque) []clay.RenderCommand {
        self.beginLayout();

        const t = self.theme;

        // Root Container
        clay.UI()(.{
            .id = clay.ElementId.ID("Root"),
            .layout = .{
                .sizing = .grow,
                .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
                .child_gap = 0,
                .direction = .top_to_bottom,
            },
            .background_color = t.bg,
        })({
            // Header mit Logo und Titel
            clay.UI()(.{
                .id = clay.ElementId.ID("Header"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(56) },
                    .child_gap = 16,
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 16, .right = 16 },
                },
                .background_color = t.surface,
                .border = .{ .width = .{ .bottom = 1 }, .color = t.border },
            })({
                // Logo Image (falls vorhanden)
                if (image_data) |ptr| {
                    clay.UI()(.{
                        .id = clay.ElementId.ID("Logo"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(32), .h = .fixed(32) },
                        },
                        .image = .{ .image_data = ptr },
                        .background_color = .{ 0, 0, 0, 0 },
                    })({});
                }

                clay.text("VULKAN-ED", .{ .font_size = 24, .color = t.text });
            });

            // Status Bar (Git Branch + Info)
            clay.UI()(.{
                .id = clay.ElementId.ID("StatusBar"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(28) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 12, .right = 12 },
                    .child_gap = 16,
                },
                .background_color = t.overlay,
                .border = .{ .width = .{ .top = 1 }, .color = t.border },
            })({
                const svg = @import("components/svg.zig");
                const arena = self.frame_arena.allocator();
                svg.Svg(arena, "status_git_icon", svg.Lucide.git_branch, 18, t.success);
                const branch_text = if (self.git_branch.len > 0) self.git_branch else "—";
                clay.text(branch_text, .{ .font_size = 18, .color = t.subtext });
            });

            // Main Content Area (Sidebar + Editor)
            clay.UI()(.{
                .id = clay.ElementId.ID("MainContent"),
                .layout = .{
                    .sizing = .grow,
                    .direction = .left_to_right,
                    .child_gap = 0,
                },
                .background_color = t.bg,
            })({
                // Phase 15: Splitter Logic
                const splitter_id = clay.ElementId.ID("ExplorerSplitter");
                if (self.show_file_explorer) {
                    if (self.file_explorer.is_resizing) {
                        if (!self.is_mouse_down) {
                            self.file_explorer.is_resizing = false;
                        } else {
                            self.file_explorer.width = self.mouse_x;
                            if (self.file_explorer.width < 100) self.file_explorer.width = 100;
                            if (self.file_explorer.width > 600) self.file_explorer.width = 600;
                        }
                    } else if (clay.pointerOver(splitter_id) and self.mouse_pressed_this_frame) {
                        self.file_explorer.is_resizing = true;
                    }
                }

                // File Explorer Sidebar
                if (self.show_file_explorer) {
                    file_explorer_mod.renderFileExplorer(
                        self.frame_arena.allocator(),
                        &self.file_explorer,
                        t,
                        self.mouse_pressed_this_frame,
                    );
                    // Deferred Toggle ausführen (nach Rendering, vor endLayout)
                    self.file_explorer.processPendingToggle();

                    // Splitter
                    clay.UI()(.{
                        .id = splitter_id,
                        .layout = .{
                            .sizing = .{ .w = .fixed(4), .h = .grow },
                        },
                        .background_color = if (self.file_explorer.is_resizing) t.primary else if (clay.pointerOver(splitter_id)) t.secondary else t.border,
                    })({});
                }

                // Recursive Pane Rendering
                self.renderPane(self.root_pane, t);

            });
        });

        // Dialog INSIDE Clay layout (floating, z_index=2000 → overlays everything)
        // Must be here so Clay can register element bounds and mouse_pressed_this_frame is still true
        var pending_dialog_result: ?dialog_mod.DialogResult = null;
        if (self.active_dialog) |*ad| {
            pending_dialog_result = ad.dialog.render(t, self.mouse_pressed_this_frame);
        }

        const commands = self.endLayout();

        // Process deferred dialog result (after layout so no use-after-free)
        if (pending_dialog_result) |res| {
            if (self.active_dialog) |*ad| {
                ad.callback(self, res, ad.context_usize, ad.context_ptr);
                if (ad.message_needs_free) {
                    self.allocator.free(ad.dialog.message);
                }
                self.active_dialog = null;
            }
        }

        // Handle global split requests
        if (self.pending_split) |dir| {
            self.splitActivePane(dir) catch |err| {
                log.err("Failed to split pane: {}", .{err});
            };
            self.pending_split = null;
        }

        // Process deferred tab closes
        while (self.pending_tab_closes.pop()) |req| {
            log.debug("pending_tab_closes: processing close for pane={*} index={d}", .{ req.pane, req.index });
            // Verify pane is still valid and has tabs
            switch (req.pane.data) {
                .leaf => |*leaf| {
                    log.debug("pending_tab_closes: leaf has {d} tabs, closing index={d}", .{ leaf.tab_bar.tabs.items.len, req.index });
                    if (req.index < leaf.tab_bar.tabs.items.len) {
                        leaf.tab_bar.closeTab(req.index);
                        // Don't call cancelWait here - causes recursive render with destroyed pane!
                    } else {
                        log.warn("pending_tab_closes: index {d} out of range (len={d}), skipping", .{ req.index, leaf.tab_bar.tabs.items.len });
                    }
                },
                else => {
                    log.warn("pending_tab_closes: pane is not a leaf, skipping", .{});
                },
            }
        }

        // Cleanup empty panes (close split if a pane becomes empty)
        _ = self.cleanupEmptyPanes(null, self.root_pane);

        return commands;
    }

    fn cleanupEmptyPanes(self: *Self, parent: ?*pane_mod.Pane, pane: *pane_mod.Pane) bool {
        switch (pane.data) {
            .leaf => |*leaf| {
                if (leaf.tab_bar.tabs.items.len == 0) {
                    if (parent) |p| {
                        log.debug("cleanupEmptyPanes: found empty leaf, collapsing split. Parent: {*}, Leaf: {*}", .{ p, pane });
                        // Find other child
                        const split = &p.data.split;
                        const other_idx: usize = if (split.children[0] == pane) 1 else 0;
                        const other_child = split.children[other_idx];

                        // Keep other child's data
                        const other_data = other_child.data;
                        const other_allocator = other_child.allocator;

                        // Focus redirection: If either the closed pane or the parent was active, 
                        // redirection focus to the parent (which now becomes the sibling).
                        if (self.active_pane == pane or self.active_pane == p or self.active_pane == other_child) {
                            self.active_pane = p;
                        }

                        // Destroy current empty pane and the other child's wrapper
                        pane.deinit();
                        p.data = other_data;
                        other_allocator.destroy(other_child);

                        return true;
                    }
                }
            },
            .split => |*split| {
                if (self.cleanupEmptyPanes(pane, split.children[0])) return true;
                if (self.cleanupEmptyPanes(pane, split.children[1])) return true;
            },
        }
        return false;
    }

    fn renderPane(self: *Self, pane: *pane_mod.Pane, t: Theme) void {
        const allocator = self.frame_arena.allocator();
        switch (pane.data) {
            .leaf => |*leaf| {
                const pane_id = clay.ElementId.IDI("Pane", @truncate(@intFromPtr(pane)));

                // Editor Area (Tabs + Editor)
                clay.UI()(.{
                    .id = pane_id,
                    .layout = .{
                        .sizing = .grow,
                        .direction = .top_to_bottom,
                        .child_gap = 0,
                    },
                    .background_color = t.bg,
                })({
                    // Focus handling
                    if (clay.pointerOver(pane_id) and self.mouse_pressed_this_frame) {
                        self.active_pane = pane;
                    }

                    const is_active = (self.active_pane == pane);

                    // Tab-Leiste
                    if (tab_bar_mod.renderTabBar(
                        allocator,
                        &leaf.tab_bar,
                        t,
                        self.mouse_pressed_this_frame,
                        self.mouse_x,
                        self.mouse_y,
                    )) |req| {
                        if (req.close) {
                            log.debug("renderPane: tab close requested for index {d}", .{req.index});
                            const tab = &leaf.tab_bar.tabs.items[req.index];
                            if (tab.modified) {
                                self.showSaveConfirmationDialog(pane, req.index);
                            } else {
                                // Defer the closure to after the layout cycle
                                self.pending_tab_closes.append(self.allocator, .{ .pane = pane, .index = req.index }) catch {};
                            }
                        } else if (req.do_switch) {
                            leaf.tab_bar.setActive(req.index);
                        }
                    }

                    if (leaf.code_editor.pending_md_preview) {
                        leaf.code_editor.pending_md_preview = false;
                        const path = leaf.code_editor.buffer.get_file_path();
                        if (path.len > 0) {
                            const preview_path = self.allocator.alloc(u8, path.len + 10) catch path;
                            const final_path = std.fmt.bufPrint(@constCast(preview_path), "preview://{s}", .{path}) catch path;
                            self.pending_tab_switch = final_path;
                        }
                    }

                    // Aktiven Tab prüfen
                    var special_active = false;
                    const tab_bar = &leaf.tab_bar;
                    if (tab_bar.active_index) |idx| {
                        if (idx < tab_bar.tabs.items.len) {
                            const tab = &tab_bar.tabs.items[idx];
                            if (tab.kind == .image) {
                                image_view_mod.ImageViewState.render(allocator, tab.path, t, &self.open_images);
                                special_active = true;
                            } else if (tab.kind == .pdf) {
                                 const maybe_handler = self.open_pdfs.get(tab.path);
                                 const maybe_texture = self.open_images.get(tab.path);
                                 if (maybe_handler) |handler_ptr| {
                                     const handler: *PdfHandler = @ptrCast(@alignCast(handler_ptr));
                                     if (PdfViewState.render(handler, maybe_texture, t, self.mouse_pressed_this_frame)) |delta| {
                                         self.pending_pdf_page_change = .{ .path = tab.path, .delta = delta };
                                     }
                                 }
                                 special_active = true;
                            } else if (tab.kind == .terminal) {
                                self.renderTerminalContentInPane(pane, tab.path, t);
                                special_active = true;
                            } else if (tab.kind == .chat) {
                                ai_chat_mod.renderAIChat(
                                    allocator,
                                    &self.ai_chat,
                                    t,
                                    self.mouse_pressed_this_frame,
                                    self.window,
                                );
                                special_active = true;
                            } else if (tab.kind == .textarea) {
                                if (leaf.tab_bar.textarea_instances.get(tab.path)) |textarea| {
                                    textarea.setWindow(self.window);
                                    textarea.render(allocator, self.mouse_pressed_this_frame);
                                    special_active = true;
                                }
                            } else if (tab.kind == .markdown_preview) {
                                var md_view = self.open_markdown_views.get(tab.path);
                                if (md_view == null) {
                                    const source_path = tab.path["preview://".len..];
                                    const content = std.fs.cwd().readFileAlloc(self.allocator, source_path, 1024 * 1024) catch |err| blk: {
                                        std.log.err("Failed to load markdown: {any}", .{err});
                                        break :blk self.allocator.dupe(u8, "# Error") catch "# Error";
                                    };
                                    defer self.allocator.free(content);
                                    const new_v = self.allocator.create(markdown_view_mod.MarkdownView) catch unreachable;
                                    new_v.* = markdown_view_mod.MarkdownView.init(self.allocator, content, source_path);
                                    self.open_markdown_views.put(self.allocator.dupe(u8, tab.path) catch tab.path, new_v) catch {};
                                    md_view = new_v;
                                }
                                if (md_view) |v| {
                                    v.window = self.window;
                                    v.render(allocator, t, self);
                                    if (v.pending_split_v) {
                                        v.pending_split_v = false;
                                        self.pending_split = .vertical;
                                    }
                                    if (v.pending_split_h) {
                                        v.pending_split_h = false;
                                        self.pending_split = .horizontal;
                                    }
                                    special_active = true;
                                }
                            }
                        }
                    }

                    if (!special_active and tab_bar.tabs.items.len > 0) {
                        if (tab_bar.getActiveTab()) |tab| {
                            if (tab.kind == .text) {
                                tab.modified = leaf.code_editor.is_modified;
                            }
                        }
                        leaf.code_editor.render(allocator, self.mouse_pressed_this_frame);
                    }

                    if (leaf.code_editor.pending_split_v) {
                        leaf.code_editor.pending_split_v = false;
                        self.pending_split = .vertical;
                    }
                    if (leaf.code_editor.pending_split_h) {
                        leaf.code_editor.pending_split_h = false;
                        self.pending_split = .horizontal;
                    }

                    if (is_active) {
                        clay.UI()(.{
                            .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top } },
                            .layout = .{ .sizing = .grow },
                            .border = .{ .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 }, .color = t.primary },
                        })({});
                    }
                });

                // Update bounds
                const editor_id = clay.ElementId.IDI("code_editor", @truncate(@intFromPtr(leaf.code_editor)));
                const editor_data = clay.getElementData(editor_id);
                if (editor_data.found) {
                    leaf.code_editor.content_origin_y = editor_data.bounding_box.y;
                    leaf.code_editor.content_origin_x = editor_data.bounding_box.x;
                    leaf.code_editor.height = editor_data.bounding_box.height;
                    leaf.code_editor.scrollbar_container_width = editor_data.bounding_box.width;
                    // Store bounds for cursor detection
                    leaf.code_editor.editor_bounds_x = editor_data.bounding_box.x;
                    leaf.code_editor.editor_bounds_y = editor_data.bounding_box.y;
                    leaf.code_editor.editor_bounds_width = editor_data.bounding_box.width;
                    leaf.code_editor.editor_bounds_height = editor_data.bounding_box.height;
                    leaf.code_editor.editor_bounds_valid = true;
                }
            },
            .split => |*split| {
                const direction = if (split.direction == .horizontal) clay.LayoutDirection.left_to_right else clay.LayoutDirection.top_to_bottom;
                clay.UI()(.{
                    .id = clay.ElementId.IDI("Split", @truncate(@intFromPtr(pane))),
                    .layout = .{ .sizing = .grow, .direction = direction },
                })({
                    clay.UI()(.{
                        .layout = .{
                            .sizing = if (split.direction == .horizontal)
                                .{ .w = .percent(split.ratio), .h = .grow }
                                else .{ .w = .grow, .h = .percent(split.ratio) },
                        },
                    })({
                        self.renderPane(split.children[0], t);
                    });

                    const splitter_id = clay.ElementId.IDI("Splitter", @truncate(@intFromPtr(pane)));
                    clay.UI()(.{
                        .id = splitter_id,
                        .layout = .{
                            .sizing = if (split.direction == .horizontal)
                                .{ .w = .fixed(4), .h = .grow }
                                else .{ .w = .grow, .h = .fixed(4) },
                        },
                        .background_color = if (split.is_resizing) t.primary else if (clay.pointerOver(splitter_id)) t.secondary else t.border,
                    })({});

                    clay.UI()(.{ .layout = .{ .sizing = .grow } })({
                        self.renderPane(split.children[1], t);
                    });

                    if (clay.pointerOver(splitter_id) and self.mouse_pressed_this_frame) split.is_resizing = true;
                    if (split.is_resizing) {
                        if (!self.is_mouse_down) {
                            split.is_resizing = false;
                        } else {
                            const data = clay.getElementData(clay.ElementId.IDI("Split", @truncate(@intFromPtr(pane))));
                            if (data.found) {
                                if (split.direction == .horizontal) {
                                    split.ratio = (self.mouse_x - data.bounding_box.x) / data.bounding_box.width;
                                } else {
                                    split.ratio = (self.mouse_y - data.bounding_box.y) / data.bounding_box.height;
                                }
                                split.ratio = std.math.clamp(split.ratio, 0.05, 0.95);
                            }
                        }
                    }
                });
            },
        }
    }

    /// Berechnet den gewünschten Cursor für diesen Frame
    pub fn getDesiredCursor(self: *Self) wio.Cursor {
        if (self.file_explorer.is_resizing or clay.pointerOver(clay.ElementId.ID("ExplorerSplitter"))) {
            return .size_ew;
        }

        // Chat-Input → I-Beam (Bounds-Check wie Editor, nicht clay.pointerOver)
        if (self.isChatTabActive() and self.ai_chat.input_bounds_valid) {
            const c = &self.ai_chat;
            if (self.mouse_x >= c.input_bounds_x and self.mouse_x < c.input_bounds_x + c.input_bounds_w and
                self.mouse_y >= c.input_bounds_y and self.mouse_y < c.input_bounds_y + c.input_bounds_h)
            {
                return c.input_editor.desired_cursor;
            }
        }

        // Mit Mausposition + Bounds prüfen ob wir über einem Editor sind
        if (self.isMouseOverEditor()) {
            return .text;
        }

        return .arrow;
    }

    fn isMouseOverEditor(self: *Self) bool {
        return self.checkEditorBounds(self.root_pane);
    }

    fn checkEditorBounds(self: *Self, pane: *pane_mod.Pane) bool {
        switch (pane.data) {
            .leaf => |*leaf| {
                if (leaf.code_editor.editor_bounds_valid) {
                    const bx = leaf.code_editor.editor_bounds_x;
                    const by = leaf.code_editor.editor_bounds_y;
                    const bw = leaf.code_editor.editor_bounds_width;
                    const bh = leaf.code_editor.editor_bounds_height;
                    if (self.mouse_x >= bx and self.mouse_x < bx + bw and
                        self.mouse_y >= by and self.mouse_y < by + bh) {
                        // Über Editor, aber Scrollbalken ausschließen
                        if (leaf.code_editor.isMouseOverScrollbar(self.mouse_x, self.mouse_y)) {
                            return false;
                        }
                        return true;
                    }
                }
            },
            .split => |*split| {
                if (self.checkEditorBounds(split.children[0])) return true;
                if (self.checkEditorBounds(split.children[1])) return true;
            },
        }
        return false;
    }

    pub fn getOrCreateBuffer(self: *Self, path: []const u8) !*@import("flow_core").Buffer {
        if (self.open_buffers.get(path)) |buf| return buf;

        // Try to load existing file
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024 * 1024) catch |not_found| {
            if (not_found == error.FileNotFound) {
                // New file - create empty buffer with initialized root
                const new_buf = try @import("flow_core").Buffer.create(self.allocator);
                new_buf.root = try new_buf.load_from_string("", &new_buf.file_eol_mode, &new_buf.file_utf8_sanitized);
                new_buf.set_file_path(path);
                new_buf.last_save = new_buf.root;
                try self.open_buffers.put(try self.allocator.dupe(u8, path), new_buf);
                return new_buf;
            }
            return not_found;
        };
        defer self.allocator.free(content);
        const new_buf = try @import("flow_core").Buffer.create(self.allocator);
        new_buf.root = try new_buf.load_from_string(content, &new_buf.file_eol_mode, &new_buf.file_utf8_sanitized);
        new_buf.set_file_path(path);
        new_buf.last_save = new_buf.root;
        try self.open_buffers.put(try self.allocator.dupe(u8, path), new_buf);
        return new_buf;
    }

    pub fn isTerminalActive(self: *Self) bool {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) return tab_bar.tabs.items[idx].kind == .terminal;
        }
        return false;
    }

    pub fn getActiveEditor(self: *Self) *editor_mod.CodeEditor {
        var p = self.active_pane;
        while (p.data == .split) {
            p = p.data.split.children[0];
        }
        return p.data.leaf.code_editor;
    }

    pub fn getActiveTabBar(self: *Self) *tab_bar_mod.TabBarState {
        var p = self.active_pane;
        while (p.data == .split) {
            p = p.data.split.children[0];
        }
        return &p.data.leaf.tab_bar;
    }

    pub fn splitActivePane(self: *Self, direction: pane_mod.PaneDirection) !void {
        const pane = self.active_pane;
        if (pane.data != .leaf) return;

        // 1. Get current state
        const current_leaf = pane.data.leaf;
        const current_buffer = current_leaf.code_editor.buffer;

        // 2. Create TWO brand new independent leaves
        const old_content_leaf = try pane_mod.Pane.createLeaf(self.allocator, current_buffer);
        const new_split_leaf = try pane_mod.Pane.createLeaf(self.allocator, current_buffer);

        // 3. Deep-copy tab state (dupes strings)
        try old_content_leaf.data.leaf.tab_bar.cloneFrom(&current_leaf.tab_bar);
        try new_split_leaf.data.leaf.tab_bar.cloneFrom(&current_leaf.tab_bar);

        // 4. CLEANUP ORIGINAL DATA before overwriting
        // Copy the old data so we can deinit it safely after replacing the union branch
        var old_editor = current_leaf.code_editor;
        var old_tab_bar = current_leaf.tab_bar;

        // 5. Transform original pane into a split node
        pane.data = .{ .split = .{ 
            .direction = direction, 
            .ratio = 0.5, 
            .children = .{ old_content_leaf, new_split_leaf } 
        } };

        // 6. Now it's safe to deinit old resources
        old_editor.deinit();
        self.allocator.destroy(old_editor);
        old_tab_bar.deinit();

        // 7. Update focus
        self.active_pane = new_split_leaf;
        
        wio.cancelWait();
    }

    fn showSaveConfirmationDialog(self: *Self, pane: *pane_mod.Pane, tab_index: usize) void {
        const tab = &pane.data.leaf.tab_bar.tabs.items[tab_index];
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Do you want to save changes to '{s}'?", .{tab.display_name}) catch "Save?";
        
        const duped_msg = self.allocator.dupe(u8, msg) catch msg;
        const needs_free = (duped_msg.ptr != msg.ptr);

        self.active_dialog = .{
            .dialog = .{
                .title = "Unsaved Changes",
                .message = duped_msg,
                .actions = &.{
                    .{ .label = "Save", .result = .yes },
                    .{ .label = "Don't Save", .result = .no },
                    .{ .label = "Cancel", .result = .cancel },
                },
            },
            .context_usize = tab_index,
            .context_ptr = pane,
            .callback = handleSaveConfirmation,
            .message_needs_free = needs_free,
        };
    }

    fn handleSaveConfirmation(ui: *UI, res: dialog_mod.DialogResult, idx: usize, ptr: ?*anyopaque) void {
        const p: *pane_mod.Pane = @ptrCast(@alignCast(ptr.?));
        const leaf = &p.data.leaf;
        switch (res) {
            .yes => {
                leaf.code_editor.save() catch |err| {
                    log.err("Failed to save during close: {}", .{err});
                };
                ui.pending_tab_closes.append(ui.allocator, .{ .pane = p, .index = idx }) catch {};
            },
            .no => {
                ui.pending_tab_closes.append(ui.allocator, .{ .pane = p, .index = idx }) catch {};
            },
            .cancel => {},
        }
    }

    /// Branch-Name aus git_branch TaskResult übernehmen
    pub fn updateBranch(self: *Self, payload: []const u8) void {
        if (self.git_branch.len > 0) self.allocator.free(self.git_branch);
        self.git_branch = self.allocator.dupe(u8, payload) catch "";
    }

    /// Git-Status aus git_status TaskResult an den File Explorer weitergeben
    pub fn updateGitStatus(self: *Self, payload: []const u8) void {
        const repo_root = self.current_directory orelse return;
        self.file_explorer.updateGitStatus(payload, repo_root);
    }

    pub fn getActiveTerminal(self: *Self) ?*@import("../terminal/terminal_instance.zig").TerminalInstance {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) {
                const tab = tab_bar.tabs.items[idx];
                if (tab.kind == .terminal) return tab_bar.terminal_instances.get(tab.path);
            }
        }
        return null;
    }

    pub fn isChatTabActive(self: *Self) bool {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) {
                return tab_bar.tabs.items[idx].kind == .chat;
            }
        }
        return false;
    }

    pub fn isTextAreaTabActive(self: *Self) bool {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) {
                return tab_bar.tabs.items[idx].kind == .textarea;
            }
        }
        return false;
    }

    fn getActiveTextArea(self: *Self) ?*TextAreaState {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) {
                const tab = tab_bar.tabs.items[idx];
                if (tab.kind == .textarea) {
                    return tab_bar.textarea_instances.get(tab.path);
                }
            }
        }
        return null;
    }

    fn renderTerminalContentInPane(self: *Self, pane: *pane_mod.Pane, path: []const u8, t: Theme) void {
        _ = t;
        const leaf = &pane.data.leaf;
        const term_instance = leaf.tab_bar.terminal_instances.get(path) orelse return;
        term_instance.window = self.window;
        const arena_alloc = self.frame_arena.allocator();
        const cursor = term_instance.getCursor();
        const total_rows = term_instance.*.totalRows();
        const line_height: f32 = 24.0; 
        const clip_id = clay.ElementId.IDI("terminal_content_clip", @truncate(@intFromPtr(pane)));
        const term_data = clay.getElementData(clip_id);
        if (term_data.found) {
            const bb = term_data.bounding_box;
            term_instance.height = bb.height;
            term_instance.terminal_content_x = bb.x;
            term_instance.terminal_content_y = bb.y;
            const char_w = measureTextWidth("W", 16.0);
            if (char_w > 0) {
                const cols: u16 = @intFromFloat(bb.width / char_w);
                const rows: u16 = @intFromFloat(bb.height / line_height);
                if (cols != term_instance.cols or rows != term_instance.rows) {
                    if (cols > 0 and rows > 0) term_instance.resize(cols, rows) catch {};
                }
            }
        }
        const visible_rows = term_instance.visibleLineCount();
        const history_count = if (total_rows > term_instance.rows) total_rows - term_instance.rows else 0;
        const cursor_abs_row = history_count + cursor.y;
        clay.UI()(.{
            .id = clay.ElementId.IDI("terminal_outer", @truncate(@intFromPtr(pane))),
            .layout = .{ .sizing = .grow, .direction = .left_to_right, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } },
            .background_color = .{ 30, 30, 30, 255 },
        })({
            clay.UI()(.{ .id = clip_id, .layout = .{ .sizing = .grow }, .clip = .{ .vertical = true, .horizontal = true } })({
                clay.UI()(.{ .id = clay.ElementId.IDI("terminal_content", @truncate(@intFromPtr(pane))), .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom } })({
                    const start_line = @min(term_instance.view_row, total_rows);
                    const end_line = @min(start_line + visible_rows + 1, total_rows);
                    var i: usize = start_line;
                    while (i < end_line) : (i += 1) {
                        const line_text = term_instance.getLine(i, arena_alloc) catch "";
                        clay.UI()(.{ .id = clay.ElementId.IDI("term_row", @truncate(i ^ @intFromPtr(pane))), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(line_height) }, .direction = .left_to_right, .child_alignment = .{ .x = .left, .y = .center } } })({
                            var pos: usize = 0;
                            var current_fg: clay.Color = .{ 204, 204, 204, 255 };
                            var current_bg: ?clay.Color = null;
                            var text_start: usize = 0;
                            const default_fg: clay.Color = .{ 204, 204, 204, 255 };
                            while (pos < line_text.len) {
                                if (line_text[pos] == '\x1B' and pos + 1 < line_text.len and line_text[pos + 1] == '[') {
                                    if (pos > text_start) {
                                        const seg = line_text[text_start..pos];
                                        if (current_bg) |bg| { clay.UI()(.{ .background_color = bg })({ clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg }); }); } else { clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg }); }
                                    }
                                    pos += 2;
                                    var args: [16]u8 = undefined;
                                    var arg_count: usize = 0;
                                    var num: u8 = 0;
                                    var has_num = false;
                                    while (pos < line_text.len) {
                                        const c = line_text[pos];
                                        if (c >= '0' and c <= '9') { num = num * 10 + (c - '0'); has_num = true; pos += 1; } else if (c == ';') { if (arg_count < args.len) { args[arg_count] = num; arg_count += 1; } num = 0; has_num = false; pos += 1; } else if (c == 'm') { if (has_num and arg_count < args.len) { args[arg_count] = num; arg_count += 1; } pos += 1; break; } else { pos += 1; break; }
                                    }
                                    var arg_idx: usize = 0;
                                    if (arg_count == 0) { current_fg = default_fg; current_bg = null; }
                                    while (arg_idx < arg_count) {
                                        const code = args[arg_idx];
                                        arg_idx += 1;
                                        switch (code) {
                                            0 => { current_fg = default_fg; current_bg = null; },
                                            30...37 => { current_fg = switch (code - 30) { 0 => .{ 0, 0, 0, 255 }, 1 => .{ 205, 49, 49, 255 }, 2 => .{ 13, 188, 121, 255 }, 3 => .{ 229, 229, 16, 255 }, 4 => .{ 36, 114, 200, 255 }, 5 => .{ 188, 63, 188, 255 }, 6 => .{ 17, 168, 205, 255 }, 7 => .{ 229, 229, 229, 255 }, else => default_fg }; },
                                            38 => { if (arg_idx + 1 < arg_count and args[arg_idx] == 5) { arg_idx += 2; } else if (arg_idx + 3 < arg_count and args[arg_idx] == 2) { current_fg = .{ @floatFromInt(args[arg_idx + 1]), @floatFromInt(args[arg_idx + 2]), @floatFromInt(args[arg_idx + 3]), 255 }; arg_idx += 4; } },
                                            39 => current_fg = default_fg,
                                            40...47 => { current_bg = switch (code - 40) { 0 => .{ 0, 0, 0, 255 }, 1 => .{ 205, 49, 49, 255 }, 2 => .{ 13, 188, 121, 255 }, 3 => .{ 229, 229, 16, 255 }, 4 => .{ 36, 114, 200, 255 }, 5 => .{ 188, 63, 188, 255 }, 6 => .{ 17, 168, 205, 255 }, 7 => .{ 229, 229, 229, 255 }, else => null }; },
                                            48 => { if (arg_idx + 1 < arg_count and args[arg_idx] == 5) { arg_idx += 2; } else if (arg_idx + 3 < arg_count and args[arg_idx] == 2) { current_bg = .{ @floatFromInt(args[arg_idx + 1]), @floatFromInt(args[arg_idx + 2]), @floatFromInt(args[arg_idx + 3]), 255 }; arg_idx += 4; } },
                                            49 => current_bg = null,
                                            90...97 => { current_fg = switch (code - 90) { 0 => .{ 102, 102, 102, 255 }, 1 => .{ 241, 76, 76, 255 }, 2 => .{ 35, 209, 139, 255 }, 3 => .{ 245, 245, 67, 255 }, 4 => .{ 59, 142, 234, 255 }, 5 => .{ 214, 112, 214, 255 }, 6 => .{ 41, 184, 219, 255 }, 7 => .{ 255, 255, 255, 255 }, else => default_fg }; },
                                            else => {},
                                        }
                                    }
                                    text_start = pos;
                                } else pos += 1;
                            }
                            if (pos > text_start) {
                                const seg = line_text[text_start..pos];
                                if (current_bg) |bg| { clay.UI()(.{ .background_color = bg })({ clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg }); }); } else { clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg }); }
                            }
                            if (i == cursor_abs_row) {
                                const char_w = measureTextWidth("W", 16.0);
                                const exact_x = @as(f32, @floatFromInt(cursor.x)) * char_w;
                                clay.UI()(.{ .id = clay.ElementId.IDI("terminal_cursor", @truncate(@intFromPtr(pane))), .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = exact_x, .y = 0 } }, .layout = .{ .sizing = .{ .w = .fixed(char_w), .h = .fixed(line_height) } }, .background_color = .{ 200, 200, 200, 180 } })({});
                            }
                            {
                                var col: u16 = 0;
                                var selection_start_col: ?u16 = null;
                                const char_w = measureTextWidth("W", 16.0);
                                while (col < term_instance.cols) {
                                    if (term_instance.isSelected(col, i)) { if (selection_start_col == null) selection_start_col = col; } else {
                                        if (selection_start_col) |start| {
                                            const width = @as(f32, @floatFromInt(col - start)) * char_w;
                                            clay.UI()(.{ .id = clay.ElementId.IDI("term_sel", @truncate(i * 1000 + start ^ @intFromPtr(pane))), .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = @as(f32, @floatFromInt(start)) * char_w, .y = 0 } }, .layout = .{ .sizing = .{ .w = .fixed(width), .h = .fixed(line_height) } }, .background_color = .{ 100, 100, 255, 60 } })({});
                                            selection_start_col = null;
                                        }
                                    }
                                    col += 1;
                                }
                                if (selection_start_col) |start| {
                                    const width = @as(f32, @floatFromInt(col - start)) * char_w;
                                    clay.UI()(.{ .id = clay.ElementId.IDI("term_sel", @truncate(i * 1000 + start ^ @intFromPtr(pane))), .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = @as(f32, @floatFromInt(start)) * char_w, .y = 0 } }, .layout = .{ .sizing = .{ .w = .fixed(width), .h = .fixed(line_height) } }, .background_color = .{ 100, 100, 255, 60 } })({});
                                }
                            }
                        });
                    }
                });
            });
            if (total_rows > visible_rows) {
                const track_id = clay.ElementId.IDI("terminal_scrollbar_track", @truncate(@intFromPtr(pane)));
                const track_data = clay.getElementData(track_id);
                if (track_data.found) { term_instance.scrollbar_track_x = track_data.bounding_box.x; term_instance.scrollbar_track_y = track_data.bounding_box.y; }
                const track_height = term_instance.height;
                const thumb_ratio: f32 = @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows));
                const thumb_height = @max(20.0, track_height * thumb_ratio);
                const max_offset: usize = total_rows - visible_rows;
                const scroll_frac: f32 = if (max_offset > 0) @as(f32, @floatFromInt(term_instance.view_row)) / @as(f32, @floatFromInt(max_offset)) else 0.0;
                const thumb_y = scroll_frac * (track_height - thumb_height);
                term_instance.scrollbar_thumb_y = term_instance.scrollbar_track_y + thumb_y;
                term_instance.scrollbar_thumb_height = thumb_height;
                clay.UI()(.{ .id = track_id, .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .right_top, .parent = .right_top }, .z_index = 1000 }, .layout = .{ .sizing = .{ .w = .fixed(term_instance.scrollbar_width), .h = .grow }, .direction = .top_to_bottom }, .background_color = .{ 30, 30, 46, 255 } })({
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_y) } } })({});
                    clay.UI()(.{ .id = clay.ElementId.IDI("terminal_scrollbar_thumb", @truncate(@intFromPtr(pane))), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_height) } }, .background_color = .{ 88, 88, 120, 200 }, .corner_radius = .all(3) })({});
                });
            }
        });
        term_instance.renderContextMenu();
    }

    fn renderChatContentInPane(self: *Self, pane: *pane_mod.Pane, t: Theme) void {
        const chat = &self.ai_chat;
        const line_height: f32 = 24.0;
        const input_height: f32 = 80.0;
        const padding: f32 = 12.0;

        // Messages viewport
        const viewport_id = clay.ElementId.IDI("chat_viewport", @truncate(@intFromPtr(pane)));
        const clip_id = clay.ElementId.IDI("chat_clip", @truncate(@intFromPtr(pane)));

        clay.UI()(.{
            .id = clay.ElementId.IDI("chat_outer", @truncate(@intFromPtr(pane))),
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .padding = .{ .left = padding, .right = padding, .top = padding, .bottom = 0 },
            },
            .background_color = t.surface,
        })({
            // Header
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(40) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .y = .center },
                    .child_gap = 8,
                },
            })({
                clay.text("Chat", .{ .font_size = 18, .color = t.text });
                if (chat.is_loading) {
                    clay.text("...", .{ .font_size = 14, .color = t.muted });
                }
            });

            // Messages area
            clay.UI()(.{
                .id = viewport_id,
                .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
                .clip = .{ .vertical = true },
            })({
                clay.UI()(.{
                    .id = clip_id,
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = 8,
                    },
                }({
                    chat.mutex.lock();
                    defer chat.mutex.unlock();
                    for (chat.messages.items, 0..) |msg, idx| {
                        const is_user = std.mem.eql(u8, msg.role, "user");
                        const msg_id = clay.ElementId.IDI("chat_msg", @truncate(idx ^ @intFromPtr(pane)));

                        const role_label = if (is_user) "You:" else "Gemma:";
                        const role_color: clay.Color = if (is_user) .{ 200, 200, 255, 255 } else .{ 200, 255, 200, 255 };

                        clay.UI()(.{
                            .id = msg_id,
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fit },
                                .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
                                .direction = .top_to_bottom,
                            },
                            .background_color = if (is_user) .{ 40, 40, 60, 255 } else .{ 35, 35, 45, 255 },
                            .corner_radius = .all(4),
                        })({
                            clay.text(role_label, .{ .font_size = 12, .color = role_color });
                            clay.text(msg.content, .{ .font_size = 14, .color = t.text });
                        });
                    }
                    if (chat.is_loading) {
                        clay.text("Thinking...", .{ .font_size = 14, .color = t.muted });
                    }
                }));
            });

            // Update viewport heights for scrolling
            const vp_data = clay.getElementData(viewport_id);
            const content_data = clay.getElementData(clip_id);
            if (vp_data.found) chat.viewport_height = vp_data.bounding_box.height;
            if (content_data.found) chat.content_height = content_data.bounding_box.height;
            const max_scroll = @max(0, chat.content_height - chat.viewport_height);
            if (chat.scroll_offset_y > max_scroll) chat.scroll_offset_y = max_scroll;

            // Input area at bottom
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(input_height) },
                    .direction = .top_to_bottom,
                    .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
                },
                .background_color = .{ 25, 25, 30, 255 },
                .border = .{ .width = .{ .top = 1 }, .color = t.border },
            })({
                const input_text = if (chat.input_buffer.items.len == 0) "> " else chat.input_buffer.items;
                clay.text(input_text, .{ .font_size = 16, .color = t.text });

                // Blinking cursor
                {
                    const blink_ms: f32 = 530.0;
                    const visible = @mod(chat.ui_time_ms, blink_ms * 2.0) < blink_ms;
                    if (visible) {
                        const char_w: f32 = 9.0;
                        const text_w = @as(f32, @floatFromInt(chat.input_buffer.items.len)) * char_w;
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(line_height) } },
                            .floating = .{
                                .attach_to = .to_parent,
                                .attach_points = .{ .element = .left_top, .parent = .left_top },
                                .offset = .{ .x = text_w + 8, .y = 8 },
                            },
                            .background_color = .{ 200, 200, 200, 255 },
                        })({});
                    }
                }
            });
        });

        // Handle scroll
        if (self.active_tab_bar) |tab_bar| {
            if (tab_bar.getActiveTab()) |tab| {
                _ = tab;
                // Scroll handled by scroll wheel events
            }
        }
    }
};
