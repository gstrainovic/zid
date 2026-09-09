//! Standardpfade für Engine und Modell relativ zum Repo (reine Logik, unit-getestet).
//!
//! Engines und Modelle liegen seit 06.09.2026 im Repo (`engines/`, `models/`), nicht mehr
//! unter `~/projects/ki`. Die ausführbare Datei liegt in `<repo>/zig-out/bin`, daraus folgt die
//! Repo-Wurzel; sonst gilt das Arbeitsverzeichnis.
const std = @import("std");

pub const engine_rel = "engines/llama.cpp-vulkan/build/bin/llama-server";
pub const model_rel = "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";

/// `<repo>/zig-out/bin` → `<repo>`; null, wenn die Datei woanders liegt.
pub fn repoRootFromExeDir(exe_dir: []const u8) ?[]const u8 {
    const suffix = "/zig-out/bin";
    const trimmed = std.mem.trimEnd(u8, exe_dir, "/");
    if (!std.mem.endsWith(u8, trimmed, suffix)) return null;
    const root = trimmed[0 .. trimmed.len - suffix.len];
    return if (root.len == 0) "/" else root;
}

pub fn defaultEngine(alloc: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, engine_rel });
}

pub fn defaultModel(alloc: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, model_rel });
}

const testing = std.testing;

test "repoRootFromExeDir: zig-out/bin → Repo-Wurzel, sonst null" {
    try testing.expectEqualStrings("/x/zid", repoRootFromExeDir("/x/zid/zig-out/bin").?);
    try testing.expectEqualStrings("/x/zid", repoRootFromExeDir("/x/zid/zig-out/bin/").?);
    try testing.expect(repoRootFromExeDir("/usr/local/bin") == null);
}

test "Standardpfade liegen unter engines/ und models/ des Repos, nicht unter HOME" {
    const a = testing.allocator;
    const e = try defaultEngine(a, "/x/zid");
    defer a.free(e);
    try testing.expectEqualStrings("/x/zid/engines/llama.cpp-vulkan/build/bin/llama-server", e);
    const m = try defaultModel(a, "/x/zid");
    defer a.free(m);
    try testing.expectEqualStrings("/x/zid/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf", m);
    try testing.expect(std.mem.indexOf(u8, e, "projects/ki") == null);
}
