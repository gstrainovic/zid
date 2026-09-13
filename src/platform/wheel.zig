//! Mausrad → Zeilen-Delta für `UI.handleScroll`.
//!
//! wio liefert auf allen Plattformen dasselbe Vorzeichen: positiv heißt „Rad nach
//! unten“ (Wayland und X11 nativ, Windows, macOS und Android dreht wio selbst um).
//! Die UI versteht ein positives Zeilen-Delta als „nach oben“ (`scrollLines`),
//! deshalb wird hier überall gespiegelt, ohne Sonderfall je Betriebssystem.
const std = @import("std");

/// Rad-Delta aus wio in ganze Zeilen; Bruchteile werden gerundet.
pub fn wheelLines(delta: f32) i32 {
    const lines: i32 = @intFromFloat(@round(delta));
    return -lines;
}

test "Rad nach unten scrollt nach unten" {
    // wio: +1 = ein Rastpunkt nach unten → UI: negativ = Ansicht nach unten
    try std.testing.expectEqual(@as(i32, -1), wheelLines(1.0));
    try std.testing.expectEqual(@as(i32, -3), wheelLines(3.0));
}

test "Rad nach oben scrollt nach oben, Bruchteile werden gerundet" {
    // Wayland liefert je Rastpunkt oft 1.5
    try std.testing.expectEqual(@as(i32, 2), wheelLines(-1.5));
    try std.testing.expectEqual(@as(i32, -2), wheelLines(1.5));
    try std.testing.expectEqual(@as(i32, 0), wheelLines(0.3));
}
