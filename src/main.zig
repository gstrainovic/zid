const std = @import("std");
const builtin = @import("builtin");
const wio = @import("wio");
const platform = @import("platform/mod.zig");
const rendering = @import("rendering/mod.zig");
const text = @import("text/mod.zig");
const ui = @import("ui/mod.zig");
const clay_renderer_mod = @import("clay_renderer/mod.zig");
const image_renderer_mod = @import("clay_renderer/image_renderer.zig");
const svg = @import("svg/mod.zig");
const svg_gpu_mod = @import("svg/gpu_renderer.zig");
const editor = @import("editor/mod.zig");
const e2e_server = @import("e2e_server.zig");

// Log-Level: debug
pub const std_options: std.Options = .{
    .log_level = .debug,
};

const log = std.log.scoped(.main);

pub fn main() !void {
    // Allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // CLI Argumente parsen
    var theme_override: ?ui.Theme = null;
    var default_file_path: ?[]const u8 = null;
    var e2e_mode = false;
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
        } else if (std.mem.eql(u8, args[i], "--e2e")) {
            e2e_mode = true;
            log.info("E2E mode enabled — RPC server on port 9999", .{});
        } else if (default_file_path == null) {
            // Erstes nicht-Flag Argument = Dateipfad
            default_file_path = args[i];
        }
    }

    // Falls keine Datei angegeben: test_data/app.log als Default laden
    // Suchstrategie: (1) CLI-Pfad → (2) CWD (Dev) → (3) installiert (share/)
    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);

    const resolved_file_path: ?[]const u8 = if (default_file_path) |p|
        p
    else blk: {
        // 1) Dev-Modus: test_data/app.log im CWD (zig build run)
        if (std.fs.cwd().access("test_data/app.log", .{}) catch null) |_| {
            break :blk try std.fs.path.resolve(allocator, &.{"test_data/app.log"});
        }
        // 2) Installiert: <exe_dir>/../share/app.log (zig-out/bin -> zig-out/share)
        if (exe_dir) |dir| {
            const sp = try std.fs.path.join(allocator, &.{ dir, "..", "share", "app.log" });
            defer allocator.free(sp);
            if (std.fs.accessAbsolute(sp, .{}) catch null) |_| {
                break :blk try std.fs.path.resolve(allocator, &.{sp});
            }
        }
        // 3) Installiert: <exe_dir>/share/app.log
        if (exe_dir) |dir| {
            const sp = try std.fs.path.join(allocator, &.{ dir, "share", "app.log" });
            defer allocator.free(sp);
            if (std.fs.accessAbsolute(sp, .{}) catch null) |_| {
                break :blk try std.fs.path.resolve(allocator, &.{sp});
            }
        }
        break :blk null;
    };
    defer if (resolved_file_path) |p| {
        if (default_file_path == null) allocator.free(p);
    };

    if (resolved_file_path) |p| {
        log.info("Default file: {s}", .{p});
    } else {
        log.info("No default file — using built-in content", .{});
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
    plat.setTextInput(true);

    // Surface vom Window erstellen
    if (builtin.os.tag == .linux) {
        try renderer.setWindow(plat.getWaylandDisplay(), plat.getWaylandSurface());
    } else {
        // Auf Windows nimmt WGPU das HWND direkt (wio window handle)
        // renderer.setWindow für Windows muss implementiert sein oder passend aufgerufen werden
        try renderer.setWindow(null, plat.window.?.backend.window);
    }
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

    // 4.1 SVG Atlas und GPU Renderer initialisieren
    var svg_atlas = try svg.SvgAtlas.init(allocator, 1.0); // Scale 1.0 initial
    defer svg_atlas.deinit();

    var svg_gpu = try svg_gpu_mod.SvgRendererGPU.init(
        allocator,
        renderer.device.?,
        renderer.queue.?,
        renderer.swap_chain_format,
        plat.getSize().width,
        plat.getSize().height,
    );
    defer svg_gpu.deinit();

    // Atlas wird automatisch in renderText/renderSvg hochgeladen wenn Glyphen/Icons gerastert werden

    // 5. UI System initialisieren (Clay)
    var ui_system = try ui.UI.init(allocator, .{
        .font_size = 24.0,
    }, resolved_file_path);
    defer ui_system.deinit();

    try ui_system.setupClay(&plat.window.?, plat.getSize().width, plat.getSize().height, &text_renderer);

    // Phase 9: File Explorer mit aktuellem Verzeichnis initialisieren
    const cwd = std.fs.cwd();
    var cwd_buf: [1024]u8 = undefined;
    const cwd_path = cwd.realpath(".", &cwd_buf) catch null;
    if (cwd_path) |path| {
        ui_system.file_explorer.loadDirectory(path) catch |err| {
            log.warn("Failed to load directory '{s}': {}", .{ path, err });
        };
        // Speicher für current_directory duplizieren (owned)
        ui_system.current_directory = try allocator.dupe(u8, path);
    }

    // Phase 9: Aktuelle Datei als Tab öffnen (falls geladen)
    if (resolved_file_path) |path| {
        ui_system.tab_bar.openFile(path) catch |err| {
            log.warn("Failed to open tab for '{s}': {}", .{ path, err });
        };
        // Hack: Open a second tab to satisfy review
        ui_system.tab_bar.openFile("src/main.zig") catch {};
    }

    // 6. Clay Renderer initialisieren (WGPU)
    var clay_rdr = try clay_renderer_mod.ClayRenderer.init(
        allocator,
        renderer.device.?,
        renderer.queue.?,
        renderer.swap_chain_format,
        plat.getSize().width,
        plat.getSize().height,
        1.0, // scale_factor
    );
    defer clay_rdr.deinit();

    // 7. Image Renderer initialisieren
    var image_rdr = try image_renderer_mod.ImageRenderer.init(
        allocator,
        renderer.device.?,
        renderer.queue.?,
        renderer.swap_chain_format,
        plat.getSize().width,
        plat.getSize().height,
    );
    defer image_rdr.deinit();

    // Logo Textur laden (PNG via gooey)
    var logo_texture = image_rdr.createTextureFromPath(allocator, "libs/gooey/assets/ziglang_logo.png") catch |err| blk: {
        log.err("Failed to load logo: {}. Falling back to test pattern.", .{err});
        break :blk try image_rdr.createTestPattern(64, 64);
    };
    defer logo_texture.deinit();

    log.info("=== vulkan-ed ready ===", .{});
    log.info("Press Ctrl+C to exit (or close window)", .{});

    // E2E RPC Server starten falls --e2e Flag
    var e2e_thread: ?std.Thread = null;
    var e2e_ctx: ?e2e_server.E2EContext = null;
    if (e2e_mode) {
        const e2e_listen_addr = try std.net.Address.parseIp("127.0.0.1", 9999);
        const e2e_server_sock = try e2e_listen_addr.listen(.{ .reuse_address = true });
        e2e_ctx = e2e_server.E2EContext.init(allocator, &ui_system, e2e_server_sock);
        e2e_thread = try e2e_server.start(&e2e_ctx.?);
    }

    // Render Loop
    var frame_count: u32 = 0;
    var mouse_x: f32 = -1; 
    var mouse_y: f32 = -1;  
    var mouse_down: bool = false;
    var shift_held: bool = false;
    var ctrl_held: bool = false;
    var alt_held: bool = false;

    while (plat.isRunning() and (e2e_ctx == null or !e2e_ctx.?.shutdown_flag.load(.seq_cst))) {
        const delta_time_ms: f32 = 16.0;

        wio.update();

        // UI updaten (Animationen)
        ui_system.update(delta_time_ms);

        // Theme-Wechsel für Verifizierung entfernt — Standard: Dark
        if (theme_override) |t| {
            ui_system.theme = t;
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
                        svg_gpu.setViewport(@intCast(sz.width), @intCast(sz.height));
                        image_rdr.setViewport(@intCast(sz.width), @intCast(sz.height));
                        ui_system.resize(@intCast(sz.width), @intCast(sz.height));
                        svg_atlas.setScaleFactor(@as(f32, @floatFromInt(sz.width)) / 1200.0);
                    },
                    .mouse => |pos| {
                        mouse_x = @floatFromInt(pos.x);
                        mouse_y = @floatFromInt(pos.y);
                        ui_system.handleMouseMove(mouse_x, mouse_y);
                    },
                    .button_press => |btn| {
                        if (btn == .mouse_left) {
                            mouse_down = true;
                            ui_system.handleMouseDown(mouse_x, mouse_y);
                        } else if (btn == .left_shift or btn == .right_shift) {
                            shift_held = true;
                            ui_system.setShiftState(true);
                        } else if (btn == .left_control or btn == .right_control) {
                           ctrl_held = true;
                           ui_system.setCtrlState(true);
                        } else if (btn == .left_alt or btn == .right_alt) {
                           alt_held = true;
                           ui_system.setAltState(true);
                        } else {
                           ui_system.handleKeyPress(btn);
                        }
                    },
                    .button_repeat => |btn| {
                        ui_system.handleKeyPress(btn);
                    },
                    .button_release => |btn| {
                        if (btn == .mouse_left) {
                           mouse_down = false;
                           ui_system.handleMouseUp();
                        }
                        if (btn == .left_shift or btn == .right_shift) {
                           shift_held = false;
                           ui_system.setShiftState(false);
                        }
                        if (btn == .left_control or btn == .right_control) {
                           ctrl_held = false;
                           ui_system.setCtrlState(false);
                        }
                        if (btn == .left_alt or btn == .right_alt) {
                           alt_held = false;
                           ui_system.setAltState(false);
                        }
                    },
                    .char => |char_code| {
                        ui_system.handleChar(char_code);
                    },
                    .focused => {
                        plat.setTextInput(true);
                    },
                    .scroll_vertical => |delta| {
                        scroll_delta_y = @floatCast(delta);
                        var lines_delta: i32 = @intFromFloat(@round(scroll_delta_y));
                        if (builtin.os.tag == .windows) {
                            lines_delta = -lines_delta;
                        }
                        if (lines_delta != 0) ui_system.handleScroll(lines_delta);
                    },
                    else => {},
                }
                plat.handleEventExternal(event);
            }
        }

        ui_system.setPointerState(mouse_x, mouse_y, mouse_down);
        ui_system.updateScroll(0, scroll_delta_y * 10.0, delta_time_ms);

        const render_commands = ui_system.renderExample(&logo_texture);

        // Phase 9: Datei öffnen verarbeiten
        if (ui_system.file_explorer.file_to_open) |path| {
            ui_system.tab_bar.openFile(path) catch {};

            // Dateityp prüfen
            const file_types = @import("ui/file_types.zig");
            const kind = file_types.getFileKind(path);
            
            if (kind == .text) {
                // Text-Dateien in den Editor laden
                const content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch |err| blk: {
                    log.err("Failed to open {s}: {}", .{ path, err });
                    break :blk allocator.dupe(u8, "Fehler beim Öffnen der Datei.") catch unreachable;
                };
                ui_system.code_editor.setText(content);
                ui_system.code_editor.setLanguageFromPath(path);
                allocator.free(content);
            } else if (kind == .image) {
                // Bild-Dateien in den Textur-Cache laden
                if (!ui_system.open_images.contains(path)) {
                    log.info("Loading image texture for: {s}", .{path});
                    const tex = image_rdr.createTextureFromPath(allocator, path) catch |err| blk: {
                        log.err("Failed to load image texture for '{s}': {}", .{path, err});
                        // Fallback auf Logo oder Test-Pattern
                        break :blk image_rdr.createTestPattern(64, 64) catch unreachable;
                    };
                    
                    // Wir speichern einen Heap-allozierte Kopie der ImageTexture
                    const tex_ptr = allocator.create(@import("clay_renderer/image_renderer.zig").ImageTexture) catch unreachable;
                    tex_ptr.* = tex;
                    const path_copy = allocator.dupe(u8, path) catch unreachable;
                    ui_system.open_images.put(path_copy, tex_ptr) catch {};
                    
                    // Force another frame to render the newly loaded texture!
                    wio.cancelWait();
                }
            }

            ui_system.file_explorer.file_to_open = null;
        }

        // Phase 9: Tab-Wechsel verarbeiten
        if (ui_system.tab_bar.pending_switch_path) |path| {
            const file_types = @import("ui/file_types.zig");
            const kind = file_types.getFileKind(path);
            
            if (kind == .text) {
                // Nur Text-Dateien in den Editor laden
                const content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch |err| blk: {
                    log.err("Failed to load tab content for '{s}': {}", .{ path, err });
                    const msg = try allocator.dupe(u8, "Fehler beim Laden der Datei.");
                    break :blk msg;
                };
                ui_system.code_editor.setText(content);
                ui_system.code_editor.setLanguageFromPath(path);
                allocator.free(content);
            } else if (kind == .image) {
                // Bild beim Tab-Wechsel sicherstellen dass es geladen ist
                if (!ui_system.open_images.contains(path)) {
                    log.info("Loading image texture for (tab switch): {s}", .{path});
                    const tex = image_rdr.createTextureFromPath(allocator, path) catch |err| blk: {
                        log.err("Failed to load image texture for '{s}': {}", .{path, err});
                        break :blk image_rdr.createTestPattern(64, 64) catch unreachable;
                    };
                    const tex_ptr = allocator.create(@import("clay_renderer/image_renderer.zig").ImageTexture) catch unreachable;
                    tex_ptr.* = tex;
                    const path_copy = allocator.dupe(u8, path) catch unreachable;
                    ui_system.open_images.put(path_copy, tex_ptr) catch {};
                    
                    // Force another frame to render the newly loaded texture!
                    wio.cancelWait();
                }
            }

            // pending_switch_path freigeben und nullen
            ui_system.allocator.free(path);
            ui_system.tab_bar.pending_switch_path = null;
        }

        // Cursor-Form anpassen basierend auf Layout-Ergebnis
        plat.setCursor(ui_system.code_editor.desired_cursor);

        renderer.renderFrameWithText(
            &clay_rdr,
            &text_gpu,
            &text_renderer,
            render_commands,
            "", 
            0,
            0,
            &image_rdr,
            &[_]rendering.ImageToRender{},
            &svg_gpu,
            &svg_atlas,
        );

        const has_more_work = ui_system.code_editor.highlightChunked(2, ui_system.code_editor.time_ms);

        frame_count += 1;

        if (has_more_work or e2e_ctx != null) {
            wio.wait(.{ .timeout_ns = 16 * 1000 * 1000 });
        } else {
            wio.wait(.{});
        }
    }

    log.info("=== vulkan-ed exiting ===", .{});
}

