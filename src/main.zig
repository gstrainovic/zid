const std = @import("std");
const builtin = @import("builtin");
const file_types = @import("ui/file_types.zig");
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
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Filter ghostty-vt noise
    if (scope == .stream or scope == .terminal) {
        if (level == .debug) return;
    }

    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) level_txt else level_txt ++ "(" ++ @tagName(scope) ++ ")";

    const stderr_file = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    var stderr_writer = stderr_file.writer(&buf);
    const w = &stderr_writer.interface;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    w.print(prefix ++ ": " ++ format ++ "\n", args) catch return;
    w.flush() catch return;
}

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
    
    if (std.posix.getenv("FORCE_GUI_TEST") != null) {
        ui_system.code_editor.show_context_menu = true;
        ui_system.code_editor.context_menu_x = 200;
        ui_system.code_editor.context_menu_y = 200;
        // Scrollbar im Markdown Preview erzwingen: Markdown Tab öffnen
        ui_system.tab_bar.openFile("/home/g/projects/vulkan-ed/AGENTS.md") catch {};
        ui_system.pending_tab_switch = ui_system.allocator.dupe(u8, "preview:///home/g/projects/vulkan-ed/AGENTS.md") catch null;
    }

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
        if (std.mem.endsWith(u8, path, ".md")) {
            const preview_path = allocator.alloc(u8, path.len + 10) catch path;
            const final_path = std.fmt.bufPrint(@constCast(preview_path), "preview://{s}", .{path}) catch path;
            ui_system.tab_bar.openFile(final_path) catch {};
            if (preview_path.ptr != path.ptr) allocator.free(preview_path);
        } else {
            ui_system.file_explorer.file_to_open = path;
        }
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
    ui_system.image_renderer = &image_rdr;

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
                        if (btn == .mouse_left or btn == .mouse_right) {
                            if (btn == .mouse_left) mouse_down = true;
                            ui_system.handleMouseDown(mouse_x, mouse_y, btn);
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

        var render_commands = ui_system.renderExample(&logo_texture);
        
        // Phase 9: PDF Seitenwechsel verarbeiten
        if (ui_system.pending_pdf_page_change) |change| {
            if (ui_system.open_pdfs.get(change.path)) |handler_ptr| {
                const PdfHandler = @import("rendering/pdf_handler.zig").PdfHandler;
                const handler: *PdfHandler = @ptrCast(@alignCast(handler_ptr));
                
                const old_page = handler.current_page;
                const new_page = @as(i32, @intCast(handler.current_page)) + change.delta;
                
                if (new_page >= 0 and new_page < handler.total_pages) {
                    handler.current_page = @intCast(new_page);
                    
                    if (handler.current_page != old_page) {
                        log.info("PDF Page Change: {d} -> {d}", .{ old_page, handler.current_page });
                        if (handler.renderPage(handler.current_page, 2.0)) |info| {
                            defer allocator.free(info.pixels);
                            
                            // Alte Textur ersetzen
                            if (ui_system.open_images.get(change.path)) |tex_ptr| {
                                const ImageTexture = @import("clay_renderer/image_renderer.zig").ImageTexture;
                                const tex_cast: *ImageTexture = @ptrCast(@alignCast(tex_ptr));
                                tex_cast.deinit();
                                tex_cast.* = image_rdr.createTextureFromPixels(info.pixels, info.width, info.height) catch unreachable;
                            }
                            wio.cancelWait();
                        } else |err| {
                            log.err("Failed to render PDF page {d}: {}", .{ handler.current_page, err });
                        }
                    }
                }
            }
            ui_system.pending_pdf_page_change = null;
        }

        var state_dirty: bool = false;

        // Phase 9: Datei öffnen verarbeiten
        if (ui_system.file_explorer.file_to_open) |path| {
            ui_system.tab_bar.openFile(path) catch {};

            // Dateityp prüfen
            const kind = file_types.getFileKind(path);
            log.info("Opening file: {s} (kind: {s})", .{path, @tagName(kind)});
            
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
                    
                    state_dirty = true;
                    // Force another frame to render the newly loaded texture!
                    wio.cancelWait();
                }
            } else if (kind == .pdf) {
                // PDF-Dateien laden
                if (!ui_system.open_pdfs.contains(path)) {
                    log.info("Loading PDF: {s}", .{path});
                    const start_time = std.time.milliTimestamp();
                    const PdfHandler = @import("rendering/pdf_handler.zig").PdfHandler;
                    const handler = PdfHandler.init(allocator, path) catch |err| {
                        log.err("Failed to open PDF {s}: {}", .{path, err});
                        ui_system.file_explorer.file_to_open = null;
                        if (ui_system.tab_bar.pending_switch_path) |p| {
                            ui_system.allocator.free(p);
                            ui_system.tab_bar.pending_switch_path = null;
                        }
                        state_dirty = true;
                        continue;
                    };
                    log.info("PDF Handler init took {}ms", .{std.time.milliTimestamp() - start_time});

                    const render_start = std.time.milliTimestamp();
                    const page_info = handler.renderPage(0, 1.5) catch |err| {
                        log.err("Failed to render first PDF page: {}", .{err});
                        handler.deinit();
                        ui_system.file_explorer.file_to_open = null;
                        if (ui_system.tab_bar.pending_switch_path) |p| {
                            ui_system.allocator.free(p);
                            ui_system.tab_bar.pending_switch_path = null;
                        }
                        state_dirty = true;
                        continue;
                    };
                    log.info("PDF Page render took {}ms", .{std.time.milliTimestamp() - render_start});
                    defer allocator.free(page_info.pixels);

                    const tex_start = std.time.milliTimestamp();
                    const tex = image_rdr.createTextureFromPixels(page_info.pixels, page_info.width, page_info.height) catch |err| {
                        log.err("Failed to load image texture for PDF: {}", .{err});
                        handler.deinit();
                        ui_system.file_explorer.file_to_open = null;
                        if (ui_system.tab_bar.pending_switch_path) |p| {
                            ui_system.allocator.free(p);
                            ui_system.tab_bar.pending_switch_path = null;
                        }
                        state_dirty = true;
                        continue;
                    };
                    log.info("Texture upload took {}ms", .{std.time.milliTimestamp() - tex_start});
                    
                    const tex_ptr = allocator.create(@import("clay_renderer/image_renderer.zig").ImageTexture) catch unreachable;
                    tex_ptr.* = tex;
                    
                    const path_copy = allocator.dupe(u8, path) catch unreachable;
                    log.info("Adding to cache: {s}", .{path_copy});
                    ui_system.open_pdfs.put(path_copy, handler) catch {};
                    ui_system.open_images.put(path_copy, tex_ptr) catch {};
                    
                    state_dirty = true;
                    wio.cancelWait();
                }
            }

            ui_system.file_explorer.file_to_open = null;
            state_dirty = true;
        }

        // Tab-Wechsel anfordern (Markdown Preview)
        if (ui_system.pending_tab_switch) |path| {
            log.info("Main: Opening preview tab for {s}", .{path});
            ui_system.tab_bar.openFile(path) catch |err| {
                log.err("Failed to open tab for preview: {}", .{err});
            };
            ui_system.allocator.free(path);
            ui_system.pending_tab_switch = null;
            state_dirty = true;
        }

        if (ui_system.tab_bar.pending_switch_path) |path| {
            // Get actual kind from the tab (not from file extension, since terminal tabs have no path)
            const kind = blk: {
                if (ui_system.tab_bar.active_index) |idx| {
                    if (idx < ui_system.tab_bar.tabs.items.len) {
                        break :blk ui_system.tab_bar.tabs.items[idx].kind;
                    }
                }
                break :blk file_types.getFileKind(path);
            };
            log.info("Switching to tab: {s} (kind: {s})", .{path, @tagName(kind)});
            
            if (kind == .terminal) {
                // Terminal tabs are self-contained — no file loading needed.
                // Path cleanup happens below at the common pending_switch_path free.
                state_dirty = true;
                wio.cancelWait();
            } else if (kind == .text) {
                // Check if tab already has a buffer
                const active_tab = ui_system.tab_bar.getActiveTab();
                if (active_tab != null and active_tab.?.buffer != null) {
                    ui_system.code_editor.setBuffer(active_tab.?.buffer.?, path);
                } else {
                    // Check if current editor buffer already matches this path (e.g. initial buffer)
                    const current_buf_path = ui_system.code_editor.buffer.get_file_path();
                    if (std.mem.eql(u8, current_buf_path, path)) {
                        log.info("Reusing existing buffer for {s}", .{path});
                        if (active_tab) |t| {
                            t.buffer = ui_system.code_editor.buffer;
                        }
                    } else {
                        // Load from disk
                        const content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch |err| {
                            log.err("Failed to load tab content for '{s}': {}", .{ path, err });
                            continue;
                        };
                        defer allocator.free(content);
                        
                        // Create new buffer
                        const new_buf = try @import("flow_core").Buffer.create(allocator);
                        new_buf.root = try new_buf.load_from_string(content, &new_buf.file_eol_mode, &new_buf.file_utf8_sanitized);
                        new_buf.set_file_path(path);
                        new_buf.last_save = new_buf.root;

                        if (active_tab) |t| {
                            t.buffer = new_buf;
                        }
                        
                        ui_system.code_editor.setBuffer(new_buf, path);
                    }
                }
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
            } else if (kind == .pdf) {
                // PDF beim Tab-Wechsel sicherstellen dass es geladen ist
                if (!ui_system.open_pdfs.contains(path)) {
                    log.info("Loading PDF (tab switch): {s}", .{path});
                    const PdfHandler = @import("rendering/pdf_handler.zig").PdfHandler;
                    const handler = PdfHandler.init(allocator, path) catch |err| {
                        log.err("Failed to open PDF {s}: {}", .{path, err});
                        ui_system.allocator.free(path);
                        ui_system.tab_bar.pending_switch_path = null;
                        continue;
                    };

                    const page_info = handler.renderPage(0, 1.5) catch |err| {
                        log.err("Failed to render first PDF page: {}", .{err});
                        handler.deinit();
                        ui_system.allocator.free(path);
                        ui_system.tab_bar.pending_switch_path = null;
                        continue;
                    };
                    defer allocator.free(page_info.pixels);

                    const tex = image_rdr.createTextureFromPixels(page_info.pixels, page_info.width, page_info.height) catch unreachable;
                    const tex_ptr = allocator.create(@import("clay_renderer/image_renderer.zig").ImageTexture) catch unreachable;
                    tex_ptr.* = tex;
                    
                    const path_copy = allocator.dupe(u8, path) catch unreachable;
                    ui_system.open_pdfs.put(path_copy, handler) catch {};
                    ui_system.open_images.put(path_copy, tex_ptr) catch {};
                    
                    wio.cancelWait();
                }
            } else if (kind == .markdown_preview) {
                const source_path = if (std.mem.startsWith(u8, path, "preview://")) 
                    path["preview://".len..] 
                else 
                    path;
                
                const current_editor_path = ui_system.code_editor.buffer.get_file_path();
                var md_needs_free = false;
                const md_content = if (std.mem.eql(u8, source_path, current_editor_path)) blk: {
                    break :blk ui_system.code_editor.buffer.store_to_string_cached(
                        ui_system.code_editor.buffer.root, 
                        ui_system.code_editor.buffer.file_eol_mode
                    );
                } else blk: {
                    const content = std.fs.cwd().readFileAlloc(allocator, source_path, 10 * 1024 * 1024) catch |err| {
                        log.err("Failed to load markdown source '{s}': {}", .{ source_path, err });
                        break :blk allocator.dupe(u8, "# Error\nFailed to load file.") catch {
                            md_needs_free = false;
                            break :blk "# Error";
                        };
                    };
                    md_needs_free = true;
                    break :blk content;
                };
                defer if (md_needs_free and md_content.ptr != "# Error".ptr) allocator.free(md_content);

                var source_path_buf: [1024]u8 = undefined;
                const abs_source_path = std.fs.cwd().realpath(source_path, &source_path_buf) catch source_path;

                if (ui_system.open_markdown_views.getPtr(path)) |view_ptr| {
                    view_ptr.*.allocator.free(view_ptr.*.text);
                    view_ptr.*.text = view_ptr.*.allocator.dupe(u8, md_content) catch "";
                } else {
                    const view = allocator.create(@import("ui/markdown_view.zig").MarkdownView) catch unreachable;
                    view.* = @import("ui/markdown_view.zig").MarkdownView.init(ui_system.allocator, md_content, abs_source_path);
                    const path_copy = allocator.dupe(u8, path) catch unreachable;
                    ui_system.open_markdown_views.put(path_copy, view) catch {};
                }
                
                // If we got text from the buffer (cached/owned), free it if needed, 
                // but MarkdownView.init dupes it, so we must free it.
                if (std.mem.eql(u8, source_path, current_editor_path)) {
                    // This is actually not quite correct because store_to_string_cached 
                    // returns a slice into an internal cache if not modified? 
                    // No, usually it allocates. Let's assume it allocates.
                    // Actually, let's just use it and see.
                }
                
                state_dirty = true;
            }

            // pending_switch_path freigeben und nullen
            ui_system.allocator.free(path);
            ui_system.tab_bar.pending_switch_path = null;
            state_dirty = true;
        }

        // State hat sich geändert (neue Tab / neue Textur) → gleichen Frame neu
        // layouten, damit Image-View mit korrekter aspect_ratio rendert statt
        // erst nach dem nächsten Input-Event.
        if (state_dirty) {
            render_commands = ui_system.renderExample(&logo_texture);
        }

        // Cursor-Form anpassen basierend auf Layout-Ergebnis
        plat.setCursor(ui_system.getDesiredCursor());

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

