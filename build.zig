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

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Module importieren
    exe_mod.addImport("clay", clay_dep.module("zclay"));
    exe_mod.addImport("wio", wio_dep.module("wio"));
    exe_mod.addImport("wgpu", wgpu_dep.module("wgpu"));
    exe_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    exe_mod.addImport("zigjr", zigjr_dep.module("zigjr"));
    exe_mod.addImport("flow_core", flow_core_dep.module("flow-core"));
    exe_mod.addImport("syntax", syntax_mod);
    exe_mod.addImport("nanosvg", nanosvg_mod);
    exe_mod.addImport("zigdown", zigdown_mod);

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

    const exe = b.addExecutable(.{
        .name = "vulkan-ed",
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

    const run_step = b.step("run", "Run vulkan-ed");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const editor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    editor_tests.root_module.addImport("clay", clay_dep.module("zclay"));
    editor_tests.root_module.addImport("wio", wio_dep.module("wio"));
    editor_tests.root_module.addImport("flow_core", flow_core_dep.module("flow-core"));
    editor_tests.root_module.addImport("syntax", syntax_mod);

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

    const async_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/async/scheduler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run tests");

    const run_async_tests = b.addRunArtifact(async_tests);
    run_async_tests.has_side_effects = true;
    test_step.dependOn(&run_async_tests.step);

    const run_editor_tests = b.addRunArtifact(editor_tests);
    if (target.result.os.tag == .linux) {
        editor_tests.root_module.linkSystemLibrary("wayland-client", .{});
        editor_tests.root_module.linkSystemLibrary("wayland-egl", .{});
        editor_tests.root_module.linkSystemLibrary("xkbcommon", .{});
        editor_tests.root_module.linkSystemLibrary("decor-0", .{});
        editor_tests.root_module.linkSystemLibrary("EGL", .{});
        editor_tests.root_module.linkSystemLibrary("vulkan", .{});
        editor_tests.root_module.linkSystemLibrary("freetype2", .{});
        editor_tests.root_module.linkSystemLibrary("harfbuzz", .{});
        editor_tests.root_module.linkSystemLibrary("png", .{});
        editor_tests.root_module.link_libc = true;
    }
    run_editor_tests.has_side_effects = true;
    test_step.dependOn(&run_editor_tests.step);
    test_step.dependOn(&run_perf_tests.step);

    // Performance Benchmark für Highlighting
    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/highlight_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_mod.addImport("flow_core", flow_core_dep.module("flow-core"));
    benchmark_mod.addImport("syntax", syntax_mod);

    const benchmark_exe = b.addExecutable(.{
        .name = "highlight-benchmark",
        .root_module = benchmark_mod,
    });

    const run_benchmark = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }

    const benchmark_step = b.step("benchmark", "Run highlight performance benchmark");
    benchmark_step.dependOn(&run_benchmark.step);
}
