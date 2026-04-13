const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const syntax_dep = b.dependency("syntax", .{
        .target = target,
        .optimize = optimize,
    });
    const syntax_mod = syntax_dep.module("syntax");

    const cbor_dep = b.dependency("cbor", .{
        .target = target,
        .optimize = optimize,
    });
    const cbor_mod = cbor_dep.module("cbor");

    const file_type_config_mod = b.createModule(.{
        .root_source_file = b.path("src/file_type_config.zig"),
        .imports = &.{
            .{ .name = "syntax", .module = syntax_mod },
        },
    });

    const typed_int_mod = b.createModule(.{
        .root_source_file = b.path("src/TypedInt.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });

    const buffer_mod = b.createModule(.{
        .root_source_file = b.path("src/buffer/Buffer.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "TypedInt", .module = typed_int_mod },
            .{ .name = "file_type_config", .module = file_type_config_mod },
        },
    });

    const diff_mod = b.createModule(.{
        .root_source_file = b.path("src/diff.zig"),
    });

    const snippet_mod = b.createModule(.{
        .root_source_file = b.path("src/snippet.zig"),
    });

    const keybind_input_mod = b.createModule(.{
        .root_source_file = b.path("src/keybind/input.zig"),
    });

    const keybind_mod = b.createModule(.{
        .root_source_file = b.path("src/keybind/mod.zig"),
        .imports = &.{
            .{ .name = "input", .module = keybind_input_mod },
        },
    });

    _ = b.addModule("flow-core", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
            .{ .name = "TypedInt", .module = typed_int_mod },
            .{ .name = "file_type_config", .module = file_type_config_mod },
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "diff", .module = diff_mod },
            .{ .name = "snippet", .module = snippet_mod },
            .{ .name = "keybind", .module = keybind_mod },
            .{ .name = "syntax", .module = syntax_mod },
        },
    });

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const buffer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/buffer/Buffer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cbor", .module = cbor_mod },
                .{ .name = "TypedInt", .module = typed_int_mod },
                .{ .name = "file_type_config", .module = file_type_config_mod },
            },
        }),
    });

    const run_buffer_tests = b.addRunArtifact(buffer_tests);
    test_step.dependOn(&run_buffer_tests.step);

    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cbor", .module = cbor_mod },
                .{ .name = "TypedInt", .module = typed_int_mod },
                .{ .name = "file_type_config", .module = file_type_config_mod },
                .{ .name = "buffer", .module = buffer_mod },
                .{ .name = "diff", .module = diff_mod },
                .{ .name = "snippet", .module = snippet_mod },
                .{ .name = "syntax", .module = syntax_mod },
            },
        }),
    });

    const run_root_tests = b.addRunArtifact(root_tests);
    test_step.dependOn(&run_root_tests.step);

    // Keybind tests
    const keybind_test_mod = b.createModule(.{
        .root_source_file = b.path("src/keybind/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "input", .module = keybind_input_mod },
        },
    });

    const keybind_tests = b.addTest(.{
        .root_module = keybind_test_mod,
    });

    const run_keybind_tests = b.addRunArtifact(keybind_tests);
    test_step.dependOn(&run_keybind_tests.step);
}
