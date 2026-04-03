//! UI Modul für vulkan-ed
//!
//! Verwendet Clay für Layout und migrierte Gooey Components.

const std = @import("std");
const clay = @import("clay");

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
        clay.setLayoutDimensions(.{ .x = width, .y = height });
    }

    /// Beispiel: Einfaches Layout rendern
    pub fn renderExample(self: *Self) []clay.RenderCommand {
        self.beginLayout();

        // Root Container
        clay.ui()(.{
            .id = clay.id("Root"),
            .layout = .{
                .sizing = clay.Element.Sizing.grow(.{}),
                .padding = clay.Padding.all(16),
                .child_gap = 16,
            },
        })({
            // Header
            clay.ui()(.{
                .id = clay.id("Header"),
                .layout = .{
                    .sizing = .{
                        .width = clay.Element.Sizing.Axis.grow(.{}),
                        .height = clay.Element.Sizing.Axis.fixed(40),
                    },
                },
                .rectangle = .{ .color = .{ .r = 40, .g = 40, .b = 50 } },
            })({
                clay.text("vulkan-ed", .{
                    .font_size = 18,
                    .text_color = .{ .r = 255, .g = 255, .b = 255 },
                });
            });

            // Content Area
            clay.ui()(.{
                .id = clay.id("Content"),
                .layout = .{
                    .sizing = clay.Element.Sizing.grow(.{}),
                },
                .rectangle = .{ .color = .{ .r = 30, .g = 30, .b = 40 } },
            })({
                clay.text("Hello from Clay UI!", .{
                    .font_size = 16,
                    .text_color = .{ .r = 200, .g = 200, .b = 200 },
                });
            });
        });

        return self.endLayout();
    }
};
