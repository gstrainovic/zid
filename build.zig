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

    // Shader als Resource-File installieren
    const shader_install_triangle = b.addInstallFileWithDir(b.path("shaders/triangle.wgsl"), .{ .custom = "share" }, "triangle.wgsl");
    b.getInstallStep().dependOn(&shader_install_triangle.step);
    const shader_install_rectangle = b.addInstallFileWithDir(b.path("shaders/rectangle.wgsl"), .{ .custom = "share" }, "rectangle.wgsl");
    b.getInstallStep().dependOn(&shader_install_rectangle.step);
    const shader_install_text = b.addInstallFileWithDir(b.path("shaders/text.wgsl"), .{ .custom = "share" }, "text.wgsl");
    b.getInstallStep().dependOn(&shader_install_text.step);

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
        // FreeType + HarfBuzz + Fontconfig für Gooey Text/SVG Rendering
        exe.root_module.linkSystemLibrary("freetype2", .{});
        exe.root_module.linkSystemLibrary("harfbuzz", .{});
        exe.root_module.linkSystemLibrary("fontconfig", .{});
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
