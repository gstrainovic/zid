//! Scrollbalken für virtualisierte Ansichten (Editor, Explorer, Terminal), senkrecht
//! und waagrecht: Geometrie, Klick (blättern), Ziehen und Zeichnen. Clay bringt keinen
//! Balken mit, nur Clip-Container mit Offset; die Ansichten hier scrollen ohnehin über
//! eigene Offsets (Zeilen, Spalten). Geometrie und Treffer sind Clay-frei und getestet,
//! nur `render` zeichnet. Eigenes Build-Modul, weil code_editor.zig ein eigenes
//! Test-Root ist.

const std = @import("std");
const clay = @import("clay");

pub const Axis = enum { vertical, horizontal };

/// Zustand der Ansicht für einen Frame. Inhaltseinheiten sind Zeilen bzw. Spalten.
pub const Model = struct {
    axis: Axis,
    /// Linke obere Ecke des Tracks in Fensterpixeln, Länge entlang der Achse, Dicke quer dazu
    x: f32,
    y: f32,
    len: f32,
    thickness: f32,
    /// Gesamtgröße des Inhalts, sichtbarer Anteil, aktueller Offset
    total: usize,
    visible: usize,
    offset: usize,
    /// Größter erlaubter Offset. Nicht immer `total - visible`: der Editor mit Word-Wrap
    /// zählt den Offset in Zeilen, `total` aber in Reihen.
    max_offset: usize,
    min_thumb: f32 = 20,
};

pub const Geometry = struct { thumb_start: f32, thumb_len: f32 };

/// Lage des Thumbs entlang des Tracks, null wenn nichts zu scrollen ist.
pub fn geometry(m: Model) ?Geometry {
    if (m.max_offset == 0) return null;
    const ratio = @as(f32, @floatFromInt(m.visible)) / @as(f32, @floatFromInt(@max(m.total, 1)));
    const thumb_len = @min(m.len, @max(m.min_thumb, m.len * ratio));
    const frac = @as(f32, @floatFromInt(@min(m.offset, m.max_offset))) / @as(f32, @floatFromInt(m.max_offset));
    return .{ .thumb_start = frac * (m.len - thumb_len), .thumb_len = thumb_len };
}

/// Laufendes Ziehen: Mausposition entlang der Achse beim Greifen und Offset zu dem Zeitpunkt
pub const Drag = struct { start: f32, offset_at_start: usize };

pub const Hit = union(enum) { none, thumb: Drag, page_back, page_forward };

/// Klick bei (x, y): Thumb greifen, eine Seite blättern oder nichts (außerhalb der Leiste).
pub fn hitTest(m: Model, x: f32, y: f32) Hit {
    const g = geometry(m) orelse return .none;
    const along = if (m.axis == .vertical) y - m.y else x - m.x;
    const across = if (m.axis == .vertical) x - m.x else y - m.y;
    if (along < 0 or along > m.len or across < 0 or across > m.thickness) return .none;
    if (along >= g.thumb_start and along <= g.thumb_start + g.thumb_len) {
        return .{ .thumb = .{ .start = along, .offset_at_start = m.offset } };
    }
    return if (along < g.thumb_start) .page_back else .page_forward;
}

/// Offset nach einem Klick neben dem Thumb: eine Seite (`visible`) in Klickrichtung.
pub fn pageOffset(m: Model, hit: Hit) usize {
    return switch (hit) {
        .page_back => m.offset -| m.visible,
        .page_forward => @min(m.offset + m.visible, m.max_offset),
        else => m.offset,
    };
}

/// Offset beim Ziehen: Mausweg seit dem Greifen im Verhältnis zum freien Track.
pub fn dragOffset(m: Model, drag: Drag, x: f32, y: f32) usize {
    const g = geometry(m) orelse return drag.offset_at_start;
    const scrollable = m.len - g.thumb_len;
    if (scrollable <= 0) return drag.offset_at_start;
    const along = if (m.axis == .vertical) y - m.y else x - m.x;
    const delta = (along - drag.start) / scrollable * @as(f32, @floatFromInt(m.max_offset));
    const d: isize = @intFromFloat(@round(delta));
    const new = @as(isize, @intCast(drag.offset_at_start)) + d;
    return @intCast(@max(0, @min(new, @as(isize, @intCast(m.max_offset)))));
}

/// Virtualisierte Ansichten mit geschätzten Blockhöhen (Markdown-Vorschau): wird ein Block
/// nachgemessen, der ganz oberhalb der Oberkante liegt, rutscht alles darunter um die
/// Differenz — der sichtbare Inhalt springt. Liefert, um wie viel der Offset mitgehen muss,
/// damit er stehen bleibt: die Differenz für Blöcke über der Kante, 0 für Blöcke, die die
/// Kante schneiden oder darunter liegen. `top` ist die Oberkante des Blocks mit der alten Höhe,
/// in denselben Einheiten wie `offset`.
pub fn anchorShift(offset: f32, top: f32, old: f32, new: f32) f32 {
    if (top + old > offset) return 0;
    return new - old;
}

pub const Ids = struct { track: clay.ElementId, thumb: clay.ElementId };

pub const track_color: clay.Color = .{ 30, 30, 46, 255 };
pub const thumb_color: clay.Color = .{ 88, 88, 120, 200 };

/// Zeichnet Track und Thumb als Floating-Element am Rand des umgebenden Elements:
/// senkrecht rechts oben beginnend, waagrecht links unten. Liefert true, wenn die
/// Maus über der Leiste steht (Aufrufer setzt dann den Pfeil-Cursor).
pub fn render(m: Model, ids: Ids) bool {
    const g = geometry(m) orelse return false;
    var hovered = false;
    const is_vertical = m.axis == .vertical;
    const attach: clay.FloatingAttachPoints = if (is_vertical)
        .{ .element = .right_top, .parent = .right_top }
    else
        .{ .element = .left_bottom, .parent = .left_bottom };
    const track_size: clay.Sizing = if (is_vertical)
        .{ .w = .fixed(m.thickness), .h = .fixed(m.len) }
    else
        .{ .w = .fixed(m.len), .h = .fixed(m.thickness) };
    const thumb_size: clay.Sizing = if (is_vertical)
        .{ .w = .fixed(m.thickness), .h = .fixed(g.thumb_len) }
    else
        .{ .w = .fixed(g.thumb_len), .h = .fixed(m.thickness) };
    const thumb_offset: clay.Vector2 = if (is_vertical) .{ .x = 0, .y = g.thumb_start } else .{ .x = g.thumb_start, .y = 0 };
    clay.UI()(.{
        .id = ids.track,
        .floating = .{ .attach_to = .to_parent, .attach_points = attach, .z_index = 1000 },
        .layout = .{ .sizing = track_size },
        .background_color = track_color,
    })({
        if (clay.hovered()) hovered = true;
        clay.UI()(.{
            .id = ids.thumb,
            .floating = .{
                .attach_to = .to_parent,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = thumb_offset,
                .z_index = 1001,
            },
            .layout = .{ .sizing = thumb_size },
            .background_color = thumb_color,
            .corner_radius = .all(3),
        })({
            if (clay.hovered()) hovered = true;
        });
    });
    return hovered;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn vertical(offset: usize) Model {
    return .{ .axis = .vertical, .x = 300, .y = 50, .len = 100, .thickness = 10, .total = 100, .visible = 10, .offset = offset, .max_offset = 90 };
}

test "geometry: Thumb mindestens min_thumb, Lage proportional zum Offset, null ohne Scrollbedarf" {
    const g0 = geometry(vertical(0)).?;
    try testing.expectEqual(@as(f32, 20), g0.thumb_len);
    try testing.expectEqual(@as(f32, 0), g0.thumb_start);
    const g_end = geometry(vertical(90)).?;
    try testing.expectEqual(@as(f32, 80), g_end.thumb_start);
    const g_over = geometry(vertical(500)).?; // Offset über max: geklemmt
    try testing.expectEqual(@as(f32, 80), g_over.thumb_start);
    var none = vertical(0);
    none.max_offset = 0;
    try testing.expect(geometry(none) == null);
}

test "hitTest: Thumb, Seite zurück/vor, außerhalb nichts, senkrecht und waagrecht" {
    const m = vertical(45); // Thumb 20 px lang bei 40 px
    try testing.expect(hitTest(m, 305, 95) == .thumb);
    try testing.expect(hitTest(m, 305, 60) == .page_back);
    try testing.expect(hitTest(m, 305, 140) == .page_forward);
    try testing.expect(hitTest(m, 295, 95) == .none); // links neben der Leiste
    try testing.expect(hitTest(m, 305, 160) == .none); // unter dem Track
    const grab = hitTest(m, 305, 95).thumb;
    try testing.expectEqual(@as(f32, 45), grab.start);
    try testing.expectEqual(@as(usize, 45), grab.offset_at_start);

    const h: Model = .{ .axis = .horizontal, .x = 0, .y = 400, .len = 200, .thickness = 10, .total = 200, .visible = 50, .offset = 0, .max_offset = 150, .min_thumb = 30 };
    try testing.expect(hitTest(h, 10, 405) == .thumb);
    try testing.expect(hitTest(h, 150, 405) == .page_forward);
    try testing.expect(hitTest(h, 150, 395) == .none);
}

test "anchorShift: nur Blöcke ganz über der Oberkante verschieben den Offset" {
    try testing.expectEqual(@as(f32, 30), anchorShift(500, 100, 50, 80)); // über der Kante, gewachsen
    try testing.expectEqual(@as(f32, -20), anchorShift(500, 100, 50, 30)); // geschrumpft
    try testing.expectEqual(@as(f32, 0), anchorShift(500, 480, 50, 80)); // schneidet die Kante
    try testing.expectEqual(@as(f32, 0), anchorShift(500, 600, 50, 80)); // darunter
    try testing.expectEqual(@as(f32, 30), anchorShift(500, 450, 50, 80)); // Unterkante genau auf der Kante
    try testing.expectEqual(@as(f32, 0), anchorShift(0, 0, 50, 80)); // ganz oben: nichts über der Kante
}

test "pageOffset und dragOffset klemmen auf 0..max_offset" {
    const m = vertical(85);
    try testing.expectEqual(@as(usize, 90), pageOffset(m, .page_forward));
    try testing.expectEqual(@as(usize, 75), pageOffset(m, .page_back));
    try testing.expectEqual(@as(usize, 0), pageOffset(vertical(5), .page_back));
    const drag: Drag = .{ .start = 60, .offset_at_start = 0 };
    try testing.expectEqual(@as(usize, 90), dragOffset(vertical(0), drag, 305, 50 + 60 + 80)); // freier Track 80 px
    try testing.expectEqual(@as(usize, 45), dragOffset(vertical(0), drag, 305, 50 + 60 + 40));
    try testing.expectEqual(@as(usize, 0), dragOffset(vertical(0), drag, 305, 0));
}
