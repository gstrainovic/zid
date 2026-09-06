const std = @import("std");
const builtin = @import("builtin");
const file_types = @import("ui/file_types.zig");
const wio = @import("wio");
const platform = @import("platform/mod.zig");
const rendering = @import("rendering/mod.zig");
const text = @import("text/mod.zig");
const ui = @import("ui/mod.zig");
const PaneT = @import("ui/pane.zig").Pane;
const clay_renderer_mod = @import("clay_renderer/mod.zig");
const image_renderer_mod = @import("clay_renderer/image_renderer.zig");
const svg = @import("svg/mod.zig");
const svg_gpu_mod = @import("svg/gpu_renderer.zig");
const editor = @import("editor/mod.zig");
const e2e_server = @import("e2e_server.zig");
const e2e_interactive = @import("e2e_interactive.zig");
const async_mod = @import("scheduler");
const git_worker = @import("git_worker");
const file_watcher_mod = @import("file_watcher");
const lsp_client_mod = @import("lsp_client");

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
    // Debug-Zeilen nur mit VULKAN_ED_DEBUG=1: ohne Filter sind es tausende Zeilen
    // pro Sitzung (jeder Tastendruck, jedes Resize, jeder Frame-Klick).
    if (level == .debug and !debugLogEnabled()) return;

    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) level_txt else level_txt ++ "(" ++ @tagName(scope) ++ ")";

    const stderr_file = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    // writerStreaming: File.writer() schreibt positional ab Offset 0 und
    // überschreibt bei umgeleitetem stderr (2>log) laufend den Dateianfang.
    var stderr_writer = stderr_file.writerStreaming(&buf);
    const w = &stderr_writer.interface;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    w.print(prefix ++ ": " ++ format ++ "\n", args) catch return;
    w.flush() catch return;
}

const log = std.log.scoped(.main);

var debug_log_state: enum { unknown, off, on } = .unknown;

fn debugLogEnabled() bool {
    if (debug_log_state == .unknown) {
        debug_log_state = if (std.posix.getenv("VULKAN_ED_DEBUG")) |v| (if (v.len > 0 and v[0] != '0') .on else .off) else .off;
    }
    return debug_log_state == .on;
}

pub fn main() !void {
    // Allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // CLI Argumente parsen
    var theme_override: ?ui.Theme = null;
    var default_file_path: ?[]const u8 = null;
    var e2e_mode = false;
    var headless_mode = false;
    var interactive_mode = false;
    var ai_disabled = false;
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
        } else if (std.mem.eql(u8, args[i], "--headless")) {
            headless_mode = true;
            e2e_mode = true;
            log.info("Headless mode enabled — no window, screenshots possible via RPC on port 9999", .{});
        } else if (std.mem.eql(u8, args[i], "--interactive")) {
            interactive_mode = true;
            headless_mode = true;
            e2e_mode = true;
            log.info("Interactive mode enabled — stdin/stdout command interface", .{});
        } else if (std.mem.eql(u8, args[i], "--ai=off")) {
            ai_disabled = true;
            log.info("AI disabled via --ai=off", .{});
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var buf: [4096]u8 = undefined;
            var stdout_f = std.fs.File.stdout();
            var stdout_writer = stdout_f.writer(&buf);
            const w = &stdout_writer.interface;
            try w.writeAll("Usage: vulkan-ed [OPTIONS] [FILE]\n\n");
            try w.writeAll("Options:\n");
            try w.writeAll("  --theme light|dark    Override theme\n");
            try w.writeAll("  --e2e                 Enable E2E mode (RPC on port 9999)\n");
            try w.writeAll("  --headless            Headless mode (no window, screenshots via RPC on port 9999)\n");
            try w.writeAll("  --interactive         Interactive mode (stdin/stdout command interface)\n");
            try w.writeAll("  --ai=off              Disable AI chat (llama-server)\n");
            try w.writeAll("  --help, -h            Show this help\n");
            try w.writeAll("\nEnvironment:\n");
            try w.writeAll("  VULKAN_ED_DEBUG=1     Enable debug log lines\n");
            try w.writeAll("  LLAMA_SERVER_PATH     llama-server binary (default: ollama)\n");
            try w.writeAll("  LLAMA_MODEL_PATH      GGUF path or Ollama model (default: gemma4:e2b)\n");
            try w.flush();
            return;
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
        // 1) Dev-Modus: test_data/syntax_test.md im CWD
        if (std.fs.cwd().access("test_data/syntax_test.md", .{}) catch null) |_| {
            break :blk try std.fs.path.resolve(allocator, &.{"test_data/syntax_test.md"});
        }
        // 2) Installiert: <exe_dir>/../share/README.md (zig-out/bin -> zig-out/share)
        if (exe_dir) |dir| {
            const sp = try std.fs.path.join(allocator, &.{ dir, "..", "share", "test_data/syntax_test.md" });
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
    // ACHTUNG: renderer.deinit() und plat.deinit() MÜSSEN in korrekter
    // Reihenfolge laufen — Vulkan-Driver greift in Surface-Cleanup noch
    // auf Wayland-Objekte zu. Erst renderer (WGPU/Vulkan), dann plat
    // (Wayland). Wird am Ende der Funktion explizit gemacht.
    var renderer_owned = true;
    defer if (renderer_owned) renderer.deinit();
    rendering.Renderer.g_renderer_ptr = &renderer;

    // 2. Platform initialisieren (wio - NACH wgpu, vermeidet EGL-Konflikt)
    // Headless: kein Platform/Window/Surface nötig
    var plat: platform.Platform = if (headless_mode) undefined else try platform.Platform.init(allocator, .{
        .title = "vulkan-ed",
        .width = 1200,
        .height = 800,
    });

    // Headless: use default viewport dimensions
    const viewport_width: u32 = if (headless_mode) 1200 else plat.getSize().width;
    const viewport_height: u32 = if (headless_mode) 800 else plat.getSize().height;

    // defer cleanup — gewrapped mit Flag, da Reihenfolge am Exit manuell
    // nach renderer.deinit() erzwungen wird (Vulkan braucht Wayland-Surface
    // noch beim device-destroy).
    var plat_owned = true;
    defer if (plat_owned and !headless_mode) plat.deinit();

    // Alle GPU-Ressourcen in einem inneren Scope, damit ihre defers am
    // Scope-Ende laufen — BEVOR wir renderer.deinit() und plat.deinit()
    // in korrekter Reihenfolge manuell triggern. Ohne diesen Scope würden
    // die defers in falscher Reihenfolge laufen und Vulkan/Wayland
    // crashen (use-after-destroy der Wayland-Surface).
    {

    // Window erstellen (NACH renderer) - Headless: kein Window nötig
    if (!headless_mode) {
        try plat.createWindow();
        plat.setTextInput(true);

        // Surface vom Window erstellen
        if (builtin.os.tag == .linux) {
            try renderer.setWindow(plat.getWaylandDisplay(), plat.getWaylandSurface());
        } else {
            // Auf Windows nimmt WGPU das HWND direkt (wio window handle)
            try renderer.setWindow(null, plat.window.?.backend.window);
        }
        try renderer.configureSwapChain(plat.getSize().width, plat.getSize().height);
    }

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
        viewport_width,
        viewport_height,
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
        viewport_width,
        viewport_height,
    );
    defer svg_gpu.deinit();

    // Atlas wird automatisch in renderText/renderSvg hochgeladen wenn Glyphen/Icons gerastert werden

    // 5. UI System initialisieren (Clay)
    var ui_system = try ui.UI.init(allocator, .{
        .font_size = 24.0,
        .ai_disabled = ai_disabled,
    }, resolved_file_path);
    defer ui_system.deinit();

    try ui_system.setupClay(plat.window_ptr, viewport_width, viewport_height, &text_renderer);
    ui_system.loadUserState();
    // --theme light|dark überstimmt den gemerkten Zustand (einmalig; vorher wurde das Theme
    // in jedem Frame auf Dark gesetzt und der Umschalter griff nie)
    if (theme_override) |t| {
        ui_system.theme = t;
        ui_system.applyThemeToEditors();
    }

    const force_gui_test = if (std.process.getEnvVarOwned(allocator, "FORCE_GUI_TEST")) |val| blk: {
        allocator.free(val);
        break :blk true;
    } else |_| false;
    if (force_gui_test) {
        ui_system.getActiveEditor().show_context_menu = true;
        ui_system.getActiveEditor().context_menu_x = 200;
        ui_system.getActiveEditor().context_menu_y = 200;
        // Scrollbar im Markdown Preview erzwingen: Markdown Tab öffnen
        ui_system.getActiveTabBar().openFile("/home/g/projects/vulkan-ed/AGENTS.md") catch {};
        ui_system.pending_tab_switch = ui_system.allocator.dupe(u8, "preview:///home/g/projects/vulkan-ed/AGENTS.md") catch null;
    }

    // Scheduler für async Git/LSP/FileWatcher/AI Tasks
    var scheduler = try async_mod.Scheduler.init(allocator, 4);
    defer scheduler.deinit();

    ui_system.setAIScheduler(scheduler);

    // File Watcher (inotify auf Linux)
    var watcher: ?*file_watcher_mod.FileWatcher = null;
    // Datei-Ereignisse kommen in Bursts (ein Schreibvorgang = hunderte IN_MODIFY).
    // Ein git-status-Task pro Fenster reicht, sonst läuft die Work-Queue voll.
    var git_refresh = async_mod.Debounce{ .delay_ms = 300 };
    defer if (watcher) |w| w.deinit();

    // Phase 9: File Explorer mit aktuellem Verzeichnis initialisieren
    const cwd = std.fs.cwd();
    var cwd_buf: [1024]u8 = undefined;
    const cwd_path = cwd.realpath(".", &cwd_buf) catch null;
    var git_repo_path: ?[]u8 = null;
    defer if (git_repo_path) |p| allocator.free(p);
    if (cwd_path) |path| {
        try openProjectFolder(allocator, &ui_system, scheduler, &watcher, &git_repo_path, path);
    }

    // Phase 9: Aktuelle Datei als Tab öffnen (falls geladen)
    if (resolved_file_path) |path| {
        if (std.mem.endsWith(u8, path, ".md")) {
            const preview_path = allocator.alloc(u8, path.len + 10) catch path;
            const final_path = std.fmt.bufPrint(@constCast(preview_path), "preview://{s}", .{path}) catch path;
            ui_system.getActiveTabBar().openFile(final_path) catch {};
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
        viewport_width,
        viewport_height,
        1.0, // scale_factor
    );
    defer clay_rdr.deinit();

    // 7. Image Renderer initialisieren
    var image_rdr = try image_renderer_mod.ImageRenderer.init(
        allocator,
        renderer.device.?,
        renderer.queue.?,
        renderer.swap_chain_format,
        viewport_width,
        viewport_height,
    );
    defer image_rdr.deinit();
    ui_system.image_renderer = &image_rdr;

    // Logo Textur laden (PNG via gooey)
    var logo_texture = image_rdr.createTextureFromPath(allocator, "libs/gooey/assets/ziglang_logo.png") catch |err| blk: {
        log.err("Failed to load logo: {}. Falling back to test pattern.", .{err});
        break :blk try image_rdr.createTestPattern(64, 64);
    };
    defer logo_texture.deinit();

    // Headless: globals für screenshot
    rendering.Renderer.g_clay_rdr = @ptrCast(&clay_rdr);
    rendering.Renderer.g_text_gpu = @ptrCast(&text_gpu);
    rendering.Renderer.g_text_renderer = @ptrCast(&text_renderer);
    rendering.Renderer.g_image_rdr = @ptrCast(&image_rdr);
    rendering.Renderer.g_svg_gpu = @ptrCast(&svg_gpu);
    rendering.Renderer.g_svg_atlas = @ptrCast(&svg_atlas);
    rendering.Renderer.g_viewport_width = viewport_width;
    rendering.Renderer.g_viewport_height = viewport_height;
    renderer.width = viewport_width;
    renderer.height = viewport_height;

    log.info("=== vulkan-ed ready ===", .{});
    log.info("Press Ctrl+C to exit (or close window)", .{});

    // E2E RPC Server starten falls --e2e Flag
    var e2e_thread: ?std.Thread = null;
    var e2e_ctx: ?e2e_server.E2EContext = null;
    if (e2e_mode) {
        const e2e_listen_addr = try std.net.Address.parseIp("127.0.0.1", 9999);
        const e2e_server_sock = try e2e_listen_addr.listen(.{ .reuse_address = true });
        e2e_ctx = e2e_server.E2EContext.init(allocator, &ui_system, e2e_server_sock);
        // Fenstermodus: RPC-Eingaben puffern, der Main-Loop wendet sie pro Frame an.
        e2e_ctx.?.defer_input = !interactive_mode;
        e2e_thread = try e2e_server.start(&e2e_ctx.?);
    }
    defer if (e2e_ctx) |*c| c.deinit();

    // Interactive mode (stdin/stdout) hat keinen Frame-Loop: Handler laufen direkt.
    if (headless_mode and interactive_mode) {
        log.info("=== vulkan-ed headless ready ===", .{});
        log.info("Interactive mode — stdin/stdout command interface", .{});
        e2e_interactive.runInteractiveLoop(&e2e_ctx.?);
        log.info("Interactive mode ended", .{});
        return;
    }
    if (headless_mode) log.info("=== vulkan-ed headless ready — frame loop without window, RPC on port 9999 ===", .{});

    // Render Loop
    var frame_count: u32 = 0;
    var mouse_x: f32 = -1; 
    var mouse_y: f32 = -1;  
    var mouse_down: bool = false;
    var shift_held: bool = false;
    var ctrl_held: bool = false;
    var alt_held: bool = false;

    // Headless und Fenster teilen sich diesen Loop. Headless hat keine Plattform:
    // keine Fenster-Events, kein Cursor, keine Präsentation, Polling statt wio.wait.
    while ((headless_mode or plat.isRunning()) and (e2e_ctx == null or !e2e_ctx.?.shutdown_flag.load(.seq_cst))) {
        if (e2e_ctx) |*c| e2e_server.drainInputs(c);
        const delta_time_ms: f32 = 16.0;
        const frame_t0 = std.time.nanoTimestamp();

        if (!headless_mode) wio.update();

        // Async Results verarbeiten (non-blocking)
        {
            var result_buf: [32]async_mod.TaskResult = undefined;
            const results = scheduler.pollResults(&result_buf);
            for (results) |result| {
                defer result.deinit();
                switch (result.tag) {
                    .git_branch => ui_system.updateBranch(result.payload),
                    .git_status => ui_system.updateGitStatus(result.payload),
                    .ai_chat_reply => ui_system.handleAIReply(result.payload),
                    .ai_chat_error => ui_system.handleAIError(result.payload),
                    .ai_chat_delta => ui_system.handleAIDelta(result.payload),
                    .ai_chat_cancelled => ui_system.handleAICancelled(result.payload),
                    .ai_chat_tool_calls => ui_system.handleAIToolCalls(result.payload),
                    .ai_warmup_done => ui_system.handleAIWarmupDone(),
                    .ai_warmup_error => ui_system.handleAIWarmupError(result.payload),
                    .ai_download_done => ui_system.handleAIDownloadDone(),
                    .ai_download_error => ui_system.handleAIDownloadError(result.payload),
                    .lsp_definition => ui_system.handleLspDefinition(result.payload),
                    .file_changed, .file_created, .file_deleted => {
                        log.debug("file event: {} for {s}", .{ result.tag, result.payload });
                        git_refresh.mark(std.time.milliTimestamp());
                        if (result.tag == .file_changed) ui_system.handleExternalChange(result.payload);
                    },
                    else => {},
                }
            }
            if (results.len > 0) wio.cancelWait();
            submitGitStatusIfDue(&git_refresh, scheduler, allocator, git_repo_path);
        }

        // UI updaten (Animationen)
        ui_system.update(delta_time_ms);

        // "Open Folder…" bestätigt: Explorer, Git und Watcher auf den neuen Ordner umstellen
        if (ui_system.takePendingOpenFolder()) |new_root| {
            defer allocator.free(new_root);
            openProjectFolder(allocator, &ui_system, scheduler, &watcher, &git_repo_path, new_root) catch |err| {
                log.err("open folder '{s}' failed: {}", .{ new_root, err });
            };
        }

        // Events verarbeiten
        var scroll_delta_y: f32 = 0;
        const event_window: ?*wio.Window = if (headless_mode) null else (if (plat.window) |*w| w else null);
        if (event_window) |win| {
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
                        log.debug("button_press: btn={}", .{btn});
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
                    .scroll_horizontal => |delta| {
                        const cols_delta: i32 = @intFromFloat(@round(@as(f32, @floatCast(delta)) * 4));
                        if (cols_delta != 0) ui_system.handleScrollHorizontal(-cols_delta);
                    },
                    else => {},
                }
                plat.handleEventExternal(event);
            }
        }

        // Pointer-Position aus der UI: enthält auch Positionen aus gepufferten
        // RPC-Eingaben (headless), nicht nur aus Fenster-Events.
        ui_system.setPointerState(ui_system.mouse_x, ui_system.mouse_y, mouse_down or ui_system.is_mouse_down);
        ui_system.updateScroll(0, scroll_delta_y * 10.0, delta_time_ms);

        var render_commands = ui_system.renderExample(&logo_texture);
        if (e2e_ctx) |*c| e2e_server.serviceScreenshot(c, render_commands);
        
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
            ui_system.getActiveTabBar().openFileAs(path, ui_system.file_explorer.file_to_open_preview and ui_system.preview_tabs) catch {};
            ui_system.file_explorer.file_to_open_preview = false;

            // Dateityp prüfen
            const kind = file_types.detectFileKind(path);
            log.debug("Opening file: {s} (kind: {s})", .{path, @tagName(kind)});
            
            if (kind == .text) {
                // Nichts zu tun: openFile → setActive → pending_switch_path, und der
                // Tab-Wechsel unten lädt den Buffer über getOrCreateBuffer. Früher stand
                // hier ein setText in den *aktuellen* Buffer, also den der vorher aktiven
                // Datei — die galt danach als geändert und zeigte fremden Inhalt.
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
                        if (ui_system.getActiveTabBar().pending_switch_path) |p| {
                            ui_system.allocator.free(p);
                            ui_system.getActiveTabBar().pending_switch_path = null;
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
                        if (ui_system.getActiveTabBar().pending_switch_path) |p| {
                            ui_system.allocator.free(p);
                            ui_system.getActiveTabBar().pending_switch_path = null;
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
                        if (ui_system.getActiveTabBar().pending_switch_path) |p| {
                            ui_system.allocator.free(p);
                            ui_system.getActiveTabBar().pending_switch_path = null;
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
            log.debug("Main: Opening preview tab for {s}", .{path});
            ui_system.getActiveTabBar().openFile(path) catch |err| {
                log.err("Failed to open tab for preview: {}", .{err});
            };
            ui_system.allocator.free(path);
            ui_system.pending_tab_switch = null;
            state_dirty = true;
        }

        // Tab-Wechsel für JEDES Pane abarbeiten, nicht nur das aktive: der Agent öffnet
        // Dateien im Nachbar-Pane und lässt den Fokus im Chat. Der Block arbeitet über
        // getActiveTabBar()/getActiveEditor(), deshalb wird active_pane pro Leaf kurz
        // umgebogen und per defer wiederhergestellt (auch bei `continue`).
        var switch_leaves_buf: [32]*PaneT = undefined;
        for (ui_system.leavesWithPendingSwitch(&switch_leaves_buf)) |switch_leaf| {
        const saved_active_pane = ui_system.active_pane;
        ui_system.active_pane = switch_leaf;
        defer ui_system.active_pane = saved_active_pane;
        if (ui_system.getActiveTabBar().pending_switch_path) |path| {
            // Get actual kind from the tab (not from file extension, since terminal tabs have no path)
            const kind = blk: {
                if (ui_system.getActiveTabBar().active_index) |idx| {
                    if (idx < ui_system.getActiveTabBar().tabs.items.len) {
                        break :blk ui_system.getActiveTabBar().tabs.items[idx].kind;
                    }
                }
                break :blk file_types.getFileKind(path);
            };
            log.debug("Switching to tab: {s} (kind: {s})", .{path, @tagName(kind)});
            
            if (kind == .terminal) {
                // Terminal tabs are self-contained — no file loading needed.
                // Path cleanup happens below at the common pending_switch_path free.
                state_dirty = true;
                wio.cancelWait();
            } else if (kind == .binary) {
                // Binärdatei: kein Buffer, der Tab zeigt nur den Hinweis (binary_view.zig).
                state_dirty = true;
                wio.cancelWait();
            } else if (kind == .text) {
                // Fetch or create buffer from ui_system (ensures central ownership)
                const new_buf = ui_system.getOrCreateBuffer(path) catch |err| {
                    if (err == error.FileTooBig) {
                        ui_system.reportError("Cannot open '{s}': file is larger than 64 MB", .{std.fs.path.basename(path)});
                    } else {
                        ui_system.reportError("Cannot open '{s}': {s}", .{ std.fs.path.basename(path), @errorName(err) });
                    }
                    continue;
                };
                
                if (ui_system.getActiveTabBar().getActiveTab()) |t| {
                    t.buffer = new_buf;
                }
                
                ui_system.getActiveEditor().setBuffer(new_buf, path);
                // Explorer folgt dem aktiven Tab (Auto-Reveal), ohne den Fokus zu nehmen
                ui_system.file_explorer.revealPath(path);
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
                        ui_system.getActiveTabBar().pending_switch_path = null;
                        continue;
                    };

                    const page_info = handler.renderPage(0, 1.5) catch |err| {
                        log.err("Failed to render first PDF page: {}", .{err});
                        handler.deinit();
                        ui_system.allocator.free(path);
                        ui_system.getActiveTabBar().pending_switch_path = null;
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
                
                const current_editor_path = ui_system.getActiveEditor().buffer.get_file_path();
                var md_needs_free = false;
                const md_content = if (std.mem.eql(u8, source_path, current_editor_path)) blk: {
                    break :blk ui_system.getActiveEditor().buffer.store_to_string_cached(
                        ui_system.getActiveEditor().buffer.root, 
                        ui_system.getActiveEditor().buffer.file_eol_mode
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
            ui_system.getActiveTabBar().pending_switch_path = null;
            state_dirty = true;
        }
        }

        // State hat sich geändert (neue Tab / neue Textur) → gleichen Frame neu
        // layouten, damit Image-View mit korrekter aspect_ratio rendert statt
        // erst nach dem nächsten Input-Event.
        if (state_dirty) {
            render_commands = ui_system.renderExample(&logo_texture);
        }

        // Cursor-Form anpassen basierend auf Layout-Ergebnis
        if (!headless_mode) plat.setCursor(ui_system.getDesiredCursor());

        if (!headless_mode) renderer.renderFrameWithText(
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

        const has_more_work = ui_system.getActiveEditor().highlightChunked(2, ui_system.getActiveEditor().time_ms);

        frame_count += 1;
        ui_system.recordFrameTime(@as(f32, @floatFromInt(std.time.nanoTimestamp() - frame_t0)) / 1_000_000.0);

        if (headless_mode) {
            std.Thread.sleep(16 * std.time.ns_per_ms);
        } else if (has_more_work or e2e_ctx != null) {
            wio.wait(.{ .timeout_ns = 16 * 1000 * 1000 });
        } else {
            wio.wait(.{});
        }
    }

    log.info("=== vulkan-ed exiting ===", .{});

    } // Ende des inneren GPU-Scope → alle GPU-defers laufen hier

    // Jetzt Renderer (WGPU/Vulkan) + Platform (Wayland) in korrekter
    // Reihenfolge freigeben. Outer defers skippen via Flags.
    if (!headless_mode) {
        renderer.deinit();
        renderer_owned = false;
        plat.deinit();
        plat_owned = false;
    }
}



/// Projektordner setzen: Explorer-Root, current_directory, Git-Branch/-Status
/// und File-Watcher. Beim Start und nach "Open Folder…" (dann ersetzt es den
/// alten Ordner; offene Tabs bleiben erhalten).
fn openProjectFolder(
    allocator: std.mem.Allocator,
    ui_system: *ui.UI,
    scheduler: *async_mod.Scheduler,
    watcher: *?*file_watcher_mod.FileWatcher,
    git_repo_path: *?[]u8,
    path: []const u8,
) !void {
    ui_system.file_explorer.loadDirectory(path) catch |err| {
        log.warn("Failed to load directory '{s}': {}", .{ path, err });
    };

    const dir_copy = try allocator.dupe(u8, path);
    if (ui_system.current_directory) |old| allocator.free(old);
    ui_system.current_directory = dir_copy;

    const repo_copy = try allocator.dupe(u8, path);
    if (git_repo_path.*) |old| allocator.free(old);
    git_repo_path.* = repo_copy;

    // Alte Git-Daten gelten nicht mehr; neue kommen asynchron
    ui_system.updateBranch("");
    ui_system.updateGitStatus("");
    if (git_worker.Params.init(allocator, path, "")) |params| {
        _ = scheduler.submit(.{ .func = git_worker.taskGitBranch, .data = params });
    } else |err| {
        log.warn("git_branch submit failed: {}", .{err});
    }
    if (git_worker.Params.init(allocator, path, "")) |params| {
        _ = scheduler.submit(.{ .func = git_worker.taskGitStatus, .data = params });
    } else |err| {
        log.warn("git_status submit failed: {}", .{err});
    }

    // File Watcher auf das neue Verzeichnis umstellen
    if (watcher.*) |w| {
        w.deinit();
        watcher.* = null;
    }
    if (file_watcher_mod.FileWatcher.start(allocator, scheduler, path)) |w| {
        watcher.* = w;
    } else |err| {
        log.warn("file_watcher start failed: {}", .{err});
    }
    log.info("project folder: {s}", .{path});
}

/// Reiht genau einen git-status-Task ein, wenn die Debounce fällig ist.
fn submitGitStatusIfDue(
    git_refresh: *async_mod.Debounce,
    scheduler: *async_mod.Scheduler,
    allocator: std.mem.Allocator,
    git_repo_path: ?[]const u8,
) void {
    if (!git_refresh.take(std.time.milliTimestamp())) return;
    const path = git_repo_path orelse return;
    const params = git_worker.Params.init(allocator, path, "") catch return;
    log.debug("git status refresh submitted (debounced)", .{});
    // Task gibt params selbst frei; bei voller Queue müssen wir es tun.
    if (!scheduler.submit(.{ .func = git_worker.taskGitStatus, .data = params })) {
        params.deinit();
    }
}
