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
const editor_mod = @import("../editor/mod.zig");
const wio = @import("wio");

const log = std.log.scoped(.ui);

/// Globaler Measure-Context (thread-local) — wird von CodeEditor.colFromX genutzt
var g_text_renderer: ?*@import("../text/mod.zig").TextRenderer = null;
var g_font_size: f32 = 0;

/// C-kompatibler Callback: misst Text-Breite in px
fn cMeasureText(ptr: [*c]const u8, len: usize) f32 {
    const tr = g_text_renderer orelse return 0;
    return tr.measureTextAtSize(ptr[0..len], g_font_size);
}

/// UI Konfiguration
pub const UIConfig = struct {
    font_size: f32 = 14.0,
    padding: f32 = 8.0,
    gap: f32 = 4.0,
};

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

    const Self = @This();

    /// UI initialisieren
    pub fn init(allocator: std.mem.Allocator, config: UIConfig, default_file_path: ?[]const u8) !Self {
        log.debug("Initializing UI system", .{});

        // Clay Memory allozieren (großzügiger Puffer für viele Elemente/Zeilen)
        const min_memory = clay.minMemorySize();
        const generous_memory = @max(min_memory, 10 * 1024 * 1024); // 10 MB
        log.debug("Clay requires {} bytes, allocating {} bytes", .{ min_memory, generous_memory });

        const clay_memory = try allocator.alloc(u8, generous_memory);

        var code_editor = editor_mod.CodeEditor.init(allocator);

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
                };
            };
            defer allocator.free(file_content);
            code_editor.setText(file_content);
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
        };
    }

    /// UI aufräumen
    pub fn deinit(self: *Self) void {
        log.debug("UI system shutdown", .{});
        self.anim_manager.deinit();
        self.frame_arena.deinit();
        self.allocator.free(self.clay_memory);
        self.code_editor.deinit();
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
        const width = renderer.ts_ptr.measureTextAtSize(text_str, @floatFromInt(config.font_size)) catch 0;
        
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
        self.code_editor.handleKeyPress(key);
    }

    /// Text Input verarbeiten
    pub fn handleChar(self: *Self, char_code: u21) void {
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
        self.code_editor.handleMouseDown(x, y);
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
        _ = self;
        return clay.endLayout();
    }

    /// Window Resize behandeln
    pub fn resize(self: *Self, width: u32, height: u32) void {
        clay.setLayoutDimensions(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) });
        // Editor-Höhe aktualisieren für korrekte visibleLineCount-Berechnung
        self.code_editor.height = @floatFromInt(height);
    }

    /// Maus-Position und Button-Status an Clay weiterleiten
    pub fn setPointerState(self: *Self, x: f32, y: f32, is_down: bool) void {
        _ = self;
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
                .padding = .all(16),
                .child_gap = 16,
                .direction = .top_to_bottom,
            },
            .background_color = t.bg,
        })({
            // Header mit Logo und Titel
            clay.UI()(.{
                .id = clay.ElementId.ID("Header"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(64) },
                    .child_gap = 16,
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .all(10),
                },
                .background_color = t.surface,
                .border = .{ .width = .all(2), .color = t.accent },
            })({
                // Logo Image (falls vorhanden)
                if (image_data) |ptr| {
                    clay.UI()(.{
                        .id = clay.ElementId.ID("Logo"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(48), .h = .fixed(48) },
                        },
                        .image = .{ .image_data = ptr },
                        .background_color = .{ 255, 255, 255, 255 },
                    })({});
                }

                clay.text("VULKAN-ED", .{ .font_size = 28, .color = t.text });
            });

            // Nur Code Editor - füllt den restlichen Raum
            self.code_editor.render(self.frame_arena.allocator());
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
};
