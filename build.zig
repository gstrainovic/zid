const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // wio Dependency - nur Wayland Backend
    const wio_dep = b.dependency("wio", .{
        .target = target,
        .optimize = optimize,
        .unix_backends = "wayland",
        .enable_vulkan = true,
        .enable_opengl = false,
    });

    // clay-zig from submodule
    const clay_dep = b.dependency("clay", .{
        .target = target,
        .optimize = optimize,
    });

    // wgpu_native_zig from submodule
    const wgpu_dep = b.dependency("wgpu", .{
        .target = target,
        .optimize = optimize,
    });

    // zigimg for Windows PNG loading
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    // zigjr for JSON-RPC 2.0 (E2E Testing)
    const zigjr_dep = b.dependency("zigjr", .{
        .target = target,
        .optimize = optimize,
    });

    // flow-core for buffer/text editing
    const flow_core_dep = b.dependency("flow_core", .{
        .target = target,
        .optimize = optimize,
    });

    // syntax for tree-sitter integration
    const syntax_dep = b.dependency("syntax", .{
        .target = target,
        .optimize = optimize,
    });
    const syntax_mod = syntax_dep.module("syntax");

    const nanosvg_dep = b.dependency("nanosvg_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const nanosvg_mod = nanosvg_dep.module("root");

    const zigdown_dep = b.dependency("zigdown", .{
        .target = target,
        .optimize = optimize,
        .builtin_ts_parsers = @as([]const u8, ""),
    });
    const zigdown_mod = zigdown_dep.module("zigdown");

    // Marp: Deck-Parser und HTML-Aufbereitung. Eigene Module, weil sowohl das
    // Executable als auch der PDF-Export sie brauchen.
    const marp_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/marp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const marp_html_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/marp_html.zig"),
        .target = target,
        .optimize = optimize,
    });
    marp_html_mod.addImport("zigdown", zigdown_mod);
    marp_html_mod.addImport("marp", marp_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Module importieren
    exe_mod.addImport("clay", clay_dep.module("zclay"));
    // Zentrale Kürzel-Tabelle: eigenes Modul, weil sowohl ui/mod.zig als auch
    // editor/code_editor.zig (eigenes Test-Root) sie brauchen.
    const shortcuts_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/shortcuts.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("shortcuts", shortcuts_mod);
    // Umgebungsvariablen plattformübergreifend (std.posix.getenv fehlt unter Windows):
    // eigenes Modul, weil mehrere Test-Roots (explorer_ops, backup, user_state) es brauchen.
    const env_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/env.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("env", env_mod);
    // Gemeinsames Kontextmenü (Tab, Editor, Markdown, Terminal, Explorer): eigenes Modul
    // aus demselben Grund wie die Kürzel-Tabelle.
    const context_menu_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/context_menu.zig"),
        .target = target,
        .optimize = optimize,
    });
    context_menu_mod.addImport("clay", clay_dep.module("zclay"));
    context_menu_mod.addImport("shortcuts", shortcuts_mod);
    exe_mod.addImport("context_menu", context_menu_mod);
    // Agent-Werkzeuge: eigenes Modul (Tests ohne UI), braucht die Kürzel-Tabelle
    const ai_tools_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_tools_mod.addImport("shortcuts", shortcuts_mod);
    exe_mod.addImport("ai_tools", ai_tools_mod);
    exe_mod.addImport("wio", wio_dep.module("wio"));
    exe_mod.addImport("wgpu", wgpu_dep.module("wgpu"));
    exe_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    exe_mod.addImport("zigjr", zigjr_dep.module("zigjr"));
    exe_mod.addImport("flow_core", flow_core_dep.module("flow-core"));
    exe_mod.addImport("syntax", syntax_mod);
    exe_mod.addImport("nanosvg", nanosvg_mod);
    exe_mod.addImport("zigdown", zigdown_mod);
    exe_mod.addImport("marp", marp_mod);
    exe_mod.addImport("marp_html", marp_html_mod);

    // ghostty-vt: Terminal emulator library
    if (b.lazyDependency("ghostty", .{
        .simd = false, // no SIMD for simpler build, no libc dep
    })) |ghostty_dep| {
        exe_mod.addImport("ghostty-vt", ghostty_dep.module("ghostty-vt"));
    }
    // Shader als Resource-File installieren
    const shader_install_triangle = b.addInstallFileWithDir(b.path("shaders/triangle.wgsl"), .{ .custom = "share" }, "triangle.wgsl");
    b.getInstallStep().dependOn(&shader_install_triangle.step);
    const shader_install_rectangle = b.addInstallFileWithDir(b.path("shaders/rectangle.wgsl"), .{ .custom = "share" }, "rectangle.wgsl");
    b.getInstallStep().dependOn(&shader_install_rectangle.step);
    const shader_install_text = b.addInstallFileWithDir(b.path("shaders/text.wgsl"), .{ .custom = "share" }, "text.wgsl");
    b.getInstallStep().dependOn(&shader_install_text.step);
    const shader_install_text_color = b.addInstallFileWithDir(b.path("shaders/text_color.wgsl"), .{ .custom = "share" }, "text_color.wgsl");
    b.getInstallStep().dependOn(&shader_install_text_color.step);
    const shader_install_text_atlas = b.addInstallFileWithDir(b.path("shaders/text_atlas.wgsl"), .{ .custom = "share" }, "text_atlas.wgsl");
    b.getInstallStep().dependOn(&shader_install_text_atlas.step);
    const shader_install_texture = b.addInstallFileWithDir(b.path("shaders/texture.wgsl"), .{ .custom = "share" }, "texture.wgsl");
    b.getInstallStep().dependOn(&shader_install_texture.step);

    // Test-Daten installieren (app.log wird standardmäßig im Editor geladen)
    const app_log_install = b.addInstallFileWithDir(b.path("test_data/app.log"), .{ .custom = "share" }, "app.log");
    b.getInstallStep().dependOn(&app_log_install.step);
    const syntax_test_install = b.addInstallFileWithDir(b.path("test_data/syntax_test.md"), .{ .custom = "share" }, "syntax_test.md");
    b.getInstallStep().dependOn(&syntax_test_install.step);

    const exe = b.addExecutable(.{
        .name = "zid",
        .root_module = exe_mod,
    });

    // Platform-specific linking
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("dwrite", .{});
        exe.root_module.linkSystemLibrary("d2d1", .{});
        exe.root_module.linkSystemLibrary("ole32", .{});
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("comdlg32", .{});
        exe.root_module.link_libc = true;

        // MuPDF Integration
        exe.root_module.addIncludePath(b.path("src/rendering/mupdf_wrapper"));
        exe.root_module.addIncludePath(b.path("libs/fancy-cat/deps/mupdf/include"));
        exe.root_module.addLibraryPath(b.path("libs/fancy-cat/deps/mupdf/build/release"));
        exe.linkSystemLibrary("mupdf");
        exe.linkSystemLibrary("mupdf-third");
        exe.addCSourceFile(.{
            .file = b.path("src/rendering/mupdf_wrapper/fitz-z.c"),
            .flags = &[_][]const u8{ "-std=c99", "-w" },
        });
    } else if (target.result.os.tag == .linux) {
        // wio (Wayland Backend) benötigt diese Libraries
        exe.root_module.linkSystemLibrary("wayland-client", .{});
        exe.root_module.linkSystemLibrary("wayland-egl", .{});
        exe.root_module.linkSystemLibrary("xkbcommon", .{});
        exe.root_module.linkSystemLibrary("decor-0", .{});
        exe.root_module.linkSystemLibrary("EGL", .{});
        // Vulkan für WGPU/Vulkan Rendering
        exe.root_module.linkSystemLibrary("vulkan", .{});
        // FreeType + HarfBuzz für Text/SVG Rendering
        exe.root_module.linkSystemLibrary("freetype2", .{});
        exe.root_module.linkSystemLibrary("harfbuzz", .{});
        exe.root_module.linkSystemLibrary("png", .{});
        exe.root_module.link_libc = true;

        // MuPDF: System-Library + System-Header verwenden (Fedora: mupdf-devel).
        // Der bundled Header-Pfad darf NICHT addiert werden — FZ_VERSION wird
        // in fz_new_context() als Laufzeit-Check gegen libmupdf.so geprüft,
        // und bundled (1.26.5) ≠ System (1.27.x) würde den Context verwerfen.
        // fitz-z.c ist unser setjmp-Wrapper.
        exe.root_module.addIncludePath(b.path("src/rendering/mupdf_wrapper"));
        // Fedoras mupdf.pc ist defekt (leeres -L) → pkg-config umgehen.
        exe.root_module.linkSystemLibrary("mupdf", .{ .use_pkg_config = .no });
        exe.addCSourceFile(.{
            .file = b.path("src/rendering/mupdf_wrapper/fitz-z.c"),
            .flags = &[_][]const u8{ "-std=c99", "-w" },
        });
    }

    // Automatische Kompilierung der MuPDF Font-Ressourcen nur unter Windows
    // (Linux verwendet System-libmupdf — Fonts sind dort bereits enthalten).
    if (target.result.os.tag == .windows) {
        if (std.fs.cwd().openDir("libs/fancy-cat/deps/mupdf/generated/resources/fonts/urw", .{ .iterate = true })) |mut_dir| {
            var dir = mut_dir;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".c")) {
                    const fpath = b.fmt("libs/fancy-cat/deps/mupdf/generated/resources/fonts/urw/{s}", .{entry.name});
                    exe.addCSourceFile(.{
                        .file = b.path(fpath),
                        .flags = &[_][]const u8{ "-O3", "-std=c99" },
                    });
                }
            }
        } else |_| {
            @import("std").log.warn("MuPDF font directory not found, skipping font compilation.", .{});
        }
    }

    b.installArtifact(exe);

    // Run the app
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zid");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const code_editor_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/code_editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    code_editor_mod.addImport("flow_core", flow_core_dep.module("flow-core"));
    code_editor_mod.addImport("syntax", syntax_mod);
    code_editor_mod.addImport("shortcuts", shortcuts_mod);
    code_editor_mod.addImport("context_menu", context_menu_mod);
    code_editor_mod.addImport("marp", marp_mod);

    // Tests IN code_editor.zig laufen nur, wenn die Datei selbst Test-Root ist:
    // Tests aus importierten Modulen (test/test_editor.zig → "code_editor")
    // führt der Test-Runner nicht aus.
    code_editor_mod.addImport("clay", clay_dep.module("zclay"));
    code_editor_mod.addImport("wio", wio_dep.module("wio"));
    code_editor_mod.addImport("env", env_mod);
    const code_editor_tests = b.addTest(.{ .root_module = code_editor_mod });
    const run_code_editor_tests = b.addRunArtifact(code_editor_tests);
    run_code_editor_tests.has_side_effects = true;

    const perf_test_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/highlight_perf_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    perf_test_mod.addImport("flow_core", flow_core_dep.module("flow-core"));
    perf_test_mod.addImport("syntax", syntax_mod);
    const perf_test_helper_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/highlight_perf_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    perf_test_helper_mod.addImport("flow_core", flow_core_dep.module("flow-core"));
    perf_test_helper_mod.addImport("syntax", syntax_mod);

    const perf_test_exe = b.addTest(.{
        .root_module = perf_test_mod,
    });
    const run_perf_tests = b.addRunArtifact(perf_test_exe);
    run_perf_tests.has_side_effects = true;
    perf_test_exe.root_module.addImport("highlight_perf_test.zig", perf_test_helper_mod);

    const scheduler_mod = b.createModule(.{
        .root_source_file = b.path("src/async/scheduler.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("scheduler", scheduler_mod);

    const async_tests = b.addTest(.{ .root_module = scheduler_mod });

    // Git-History: Tab-Pfade, Argumente, Log-/Diff-Parsing (ohne Prozesse, unit-getestet).
    const git_history_mod = b.createModule(.{
        .root_source_file = b.path("src/git/git_history.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("git_history", git_history_mod);
    const git_history_tests = b.addTest(.{ .root_module = git_history_mod });
    const run_git_history_tests = b.addRunArtifact(git_history_tests);
    run_git_history_tests.has_side_effects = true;

    const git_worker_mod = b.createModule(.{
        .root_source_file = b.path("src/git/git_worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_worker_mod.addImport("scheduler", scheduler_mod);
    git_worker_mod.addImport("git_history", git_history_mod);
    exe_mod.addImport("git_worker", git_worker_mod);
    const git_tests = b.addTest(.{ .root_module = git_worker_mod });

    const file_watcher_path = if (target.result.os.tag == .windows)
        b.path("src/async/file_watcher_win.zig")
    else
        b.path("src/async/file_watcher_linux.zig");

    const file_watcher_mod = b.createModule(.{
        .root_source_file = file_watcher_path,
        .target = target,
        .optimize = optimize,
    });
    file_watcher_mod.addImport("scheduler", scheduler_mod);
    exe_mod.addImport("file_watcher", file_watcher_mod);

    const lsp_proto_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp/lsp_proto.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("lsp_proto", lsp_proto_mod);

    const lsp_client_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp/lsp_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_client_mod.addImport("scheduler", scheduler_mod);
    lsp_client_mod.addImport("lsp_proto", lsp_proto_mod);
    exe_mod.addImport("lsp_client", lsp_client_mod);

    const ai_paths_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/paths.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ai_paths", ai_paths_mod);
    const ai_paths_tests = b.addTest(.{ .root_module = ai_paths_mod });
    const run_ai_paths_tests = b.addRunArtifact(ai_paths_tests);
    run_ai_paths_tests.has_side_effects = true;

    const ai_history_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/history.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ai_history", ai_history_mod);

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("agent", agent_mod);

    const ai_worker_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/ai_worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_worker_mod.addImport("scheduler", scheduler_mod);
    ai_worker_mod.addImport("agent", agent_mod);
    exe_mod.addImport("ai_worker", ai_worker_mod);
    const ai_worker_tests = b.addTest(.{ .root_module = ai_worker_mod });

    const chat_markdown_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/chat_markdown.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_markdown_mod.addImport("zigdown", zigdown_mod);
    exe_mod.addImport("chat_markdown", chat_markdown_mod);
    const chat_markdown_tests = b.addTest(.{ .root_module = chat_markdown_mod });

    const explorer_ops_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/explorer_ops.zig"),
        .target = target,
        .optimize = optimize,
    });
    explorer_ops_mod.addImport("env", env_mod);
    const explorer_ops_tests = b.addTest(.{ .root_module = explorer_ops_mod });
    const run_explorer_ops_tests = b.addRunArtifact(explorer_ops_tests);
    run_explorer_ops_tests.has_side_effects = true;

    const folder_ops_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/folder_ops.zig"),
        .target = target,
        .optimize = optimize,
    });
    folder_ops_mod.addImport("env", env_mod);
    const folder_ops_tests = b.addTest(.{ .root_module = folder_ops_mod });
    const run_folder_ops_tests = b.addRunArtifact(folder_ops_tests);
    run_folder_ops_tests.has_side_effects = true;

    // Keysym-Tabelle des wio-Forks: layout-unabhängige Tastenzuordnung.
    const wio_keysym_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("libs/wio/src/keysym.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_wio_keysym_tests = b.addRunArtifact(wio_keysym_tests);
    run_wio_keysym_tests.has_side_effects = true;

    // Blätter-Logik der PDF-Vorschau.
    const pdf_nav_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/pdf_nav.zig"),
        .target = target,
        .optimize = optimize,
    });
    pdf_nav_mod.addImport("shortcuts", shortcuts_mod);
    const pdf_nav_tests = b.addTest(.{ .root_module = pdf_nav_mod });
    const run_pdf_nav_tests = b.addRunArtifact(pdf_nav_tests);
    run_pdf_nav_tests.has_side_effects = true;

    // Erklärtext, wenn kein Wayland-Compositor erreichbar ist.
    const display_check_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/platform/display_check.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_display_check_tests = b.addRunArtifact(display_check_tests);
    run_display_check_tests.has_side_effects = true;

    // Mausrad → Zeilen-Delta: reine Funktion, damit das Vorzeichen testbar ist.
    const wheel_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/platform/wheel.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_wheel_tests = b.addRunArtifact(wheel_tests);
    run_wheel_tests.has_side_effects = true;

    const shortcuts_tests = b.addTest(.{ .root_module = shortcuts_mod });
    const run_shortcuts_tests = b.addRunArtifact(shortcuts_tests);
    run_shortcuts_tests.has_side_effects = true;

    const context_menu_tests = b.addTest(.{ .root_module = context_menu_mod });
    const run_context_menu_tests = b.addRunArtifact(context_menu_tests);
    run_context_menu_tests.has_side_effects = true;

    const find_ops_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/editor/find_ops.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_find_ops_tests = b.addRunArtifact(find_ops_tests);
    run_find_ops_tests.has_side_effects = true;

    const ai_history_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ai/history.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_ai_history_tests = b.addRunArtifact(ai_history_tests);
    run_ai_history_tests.has_side_effects = true;

    const device_select_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ai/device_select.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_device_select_tests = b.addRunArtifact(device_select_tests);
    run_device_select_tests.has_side_effects = true;

    const ai_tools_tests = b.addTest(.{ .root_module = ai_tools_mod });
    const run_ai_tools_tests = b.addRunArtifact(ai_tools_tests);
    run_ai_tools_tests.has_side_effects = true;

    const tiny_regex_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/editor/tiny_regex.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_tiny_regex_tests = b.addRunArtifact(tiny_regex_tests);
    run_tiny_regex_tests.has_side_effects = true;

    const backup_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/backup.zig"),
        .target = target,
        .optimize = optimize,
    });
    backup_mod.addImport("env", env_mod);
    const backup_tests = b.addTest(.{ .root_module = backup_mod });
    const run_backup_tests = b.addRunArtifact(backup_tests);
    run_backup_tests.has_side_effects = true;

    const user_state_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/user_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    user_state_mod.addImport("env", env_mod);
    const user_state_tests = b.addTest(.{ .root_module = user_state_mod });
    const run_user_state_tests = b.addRunArtifact(user_state_tests);
    run_user_state_tests.has_side_effects = true;

    const fuzzy_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/fuzzy.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_fuzzy_tests = b.addRunArtifact(fuzzy_tests);
    run_fuzzy_tests.has_side_effects = true;

    const lsp_proto_tests = b.addTest(.{ .root_module = lsp_proto_mod });
    const run_lsp_proto_tests = b.addRunArtifact(lsp_proto_tests);
    run_lsp_proto_tests.has_side_effects = true;

    const tab_mru_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/tab_mru.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_tab_mru_tests = b.addRunArtifact(tab_mru_tests);
    run_tab_mru_tests.has_side_effects = true;

    const wrap_ops_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/editor/wrap_ops.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_wrap_ops_tests = b.addRunArtifact(wrap_ops_tests);
    run_wrap_ops_tests.has_side_effects = true;

    const edit_ops_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/editor/edit_ops.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_edit_ops_tests = b.addRunArtifact(edit_ops_tests);
    run_edit_ops_tests.has_side_effects = true;

    const dialog_ops_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/dialog_ops.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_dialog_ops_tests = b.addRunArtifact(dialog_ops_tests);
    run_dialog_ops_tests.has_side_effects = true;

    const file_types_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/file_types.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_file_types_tests = b.addRunArtifact(file_types_tests);
    run_file_types_tests.has_side_effects = true;

    const glyph_layout_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/text/glyph_layout.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_glyph_layout_tests = b.addRunArtifact(glyph_layout_tests);
    run_glyph_layout_tests.has_side_effects = true;

    // Glyph-Cache (src/text_tests.zig als Root, weil text/types.zig ../platform importiert).
    const text_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/text_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_tests_mod.addImport("wio", wio_dep.module("wio"));
    const text_tests = b.addTest(.{ .root_module = text_tests_mod });
    const run_text_tests = b.addRunArtifact(text_tests);
    run_text_tests.has_side_effects = true;
    b.step("test-text", "Run text system tests").dependOn(&run_text_tests.step);

    const word_wrap_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/word_wrap.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    const path_display_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/path_display.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_path_display_tests = b.addRunArtifact(path_display_tests);
    run_path_display_tests.has_side_effects = true;

    const marp_tests = b.addTest(.{ .root_module = marp_mod });
    const run_marp_tests = b.addRunArtifact(marp_tests);
    run_marp_tests.has_side_effects = true;

    const marp_html_tests = b.addTest(.{ .root_module = marp_html_mod });
    const run_marp_html_tests = b.addRunArtifact(marp_html_tests);
    run_marp_html_tests.has_side_effects = true;

    // PDF-Export: braucht dieselbe MuPDF-Anbindung wie das Executable.
    const marp_pdf_mod = b.createModule(.{
        .root_source_file = b.path("src/rendering/marp_pdf.zig"),
        .target = target,
        .optimize = optimize,
    });
    marp_pdf_mod.addImport("marp", marp_mod);
    marp_pdf_mod.addImport("marp_html", marp_html_mod);
    marp_pdf_mod.addIncludePath(b.path("src/rendering/mupdf_wrapper"));
    marp_pdf_mod.link_libc = true;
    const marp_pdf_tests = b.addTest(.{ .root_module = marp_pdf_mod });
    if (target.result.os.tag == .linux) {
        marp_pdf_mod.linkSystemLibrary("mupdf", .{ .use_pkg_config = .no });
        marp_pdf_tests.addCSourceFile(.{
            .file = b.path("src/rendering/mupdf_wrapper/fitz-z.c"),
            .flags = &[_][]const u8{ "-std=c99", "-w" },
        });
    }
    const run_marp_pdf_tests = b.addRunArtifact(marp_pdf_tests);
    run_marp_pdf_tests.has_side_effects = true;

    const test_step = b.step("test", "Run tests");

    const run_async_tests = b.addRunArtifact(async_tests);
    run_async_tests.has_side_effects = true;
    test_step.dependOn(&run_async_tests.step);

    const run_git_tests = b.addRunArtifact(git_tests);
    run_git_tests.has_side_effects = true;
    test_step.dependOn(&run_git_tests.step);
    test_step.dependOn(&run_git_history_tests.step);

    const run_ai_worker_tests = b.addRunArtifact(ai_worker_tests);
    run_ai_worker_tests.has_side_effects = true;
    test_step.dependOn(&run_ai_worker_tests.step);

    test_step.dependOn(&run_explorer_ops_tests.step);
    test_step.dependOn(&run_folder_ops_tests.step);
    test_step.dependOn(&run_shortcuts_tests.step);
    test_step.dependOn(&run_wio_keysym_tests.step);
    test_step.dependOn(&run_display_check_tests.step);
    test_step.dependOn(&run_wheel_tests.step);
    test_step.dependOn(&run_pdf_nav_tests.step);
    test_step.dependOn(&run_context_menu_tests.step);
    test_step.dependOn(&run_find_ops_tests.step);
    test_step.dependOn(&run_wrap_ops_tests.step);
    test_step.dependOn(&run_tab_mru_tests.step);
    test_step.dependOn(&run_lsp_proto_tests.step);
    test_step.dependOn(&run_device_select_tests.step);
    test_step.dependOn(&run_ai_history_tests.step);
    test_step.dependOn(&run_ai_paths_tests.step);
    test_step.dependOn(&run_ai_tools_tests.step);

    const run_word_wrap_tests = b.addRunArtifact(word_wrap_tests);
    run_word_wrap_tests.has_side_effects = true;
    test_step.dependOn(&run_word_wrap_tests.step);
    test_step.dependOn(&run_glyph_layout_tests.step);
    test_step.dependOn(&run_text_tests.step);
    test_step.dependOn(&run_path_display_tests.step);
    test_step.dependOn(&run_marp_tests.step);
    test_step.dependOn(&run_marp_html_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_marp_pdf_tests.step);
    test_step.dependOn(&run_file_types_tests.step);
    test_step.dependOn(&run_dialog_ops_tests.step);
    test_step.dependOn(&run_edit_ops_tests.step);
    test_step.dependOn(&run_fuzzy_tests.step);
    test_step.dependOn(&run_user_state_tests.step);
    test_step.dependOn(&run_backup_tests.step);
    test_step.dependOn(&run_tiny_regex_tests.step);

    const run_chat_markdown_tests = b.addRunArtifact(chat_markdown_tests);
    run_chat_markdown_tests.has_side_effects = true;
    test_step.dependOn(&run_chat_markdown_tests.step);

    if (target.result.os.tag == .linux) {
        code_editor_tests.root_module.linkSystemLibrary("wayland-client", .{});
        code_editor_tests.root_module.linkSystemLibrary("wayland-egl", .{});
        code_editor_tests.root_module.linkSystemLibrary("xkbcommon", .{});
        code_editor_tests.root_module.linkSystemLibrary("decor-0", .{});
        code_editor_tests.root_module.linkSystemLibrary("EGL", .{});
        code_editor_tests.root_module.linkSystemLibrary("vulkan", .{});
        code_editor_tests.root_module.linkSystemLibrary("freetype2", .{});
        code_editor_tests.root_module.linkSystemLibrary("harfbuzz", .{});
        code_editor_tests.root_module.linkSystemLibrary("png", .{});
        code_editor_tests.root_module.link_libc = true;
    }
    test_step.dependOn(&run_code_editor_tests.step);
    test_step.dependOn(&run_perf_tests.step);
}
