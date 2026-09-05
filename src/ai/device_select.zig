//! Gerätewahl für llama-server: parst `llama-server --list-devices` und wählt
//! eine diskrete GPU mit genug Speicher, sonst CPU. Reine Logik, unit-getestet.
//!
//! Beispielausgabe:
//!   Available devices:
//!     Vulkan0: Intel(R) UHD Graphics 630 (CFL GT2) (35976 MiB, 32378 MiB free)
//!     Vulkan1: Quadro P1000 (4342 MiB, 4263 MiB free)

const std = @import("std");

pub const Device = struct {
    /// Bezeichner für `-dev`, z.B. "Vulkan1"
    id: []const u8,
    /// Anzeigename, z.B. "Quadro P1000"
    name: []const u8,
    total_mib: u64,
    free_mib: u64,
};

pub const Choice = union(enum) {
    gpu: Device,
    cpu,

    pub fn label(self: Choice) []const u8 {
        return switch (self) {
            .gpu => |d| d.name,
            .cpu => "CPU",
        };
    }
};

/// Integrierte GPUs teilen sich den RAM und melden absurde Größen; sie sind
/// laut Messung (UHD 630: ein Drittel der CPU) nie die richtige Wahl.
pub fn isIntegrated(name: []const u8) bool {
    const markers = [_][]const u8{ "Intel", "UHD", "Iris", "Radeon Graphics", "Radeon(TM) Graphics", "Vega 8", "llvmpipe", "SwiftShader" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, name, m) != null) return true;
    }
    return false;
}

/// Eine Zeile wie "  Vulkan1: Quadro P1000 (4342 MiB, 4263 MiB free)" parsen.
pub fn parseLine(line: []const u8) ?Device {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    const id = trimmed[0..colon];
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, ' ') != null) return null;
    const rest = std.mem.trim(u8, trimmed[colon + 1 ..], " ");
    // Letzte Klammer enthält "(TOTAL MiB, FREE MiB free)"
    const open = std.mem.lastIndexOfScalar(u8, rest, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, rest, ')') orelse return null;
    if (close <= open) return null;
    const mem = rest[open + 1 .. close];
    var it = std.mem.splitScalar(u8, mem, ',');
    const total = parseMib(it.next() orelse return null) orelse return null;
    const free = parseMib(it.next() orelse return null) orelse return null;
    return .{
        .id = id,
        .name = std.mem.trim(u8, rest[0..open], " "),
        .total_mib = total,
        .free_mib = free,
    };
}

fn parseMib(text: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, text, " ");
    const num = it.next() orelse return null;
    return std.fmt.parseInt(u64, num, 10) catch null;
}

/// Beste diskrete GPU mit mindestens `min_total_mib` Gesamtspeicher, sonst CPU.
pub fn choose(list_output: []const u8, min_total_mib: u64) Choice {
    var best: ?Device = null;
    var lines = std.mem.splitScalar(u8, list_output, '\n');
    while (lines.next()) |line| {
        const dev = parseLine(line) orelse continue;
        if (isIntegrated(dev.name)) continue;
        if (dev.total_mib < min_total_mib) continue;
        if (best == null or dev.total_mib > best.?.total_mib) best = dev;
    }
    if (best) |d| return .{ .gpu = d };
    return .cpu;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const sample =
    \\Available devices:
    \\  Vulkan0: Intel(R) UHD Graphics 630 (CFL GT2) (35976 MiB, 32378 MiB free)
    \\  Vulkan1: Quadro P1000 (4342 MiB, 4263 MiB free)
;

test "parseLine: Bezeichner, Name mit Klammern, Speicher" {
    const d = parseLine("  Vulkan0: Intel(R) UHD Graphics 630 (CFL GT2) (35976 MiB, 32378 MiB free)").?;
    try testing.expectEqualStrings("Vulkan0", d.id);
    try testing.expectEqualStrings("Intel(R) UHD Graphics 630 (CFL GT2)", d.name);
    try testing.expectEqual(@as(u64, 35976), d.total_mib);
    try testing.expectEqual(@as(u64, 32378), d.free_mib);
    try testing.expect(parseLine("Available devices:") == null);
    try testing.expect(parseLine("") == null);
}

test "choose: diskrete GPU vor iGPU, iGPU wird ignoriert" {
    const c = choose(sample, 3000);
    try testing.expectEqualStrings("Vulkan1", c.gpu.id);
    try testing.expectEqualStrings("Quadro P1000", c.label());
}

test "choose: nur iGPU oder zu wenig Speicher → CPU" {
    const only_igpu =
        \\Available devices:
        \\  Vulkan0: Intel(R) UHD Graphics 630 (CFL GT2) (35976 MiB, 32378 MiB free)
    ;
    try testing.expect(choose(only_igpu, 3000) == .cpu);
    try testing.expect(choose(sample, 8000) == .cpu);
    try testing.expect(choose("", 3000) == .cpu);
    try testing.expectEqualStrings("CPU", choose("", 3000).label());
}

test "choose: bei mehreren diskreten GPUs die mit dem meisten Speicher" {
    const two =
        \\  Vulkan0: NVIDIA GeForce RTX 3060 (12288 MiB, 12000 MiB free)
        \\  Vulkan1: Quadro P1000 (4342 MiB, 4263 MiB free)
    ;
    try testing.expectEqualStrings("Vulkan0", choose(two, 3000).gpu.id);
}
