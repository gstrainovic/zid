const std = @import("std");
const builtin = @import("builtin");
const wio = @import("wio");
const platform = @import("platform/mod.zig");
const rendering = @import("rendering/mod.zig");
const text = @import("text/mod.zig");
const ui = @import("ui/mod.zig");
const clay_renderer_mod = @import("clay_renderer/mod.zig");
const editor = @import("editor/mod.zig");
// const vkvg_mod = @import("vkvg/mod.zig"); // TODO: vkvg muss als System-Library installiert werden

const log = std.log.scoped(.main);

pub fn main() !void {
    // Allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // CLI Argumente parsen
    var theme_override: ?ui.Theme = null;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--theme")) {
            if (i + 1 < args.len) {
                i += 1;
                if (std.mem.eql(u8, args[i], "light")) {
                    theme_override = ui.Theme.light();
                    log.info("Theme override: light", .{});
                } else if (std.mem.eql(u8, args[i], "dark")) {
                    theme_override = ui.Theme.dark();
                    log.info("Theme override: dark", .{});
                }
            }
        }
    }

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

    // 2. Platform initialisieren (wio - NACH wgpu, vermeidet EGL-Konflikt)
    var plat = try platform.Platform.init(allocator, .{
        .title = "vulkan-ed",
        .width = 1200,
        .height = 800,
    });

    // defer wird REVERSE ausgeführt: plat.deinit() ZUERST geschrieben → ZULETZT ausgeführt
    defer plat.deinit();     // wird zuletzt ausgeführt (nach renderer)
    defer renderer.deinit(); // wird zuerst ausgeführt (vor plat)

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

    try ui_system.setupClay(plat.getSize().width, plat.getSize().height, &text_renderer);

    // Start Test-Animationen (3 Sekunden)
    _ = try ui_system.anim_manager.addAnimation(.fade_in, 3000.0);
    _ = try ui_system.anim_manager.addAnimation(.slide_in_left, 3000.0);
    _ = try ui_system.anim_manager.addAnimation(.scale_up, 3000.0);

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

    // TODO: vkvg Renderer (wenn vkvg installiert ist)
    // var vkvg_rdr = try vkvg_mod.Renderer.init(...);
    // defer vkvg_rdr.deinit();

    log.info("=== vulkan-ed ready ===", .{});
    log.info("Press Ctrl+C to exit (or close window)", .{});

    // Render Loop
    var frame_count: u32 = 0;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
    
    while (plat.isRunning()) {
        const delta_time_ms: f32 = 16.0;

        // Event-basierter Render Loop mit wio.wait (Timeout für CPU-Effizienz)
        wio.wait(.{ .timeout_ns = @intFromFloat(delta_time_ms * std.time.ns_per_ms) });
        wio.update();

        // UI updaten (Animationen) - ca. 60 FPS
        ui_system.update(delta_time_ms);

        // Theme-Wechsel für Verifizierung (0-300: Light, 301-600: Dark)
        const cycle_frames = 600;
        const current_cycle = frame_count % cycle_frames;
        if (theme_override) |t| {
            ui_system.theme = t;
        } else if (current_cycle < 300) {
            ui_system.theme = ui.Theme.light();
        } else {
            ui_system.theme = ui.Theme.dark();
        }

        // Events verarbeiten
        var scroll_delta_y: f32 = 0;
        if (plat.window) |*win| {
            while (win.getEvent()) |event| {
                switch (event) {
                    .size_logical => |sz| {
                        renderer.resize(@intCast(sz.width), @intCast(sz.height)) catch {};
                        clay_rdr.setViewport(@intCast(sz.width), @intCast(sz.height));
                        text_gpu.setViewport(@intCast(sz.width), @intCast(sz.height));
                        ui_system.resize(@intCast(sz.width), @intCast(sz.height));
                    },
                    .mouse => |pos| {
                        mouse_x = @floatFromInt(pos.x);
                        mouse_y = @floatFromInt(pos.y);
                    },
                    .button_press => |btn| {
                        if (btn == .mouse_left) mouse_down = true;
                    },
                    .button_release => |btn| {
                        if (btn == .mouse_left) mouse_down = false;
                    },
                    .scroll_vertical => |delta| {
                        scroll_delta_y = @floatCast(delta);
                    },
                    else => {},
                }
                plat.handleEventExternal(event);
            }
        }

        // Pointer-Status an Clay (immer pro Frame vor updateScroll)
        ui_system.setPointerState(mouse_x, mouse_y, mouse_down);
        
        // Scroll-Events an Clay (Scroll-Multiplikator 10.0 für bessere Geschwindigkeit)
        if (scroll_delta_y != 0) {
            ui_system.updateScroll(0, scroll_delta_y * 10.0, delta_time_ms);
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

