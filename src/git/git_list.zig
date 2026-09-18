//! Virtualisierte Listen mit fester Zeilenhöhe (Timeline, Source Control Graph): welche
//! Zeilen gezeichnet werden, Scrollen zur Auswahl, Klemmen des Scroll-Versatzes. Ohne Clay.

const std = @import("std");

/// Zu zeichnende Zeilen [first, end) einer Liste mit fester Zeilenhöhe, mit `overscan`
/// Zeilen Vorlauf je Richtung.
pub fn visibleRange(scroll: f32, viewport: f32, row_h: f32, count: usize, overscan: usize) struct { first: usize, end: usize } {
    const first_vis: usize = @intFromFloat(@max(0, @floor(scroll / row_h)));
    const last_vis: usize = @intFromFloat(@max(0, @ceil((scroll + viewport) / row_h)));
    const end = @min(count, last_vis + overscan);
    return .{ .first = @min(first_vis -| overscan, end), .end = end };
}

/// Scroll-Versatz, bei dem Zeile `index` ganz im Fenster steht (möglichst wenig bewegt).
pub fn scrollToShow(scroll: f32, viewport: f32, row_h: f32, index: usize) f32 {
    const top = @as(f32, @floatFromInt(index)) * row_h;
    if (top < scroll) return top;
    if (top + row_h > scroll + viewport) return top + row_h - viewport;
    return scroll;
}

pub fn clampScroll(scroll: f32, viewport: f32, row_h: f32, count: usize) f32 {
    const max = @max(0, @as(f32, @floatFromInt(count)) * row_h - viewport);
    return std.math.clamp(scroll, 0, max);
}

test "visibleRange: Vorlauf, Ende, leerer Viewport" {
    // 10 px Zeilen, 50 px sichtbar, 100 px gescrollt → Zeilen 10..15, plus 5 Vorlauf je Seite
    const r = visibleRange(100, 50, 10, 1000, 5);
    try std.testing.expectEqual(@as(usize, 5), r.first);
    try std.testing.expectEqual(@as(usize, 20), r.end);
    const tail = visibleRange(9990, 50, 10, 1000, 5);
    try std.testing.expectEqual(@as(usize, 1000), tail.end);
    const none = visibleRange(0, 50, 10, 0, 5);
    try std.testing.expectEqual(@as(usize, 0), none.first);
    try std.testing.expectEqual(@as(usize, 0), none.end);
}

test "scrollToShow und clampScroll" {
    // Zeile 20 (200..210) liegt unter einem 50-px-Fenster ab 0 → Fenster endet bei 210
    try std.testing.expectEqual(@as(f32, 160), scrollToShow(0, 50, 10, 20));
    // schon sichtbar → unverändert
    try std.testing.expectEqual(@as(f32, 180), scrollToShow(180, 50, 10, 20));
    // über dem Fenster → Zeile oben
    try std.testing.expectEqual(@as(f32, 200), scrollToShow(300, 50, 10, 20));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(-5, 50, 10, 100));
    try std.testing.expectEqual(@as(f32, 950), clampScroll(5000, 50, 10, 100));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(30, 50, 10, 3));
}
