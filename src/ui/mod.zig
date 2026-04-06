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

const log = std.log.scoped(.ui);

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

    // Code Editor
    code_editor: editor_mod.CodeEditor,

    // Text Renderer (für Measurement)
    text_renderer: ?*@import("../text/mod.zig").TextRenderer = null,

    const Self = @This();

    /// UI initialisieren
    pub fn init(allocator: std.mem.Allocator, config: UIConfig) !Self {
        log.info("Initializing UI system", .{});

        // Clay Memory allozieren
        const min_memory = clay.minMemorySize();
        log.info("Clay requires {} bytes", .{min_memory});

        const clay_memory = try allocator.alloc(u8, min_memory);

        var code_editor = editor_mod.CodeEditor.init(allocator);
        code_editor.setText(
            \\pub fn main() !void {
            \\    std.log.info("Hello World", .{});
            \\const x: u32 = 42;
            \\// This is a comment
            \\var y = x + 1;
            \\}
        );

        return Self{
            .allocator = allocator,
            .config = config,
            .theme = Theme.dark(),
            .clay_memory = clay_memory,
            .initialized = false,
            .anim_manager = AnimationManager.init(allocator),
            .code_editor = code_editor,
        };
    }

    /// UI aufräumen
    pub fn deinit(self: *Self) void {
        log.info("UI system shutdown", .{});
        self.anim_manager.deinit();
        self.allocator.free(self.clay_memory);
    }

    /// Clay initialisieren (nach Window Creation)
    pub fn setupClay(self: *Self, width: u32, height: u32, text_renderer: *@import("../text/mod.zig").TextRenderer) !void {
        log.info("Setting up Clay layout: {}x{}", .{ width, height });
        self.text_renderer = text_renderer;

        const arena = clay.createArenaWithCapacityAndMemory(self.clay_memory);

        _ = clay.initialize(arena, .{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, .{});

        // Measure Text Function setzen
        clay.setMeasureTextFunction(*Self, self, clayMeasureText);

        self.initialized = true;
        log.info("Clay initialized", .{});
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

    /// UI updaten (pro Frame)
    pub fn update(self: *Self, delta_ms: f32) void {
        self.anim_manager.update(delta_ms);
    }

    /// Layout beginnen
    pub fn beginLayout(self: *Self) void {
        _ = self;
        clay.beginLayout();
    }

    /// Layout beenden und Render Commands holen
    pub fn endLayout(self: *Self) []clay.RenderCommand {
        _ = self;
        return clay.endLayout();
    }

    /// Window Resize behandeln
    pub fn resize(self: *Self, width: u32, height: u32) void {
        _ = self;
        clay.setLayoutDimensions(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) });
    }

    /// Beispiel: Layout mit Theme rendern
    pub fn renderExample(self: *Self) []clay.RenderCommand {
        self.beginLayout();

        const t = self.theme;

        // Animations-Werte holen
        var current_scale: f32 = 1.0;
        var current_opacity: f32 = 1.0;
        var current_offset_x: f32 = 0.0;

        if (self.anim_manager.animations.items.len > 0) {
            const anim = self.anim_manager.animations.items[0];
            current_scale = anim.scale();
            current_opacity = anim.opacity();
            current_offset_x = anim.offsetX(100.0);
        }

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
            // Header mit Button (Animiert mit Opacity und Offset)
            var header_bg = t.surface;
            header_bg[3] = header_bg[3] * current_opacity;

            clay.UI()(.{
                .id = clay.ElementId.ID("Header"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(80) },
                    .child_gap = 32, // Mehr Platz zwischen Buttons
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .all(10),
                },
                .background_color = header_bg,
                .border = .{ .width = .all(2), .color = t.accent },
            })({
                // Button 1 (Statisch)
                components.Button("TestButton", "HELLO CLAY", t);

                // Button 2 (Animiert mit Scale und Opacity)
                var accent_theme = t;
                accent_theme.primary = t.accent;
                accent_theme.text_on_primary = t.text_on_accent;
                
                // Alpha auch für Button-Hintergrund übernehmen
                accent_theme.primary[3] = accent_theme.primary[3] * current_opacity;

                clay.UI()(.{
                    .id = clay.ElementId.ID("AnimatedButton"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(180 * current_scale), .h = .fixed(50 * current_scale) },
                        .padding = .axes(@intFromFloat(10 * current_scale), @intFromFloat(20 * current_scale)),
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                    .background_color = accent_theme.primary,
                    .corner_radius = .all(4 * current_scale),
                    .border = .{ .width = .all(2), .color = t.primary },
                })({
                    clay.text("ANIMATED", .{ 
                        .font_size = 24, 
                        .color = accent_theme.text_on_primary,
                    });
                });
            });

            // Content Area mit TextInput, TextArea, ScrollContainer
            clay.UI()(.{
                .id = clay.ElementId.ID("Content"),
                .layout = .{
                    .sizing = .grow,
                    .padding = .all(16),
                    .child_gap = 16,
                    .direction = .top_to_bottom,
                },
                .background_color = t.bg,
            })({
                // TextInput
                components.TextInput("MyInput", "", "Type something...", t);

                // TextArea
                components.TextArea("MyTextArea", "This is a multiline\ntext area component\nwith multiple lines.", t);

                // ScrollContainer
                components.ScrollContainer("MyScroll", t)({
                    clay.UI()(.{
                        .layout = .{ 
                            .sizing = .{ .w = .grow, .h = .fixed(400) }, 
                            .padding = .all(10), 
                            .child_gap = 10,
                            .direction = .top_to_bottom,
                        },
                        .background_color = t.overlay,
                    })({
                        clay.text("SCROLLABLE CONTENT", .{ .font_size = 24, .color = t.text });
                        clay.text("Line 1: Clay now has measureText!", .{ .font_size = 24, .color = t.subtext });
                        clay.text("Line 2: UI elements should no longer overlap.", .{ .font_size = 24, .color = t.subtext });
                        clay.text("Line 3: Spacing is handled by child_gap.", .{ .font_size = 24, .color = t.subtext });
                        clay.text("Line 4: This is a scrollable area.", .{ .font_size = 24, .color = t.subtext });
                        clay.text("Line 5: Multiple lines of text are now working.", .{ .font_size = 24, .color = t.subtext });
                    });
                });

                // Code Editor (mit Syntax Highlighting, Current Line Highlight, Scrollable Content)
                self.code_editor.render();
            });
        });

        return self.endLayout();
    }
};
