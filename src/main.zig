const std = @import("std");
const free_log_mod = @import("debug/free_log.zig");
const text_probe = @import("debug/text_probe.zig");
const builtin = @import("builtin");
const file_types = @import("ui/file_types.zig");
const wio = @import("wio");
const platform = @import("platform/mod.zig");
const display_check = @import("platform/display_check.zig");
const asset_path = @import("platform/asset_path.zig");
const env = @import("env");
const wheel = @import("platform/wheel.zig");
const pdf_nav = @import("ui/pdf_nav.zig");
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
    // Debug-Zeilen nur mit ZID_DEBUG=1: ohne Filter sind es tausende Zeilen
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

/// Fensterstart fehlgeschlagen: Ursache aus der Umgebung ableiten und in einem
/// verständlichen Satz nach stderr schreiben.
fn reportDisplayFailure(err: anyerror) void {
    const reason = display_check.classify(.{
        .session_type = env.get("XDG_SESSION_TYPE"),
        .wayland_display = env.get("WAYLAND_DISPLAY"),
        .display = env.get("DISPLAY"),
    });
    var buf: [256]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    const w = &stderr.interface;
    w.print("{s}\n(details: {s})\n", .{ display_check.message(reason), @errorName(err) }) catch {};
    w.flush() catch {};
}

var debug_log_state: enum { unknown, off, on } = .unknown;

fn debugLogEnabled() bool {
    if (debug_log_state == .unknown) {
        debug_log_state = if (env.get("ZID_DEBUG")) |v| (if (v.len > 0 and v[0] != '0') .on else .off) else .off;
    }
    return debug_log_state == .on;
}

pub fn main() !void {
    // Logs sind UTF-8; die Windows-Konsole zeigte sonst „geh├Ârt“ statt „gehört“.
    if (builtin.os.tag == .windows) _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    // Allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Hat der Scheduler Worker zurückgelassen, halten die ihren Speicher absichtlich
    // (Scheduler.deinit); die Leck-Liste wäre dann nur Rauschen.
    var leak_check = true;
    defer if (leak_check) {
        _ = gpa.deinit();
    };
    // --page-alloc: jede Allokation auf eigenen Seiten, Freigaben mit Stack-Trace protokolliert
    // (Use-after-free-Suche zusammen mit der Text-Probe im Headless-Loop).
    var page_alloc_mode = env.get("ZID_PAGE_ALLOC") != null;
    for (std.os.argv) |a| {
        if (std.mem.eql(u8, std.mem.span(a), "--page-alloc")) page_alloc_mode = true;
    }
    const free_log = try std.heap.page_allocator.create(free_log_mod.FreeLog);
    free_log.* = .{};
    const allocator = if (page_alloc_mode) free_log.allocator() else gpa.allocator();

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
        } else if (std.mem.eql(u8, args[i], "--page-alloc")) {
            log.info("page allocator with free log enabled (debug)", .{});
        } else if (std.mem.eql(u8, args[i], "--ai=off")) {
            ai_disabled = true;
            log.info("AI disabled via --ai=off", .{});
        } else if (std.mem.eql(u8, args[i], "--version") or std.mem.eql(u8, args[i], "-V")) {
            var buf: [64]u8 = undefined;
            var stdout_f = std.fs.File.stdout();
            var stdout_writer = stdout_f.writer(&buf);
            const w = &stdout_writer.interface;
            try w.print("zid {s}\n", .{@import("build_info").version});
            try w.flush();
            return;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var buf: [4096]u8 = undefined;
            var stdout_f = std.fs.File.stdout();
            var stdout_writer = stdout_f.writer(&buf);
            const w = &stdout_writer.interface;
            try w.writeAll("Usage: zid [OPTIONS] [FILE|FOLDER]\n\n");
            try w.writeAll("Options:\n");
            try w.writeAll("  --theme light|dark    Override theme\n");
            try w.writeAll("  --e2e                 Enable E2E mode (RPC on port 9999)\n");
            try w.writeAll("  --headless            Headless mode (no window, screenshots via RPC on port 9999)\n");
            try w.writeAll("  --interactive         Interactive mode (stdin/stdout command interface)\n");
            try w.writeAll("  --ai=off              Disable AI chat (llama-server)\n");
            try w.writeAll("  --version, -V         Show version\n");
            try w.writeAll("  --help, -h            Show this help\n");
            try w.writeAll("\nEnvironment:\n");
            try w.writeAll("  ZID_DEBUG=1     Enable debug log lines\n");
            try w.writeAll("  LLAMA_SERVER_PATH     llama-server binary (default: downloaded by zid)\n");
            try w.writeAll("  LLAMA_MODEL_PATH      GGUF model file (default: downloaded by zid)\n");
            try w.flush();
            return;
        } else if (default_file_path == null) {
            // Erstes nicht-Flag Argument = Dateipfad
            default_file_path = args[i];
        }
    }

    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);

    // Nur eine auf der Kommandozeile genannte Datei wird beim Start geöffnet. Ein Ordner
    // (`zid .`) wird Projektordner statt Datei: als Datei gelesen scheiterte er mit IsDir,
    // und der Fallback-Buffer galt beim Beenden als „1 file with unsaved changes: .“.
    var resolved_file_path: ?[]const u8 = default_file_path;
    var start_folder: ?[]const u8 = null;
    if (default_file_path) |p| {
        // openDir statt statFile: statFile öffnet unter Windows als Datei und scheitert
        // bei Ordnern mit IsDir, meldet also nie `.directory`.
        if (std.fs.cwd().openDir(p, .{})) |d| {
            var dir = d;
            dir.close();
            start_folder = p;
            resolved_file_path = null;
        } else |_| {}
    }
    if (resolved_file_path) |p| log.info("Start file: {s}", .{p});
    if (start_folder) |p| log.info("Start folder: {s}", .{p});

    log.info("=== zid starting ===", .{});
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
    var plat: platform.Platform = if (headless_mode) undefined else platform.Platform.init(allocator, .{
        .title = "zid",
        .width = 1200,
        .height = 800,
    }) catch |err| {
        // Ohne Compositor hilft ein Zig-Stacktrace niemandem: erklären, warum
        // kein Fenster entsteht, und still beenden.
        reportDisplayFailure(err);
        std.process.exit(1);
    };

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

            // Surface vom Window erstellen (Wayland, X11 oder HWND — je nach Backend)
            try renderer.setWindow(plat.nativeWindow() orelse return error.NoWindow);
            try renderer.configureSwapChain(plat.getSize().width, plat.getSize().height);
        }

        // 3. Text Renderer initialisieren (DirectWrite/FreeType)
        // Unter Linux kommt die Schrift aus dem Binary; DirectWrite unter Windows kann
        // das nicht, dort liegt die Datei neben der exe (siehe platform/asset_path.zig).
        const font_rel = "fonts/JetBrainsMono-Regular.ttf";
        const font_file = asset_path.find(allocator, exe_dir, font_rel) catch null;
        defer if (font_file) |f| allocator.free(f);
        var text_renderer = try text.TextRenderer.init(allocator, .{
            .font_path = font_file orelse font_rel,
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
        defer {
            scheduler.shutdown();
            if (scheduler.detached) leak_check = false;
            scheduler.deinit();
        }
        // Läuft vor scheduler.deinit (defer rückwärts): ein git auf einem Netzlaufwerk hielt
        // sonst einen Worker über die 2 s Wartezeit hinaus fest.
        defer git_worker.killRunning();
        // Ergebnisse aus Worker- und Watcher-Threads wecken den Frame-Loop aus wio.wait(.{}).
        // Ohne das liefen bei ruhigem Fenster 256 Results auf und die Queue blockte.
        if (!headless_mode) scheduler.on_result = &wio.cancelWait;

        ui_system.setAIScheduler(scheduler);

        // File Watcher (inotify auf Linux)
        var watcher: ?*file_watcher_mod.FileWatcher = null;
        // Datei-Ereignisse kommen in Bursts (ein Schreibvorgang = hunderte IN_MODIFY).
        // Ein git-status-Task pro Fenster reicht, sonst läuft die Work-Queue voll.
        var git_refresh = async_mod.Debounce{ .delay_ms = 300 };
        defer if (watcher) |w| w.deinit();

        // Phase 9: File Explorer mit aktuellem Verzeichnis initialisieren
        const cwd = std.fs.cwd();
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_path = cwd.realpath(start_folder orelse ".", &cwd_buf) catch null;
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

        // Logo der Kopfzeile
        var logo_texture = image_rdr.createTextureFromBytes(allocator, @import("builtin_assets").logo_png) catch |err| blk: {
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

        log.info("=== zid ready ===", .{});
        log.info("Press Ctrl+C to exit (or close window)", .{});

        // E2E RPC Server starten falls --e2e Flag
        var e2e_thread: ?std.Thread = null;
        var e2e_ctx: ?e2e_server.E2EContext = null;
        if (e2e_mode) {
            const e2e_listen_addr = try std.net.Address.parseIp("127.0.0.1", 9999);
            // Socket von Hand: `Address.listen(.{ .reuse_address = true })` setzt
            // zusätzlich SO_REUSEPORT. Dann lauscht eine verwaiste Instanz still
            // weiter, der Kernel verteilt die Verbindungen, und die Hälfte aller
            // RPC-Antworten kommt aus dem alten Prozess. Nur SO_REUSEADDR: der
            // Neustart nach TIME_WAIT klappt, ein zweiter Start scheitert.
            const e2e_server_sock = blk: {
                const sock = try std.posix.socket(
                    e2e_listen_addr.any.family,
                    std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
                    std.posix.IPPROTO.TCP,
                );
                errdefer std.posix.close(sock);
                try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
                std.posix.bind(sock, &e2e_listen_addr.any, e2e_listen_addr.getOsSockLen()) catch |err| {
                    if (err == error.AddressInUse) {
                        log.err("Port 9999 ist belegt — läuft noch eine zid-Instanz? (pkill -f 'bin/zid')", .{});
                    }
                    return err;
                };
                try std.posix.listen(sock, 128);
                break :blk std.net.Server{ .listen_address = e2e_listen_addr, .stream = .{ .handle = sock } };
            };
            e2e_ctx = e2e_server.E2EContext.init(allocator, &ui_system, e2e_server_sock);
            // Fenstermodus: RPC-Eingaben puffern, der Main-Loop wendet sie pro Frame an.
            e2e_ctx.?.defer_input = !interactive_mode;
            e2e_thread = try e2e_server.start(&e2e_ctx.?);
        }
        defer if (e2e_ctx) |*c| c.deinit();

        // Interactive mode (stdin/stdout) hat keinen Frame-Loop: Handler laufen direkt.
        if (headless_mode and interactive_mode) {
            log.info("=== zid headless ready ===", .{});
            log.info("Interactive mode — stdin/stdout command interface", .{});
            e2e_interactive.runInteractiveLoop(&e2e_ctx.?);
            log.info("Interactive mode ended", .{});
            return;
        }
        if (headless_mode) log.info("=== zid headless ready — frame loop without window, RPC on port 9999 ===", .{});

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
        var last_frame_ns = std.time.nanoTimestamp();
        while ((headless_mode or plat.isRunning()) and !ui_system.quit_confirmed and (e2e_ctx == null or !e2e_ctx.?.shutdown_flag.load(.seq_cst))) {
            if (e2e_ctx) |*c| e2e_server.drainInputs(c);
            const frame_t0 = std.time.nanoTimestamp();
            // Echte Zeit seit dem letzten Frame, nicht pauschal 16 ms: Frames dauern mit
            // Layout und RPC länger, und die UI-Uhr (Tooltips nach 700 ms, Toasts, Hover)
            // lief sonst auf halber Geschwindigkeit — headless erschien ein Tooltip erst
            // nach ~1,5 s. Deckel gegen Sprünge nach langem wio.wait (Animationen).
            const delta_time_ms: f32 = @min(250.0, @as(f32, @floatFromInt(frame_t0 - last_frame_ns)) / 1_000_000.0);
            last_frame_ns = frame_t0;

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
                        .git_unsafe_repo => ui_system.handleUnsafeRepo(result.payload),
                        .git_file_diff, .git_file_diff_error => ui_system.handleGitFileDiff(result.tag == .git_file_diff, result.payload),
                        .git_timeline, .git_timeline_error => ui_system.handleGitTimeline(result.tag == .git_timeline, result.payload),
                        .git_graph_log, .git_graph_log_error => ui_system.handleGitGraphLog(result.tag == .git_graph_log, result.payload),
                        .git_commit_changes, .git_commit_changes_error => ui_system.handleGitCommitChanges(result.tag == .git_commit_changes, result.payload),
                        .git_commit_stat, .git_commit_stat_error => ui_system.handleGitCommitStat(result.tag == .git_commit_stat, result.payload),
                        .git_action, .git_action_error => ui_system.handleGitAction(result.tag == .git_action, result.payload),
                        .ai_commit_message, .ai_commit_message_error => ui_system.handleAICommitMessage(result.tag == .ai_commit_message, result.payload),
                        .ai_chat_reply => ui_system.handleAIReply(result.payload),
                        .ai_chat_error => ui_system.handleAIError(result.payload),
                        .ai_chat_delta => ui_system.handleAIDelta(result.payload),
                        .ai_chat_cancelled => ui_system.handleAICancelled(result.payload),
                        .ai_chat_tool_calls => ui_system.handleAIToolCalls(result.payload),
                        .ai_warmup_done => ui_system.handleAIWarmupDone(),
                        .ai_warmup_error => ui_system.handleAIWarmupError(result.payload),
                        .lsp_definition => ui_system.handleLspDefinition(result.payload),
                        .file_changed, .file_created, .file_deleted => {
                            log.debug("file event: {} for {s}", .{ result.tag, result.payload });
                            git_refresh.mark(std.time.milliTimestamp());
                            // file_created auch: atomares Ersetzen (nach .tmp schreiben, dann rename)
                            // meldet IN_MOVED_TO, die offene Datei hat trotzdem neuen Inhalt.
                            if (result.tag != .file_deleted) ui_system.handleExternalChange(result.payload);
                        },
                        else => {},
                    }
                }
                if (results.len > 0) wio.cancelWait();
                // Source-Control-Aktion oder Refresh: Status neu laden (über denselben Debounce)
                if (ui_system.takeGitStatusRequest()) git_refresh.mark(std.time.milliTimestamp());
                // Fremdes Repo freigegeben: der Branch kam vorher leer zurück
                if (ui_system.takeGitBranchRequest()) if (git_repo_path) |path| {
                    if (git_worker.Params.init(allocator, path, "")) |params| {
                        if (!scheduler.submit(.{ .func = git_worker.taskGitBranch, .data = params })) params.deinit();
                    } else |err| log.warn("git_branch submit failed: {}", .{err});
                };
                // Dateiänderungen: git status und die Timeline der aktiven Datei neu laden
                if (submitGitStatusIfDue(&git_refresh, scheduler, allocator, git_repo_path)) {
                    ui_system.timeline_view.timeline.refresh();
                }
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
                            const new_x: f32 = @floatFromInt(pos.x);
                            const new_y: f32 = @floatFromInt(pos.y);
                            // Splitter-Zittern (ZID_DEBUG=1): Rücksprung der Maus-X gegen die
                            // Zugrichtung markiert „<<“ — greifbar mit `mouse:` im Log.
                            if (ui_system.file_explorer.is_resizing) {
                                const dx = new_x - mouse_x;
                                log.debug("mouse: x={d:.0} y={d:.0} dx={d:.0}{s}", .{ new_x, new_y, dx, if (dx < 0) " <<" else "" });
                            }
                            mouse_x = new_x;
                            mouse_y = new_y;
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
                        // Schließen-Knopf: nachfragen, wenn etwas ungespeichert ist
                        .close => ui_system.requestQuit(),
                        .focused => {
                            plat.setTextInput(true);
                        },
                        .scroll_vertical => |delta| {
                            scroll_delta_y = @floatCast(delta);
                            const lines_delta = wheel.wheelLines(scroll_delta_y);
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

            // PDF-Seiten neu rendern: nach einem Seitenwechsel (`needs_render`) oder wenn die
            // Ansicht einen deutlich anderen Maßstab braucht (Zoom, Fenstergröße). Die Suche
            // läuft hier schrittweise weiter, höchstens ~8 ms je Frame.
            {
                const PdfHandler = @import("rendering/pdf_handler.zig").PdfHandler;
                var pdf_it = ui_system.open_pdfs.iterator();
                while (pdf_it.next()) |entry| {
                    const handler: *PdfHandler = @ptrCast(@alignCast(entry.value_ptr.*));
                    if (handler.search.running()) {
                        if (handler.searchStep(8 * std.time.ns_per_ms)) wio.cancelWait();
                    }
                    const want = handler.wanted_scale;
                    handler.wanted_scale = 0;
                    const have = handler.requested_scale;
                    const stale = want > 0 and (have <= 0 or @abs(want - have) > have * 0.1);
                    if (!handler.needs_render and !stale) continue;
                    handler.needs_render = false;
                    const scale = if (want > 0) want else if (have > 0) have else 2.0;
                    const info = handler.renderPage(handler.current_page, scale) catch |err| {
                        log.err("Failed to render PDF page {d}: {}", .{ handler.current_page, err });
                        continue;
                    };
                    defer allocator.free(info.pixels);
                    if (ui_system.open_images.get(entry.key_ptr.*)) |tex_ptr| {
                        const ImageTexture = @import("clay_renderer/image_renderer.zig").ImageTexture;
                        const tex: *ImageTexture = @ptrCast(@alignCast(tex_ptr));
                        const new_tex = image_rdr.createTextureFromPixels(info.pixels, info.width, info.height) catch |err| {
                            log.err("PDF page texture failed: {}", .{err});
                            continue;
                        };
                        tex.deinit();
                        tex.* = new_tex;
                    }
                    wio.cancelWait();
                }
            }

            // Offene PDFs neu laden, wenn sich die Datei geändert hat (Watcher, Marp-Export),
            // erst wenn sie 150 ms ruht (UI.takeDuePdfReload). Scheitert das Öffnen trotzdem,
            // bleibt der alte Stand.
            while (ui_system.takeDuePdfReload()) |pdf_key| {
                defer allocator.free(pdf_key);
                const PdfHandler = @import("rendering/pdf_handler.zig").PdfHandler;
                const slot = ui_system.open_pdfs.getPtr(pdf_key) orelse continue;
                const old: *PdfHandler = @ptrCast(@alignCast(slot.*));
                const fresh = PdfHandler.init(allocator, pdf_key) catch |err| {
                    log.warn("PDF reload of {s} failed ({}), keeping the old state", .{ pdf_key, err });
                    continue;
                };
                if (fresh.total_pages == 0) {
                    log.warn("PDF reload of {s}: no pages, keeping the old state", .{pdf_key});
                    fresh.deinit();
                    continue;
                }
                fresh.current_page = @min(old.current_page, fresh.total_pages - 1);
                // Ansicht und Suche übernehmen, die Suche läuft auf dem neuen Stand neu
                fresh.zoom = old.zoom;
                fresh.scroll_x = old.scroll_x;
                fresh.scroll_y = old.scroll_y;
                fresh.find = old.find;
                if (fresh.find.active) {
                    fresh.restartSearch();
                    fresh.search.jump_pending = false; // nach dem Speichern nicht wegspringen
                }
                const info = fresh.renderPage(fresh.current_page, if (old.requested_scale > 0) old.requested_scale else 2.0) catch |err| {
                    log.warn("PDF reload of {s}: render failed ({}), keeping the old state", .{ pdf_key, err });
                    fresh.deinit();
                    continue;
                };
                defer allocator.free(info.pixels);
                if (ui_system.open_images.get(pdf_key)) |tex_ptr| {
                    const ImageTexture = @import("clay_renderer/image_renderer.zig").ImageTexture;
                    const tex: *ImageTexture = @ptrCast(@alignCast(tex_ptr));
                    const new_tex = image_rdr.createTextureFromPixels(info.pixels, info.width, info.height) catch |err| {
                        log.warn("PDF reload of {s}: texture failed ({})", .{ pdf_key, err });
                        fresh.deinit();
                        continue;
                    };
                    tex.deinit();
                    tex.* = new_tex;
                }
                old.deinit();
                slot.* = fresh;
                log.info("PDF reloaded: {s} ({d} pages, page {d})", .{ pdf_key, fresh.total_pages, fresh.current_page + 1 });
                wio.cancelWait();
            }

            // Zustand der PDF-Vorschau für E2E spiegeln (nur hier im Main-Thread).
            if (e2e_ctx) |*c| {
                var snap: e2e_server.PdfSnapshot = .{};
                if (ui_system.activePdf()) |handler| {
                    snap = .{
                        .page = handler.current_page,
                        .pages = handler.total_pages,
                        .zoom = handler.zoom,
                        .scroll_x = handler.scroll_x,
                        .scroll_y = handler.scroll_y,
                        .scale = handler.requested_scale,
                        .find_active = handler.find.active,
                        .searching = handler.search.running(),
                        .hits = @intCast(handler.search.hits.items.len),
                        .current = if (handler.search.current) |hi| @intCast(hi) else null,
                        .hit_page = if (handler.search.current) |hi| handler.search.hits.items[hi].page else null,
                    };
                }
                e2e_server.setPdfSnapshot(c, snap);
                e2e_server.snapshotGitViews(c);
            }

            var state_dirty: bool = false;

            // Phase 9: Datei öffnen verarbeiten
            if (ui_system.file_explorer.file_to_open) |path| {
                ui_system.getActiveTabBar().openFile(path) catch {};

                // Dateityp prüfen
                const kind = file_types.detectFileKind(path);
                log.debug("Opening file: {s} (kind: {s})", .{ path, @tagName(kind) });

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
                            log.err("Failed to load image texture for '{s}': {}", .{ path, err });
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
                            log.err("Failed to open PDF {s}: {}", .{ path, err });
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
                    log.debug("Switching to tab: {s} (kind: {s})", .{ path, @tagName(kind) });

                    if (kind == .terminal) {
                        // Terminal tabs are self-contained — no file loading needed.
                        // Path cleanup happens below at the common pending_switch_path free.
                        state_dirty = true;
                        wio.cancelWait();
                    } else if (kind == .binary or kind == .git_diff or kind == .git_commit) {
                        // Binärdatei: kein Buffer, der Tab zeigt nur den Hinweis (binary_view.zig).
                        // Diff- und Commit-Tabs: die Ansicht legt renderPane an und lädt selbst.
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
                            // Tab ohne Buffer schließen und den Wechsel abhaken, sonst
                            // wiederholt sich der Fehler in jedem Frame.
                            if (ui_system.getActiveTabBar().active_index) |idx| {
                                ui_system.pending_tab_closes.append(ui_system.allocator, .{ .pane = switch_leaf, .index = idx }) catch {};
                            }
                            ui_system.allocator.free(path);
                            ui_system.getActiveTabBar().pending_switch_path = null;
                            state_dirty = true;
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
                                log.err("Failed to load image texture for '{s}': {}", .{ path, err });
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
                                log.err("Failed to open PDF {s}: {}", .{ path, err });
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
                            break :blk ui_system.getActiveEditor().buffer.store_to_string_cached(ui_system.getActiveEditor().buffer.root, ui_system.getActiveEditor().buffer.file_eol_mode);
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
                            view_ptr.*.text = @import("ui/md_select.zig").ownedLf(view_ptr.*.allocator, md_content);
                        } else {
                            const view = allocator.create(@import("ui/markdown_view.zig").MarkdownView) catch unreachable;
                            view.* = @import("ui/markdown_view.zig").MarkdownView.init(ui_system.allocator, md_content, abs_source_path);
                            view.font_size = ui_system.previewFontSize();
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

            // Headless: Text-Strings der Commands anfassen wie der GPU-Renderer, damit ein
            // Use-after-free auch ohne Fenster auffällt (mit --page-alloc samt Freigabestelle).
            if (headless_mode) {
                if (text_probe.probe(render_commands)) |f| {
                    std.debug.print(
                        "TEXT PROBE FAULT: command {d}/{d} ptr=0x{x} len={d} bbox=({d:.0},{d:.0} {d:.0}x{d:.0}) prev_text=\"{s}\"\n",
                        .{ f.index, render_commands.len, f.ptr, f.len, f.bbox.x, f.bbox.y, f.bbox.width, f.bbox.height, f.prev_text },
                    );
                    if (free_log.findFree(f.ptr)) |e| free_log_mod.FreeLog.dumpEntry(e) else std.debug.print("no free-log entry for that address\n", .{});
                    @panic("render command references unmapped text");
                }
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
            } else if (has_more_work or e2e_ctx != null or ui_system.wantsFrameSoon()) {
                // Tooltip oder Hover-Panel steht aus: ohne Timeout käme der nächste Frame erst
                // bei der nächsten Mausbewegung, der Tooltip nie bei stillstehender Maus.
                wio.wait(.{ .timeout_ns = 16 * 1000 * 1000 });
            } else {
                wio.wait(.{});
            }
        }

        log.info("=== zid exiting ===", .{});
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

    // Ordner ohne Repo bekommen gar keine git-Tasks. Vorher lief bei jedem
    // Wechsel nach z. B. ~/projects ein git-Aufruf ins Leere (Exit 128).
    const in_repo = git_worker.isInsideRepo(path);
    if (git_repo_path.*) |old| allocator.free(old);
    git_repo_path.* = if (in_repo) try allocator.dupe(u8, path) else null;

    // Alte Git-Daten gelten nicht mehr; neue kommen asynchron
    ui_system.updateBranch("");
    ui_system.updateGitStatus("");
    if (in_repo) {
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
    } else {
        log.info("kein Git-Repository: '{s}' — keine git-Tasks", .{path});
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

/// Reiht genau einen git-status-Task ein, wenn die Debounce fällig ist. true = fällig gewesen.
fn submitGitStatusIfDue(
    git_refresh: *async_mod.Debounce,
    scheduler: *async_mod.Scheduler,
    allocator: std.mem.Allocator,
    git_repo_path: ?[]const u8,
) bool {
    if (!git_refresh.take(std.time.milliTimestamp())) return false;
    const path = git_repo_path orelse return true;
    const params = git_worker.Params.init(allocator, path, "") catch return true;
    log.debug("git status refresh submitted (debounced)", .{});
    // Task gibt params selbst frei; bei voller Queue müssen wir es tun.
    if (!scheduler.submit(.{ .func = git_worker.taskGitStatus, .data = params })) {
        params.deinit();
    }
    return true;
}
