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
            const data: ?[]const u8 = switch (key) {
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

    /// Maus-Events an Editor weiterleiten
    pub fn handleMouseDown(self: *Self, x: f32, y: f32) void {
        self.mouse_pressed_this_frame = true;
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
        self.code_editor.handleMouseMove(x, y);
    }

    pub fn handleMouseUp(self: *Self) void {
        self.code_editor.handleMouseUp();
    }

    /// Scroll-Events an Editor weiterleiten
    pub fn handleScroll(self: *Self, delta: i32) void {
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
        const term_instance = self.tab_bar.terminal_instances.get(path) orelse return;
        _ = t;

        // Use frame_arena so the text survives until endLayout() processes it.
        // frame_arena is reset at the start of each frame in beginLayout().
        const arena_alloc = self.frame_arena.allocator();
        const screen_text = term_instance.getScreenText(arena_alloc) catch |err| {
            log.err("Failed to get terminal screen text: {}", .{err});
            return;
        };
        // No defer free — frame_arena handles cleanup

        // Convert to Clay string
        const text_slice: []const u8 = if (screen_text.len > 0) screen_text else " ";

        // Terminal container — dark bg, monospace font
        clay.UI()(.{
            .id = clay.ElementId.ID("terminal_content"),
            .layout = .{
                .sizing = .grow,
                .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
            },
            .background_color = .{ 30, 30, 30, 255 },
            .clip = .{ .vertical = true },
        })({
            clay.text(text_slice, .{
                .font_size = 16,
                .color = .{ 204, 204, 204, 255 },
            });
        });
    }
};
