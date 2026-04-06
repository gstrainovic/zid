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

    const Self = @This();

    /// UI initialisieren
    pub fn init(allocator: std.mem.Allocator, config: UIConfig) !Self {
        log.info("Initializing UI system", .{});

        // Clay Memory allozieren
        const min_memory = clay.minMemorySize();
        log.info("Clay requires {} bytes", .{min_memory});

        const clay_memory = try allocator.alloc(u8, min_memory);

        return Self{
            .allocator = allocator,
            .config = config,
            .theme = Theme.dark(),
            .clay_memory = clay_memory,
            .initialized = false,
            .anim_manager = AnimationManager.init(allocator),
        };
    }

    /// UI aufräumen
    pub fn deinit(self: *Self) void {
        log.info("UI system shutdown", .{});
        self.anim_manager.deinit();
        self.allocator.free(self.clay_memory);
    }

    /// Clay initialisieren (nach Window Creation)
    pub fn setupClay(self: *Self, width: u32, height: u32) !void {
        log.info("Setting up Clay layout: {}x{}", .{ width, height });

        const arena = clay.createArenaWithCapacityAndMemory(self.clay_memory);

        _ = clay.initialize(arena, .{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, .{});

        self.initialized = true;
        log.info("Clay initialized", .{});
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

        // Root Container
        clay.UI()(.{
            .id = clay.ElementId.ID("Root"),
            .layout = .{
                .sizing = .grow,
                .padding = .all(16),
                .child_gap = 16,
                .layout_direction = .top_to_bottom,
            },
            .background_color = t.bg,
        })({
            // Header mit Button
            clay.UI()(.{
                .id = clay.ElementId.ID("Header"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(80) },
                    .child_gap = 8,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .all(10),
                },
                .background_color = t.surface,
            })({
                // Button im Header
                components.Button("TestButton", "HELLO CLAY", t);

                // Animierter Button (scale-up)
                var scale: f32 = 1.0;
                if (self.anim_manager.animations.items.len > 0) {
                    scale = self.anim_manager.animations.items[0].scale();
                }

                var accent_theme = t;
                accent_theme.primary = t.accent;
                accent_theme.text_on_primary = t.text_on_accent;
                
                // Wir nutzen UI() direkt statt Button(), um Scale anzuwenden
                clay.UI()(.{
                    .id = clay.ElementId.ID("AnimatedButton"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(120 * scale), .h = .fixed(40 * scale) },
                        .padding = .axes(@intFromFloat(8 * scale), @intFromFloat(16 * scale)),
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                    .background_color = accent_theme.primary,
                    .corner_radius = .all(4 * scale),
                })({
                    clay.text("ACCENT", .{ 
                        .font_size = @intFromFloat(16 * scale), 
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
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(300) }, .padding = .all(10), .child_gap = 10 },
                        .background_color = t.overlay,
                    })({
                        clay.text("SCROLLABLE CONTENT", .{ .font_size = 16, .color = t.text });
                        clay.text("Line 1...", .{ .font_size = 14, .color = t.subtext });
                        clay.text("Line 2...", .{ .font_size = 14, .color = t.subtext });
                        clay.text("Line 3...", .{ .font_size = 14, .color = t.subtext });
                        clay.text("Line 4...", .{ .font_size = 14, .color = t.subtext });
                        clay.text("Line 5...", .{ .font_size = 14, .color = t.subtext });
                    });
                });

                // Code Editor (dunkel mit Line Numbers)
                clay.UI()(.{
                    .id = clay.ElementId.ID("CodeEditor"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fixed(200) },
                    },
                    .background_color = .{ 30, 30, 46, 255 },
                    .corner_radius = .all(4),
                })({
                    // Line Numbers Gutter (links, dunkler)
                    clay.UI()(.{
                        .id = clay.ElementId.ID("LineNumbers"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(50), .h = .grow },
                            .padding = .all(8),
                        },
                        .background_color = .{ 24, 24, 37, 255 },
                    })({
                        clay.text("1", .{ .font_size = 14, .color = .{ 108, 112, 134, 255 } });
                        clay.text("2", .{ .font_size = 14, .color = .{ 108, 112, 134, 255 } });
                    });
                });
            });
        });

        return self.endLayout();
    }
};
