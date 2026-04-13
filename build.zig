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
        exe.root_module.link_libc = true;
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

    const test_step = b.step("test", "Run tests");

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

    // Test window for Phase 11 screenshots (minimal wio window, no vulkan-ed app logic)
    const tw_mod = b.createModule(.{
        .root_source_file = b.path("scripts/test-vulkan-ed-window.zig"),
        .target = target,
        .optimize = optimize,
    });
    tw_mod.addImport("wio", wio_dep.module("wio"));
    const tw_exe = b.addExecutable(.{
        .name = "test-window",
        .root_module = tw_mod,
    });
    if (target.result.os.tag == .windows) {
        tw_exe.root_module.linkSystemLibrary("user32", .{});
    }
    b.installArtifact(tw_exe);
    const tw_run = b.addRunArtifact(tw_exe);
    const tw_step = b.step("test-window", "Run minimal test window for screenshots");
    tw_step.dependOn(&tw_run.step);
}
