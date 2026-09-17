//! Standardpfade für Engine und Modell relativ zum Repo (reine Logik, unit-getestet).
//!
//! Engines und Modelle liegen seit 06.09.2026 im Repo (`engines/`, `models/`), nicht mehr
//! unter `~/projects/ki`. Die ausführbare Datei liegt in `<repo>/zig-out/bin`, daraus folgt die
//! Repo-Wurzel; sonst gilt das Arbeitsverzeichnis.
const std = @import("std");
const builtin = @import("builtin");

/// Unter Windows heisst die Datei `llama-server.exe`; ohne Endung schlägt der
/// Existenztest in agent.zig fehl und zid fällt still auf Ollama zurück.
pub const engine_rel = "engines/llama.cpp-vulkan/build/bin/llama-server" ++ exe_suffix;
pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
pub const model_rel = "models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf";
/// Windows ohne diskrete GPU: gemma4-E2B ist dort bei gleicher Werkzeugwahl (10/10 im
/// Bench, 7/7 in e2e_ai_tools) rund die Hälfte schneller als Qwen3 (18.2 gegen 11.9 tok/s,
/// llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md). Auf dem Laptop mit P1000 nicht
/// gemessen, deshalb bleibt Qwen3 dort Standard.
pub const model_rel_windows_cpu = "models/gemma-4-E2B-it-Q4_0.gguf";

/// `<repo>/zig-out/bin` → `<repo>`; null, wenn die Datei woanders liegt.
pub fn repoRootFromExeDir(exe_dir: []const u8) ?[]const u8 {
    // Über basename/dirname statt String-Suffix: die kennen beide Trenner
    // (unter Windows auch '/') und schlucken einen Trenner am Ende.
    if (!std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin")) return null;
    const zig_out = std.fs.path.dirname(exe_dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(zig_out), "zig-out")) return null;
    return std.fs.path.dirname(zig_out);
}

pub fn defaultEngine(alloc: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, engine_rel });
}

pub fn defaultModel(alloc: std.mem.Allocator, root: []const u8) ![]u8 {
    return defaultModelFor(alloc, root, false);
}

/// `windows_cpu`: Windows und kein brauchbares Gerät laut `--list-devices` → gemma4-E2B.
pub fn defaultModelFor(alloc: std.mem.Allocator, root: []const u8, windows_cpu: bool) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, if (windows_cpu) model_rel_windows_cpu else model_rel });
}

const testing = std.testing;

test "repoRootFromExeDir: zig-out/bin → Repo-Wurzel, sonst null" {
    try testing.expectEqualStrings("/x/zid", repoRootFromExeDir("/x/zid/zig-out/bin").?);
    try testing.expectEqualStrings("/x/zid", repoRootFromExeDir("/x/zid/zig-out/bin/").?);
    try testing.expect(repoRootFromExeDir("/usr/local/bin") == null);
    try testing.expect(repoRootFromExeDir("/x/zid/bin") == null);
    try testing.expectEqualStrings("/", repoRootFromExeDir("/zig-out/bin").?);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("C:\\x\\zid", repoRootFromExeDir("C:\\x\\zid\\zig-out\\bin").?);
        try testing.expectEqualStrings("C:\\x\\zid", repoRootFromExeDir("C:\\x\\zid\\zig-out\\bin\\").?);
        try testing.expectEqualStrings("C:/x/zid", repoRootFromExeDir("C:/x/zid/zig-out/bin").?);
    }
}

test "Standardpfade liegen unter engines/ und models/ des Repos, nicht unter HOME" {
    const a = testing.allocator;
    const root = "/x/zid";
    const e = try defaultEngine(a, root);
    defer a.free(e);
    // Trenner ist plattformabhängig, deshalb Anfang und Ende statt Volltext prüfen.
    try testing.expect(std.mem.startsWith(u8, e, root ++ std.fs.path.sep_str ++ "engines"));
    try testing.expect(std.mem.endsWith(u8, e, "llama-server" ++ exe_suffix));
    const m = try defaultModel(a, root);
    defer a.free(m);
    try testing.expect(std.mem.startsWith(u8, m, root ++ std.fs.path.sep_str ++ "models"));
    try testing.expect(std.mem.endsWith(u8, m, "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"));
    try testing.expect(std.mem.indexOf(u8, e, "projects/ki") == null);
    const g = try defaultModelFor(a, root, true);
    defer a.free(g);
    try testing.expect(std.mem.startsWith(u8, g, root ++ std.fs.path.sep_str ++ "models"));
    try testing.expect(std.mem.endsWith(u8, g, "gemma-4-E2B-it-Q4_0.gguf"));
}
