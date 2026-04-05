//! UI Modul für vulkan-ed
//!
//! Verwendet Clay für Layout und migrierte Gooey Components.

const std = @import("std");
const clay = @import("clay");
const Theme = @import("theme.zig").Theme;

const log = std.log.scoped(.ui);

/// UI Konfiguration
pub const UIConfig = struct {
    font_size: f32 = 14.0,
    padding: f32 = 8.0,
    gap: f32 = 4.0,
};

/// UI Hauptstruktur
pub const UI = struct {
    allocator: std.mem.Allocator,
    config: UIConfig,
    theme: Theme,
    initialized: bool = false,

    // Clay Memory Arena
    clay_memory: []u8 = &[_]u8{},

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
        };
    }

    /// UI aufräumen
    pub fn deinit(self: *Self) void {
        log.info("UI system shutdown", .{});
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
                // Button im Header (primary color)
                clay.UI()(.{
                    .id = clay.ElementId.ID("TestButton"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(80), .h = .fixed(30) },
                    },
                    .background_color = t.primary,
                    .corner_radius = .all(4),
                })({});
            });

            // Content Area mit TextInput, TextArea, ScrollContainer
            clay.UI()(.{
                .id = clay.ElementId.ID("Content"),
                .layout = .{
                    .sizing = .grow,
                    .padding = .all(16),
                    .child_gap = 8,
                },
                .background_color = t.bg,
            })({
                // TextInput (surface color)
                clay.UI()(.{
                    .id = clay.ElementId.ID("TextInput"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(200), .h = .fixed(35) },
                    },
                    .background_color = t.surface,
                    .corner_radius = .all(4),
                })({});

                // TextArea (overlay color)
                clay.UI()(.{
                    .id = clay.ElementId.ID("TextArea"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(300), .h = .fixed(100) },
                    },
                    .background_color = t.overlay,
                    .corner_radius = .all(4),
                })({});

                // ScrollContainer (accent color)
                clay.UI()(.{
                    .id = clay.ElementId.ID("ScrollContainer"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(150), .h = .fixed(100) },
                    },
                    .background_color = t.accent,
                    .corner_radius = .all(4),
                })({});
            });
        });

        return self.endLayout();
    }
};
