const std = @import("std");
const builtin = @import("builtin");
const wio = @import("wio");
const platform = @import("platform/mod.zig");
const rendering = @import("rendering/mod.zig");
const text = @import("text/mod.zig");
const ui = @import("ui/mod.zig");
const clay_renderer_mod = @import("clay_renderer/mod.zig");
const editor = @import("editor/mod.zig");

const log = std.log.scoped(.main);

pub fn main() !void {
    // Allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("=== vulkan-ed starting ===", .{});
    log.info("Platform: {s}-{s}", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    });

    // 1. Renderer initialisieren (WGPU - VOR wio, kein EGL-Konflikt)
    var renderer = try rendering.Renderer.init(allocator, .{
        .vsync = true,
        .clear_color = .{ 0.05, 0.05, 0.05, 1.0 },
    });
    defer renderer.deinit();

    // 2. Platform initialisieren (wio - NACH wgpu, vermeidet EGL-Konflikt)
    var plat = try platform.Platform.init(allocator, .{
        .title = "vulkan-ed",
        .width = 1200,
        .height = 800,
    });
    defer plat.deinit();

    // Window erstellen (NACH renderer)
    try plat.createWindow();

    // Surface vom Window erstellen
    try renderer.setWindow(plat.getWaylandDisplay(), plat.getWaylandSurface());
    try renderer.configureSwapChain(plat.getSize().width, plat.getSize().height);

    // 3. Text Renderer initialisieren (DirectWrite/FreeType)
    var text_renderer = try text.TextRenderer.init(allocator, .{
        .font_path = "fonts/JetBrainsMono-Regular.ttf",
        .size = 24.0,
    });
    defer text_renderer.deinit();

    // 4. GPU Text Renderer initialisieren
    var text_gpu = try text.GPURenderer.init(
        allocator,
        renderer.device.?,
        renderer.queue.?,
        renderer.swap_chain_format,
        plat.getSize().width,
        plat.getSize().height,
    );
    defer text_gpu.deinit();

    // Atlas wird automatisch in renderText hochgeladen wenn Glyphen gerastert werden

    // 5. UI System initialisieren (Clay)
    var ui_system = try ui.UI.init(allocator, .{
        .font_size = 14.0,
    });
    defer ui_system.deinit();

    try ui_system.setupClay(plat.getSize().width, plat.getSize().height);

    // Start eine Test-Animation (2 Sekunden)
    _ = try ui_system.anim_manager.addAnimation(.scale_up, 2000.0);

    // 6. Clay Renderer initialisieren (WGPU)
    var clay_rdr = try clay_renderer_mod.ClayRenderer.init(
        allocator,
        renderer.device.?,
        renderer.queue.?,
        renderer.swap_chain_format,
        plat.getSize().width,
        plat.getSize().height,
    );
    defer clay_rdr.deinit();

    log.info("=== vulkan-ed ready ===", .{});
    log.info("Press Ctrl+C to exit (or close window)", .{});

    // Render Loop
    var frame_count: u32 = 0;
    while (plat.isRunning()) {
        // Event-basierter Render Loop mit wio.wait (Timeout für CPU-Effizienz)
        wio.wait(.{ .timeout_ns = 16 * std.time.ns_per_ms });
        wio.update();

        // UI updaten (Animationen) - ca. 60 FPS
        ui_system.update(16.0);

        // Theme alle 120 Frames wechseln (Beweis für Phase 5)
        if (frame_count % 240 == 120) {
            ui_system.theme = ui.Theme.light();
        } else if (frame_count % 240 == 0) {
            ui_system.theme = ui.Theme.dark();
        }

        // Events verarbeiten
        if (plat.window) |*win| {
            while (win.getEvent()) |event| {
                switch (event) {
                    .size_logical => |sz| {
                        renderer.resize(@intCast(sz.width), @intCast(sz.height)) catch {};
                        clay_rdr.setViewport(@intCast(sz.width), @intCast(sz.height));
                        text_gpu.setViewport(@intCast(sz.width), @intCast(sz.height));
                        ui_system.resize(@intCast(sz.width), @intCast(sz.height));
                    },
                    else => {},
                }
                plat.handleEventExternal(event);
            }
        }

        // Clay Layout berechnen
        const render_commands = ui_system.renderExample();

        // Rendern: Clear → Clay UI → Present
        renderer.renderFrameWithText(
            &clay_rdr,
            &text_gpu,
            &text_renderer,
            render_commands,
            "", // Kein extra Text
            0,
            0,
        );

        frame_count += 1;
    }

    log.info("=== vulkan-ed exiting ===", .{});
}

