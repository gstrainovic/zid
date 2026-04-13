const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wio_dep = b.dependency("wio", .{
        .target = target,
        .optimize = optimize,
        .enable_vulkan = true,
        .enable_opengl = false,
        .enable_framebuffer = false,
        .enable_audio = false,
        .enable_joystick = false,
        .win32_manifest = false,
    });

    const exe = b.addExecutable(.{
        .name = "test-window",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test-vulkan-ed-window.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("wio", wio_dep.module("wio"));

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run test window");
    run_step.dependOn(&run.step);
}
