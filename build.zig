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

    // gooey from submodule
    const gooey_dep = b.dependency("gooey", .{
        .target = target,
        .optimize = optimize,
    });

    // vkvg from submodule - als C-Library kompilieren
    const vkvg_mod_obj = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    const vkvg_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "vkvg",
        .root_module = vkvg_mod_obj,
    });
    vkvg_lib.linkLibC();
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/include"));
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/src"));
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/vkh/include"));
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/vkh/src"));
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/external/uthash/src"));
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/shaders"));
    // Externe Dependencies
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/external/glbinding/include"));
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/external/freetype-gl"));
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/external/libtess2/Include"));
    vkvg_lib.linkSystemLibrary("vulkan");
    vkvg_lib.linkSystemLibrary("fontconfig");
    vkvg_lib.linkSystemLibrary("freetype2");
    vkvg_lib.linkSystemLibrary("harfbuzz");
    // Alle vkvg C-Sourcen
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_context.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_context_internal.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_device.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_device_internal.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_experimental.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_fonts.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_matrix.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_pattern.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_surface.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/vkvg_surface_internal.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/src/cross_os.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    // vkh (Vulkan Helper)
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/vkh/src/vkh_device.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/vkh/src/vkh_image.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/vkh/src/vkhelpers.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/vkh/src/vkh_buffer.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/vkh/src/vkh_queue.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/vkh/src/vkh_presenter.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    vkvg_lib.addCSourceFile(.{ .file = b.path("libs/vkvg-zig/vkh/src/vkh_phyinfo.c"), .flags = &[_][]const u8{"-std=c11", "-DVKVG_BACKEND_VULKAN=1"} });
    // Shaders einbinden
    vkvg_lib.addIncludePath(b.path("libs/vkvg-zig/shaders"));

    b.installArtifact(vkvg_lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Module importieren
    exe_mod.addImport("clay", clay_dep.module("zclay"));
    exe_mod.addImport("wio", wio_dep.module("wio"));
    exe_mod.addImport("wgpu", wgpu_dep.module("wgpu"));
    exe_mod.addImport("gooey", gooey_dep.module("gooey"));
    // vkvg Header für @cImport
    exe_mod.addIncludePath(b.path("libs/vkvg-zig/include"));
    exe_mod.addIncludePath(b.path("libs/vkvg-zig/src"));
    exe_mod.addIncludePath(b.path("libs/vkvg-zig/vkh/include"));

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

    const exe = b.addExecutable(.{
        .name = "vulkan-ed",
        .root_module = exe_mod,
    });

    // Platform-specific linking
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("vulkan-1", .{});
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
        // vkvg für 2D Graphics (aus Submodule gebaut)
        exe.linkLibrary(vkvg_lib);
        exe.root_module.link_libc = true;
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run vulkan-ed");
    run_step.dependOn(&run_cmd.step);

    // === WIO TEST (temporär deaktiviert) ===
    // wio test code removed - causes build issues
}
