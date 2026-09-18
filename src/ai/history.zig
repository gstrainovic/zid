//! Chat-Historie auf ein Zeichenbudget kürzen (reine Logik, unit-getestet).
//!
//! llama-server lehnt Anfragen über `-c` mit HTTP 400 `exceed_context_size_error` ab, statt still
//! zu kürzen (gemessen 06.09.2026). Deshalb schickt der Chat nur den jüngsten Teil der Historie,
//! der ins Budget passt. Ein Fenster beginnt nie mit einem `tool`-Ergebnis: ohne den zugehörigen
//! Assistant-Aufruf ist es für das Modell (und das Jinja-Template) unbrauchbar.
const std = @import("std");

pub const Role = enum { user, assistant, tool };

pub const Entry = struct {
    role: Role,
    chars: usize,
};

/// Index, ab dem die Historie mitgeschickt wird. Die laufende Runde (letzte Frage samt Aufrufen und
/// Werkzeugergebnissen) bleibt immer ganz erhalten, auch wenn sie allein das Budget sprengt: ein
/// Ergebnis ohne Frage und Aufruf verwirft das Chat-Template, das Modell sähe gar nichts.
pub fn keepFrom(entries: []const Entry, budget_chars: usize) usize {
    if (entries.len == 0) return 0;
    const turn = lastUserIndex(entries) orelse entries.len - 1;
    var start = entries.len - 1;
    var used = entries[start].chars;
    while (start > 0) {
        const next = entries[start - 1].chars;
        if (start > turn) {
            used += next;
            start -= 1;
            continue;
        }
        if (used + next > budget_chars) break;
        used += next;
        start -= 1;
    }
    // Nicht mit einem verwaisten Werkzeugergebnis beginnen
    while (start < entries.len - 1 and entries[start].role == .tool) start += 1;
    return start;
}

fn lastUserIndex(entries: []const Entry) ?usize {
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        if (entries[i].role == .user) return i;
    }
    return null;
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

test "keepFrom: alles passt → ab 0" {
    const e = [_]Entry{ .{ .role = .user, .chars = 10 }, .{ .role = .assistant, .chars = 20 }, .{ .role = .user, .chars = 5 } };
    try testing.expectEqual(@as(usize, 0), keepFrom(&e, 100));
}

test "keepFrom: älteste Einträge fallen weg, bis das Budget passt" {
    const e = [_]Entry{ .{ .role = .user, .chars = 50 }, .{ .role = .assistant, .chars = 50 }, .{ .role = .user, .chars = 30 }, .{ .role = .assistant, .chars = 30 }, .{ .role = .user, .chars = 10 } };
    // 10 + 30 + 30 = 70 passt, + 50 nicht
    try testing.expectEqual(@as(usize, 2), keepFrom(&e, 70));
    try testing.expectEqual(@as(usize, 4), keepFrom(&e, 10));
}

test "keepFrom: letzter Eintrag bleibt auch über dem Budget" {
    const e = [_]Entry{ .{ .role = .user, .chars = 5 }, .{ .role = .user, .chars = 500 } };
    try testing.expectEqual(@as(usize, 1), keepFrom(&e, 100));
}

test "keepFrom: Fenster beginnt nie mit einem Werkzeugergebnis" {
    const e = [_]Entry{
        .{ .role = .user, .chars = 10 },
        .{ .role = .assistant, .chars = 100 }, // tool_calls
        .{ .role = .tool, .chars = 40 },
        .{ .role = .tool, .chars = 40 },
        .{ .role = .assistant, .chars = 10 },
        .{ .role = .user, .chars = 10 },
    };
    // Budget 100: 10+10+40+40 = 100 → Start wäre 2 (tool) → vorrücken auf 4
    try testing.expectEqual(@as(usize, 4), keepFrom(&e, 100));
    // Budget 200: der Assistant-Aufruf passt mit → Start 1
    try testing.expectEqual(@as(usize, 1), keepFrom(&e, 200));
}

test "keepFrom: laufende Runde bleibt ganz, auch wenn ein Werkzeugergebnis das Budget sprengt" {
    const e = [_]Entry{
        .{ .role = .user, .chars = 30 }, // ältere Frage
        .{ .role = .assistant, .chars = 50 },
        .{ .role = .user, .chars = 60 }, // aktuelle Frage
        .{ .role = .assistant, .chars = 80 }, // read_file-Aufruf
        .{ .role = .tool, .chars = 20_000 },
    };
    // Ohne Frage und Aufruf weiß das Modell nicht, wozu das Ergebnis gehört
    try testing.expectEqual(@as(usize, 2), keepFrom(&e, 12_000));
}

test "keepFrom: leer und einzelnes Werkzeugergebnis" {
    try testing.expectEqual(@as(usize, 0), keepFrom(&.{}, 10));
    const e = [_]Entry{.{ .role = .tool, .chars = 10 }};
    try testing.expectEqual(@as(usize, 0), keepFrom(&e, 1));
}
