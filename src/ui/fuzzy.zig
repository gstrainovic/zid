//! Fuzzy-Matching für Schnellöffner (Ctrl+P) und Command Palette (Ctrl+Shift+P).
//! Reine Funktionen, unit-getestet.
//!
//! Regel: alle Zeichen der Anfrage müssen in Reihenfolge im Kandidaten vorkommen
//! (Groß/Klein egal). Punkte: Treffer direkt hintereinander, am Wort-/Pfadanfang und
//! im Dateinamen (nach dem letzten `/`) zählen mehr; kürzere Kandidaten gewinnen bei Gleichstand.

const std = @import("std");

pub const Match = struct { index: usize, score: i32 };

/// null = kein Treffer. Leere Anfrage trifft alles mit Punktzahl 0.
pub fn score(query: []const u8, candidate: []const u8) ?i32 {
    if (query.len == 0) return 0;
    const name_start = if (std.mem.lastIndexOfScalar(u8, candidate, '/')) |i| i + 1 else 0;
    var total: i32 = 0;
    var qi: usize = 0;
    var last_hit: ?usize = null;
    var ci: usize = 0;
    while (ci < candidate.len and qi < query.len) : (ci += 1) {
        if (std.ascii.toLower(candidate[ci]) != std.ascii.toLower(query[qi])) continue;
        var pts: i32 = 1;
        if (last_hit != null and last_hit.? + 1 == ci) pts += 4; // direkt hintereinander zählt am meisten
        if (ci == 0 or candidate[ci - 1] == '/' or candidate[ci - 1] == '_' or candidate[ci - 1] == '-' or candidate[ci - 1] == '.' or candidate[ci - 1] == ' ') pts += 2; // Wortanfang
        if (ci >= name_start) pts += 2; // im Dateinamen
        total += pts;
        last_hit = ci;
        qi += 1;
    }
    if (qi < query.len) return null;
    // Kürzere Kandidaten leicht bevorzugen
    total -= @intCast(@min(candidate.len, 200) / 20);
    return total;
}

/// Kandidaten nach Punktzahl absteigend in `out` schreiben (höchstens out.len), liefert die Anzahl.
pub fn rank(query: []const u8, candidates: []const []const u8, out: []Match) usize {
    var n: usize = 0;
    for (candidates, 0..) |c, i| {
        const sc = score(query, c) orelse continue;
        // Einfügen in die absteigend sortierte Liste (Insertion, out ist klein)
        var pos = n;
        while (pos > 0 and out[pos - 1].score < sc) : (pos -= 1) {}
        if (pos >= out.len) continue;
        const end = @min(n, out.len - 1);
        var j = end;
        while (j > pos) : (j -= 1) out[j] = out[j - 1];
        out[pos] = .{ .index = i, .score = sc };
        if (n < out.len) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

test "score: Teilfolge in Reihenfolge, Groß/Klein egal, sonst null" {
    try testing.expect(score("mod", "src/ui/mod.zig") != null);
    try testing.expect(score("MOD", "src/ui/mod.zig") != null);
    try testing.expect(score("uimod", "src/ui/mod.zig") != null);
    try testing.expect(score("modui", "src/ui/mod.zig") == null); // falsche Reihenfolge
    try testing.expect(score("xyz", "src/ui/mod.zig") == null);
    try testing.expectEqual(@as(i32, 0), score("", "anything").?);
}

test "score: Dateiname und Wortanfänge schlagen verstreute Treffer" {
    const in_name = score("mod", "src/ui/mod.zig").?;
    const scattered = score("mod", "some/random/directory.zig").?; // m…o…d verstreut
    try testing.expect(in_name > scattered);
    const consecutive = score("edit", "src/editor/code_editor.zig").?;
    const spread = score("edit", "e/x/d/i/t.zig").?;
    try testing.expect(consecutive > spread);
}

test "rank: sortiert absteigend, respektiert die Ausgabegröße" {
    const cands = [_][]const u8{ "README.md", "src/ui/mod.zig", "src/editor/edit_ops.zig", "build.zig" };
    var out: [8]Match = undefined;
    const n = rank("mod", &cands, &out);
    try testing.expectEqual(@as(usize, 1), n); // nur mod.zig enthält m…o…d
    try testing.expectEqual(@as(usize, 1), out[0].index);
    const all = rank("zig", &cands, &out);
    try testing.expectEqual(@as(usize, 3), all);
    try testing.expect(out[0].score >= out[1].score and out[1].score >= out[2].score);
    var small: [1]Match = undefined;
    try testing.expectEqual(@as(usize, 1), rank("zig", &cands, &small));
}

test "rank: findet den Treffer auch in einer großen Liste mit voller Ausgabe" {
    const a = testing.allocator;
    var cands: std.ArrayList([]const u8) = .empty;
    defer {
        for (cands.items) |c| a.free(c);
        cands.deinit(a);
    }
    var i: usize = 0;
    while (i < 3000) : (i += 1) try cands.append(a, try std.fmt.allocPrint(a, "dir{d}/file{d}.txt", .{ i % 50, i }));
    try cands.append(a, try a.dupe(u8, "src/ui/mod.zig"));
    var out: [200]Match = undefined;
    const n = rank("mod", cands.items, &out);
    try testing.expect(n >= 1);
    try testing.expectEqual(@as(usize, 3000), out[0].index);
    const all = rank("", cands.items, &out);
    try testing.expectEqual(@as(usize, 200), all);
}
