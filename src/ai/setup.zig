//! Selbsteinrichtung der KI: wo Engine und Modell liegen, was fehlt, woher es kommt.
//!
//! Ein installiertes zid hat kein Quell-Repo neben sich. Engine (llama-server) und
//! Modell landen deshalb im Datenverzeichnis des Benutzers, und zid lädt sie beim
//! ersten Start selbst nach. Reine Logik über Zeichenketten, damit Pfadbau und
//! Erkennung ohne Netz und ohne Dateien testbar bleiben.

const std = @import("std");
const builtin = @import("builtin");

/// Gepinnt statt „latest": ein Release, das einmal geprüft wurde, bleibt geprüft.
pub const llama_tag = "b11062";

/// Modell laut `src/ai/paths.zig` (gemma-4-E2B-it Q4_0, ggml-org).
pub const model_file = "gemma-4-E2B-it-Q4_0.gguf";
pub const model_url = "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/" ++ model_file;
/// Rund 2,65 GB — für die Anzeige vor dem Laden.
pub const model_bytes: u64 = 2_846_000_000;

pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// Was noch fehlt, bevor der Chat antworten kann.
pub const Status = enum { ready, missing_engine, missing_model, missing_both };

pub fn statusOf(engine_present: bool, model_present: bool) Status {
    if (engine_present and model_present) return .ready;
    if (!engine_present and !model_present) return .missing_both;
    if (engine_present) return .missing_model;
    return .missing_engine;
}

/// Datei aus dem llama.cpp-Release für diese Plattform. Vulkan, weil es auf AMD,
/// Intel und NVIDIA gleichermassen läuft — CUDA wäre schneller, aber nur auf NVIDIA
/// und mit zusätzlicher Laufzeitbibliothek.
pub fn engineAsset() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "llama-" ++ llama_tag ++ "-bin-win-vulkan-x64.zip",
        .macos => if (builtin.cpu.arch == .aarch64)
            "llama-" ++ llama_tag ++ "-bin-macos-arm64.tar.gz"
        else
            "llama-" ++ llama_tag ++ "-bin-macos-x64.tar.gz",
        else => if (builtin.cpu.arch == .aarch64)
            "llama-" ++ llama_tag ++ "-bin-ubuntu-vulkan-arm64.tar.gz"
        else
            "llama-" ++ llama_tag ++ "-bin-ubuntu-vulkan-x64.tar.gz",
    };
}

pub fn engineUrl(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://github.com/ggml-org/llama.cpp/releases/download/{s}/{s}",
        .{ llama_tag, engineAsset() },
    );
}

/// `<AppData>/zid` bzw. `~/.local/share/zid`. Der Aufrufer gibt den Pfad frei.
pub fn dataRoot(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.getAppDataDir(allocator, "zid");
}

/// `<root>/engines/<tag>/llama-server[.exe]`. Die Version steckt im Pfad, damit ein
/// Wechsel des gepinnten Releases nicht in einem halb ausgetauschten Ordner endet.
pub fn enginePath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "engines", llama_tag, "llama-server" ++ exe_suffix });
}

pub fn engineDir(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "engines", llama_tag });
}

pub fn modelPath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "models", model_file });
}

/// Datei vorhanden und nicht leer. Eine leere Datei entsteht bei einem abgebrochenen
/// Download und würde llama-server sonst beim Start stolpern lassen.
pub fn present(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.size > 0;
}

const testing = std.testing;

test "statusOf nennt genau das Fehlende" {
    try testing.expectEqual(Status.ready, statusOf(true, true));
    try testing.expectEqual(Status.missing_model, statusOf(true, false));
    try testing.expectEqual(Status.missing_engine, statusOf(false, true));
    try testing.expectEqual(Status.missing_both, statusOf(false, false));
}

test "Engine-Asset passt zur Plattform und trägt den gepinnten Tag" {
    const asset = engineAsset();
    try testing.expect(std.mem.indexOf(u8, asset, llama_tag) != null);
    switch (builtin.os.tag) {
        .windows => try testing.expect(std.mem.endsWith(u8, asset, "win-vulkan-x64.zip")),
        .macos => try testing.expect(std.mem.endsWith(u8, asset, ".tar.gz")),
        else => try testing.expect(std.mem.indexOf(u8, asset, "ubuntu-vulkan") != null),
    }
}

test "Engine-URL zeigt auf das gepinnte Release" {
    const url = try engineUrl(testing.allocator);
    defer testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, url, "https://github.com/ggml-org/llama.cpp/releases/download/"));
    try testing.expect(std.mem.indexOf(u8, url, llama_tag) != null);
    try testing.expect(std.mem.endsWith(u8, url, engineAsset()));
}

test "Pfade liegen unter engines/<tag> und models" {
    const sep = std.fs.path.sep_str;
    const e = try enginePath(testing.allocator, "/data/zid");
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("/data/zid" ++ sep ++ "engines" ++ sep ++ llama_tag ++ sep ++ "llama-server" ++ exe_suffix, e);

    const m = try modelPath(testing.allocator, "/data/zid");
    defer testing.allocator.free(m);
    try testing.expectEqualStrings("/data/zid" ++ sep ++ "models" ++ sep ++ model_file, m);
}

test "present meldet nur nicht-leere Dateien" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);

    const empty = try std.fs.path.join(testing.allocator, &.{ dir, "leer.bin" });
    defer testing.allocator.free(empty);
    try std.fs.cwd().writeFile(.{ .sub_path = empty, .data = "" });
    try testing.expect(!present(empty));

    const full = try std.fs.path.join(testing.allocator, &.{ dir, "voll.bin" });
    defer testing.allocator.free(full);
    try std.fs.cwd().writeFile(.{ .sub_path = full, .data = "x" });
    try testing.expect(present(full));
    try testing.expect(!present("/gibt/es/nicht"));
}

test "Modell-URL zeigt auf ggml-org und die Datei aus paths.zig" {
    try testing.expect(std.mem.startsWith(u8, model_url, "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/"));
    try testing.expect(std.mem.endsWith(u8, model_url, model_file));
}
