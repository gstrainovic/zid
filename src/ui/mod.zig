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
};
pub const PdfPageChange = struct { path: []const u8, delta: i16 };

/// UI Hauptstruktur
pub const components = @import("components/mod.zig");
pub const UI = struct {
    allocator: std.mem.Allocator,
    config: UIConfig,
    theme: Theme,
    initialized: bool = false,

    // Clay Memory Arena
    clay_memory: []u8 = &[_]u8{},

    // Animationen
    anim_manager: AnimationManager,

    // Frame Arena für kurzlebige Daten (z.B. SvgRenderInfo)
    frame_arena: std.heap.ArenaAllocator,

    // Code Editor
    code_editor: editor_mod.CodeEditor,

    // Text Renderer (für Measurement)
    text_renderer: ?*@import("../text/mod.zig").TextRenderer = null,

    // Phase 9: Tab-Bar und File Explorer
    tab_bar: tab_bar_mod.TabBarState,
    file_explorer: file_explorer_mod.FileExplorerState,
    show_file_explorer: bool = true,
    current_directory: ?[]const u8 = null,
    pending_tab_switch: ?[]const u8 = null,
    pending_pdf_page_change: ?PdfPageChange = null,

    // Map von Pfad zu geladener Textur-ID/Pointer
    open_images: std.StringHashMap(*anyopaque),
    
    // Phase 9: PDF Handler
    open_pdfs: std.StringHashMap(*anyopaque),

    // Mouse state for immediate mode UI clicks
    mouse_pressed_this_frame: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    is_mouse_down: bool = false,

    const Self = @This();

    /// UI initialisieren
    pub fn init(allocator: std.mem.Allocator, config: UIConfig, default_file_path: ?[]const u8) !Self {
        log.debug("Initializing UI system", .{});

        // Clay Memory allozieren (großzügiger Puffer für viele Elemente/Zeilen)
        const min_memory = clay.minMemorySize();
        const generous_memory = @max(min_memory, 10 * 1024 * 1024); // 10 MB
        log.debug("Clay requires {} bytes, allocating {} bytes", .{ min_memory, generous_memory });

        const clay_memory = try allocator.alloc(u8, generous_memory);

        var code_editor = editor_mod.CodeEditor.init(allocator, default_file_path);

        // Phase 9: Tab-Bar und File Explorer initialisieren
        const tab_bar = tab_bar_mod.TabBarState.init(allocator);
        const file_explorer = file_explorer_mod.FileExplorerState.init(allocator);

        // Callback für File Explorer: Wenn Datei geöffnet wird
        // Hinweis: Callback muss static sein, wir speichern den Pfad direkt im Editor
        _ = &file_explorer; // Callback wird später gesetzt

        // Default-Inhalt: Entweder Datei laden oder Hardcoded-Beispiel
        if (default_file_path) |path| {
            const file_content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch |err| {
                log.err("Failed to load default file '{s}': {}. Using fallback content.", .{ path, err });
                code_editor.setText(
                    \\// Failed to load file: {s}
                    \\// Error: {}
                );
                // Formatiere Fehlermeldung in den Text
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "// Failed to load: {s}\n// Error: {}", .{ path, err }) catch "// Failed to load file";
                code_editor.setText(msg);
                return Self{
                    .allocator = allocator,
                    .config = config,
                    .theme = Theme.dark(),
                    .clay_memory = clay_memory,
                    .initialized = false,
                    .anim_manager = AnimationManager.init(allocator),
                    .frame_arena = std.heap.ArenaAllocator.init(allocator),
                    .code_editor = code_editor,
                    .text_renderer = null,
                    .tab_bar = tab_bar,
                    .file_explorer = file_explorer,
                    .show_file_explorer = true,
                    .current_directory = null,
                    .open_images = std.StringHashMap(*anyopaque).init(allocator),
                    .open_pdfs = std.StringHashMap(*anyopaque).init(allocator),
                    .pending_tab_switch = null,
                    .mouse_pressed_this_frame = false,
                    .mouse_x = 0,
                    .mouse_y = 0,
                    .is_mouse_down = false,
                };
            };
            defer allocator.free(file_content);
            code_editor.setText(file_content);
            code_editor.setLanguageFromPath(path);
            log.info("Loaded default file: {s} ({d} bytes)", .{ path, file_content.len });
        } else {
            code_editor.setText(
                \\pub fn main() !void {
                \\    std.log.info("Hello World", .{});
                \\const x: u32 = 42;
                \\// This is a comment
                \\var y = x + 1;
                \\}
            );
        }

        return Self{
            .allocator = allocator,
            .config = config,
            .theme = Theme.dark(),
            .clay_memory = clay_memory,
            .initialized = false,
            .anim_manager = AnimationManager.init(allocator),
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .code_editor = code_editor,
            .text_renderer = null,
            .tab_bar = tab_bar,
            .file_explorer = file_explorer,
            .show_file_explorer = true,
            .current_directory = null,
            .open_images = std.StringHashMap(*anyopaque).init(allocator),
            .open_pdfs = std.StringHashMap(*anyopaque).init(allocator),
        };
    }

    /// UI aufräumen
    pub fn deinit(self: *Self) void {
        log.debug("UI.deinit: start", .{});
        self.anim_manager.deinit();
        log.debug("UI.deinit: anim_manager done", .{});
        self.frame_arena.deinit();
        log.debug("UI.deinit: frame_arena done", .{});
        self.allocator.free(self.clay_memory);
        log.debug("UI.deinit: clay_memory freed", .{});
        self.code_editor.deinit();
        log.debug("UI.deinit: code_editor done", .{});
        self.tab_bar.deinit();
        log.debug("UI.deinit: tab_bar done", .{});
        self.file_explorer.deinit();
        log.debug("UI.deinit: file_explorer done", .{});

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

        if (self.current_directory) |dir| self.allocator.free(dir);
        log.debug("UI.deinit: finished", .{});
    }

    /// Clay initialisieren (nach Window Creation)
    pub fn setupClay(self: *Self, window: *wio.Window, width: u32, height: u32, text_renderer: *@import("../text/mod.zig").TextRenderer) !void {
        log.debug("Setting up Clay layout: {}x{}", .{ width, height });
        self.text_renderer = text_renderer;
        self.code_editor.window = window;

        // Globalen Measure-Context setzen (für Maus→Spalte)
        g_text_renderer = text_renderer;
        g_font_size = @floatFromInt(self.code_editor.font_size);
        self.code_editor.measure_fn = cMeasureText;

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

            if (self.code_editor.mods.ctrl) {
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
        self.code_editor.handleKeyPress(key);
    }

    /// Text Input verarbeiten
    pub fn handleChar(self: *Self, char_code: u21) void {
        // Forward to terminal if active
        if (self.getActiveTerminal()) |term| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(char_code, &buf) catch return;
            term.sendInput(buf[0..len]) catch {};
            return;
        }
        self.code_editor.handleChar(char_code);
    }

    /// Modifier-State aktualisieren
    pub fn setShiftState(self: *Self, pressed: bool) void {
        self.code_editor.setShiftState(pressed);
    }

    pub fn setCtrlState(self: *Self, pressed: bool) void {
        self.code_editor.setCtrlState(pressed);
    }

    pub fn setAltState(self: *Self, pressed: bool) void {
        self.code_editor.setAltState(pressed);
    }

    /// Maus-Events an Editor oder Terminal weiterleiten
    pub fn handleMouseDown(self: *Self, x: f32, y: f32) void {
        self.mouse_pressed_this_frame = true;
        
        if (self.tab_bar.getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.tab_bar.terminal_instances.get(tab.path)) |term| {
                    _ = term.handleScrollbarMouseDown(x, y);
                }
                return;
            }
        }

        // Nur an Editor weitergeben wenn Klick innerhalb der code_editor-BBox
        // liegt (Vorframe-Daten). Sonst setzt jeder Sidebar-/Tab-Klick
        // zusätzlich den Cursor im Editor.
        const editor_data = clay.getElementData(clay.ElementId.ID("code_editor"));
        if (editor_data.found) {
            const bb = editor_data.bounding_box;
            if (x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height) {
                self.code_editor.handleMouseDown(x, y);
            }
        }
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        if (self.tab_bar.getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.tab_bar.terminal_instances.get(tab.path)) |term| {
                    term.handleScrollbarMouseMove(x, y);
                }
                return;
            }
        }
        self.code_editor.handleMouseMove(x, y);
    }

    pub fn handleMouseUp(self: *Self) void {
        if (self.tab_bar.getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.tab_bar.terminal_instances.get(tab.path)) |term| {
                    term.handleMouseUp();
                }
                return;
            }
        }
        self.code_editor.handleMouseUp();
    }

    /// Scroll-Events an Editor oder Terminal weiterleiten
    pub fn handleScroll(self: *Self, delta: i32) void {
        if (self.tab_bar.getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.tab_bar.terminal_instances.get(tab.path)) |term| {
                    term.scrollLines(delta);
                }
                return;
            }
        }
        self.code_editor.scrollLines(delta);
    }

    /// UI updaten (pro Frame)
    pub fn update(self: *Self, delta_ms: f32) void {
        self.anim_manager.update(delta_ms);
        self.code_editor.time_ms += delta_ms;
    }

    /// Layout beginnen
    pub fn beginLayout(self: *Self) void {
        _ = self.frame_arena.reset(.retain_capacity);
        clay.beginLayout();
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
        self.code_editor.height = @floatFromInt(height);
    }

    /// Maus-Position und Button-Status an Clay weiterleiten
    pub fn setPointerState(self: *Self, x: f32, y: f32, is_down: bool) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.is_mouse_down = is_down;
        clay.setPointerState(.{ .x = x, .y = y }, is_down);
    }

    /// Scroll-Events an Clay weiterleiten
    pub fn updateScroll(self: *Self, delta_x: f32, delta_y: f32, delta_time_ms: f32) void {
        _ = self;
        // Clay erwartet Scroll-Delta als Vector2 und delta_time in Sekunden
        clay.updateScrollContainers(false, .{ .x = delta_x, .y = delta_y }, delta_time_ms / 1000.0);
    }

    /// Beispiel: Layout mit Theme rendern
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

                // Editor Area (Tabs + Editor)
                clay.UI()(.{
                    .id = clay.ElementId.ID("EditorArea"),
                    .layout = .{
                        .sizing = .grow,
                        .direction = .top_to_bottom,
                        .child_gap = 0,
                    },
                    .background_color = t.bg,
                })({
                    // Tab-Leiste
                    tab_bar_mod.renderTabBar(
                        self.frame_arena.allocator(),
                        &self.tab_bar,
                        t,
                        self.mouse_pressed_this_frame,
                    );

                    // Aktiven Tab prüfen für Weiche (Editor vs Bild vs Terminal)
                    var special_active = false;
                    if (self.tab_bar.active_index) |idx| {
                        if (idx < self.tab_bar.tabs.items.len) {
                            const tab = self.tab_bar.tabs.items[idx];
                            if (tab.kind == .image) {
                                image_view_mod.ImageViewState.render(
                                    self.frame_arena.allocator(),
                                    tab.path,
                                    t,
                                    &self.open_images,
                                );
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
                                // Render terminal tab
                                self.renderTerminalContent(tab.path, t);
                                special_active = true;
                            }
                        }
                    }

                    // Code Editor - füllt den restlichen Raum (nur wenn kein Spezial-Tab aktiv)
                    if (!special_active) {
                        self.code_editor.render(self.frame_arena.allocator());
                    }
                });
            });
        });

        const commands = self.endLayout();

        // Content-Position vom Editor für Maus-Konversion speichern (sev-Pattern)
        const editor_data = clay.getElementData(clay.ElementId.ID("code_editor"));
        if (editor_data.found) {
            self.code_editor.content_origin_y = editor_data.bounding_box.y;
            self.code_editor.content_origin_x = editor_data.bounding_box.x;
            self.code_editor.height = editor_data.bounding_box.height;
            self.code_editor.scrollbar_container_width = editor_data.bounding_box.width;
        }

        return commands;
    }

    /// Berechnet den gewünschten Cursor für diesen Frame
    pub fn getDesiredCursor(self: *Self) wio.Cursor {
        if (self.file_explorer.is_resizing or clay.pointerOver(clay.ElementId.ID("ExplorerSplitter"))) {
            return .size_ew;
        }
        return self.code_editor.desired_cursor;
    }

    /// Check if a terminal tab is currently active
    pub fn isTerminalActive(self: *Self) bool {
        if (self.tab_bar.active_index) |idx| {
            if (idx < self.tab_bar.tabs.items.len) {
                return self.tab_bar.tabs.items[idx].kind == .terminal;
            }
        }
        return false;
    }

    /// Get the active terminal instance (if any)
    pub fn getActiveTerminal(self: *Self) ?*@import("../terminal/terminal_instance.zig").TerminalInstance {
        if (self.tab_bar.active_index) |idx| {
            if (idx < self.tab_bar.tabs.items.len) {
                const tab = self.tab_bar.tabs.items[idx];
                if (tab.kind == .terminal) {
                    return self.tab_bar.terminal_instances.get(tab.path);
                }
            }
        }
        return null;
    }

    /// Render terminal content in the content area
    fn renderTerminalContent(self: *Self, path: []const u8, t: Theme) void {
        _ = t;
        const term_instance = self.tab_bar.terminal_instances.get(path) orelse return;
        
        const arena_alloc = self.frame_arena.allocator();
        const cursor = term_instance.getCursor();
        const total_rows = term_instance.totalRows();
        const line_height: f32 = 24.0; 

        // Update height and width from previous frame's bounding box
        const term_data = clay.getElementData(clay.ElementId.ID("terminal_content_clip"));
        if (term_data.found) {
            const bb = term_data.bounding_box;
            term_instance.height = bb.height;
            // Calculate cols/rows based on font size (16px) -> roughly 10px width per char
            const char_w = measureTextWidth("W", 16.0);
            if (char_w > 0) {
                const cols: u16 = @intFromFloat(bb.width / char_w);
                const rows: u16 = @intFromFloat(bb.height / line_height);
                if (cols != term_instance.cols or rows != term_instance.rows) {
                    if (cols > 0 and rows > 0) {
                        term_instance.resize(cols, rows) catch {};
                    }
                }
            }
        }

        const visible_rows = term_instance.visibleLineCount();
        const history_count = if (total_rows > term_instance.rows) total_rows - term_instance.rows else 0;
        const cursor_abs_row = history_count + cursor.y;

        // Terminal container — dark bg
        clay.UI()(.{
            .id = clay.ElementId.ID("terminal_outer"),
            .layout = .{
                .sizing = .grow,
                .direction = .left_to_right,
                .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
            },
            .background_color = .{ 30, 30, 30, 255 },
        })({
            // Scrollable container for the terminal text
            clay.UI()(.{
                .id = clay.ElementId.ID("terminal_content_clip"),
                .layout = .{
                    .sizing = .grow,
                },
                .clip = .{ .vertical = true, .horizontal = true },
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("terminal_content"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                    },
                })({
                    const start_line = @min(term_instance.view_row, total_rows);
                    const end_line = @min(start_line + visible_rows + 1, total_rows);

                    var i: usize = start_line;
                    while (i < end_line) : (i += 1) {
                        const line_text = term_instance.getLine(i, arena_alloc) catch "";
                        
                        clay.UI()(.{
                            .id = clay.ElementId.IDI("term_row", @intCast(i)),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fixed(line_height) },
                                .direction = .left_to_right,
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            // Parse ANSI
                            var pos: usize = 0;
                            var current_fg: clay.Color = .{ 204, 204, 204, 255 }; // Default fg
                            var current_bg: ?clay.Color = null; // Default bg
                            var text_start: usize = 0;

                            const default_fg: clay.Color = .{ 204, 204, 204, 255 };

                            while (pos < line_text.len) {
                                if (line_text[pos] == '\x1B' and pos + 1 < line_text.len and line_text[pos + 1] == '[') {
                                    // Flush pending text
                                    if (pos > text_start) {
                                        const seg = line_text[text_start..pos];
                                        if (current_bg) |bg| {
                                            clay.UI()(.{ .background_color = bg })({
                                                clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                            });
                                        } else {
                                            clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                        }
                                    }

                                    // Parse sequence
                                    pos += 2;
                                    var args: [16]u8 = undefined;
                                    var arg_count: usize = 0;
                                    var num: u8 = 0;
                                    var has_num = false;

                                    while (pos < line_text.len) {
                                        const c = line_text[pos];
                                        if (c >= '0' and c <= '9') {
                                            num = num * 10 + (c - '0');
                                            has_num = true;
                                            pos += 1;
                                        } else if (c == ';') {
                                            if (arg_count < args.len) {
                                                args[arg_count] = num;
                                                arg_count += 1;
                                            }
                                            num = 0;
                                            has_num = false;
                                            pos += 1;
                                        } else if (c == 'm') {
                                            if (has_num and arg_count < args.len) {
                                                args[arg_count] = num;
                                                arg_count += 1;
                                            }
                                            pos += 1;
                                            break;
                                        } else {
                                            // Unknown sequence character, just skip
                                            pos += 1;
                                            break;
                                        }
                                    }

                                    // Process args (simplified SGR)
                                    var arg_idx: usize = 0;
                                    if (arg_count == 0) {
                                        current_fg = default_fg;
                                        current_bg = null;
                                    }
                                    while (arg_idx < arg_count) {
                                        const code = args[arg_idx];
                                        arg_idx += 1;
                                        switch (code) {
                                            0 => {
                                                current_fg = default_fg;
                                                current_bg = null;
                                            },
                                            30...37 => {
                                                // Basic 8 foreground colors
                                                current_fg = switch (code - 30) {
                                                    0 => .{ 0, 0, 0, 255 },       // Black
                                                    1 => .{ 205, 49, 49, 255 },   // Red
                                                    2 => .{ 13, 188, 121, 255 },  // Green
                                                    3 => .{ 229, 229, 16, 255 },  // Yellow
                                                    4 => .{ 36, 114, 200, 255 },  // Blue
                                                    5 => .{ 188, 63, 188, 255 },  // Magenta
                                                    6 => .{ 17, 168, 205, 255 },  // Cyan
                                                    7 => .{ 229, 229, 229, 255 }, // White
                                                    else => default_fg,
                                                };
                                            },
                                            38 => {
                                                if (arg_idx + 1 < arg_count and args[arg_idx] == 5) {
                                                    arg_idx += 2; // 256 colors not fully implemented
                                                } else if (arg_idx + 3 < arg_count and args[arg_idx] == 2) {
                                                    current_fg = .{ args[arg_idx + 1], args[arg_idx + 2], args[arg_idx + 3], 255 };
                                                    arg_idx += 4;
                                                }
                                            },
                                            39 => current_fg = default_fg,
                                            40...47 => {
                                                // Basic 8 background colors
                                                current_bg = switch (code - 40) {
                                                    0 => .{ 0, 0, 0, 255 },       // Black
                                                    1 => .{ 205, 49, 49, 255 },   // Red
                                                    2 => .{ 13, 188, 121, 255 },  // Green
                                                    3 => .{ 229, 229, 16, 255 },  // Yellow
                                                    4 => .{ 36, 114, 200, 255 },  // Blue
                                                    5 => .{ 188, 63, 188, 255 },  // Magenta
                                                    6 => .{ 17, 168, 205, 255 },  // Cyan
                                                    7 => .{ 229, 229, 229, 255 }, // White
                                                    else => null,
                                                };
                                            },
                                            48 => {
                                                if (arg_idx + 1 < arg_count and args[arg_idx] == 5) {
                                                    arg_idx += 2;
                                                } else if (arg_idx + 3 < arg_count and args[arg_idx] == 2) {
                                                    current_bg = .{ args[arg_idx + 1], args[arg_idx + 2], args[arg_idx + 3], 255 };
                                                    arg_idx += 4;
                                                }
                                            },
                                            49 => current_bg = null,
                                            90...97 => { // Bright foreground
                                                current_fg = switch (code - 90) {
                                                    0 => .{ 102, 102, 102, 255 }, // Bright Black
                                                    1 => .{ 241, 76, 76, 255 },   // Bright Red
                                                    2 => .{ 35, 209, 139, 255 },  // Bright Green
                                                    3 => .{ 245, 245, 67, 255 },  // Bright Yellow
                                                    4 => .{ 59, 142, 234, 255 },  // Bright Blue
                                                    5 => .{ 214, 112, 214, 255 }, // Bright Magenta
                                                    6 => .{ 41, 184, 219, 255 },  // Bright Cyan
                                                    7 => .{ 255, 255, 255, 255 }, // Bright White
                                                    else => default_fg,
                                                };
                                            },
                                            else => {},
                                        }
                                    }
                                    text_start = pos;
                                } else {
                                    pos += 1;
                                }
                            }

                            // Flush remaining text
                            if (pos > text_start) {
                                const seg = line_text[text_start..pos];
                                if (current_bg) |bg| {
                                    clay.UI()(.{ .background_color = bg })({
                                        clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                    });
                                } else {
                                    clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                }
                            }

                            // Cursor logic for this line
                            if (i == cursor_abs_row) {
                                // Strip ANSI for accurate width measurement
                                var clean_line = std.ArrayList(u8).init(arena_alloc);
                                var clean_pos: usize = 0;
                                while (clean_pos < cursor.x and clean_pos < line_text.len) {
                                    // Note: A more robust cursor X measurement would parse the ANSI strings 
                                    // and measure just the visible characters.
                                    clean_line.append(line_text[clean_pos]) catch {};
                                    clean_pos += 1;
                                }
                                
                                // This is a rough estimation since ANSI sequences affect the raw length.
                                // A true fix requires tracking visual length during parse.
                                const char_w = measureTextWidth("W", 16.0);
                                const exact_x = @as(f32, @floatFromInt(cursor.x)) * char_w;

                                clay.UI()(.{
                                    .id = clay.ElementId.ID("terminal_cursor"),
                                    .floating = .{
                                        .attach_to = .to_parent,
                                        .attach_points = .{ .element = .left_top, .parent = .left_top },
                                        .offset = .{ .x = exact_x, .y = 0 },
                                    },
                                    .layout = .{
                                        .sizing = .{ .w = .fixed(char_w), .h = .fixed(line_height) },
                                    },
                                    .background_color = .{ 200, 200, 200, 180 },
                                })({});
                            }
                        });
                    }
                });
            });

            // Vertical Custom Scrollbar (CodeEditor Parity)
            if (total_rows > visible_rows) {
                const track_data = clay.getElementData(clay.ElementId.ID("terminal_scrollbar_track"));
                if (track_data.found) {
                    term_instance.scrollbar_track_x = track_data.bounding_box.x;
                    term_instance.scrollbar_track_y = track_data.bounding_box.y;
                }

                const track_height = term_instance.height;
                const thumb_ratio: f32 = @as(f32, @floatFromInt(visible_rows)) / @as(f32, @floatFromInt(total_rows));
                const thumb_height = @max(20.0, track_height * thumb_ratio);
                const max_offset: usize = total_rows - visible_rows;
                const scroll_frac: f32 = if (max_offset > 0)
                    @as(f32, @floatFromInt(term_instance.view_row)) / @as(f32, @floatFromInt(max_offset))
                else
                    0.0;
                const thumb_y = scroll_frac * (track_height - thumb_height);

                term_instance.scrollbar_thumb_y = term_instance.scrollbar_track_y + thumb_y;
                term_instance.scrollbar_thumb_height = thumb_height;

                const track_color: clay.Color = .{ 30, 30, 46, 100 };
                const thumb_color: clay.Color = .{ 88, 88, 120, 180 };

                clay.UI()(.{
                    .id = clay.ElementId.ID("terminal_scrollbar_track"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(term_instance.scrollbar_width), .h = .grow },
                        .direction = .top_to_bottom,
                    },
                    .background_color = track_color,
                })({
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_y) } },
                    })({});
                    clay.UI()(.{
                        .id = clay.ElementId.ID("terminal_scrollbar_thumb"),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_height) } },
                        .background_color = thumb_color,
                        .corner_radius = .all(3),
                    })({});
                });
            }
        });
    }
};
