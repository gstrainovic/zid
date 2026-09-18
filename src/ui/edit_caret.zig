//! Cursor für einzeilige Editierfelder (Explorer-Umbenennen, Filter,
//! Ordner-Dialog): Tastensteuerung, Klick-Positionierung und der gezeichnete
//! Strich. Der Puffer ist ein `explorer_ops.EditBuffer`.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const ui = @import("mod.zig");
const Theme = @import("theme.zig").Theme;

/// Cursor- und Löschtasten. True, wenn die Taste verarbeitet wurde
/// (Backspace/Entf ändern den Text, die Pfeile nur den Cursor).
pub fn handleKey(edit: anytype, key: wio.Button) bool {
    switch (key) {
        .backspace => edit.backspace(),
        .delete => edit.delete(),
        .left => edit.moveLeft(),
        .right => edit.moveRight(),
        .home => edit.moveHome(),
        .end => edit.moveEnd(),
        else => return false,
    }
    return true;
}

/// Klick ins Feld `box_id`: Cursor an die Mausposition `x` (Fensterkoordinate).
/// False, wenn die Maus nicht über dem Feld steht.
pub fn handleClick(edit: anytype, comptime box_id: []const u8, x: f32, font_size: f32, pad_left: f32) bool {
    const id = clay.ElementId.ID(box_id);
    if (!clay.pointerOver(id)) return false;
    const data = clay.getElementData(id);
    if (!data.found) return false;
    edit.setCursorAtX(ui.measureTextWidth, font_size, x - data.bounding_box.x - pad_left);
    return true;
}

/// Schmaler Cursorstrich, wie im Editor: eigenes Rechteck an der gemessenen
/// Textbreite statt eines eingefügten "|"-Zeichens, damit sich der Text hinter
/// dem Cursor nicht verschiebt. Innerhalb des Feld-Elements aufrufen.
pub fn render(comptime id: []const u8, before: []const u8, font_size: f32, pad_left: f32, theme: Theme) void {
    const x = pad_left + ui.measureTextWidth(before, font_size);
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .left_center, .parent = .left_center },
            .offset = .{ .x = x, .y = 0 },
            .z_index = 10,
            .pointer_capture_mode = .passthrough,
        },
        .layout = .{ .sizing = .{ .w = .fixed(2), .h = .fixed(font_size) } },
        .background_color = theme.text,
    })({});
}
