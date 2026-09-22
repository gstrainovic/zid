//! Blätter-Logik der PDF-Vorschau, frei von Clay und wio, damit sie testbar
//! bleibt. Die Ansicht liefert nur ein Seiten-Delta, angewendet wird es in der
//! Hauptschleife.

const std = @import("std");
const shortcuts = @import("shortcuts");
const md_find = @import("md_find.zig");

// ---- Zoom und Bildlauf innerhalb der Seite ----------------------------------------

/// Stufen für Ctrl+Rad, Ctrl+Plus/Minus und die Knöpfe. 1.0 = Seitenbreite.
pub const zoom_levels = [_]f32{ 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0 };

/// Nächste Stufe über bzw. unter `z`; an den Enden bleibt es dabei.
pub fn nextZoom(z: f32, up: bool) f32 {
    if (up) {
        for (zoom_levels) |l| if (l > z + 0.001) return l;
        return zoom_levels[zoom_levels.len - 1];
    }
    var i: usize = zoom_levels.len;
    while (i > 0) {
        i -= 1;
        if (zoom_levels[i] < z - 0.001) return zoom_levels[i];
    }
    return zoom_levels[0];
}

pub fn zoomLabel(buf: []u8, z: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d} %", .{@as(u32, @intFromFloat(@round(z * 100)))}) catch "?";
}

/// Rand um die Seite im Sichtfenster, in Pixeln.
pub const margin: f32 = 8;

/// Lage der Seite im Sichtfenster. `x`/`y` ist die linke obere Ecke relativ zum Fenster
/// (Bildlauf schon abgezogen); passt die Seite in eine Richtung, steht sie dort mittig.
pub const Geometry = struct {
    /// Anzeige-Pixel je pt
    scale: f32,
    w: f32,
    h: f32,
    x: f32,
    y: f32,
    scroll_x: f32,
    scroll_y: f32,
    max_x: f32,
    max_y: f32,
};

/// `zoom` 1.0 füllt die Breite des Fensters (abzüglich Rand). Der Bildlauf wird geklemmt.
pub fn geometry(view_w: f32, view_h: f32, page_w: f32, page_h: f32, zoom: f32, scroll_x: f32, scroll_y: f32) Geometry {
    const base = if (page_w > 0) @max(0.01, (view_w - 2 * margin) / page_w) else 1;
    const scale = base * zoom;
    const w = page_w * scale;
    const h = page_h * scale;
    const max_x = @max(0, w + 2 * margin - view_w);
    const max_y = @max(0, h + 2 * margin - view_h);
    const sx = std.math.clamp(scroll_x, 0, max_x);
    const sy = std.math.clamp(scroll_y, 0, max_y);
    return .{
        .scale = scale,
        .w = w,
        .h = h,
        .x = if (max_x > 0) margin - sx else (view_w - w) / 2,
        .y = if (max_y > 0) margin - sy else (view_h - h) / 2,
        .scroll_x = sx,
        .scroll_y = sy,
        .max_x = max_x,
        .max_y = max_y,
    };
}

/// Neuer Bildlauf nach einem Zoom um den Punkt (ax, ay) im Fenster: der Punkt der Seite
/// darunter bleibt stehen, soweit der Bildlauf es zulässt.
pub fn zoomAround(view_w: f32, view_h: f32, page_w: f32, page_h: f32, old: Geometry, new_zoom: f32, ax: f32, ay: f32) Geometry {
    const u = (ax - old.x) / old.scale;
    const v = (ay - old.y) / old.scale;
    const g0 = geometry(view_w, view_h, page_w, page_h, new_zoom, 0, 0);
    return geometry(view_w, view_h, page_w, page_h, new_zoom, margin + u * g0.scale - ax, margin + v * g0.scale - ay);
}

pub const Wheel = struct { scroll_y: f32, page_delta: i16 = 0 };

/// Mausrad ohne Ctrl: ragt die Seite über das Fenster, scrollt es darin; erst am Rand
/// wird geblättert, zurück landet man am Ende der vorigen Seite. Passt die Seite, blättert
/// jede Rasterstufe wie bisher. `lines` wie `deltaForScroll`.
pub fn wheel(lines: f32, scroll_y: f32, max_y: f32, can_back: bool, can_forward: bool) ?Wheel {
    const px_per_line: f32 = 60;
    if (max_y <= 0) {
        const d = deltaForScroll(lines) orelse return null;
        if ((d > 0 and !can_forward) or (d < 0 and !can_back)) return null;
        return .{ .scroll_y = 0, .page_delta = d };
    }
    if (lines < 0) {
        if (scroll_y >= max_y - 0.5) {
            if (!can_forward or lines > -0.5) return null;
            return .{ .scroll_y = 0, .page_delta = 1 };
        }
        return .{ .scroll_y = @min(max_y, scroll_y - lines * px_per_line) };
    }
    if (lines > 0) {
        if (scroll_y <= 0.5) {
            if (!can_back or lines < 0.5) return null;
            return .{ .scroll_y = std.math.floatMax(f32), .page_delta = -1 };
        }
        return .{ .scroll_y = @max(0, scroll_y - lines * px_per_line) };
    }
    return null;
}

/// Bildlauf, damit der Bereich [y0, y1] der Seite (pt) sichtbar ist; null, wenn er es
/// schon ist. Senkrecht und waagrecht getrennt aufrufen.
pub fn reveal(g: Geometry, lo_pt: f32, hi_pt: f32, view: f32, vertical: bool) ?f32 {
    const max = if (vertical) g.max_y else g.max_x;
    if (max <= 0) return null;
    const scroll = if (vertical) g.scroll_y else g.scroll_x;
    const pos = margin + lo_pt * g.scale;
    return md_find.reveal(pos, (hi_pt - lo_pt) * g.scale, scroll, view, 40, max);
}

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

/// Aufhellung für die überfahrene Schaltfläche. Clay-Farben sind Fließkomma
/// von 0 bis 255: Alpha bleibt, die Kanäle sättigen bei 255.
pub fn brighten(color: [4]f32, amount: f32) [4]f32 {
    return .{
        @min(255, color[0] + amount),
        @min(255, color[1] + amount),
        @min(255, color[2] + amount),
        color[3],
    };
}

const testing = std.testing;

test "Hover hellt auf, sättigt und lässt Alpha in Ruhe" {
    try testing.expectEqual([4]f32{ 40, 60, 80, 200 }, brighten(.{ 10, 30, 50, 200 }, 30));
    try testing.expectEqual([4]f32{ 255, 255, 255, 255 }, brighten(.{ 250, 240, 255, 255 }, 30));
    try testing.expectEqual([4]f32{ 10, 30, 50, 200 }, brighten(.{ 10, 30, 50, 200 }, 0));
}

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

test "Zoomstufen: nächste darüber und darunter, Enden halten" {
    try testing.expectEqual(@as(f32, 1.25), nextZoom(1.0, true));
    try testing.expectEqual(@as(f32, 0.75), nextZoom(1.0, false));
    try testing.expectEqual(@as(f32, 4.0), nextZoom(4.0, true));
    try testing.expectEqual(@as(f32, 0.5), nextZoom(0.5, false));
    try testing.expectEqual(@as(f32, 1.5), nextZoom(1.3, true)); // Zwischenwert
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("125 %", zoomLabel(&buf, 1.25));
}

test "Geometrie: Zoom 1 füllt die Breite, schmale Seite steht mittig" {
    // Fenster 816x700, Seite 400x300 pt: 800x600 px, passt samt Rand
    const g = geometry(816, 700, 400, 300, 1.0, 0, 0);
    try testing.expectEqual(@as(f32, 2), g.scale);
    try testing.expectEqual(@as(f32, 800), g.w);
    try testing.expectEqual(@as(f32, 0), g.max_x);
    try testing.expectEqual(@as(f32, 8), g.x);
    try testing.expectEqual(@as(f32, 50), g.y); // (700 - 600) / 2
    // halbe Größe: waagrecht mittig
    const h = geometry(816, 700, 400, 300, 0.5, 0, 0);
    try testing.expectEqual(@as(f32, 208), h.x);
}

test "Geometrie: Bildlauf wird geklemmt und verschiebt die Seite" {
    const g = geometry(816, 400, 400, 300, 2.0, 5000, 100);
    try testing.expectEqual(@as(f32, 800), g.max_x); // 1600 + 16 - 816
    try testing.expectEqual(@as(f32, 816), g.max_y); // 1200 + 16 - 400
    try testing.expectEqual(@as(f32, 800), g.scroll_x);
    try testing.expectEqual(@as(f32, 8 - 800), g.x);
    try testing.expectEqual(@as(f32, 8 - 100), g.y);
}

test "zoomAround: Punkt unter der Maus bleibt stehen" {
    const old = geometry(816, 400, 400, 300, 2.0, 200, 300);
    const ax: f32 = 300;
    const ay: f32 = 150;
    const u = (ax - old.x) / old.scale;
    const v = (ay - old.y) / old.scale;
    const g = zoomAround(816, 400, 400, 300, old, 3.0, ax, ay);
    try testing.expectApproxEqAbs(ax, g.x + u * g.scale, 0.01);
    try testing.expectApproxEqAbs(ay, g.y + v * g.scale, 0.01);
}

test "Mausrad: in der Seite scrollen, am Rand blättern" {
    // Seite passt: blättern wie bisher, an den Dokumenträndern nichts
    try testing.expectEqual(@as(i16, 1), wheel(-1, 0, 0, true, true).?.page_delta);
    try testing.expect(wheel(-1, 0, 0, true, false) == null);
    // Seite ragt über: erst scrollen
    const w = wheel(-1, 0, 500, true, true).?;
    try testing.expectEqual(@as(i16, 0), w.page_delta);
    try testing.expectEqual(@as(f32, 60), w.scroll_y);
    // unten angekommen: nächste Seite, oben
    const n = wheel(-1, 500, 500, true, true).?;
    try testing.expectEqual(@as(i16, 1), n.page_delta);
    try testing.expectEqual(@as(f32, 0), n.scroll_y);
    // letzte Seite unten: nichts, nicht nach oben springen
    try testing.expect(wheel(-1, 500, 500, true, false) == null);
    // oben zurück: vorige Seite, an deren Ende
    const b = wheel(1, 0, 500, true, true).?;
    try testing.expectEqual(@as(i16, -1), b.page_delta);
    try testing.expect(b.scroll_y > 1e30);
    try testing.expect(wheel(1, 0, 500, false, true) == null);
}

test "reveal: Treffer außerhalb holt den Bildlauf, sichtbar bleibt" {
    const g = geometry(816, 400, 400, 300, 2.0, 0, 0);
    try testing.expect(reveal(g, 10, 20, 400, true) == null);
    const s = reveal(g, 250, 260, 400, true).?;
    try testing.expect(s > 0 and s <= g.max_y);
    // ohne Überstand kein Bildlauf
    const f = geometry(816, 900, 400, 300, 1.0, 0, 0);
    try testing.expect(reveal(f, 250, 260, 900, true) == null);
}

test "Beschriftung zählt ab 1 und schreibt in einen fremden Puffer" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Seite 1 von 12", pageLabel(&buf, 0, 12));
    try testing.expectEqualStrings("Seite 12 von 12", pageLabel(&buf, 11, 12));
    // Der Puffer selbst hält den Text, nicht eine Arena, die der Frame verwirft.
    try testing.expectEqualStrings("Seite 12 von 12", buf[0..15]);
}
