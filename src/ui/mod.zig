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
        clay.setLayoutDimensions(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) });
    }

    /// Beispiel: Layout mit Button rendern
    pub fn renderExample(self: *Self) []clay.RenderCommand {
        self.beginLayout();

        // Root Container
        clay.UI()(.{
            .id = clay.ElementId.ID("Root"),
            .layout = .{
                .sizing = .grow,
                .padding = .all(16),
                .child_gap = 16,
            },
            .background_color = .{ 200, 50, 50, 255 },
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
                .background_color = .{ 50, 200, 50, 255 },
            })({
                // Button im Header (gelb)
                clay.UI()(.{
                    .id = clay.ElementId.ID("TestButton"),
                    .layout = .{
                        .sizing = .{ .w = .fixed(80), .h = .fixed(30) },
                    },
                    .background_color = .{ 255, 200, 50, 255 },
                    .corner_radius = .all(4),
                })({});
            });

            // Content Area
            clay.UI()(.{
                .id = clay.ElementId.ID("Content"),
                .layout = .{
                    .sizing = .grow,
                },
                .background_color = .{ 50, 50, 200, 255 },
            })({});
        });

        return self.endLayout();
    }
};
