//! Blätter-Logik der PDF-Vorschau, frei von Clay und wio, damit sie testbar
//! bleibt. Die Ansicht liefert nur ein Seiten-Delta, angewendet wird es in der
//! Hauptschleife.

const std = @import("std");
const shortcuts = @import("shortcuts");

/// Tasten, die im aktiven PDF-Tab blättern. Ctrl-Varianten bleiben beim
/// Tabwechsel, deshalb gilt das nur ohne Modifier. Hoch und Runter bleiben
/// frei: sie navigieren zwischen Panes und im Explorer.
pub fn deltaForKey(key: shortcuts.Key, mods: shortcuts.Mods) ?i16 {
    if (mods.ctrl or mods.alt or mods.shift) return null;
    return switch (key) {
        .page_down, .right => 1,
        .page_up, .left => -1,
        else => null,
    };
}

/// Mausrad: eine Rasterstufe entspricht einer Seite. `lines` ist bereits
/// plattformkorrigiert und folgt der Konvention der App: negativ heißt nach
/// unten, also vorwärts. Kleine Restbeträge von Touchpads blättern nicht.
pub fn deltaForScroll(lines: f32) ?i16 {
    const threshold = 0.5;
    if (lines <= -threshold) return 1;
    if (lines >= threshold) return -1;
    return null;
}

/// Zielseite innerhalb des Dokuments; Ergebnis ist immer gültig.
pub fn clampPage(current: u16, total: u16, delta: i16) u16 {
    if (total == 0) return 0;
    const wanted = @as(i32, current) + delta;
    if (wanted < 0) return 0;
    const last: i32 = @as(i32, total) - 1;
    if (wanted > last) return @intCast(last);
    return @intCast(wanted);
}

pub fn canGoBack(current: u16) bool {
    return current > 0;
}

pub fn canGoForward(current: u16, total: u16) bool {
    return total > 0 and current + 1 < total;
}

/// Beschriftung der Leiste, 1-basiert wie in jedem PDF-Betrachter. Der Puffer
/// muss die UI überleben: Clay merkt sich nur den Zeiger und liest ihn erst
/// beim Zeichnen, ein Stack-Puffer oder die Frame-Arena wären dann weg.
pub fn pageLabel(buf: []u8, current: u16, total: u16) []const u8 {
    return std.fmt.bufPrint(buf, "Seite {d} von {d}", .{ current + 1, total }) catch "Seite ?";
}

/// Trefferprüfung über die Bounding-Box aus dem letzten Layout. Clays
/// `pointerOver` meldet in der PDF-Ansicht nichts, deshalb rechnet die Leiste
/// selbst.
pub const Box = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn hits(box: Box, px: f32, py: f32) bool {
    return box.w > 0 and box.h > 0 and
        px >= box.x and px < box.x + box.w and
        py >= box.y and py < box.y + box.h;
}

const testing = std.testing;

test "Trefferprüfung der Schaltflächen" {
    const box: Box = .{ .x = 100, .y = 200, .w = 60, .h = 40 };
    try testing.expect(hits(box, 130, 220));
    try testing.expect(hits(box, 100, 200));
    try testing.expect(!hits(box, 160, 220));
    try testing.expect(!hits(box, 130, 240));
    try testing.expect(!hits(box, 99, 220));
    // Element fehlt im Layout: Box ist leer, nichts trifft.
    try testing.expect(!hits(Box{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, 0));
}

test "Tasten blättern vor und zurück" {
    try testing.expectEqual(@as(i16, 1), deltaForKey(.page_down, .{}).?);
    try testing.expectEqual(@as(i16, 1), deltaForKey(.right, .{}).?);
    try testing.expectEqual(@as(i16, -1), deltaForKey(.page_up, .{}).?);
    try testing.expect(deltaForKey(.a, .{}) == null);
    // Hoch/Runter bleiben der Navigation zwischen Panes und Explorer.
    try testing.expect(deltaForKey(.up, .{}) == null);
    try testing.expect(deltaForKey(.down, .{}) == null);
}

test "Ctrl+PgDn bleibt der Tabwechsel" {
    try testing.expect(deltaForKey(.page_down, .{ .ctrl = true }) == null);
    try testing.expect(deltaForKey(.right, .{ .alt = true }) == null);
}

test "Mausrad: nach unten vorwärts, kleine Reste ignorieren" {
    // Vorzeichen wie im Rest der App: negative Zeilen heißen nach unten.
    try testing.expectEqual(@as(i16, 1), deltaForScroll(-1.0).?);
    try testing.expectEqual(@as(i16, -1), deltaForScroll(1.0).?);
    try testing.expect(deltaForScroll(0.1) == null);
    try testing.expect(deltaForScroll(0) == null);
}

test "clampPage bleibt im Dokument" {
    try testing.expectEqual(@as(u16, 1), clampPage(0, 12, 1));
    try testing.expectEqual(@as(u16, 0), clampPage(0, 12, -1));
    try testing.expectEqual(@as(u16, 11), clampPage(11, 12, 1));
    try testing.expectEqual(@as(u16, 0), clampPage(5, 0, 1));
}

test "Buttons sind an den Rändern gesperrt" {
    try testing.expect(!canGoBack(0));
    try testing.expect(canGoBack(1));
    try testing.expect(canGoForward(0, 2));
    try testing.expect(!canGoForward(1, 2));
    try testing.expect(!canGoForward(0, 0));
}

test "Beschriftung zählt ab 1 und schreibt in einen fremden Puffer" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Seite 1 von 12", pageLabel(&buf, 0, 12));
    try testing.expectEqualStrings("Seite 12 von 12", pageLabel(&buf, 11, 12));
    // Der Puffer selbst hält den Text, nicht eine Arena, die der Frame verwirft.
    try testing.expectEqualStrings("Seite 12 von 12", buf[0..15]);
}
