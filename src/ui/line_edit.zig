//! Einzeiliges Editierfeld: gemeinsame Tasten-, Klick- und Zeichenlogik für
//! alle `explorer_ops.EditBuffer`-Felder (Explorer-Umbenennen/-Anlegen/-Filter,
//! Pfad im Ordner-Dialog, Suchzeile im Picker). Der Aufrufer zeichnet den
//! Rahmen selbst und ruft darin `render` auf; `handleClick` misst am selben
//! Textelement, deshalb spielt der Innenabstand des Rahmens keine Rolle.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const ui = @import("mod.zig");
const Theme = @import("theme.zig").Theme;

/// Feste Eigenschaften eines Felds: Clay-ID des Textelements und Schriftgröße.
pub const Config = struct {
    id: []const u8,
    font_size: f32,
};

/// Ergebnis von `handleKey`: Text geändert (Backspace/Entf), nur Cursor
/// bewegt (Pfeile, Pos1, Ende) oder Taste nicht für das Feld bestimmt.
pub const KeyResult = enum { edited, moved, ignored };

pub fn handleKey(edit: anytype, key: wio.Button) KeyResult {
    switch (key) {
        .backspace => edit.backspace(),
        .delete => edit.delete(),
        .left => edit.moveLeft(),
        .right => edit.moveRight(),
        .home => edit.moveHome(),
        .end => edit.moveEnd(),
        else => return .ignored,
    }
    return switch (key) {
        .backspace, .delete => .edited,
        else => .moved,
    };
}

/// Klick ins Feld: Cursor an die Mausposition `x` (Fensterkoordinate).
/// False, wenn die Maus nicht über dem Textelement steht.
pub fn handleClick(edit: anytype, comptime cfg: Config, x: f32) bool {
    const id = clay.ElementId.ID(cfg.id);
    if (!clay.pointerOver(id)) return false;
    const data = clay.getElementData(id);
    if (!data.found) return false;
    edit.setCursorAtX(ui.measureTextWidth, cfg.font_size, x - data.bounding_box.x);
    return true;
}

/// Text plus Cursorstrich als eigenes Element (füllt die Breite des Rahmens,
/// damit Klicks rechts vom Text den Cursor ans Ende setzen). Der Strich ist
/// ein Rechteck an der gemessenen Textbreite, wie im Editor, statt eines
/// eingefügten "|"-Zeichens, das den Text hinter dem Cursor verschieben würde.
pub fn render(edit: anytype, comptime cfg: Config, color: clay.Color, show_caret: bool, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(cfg.id),
        .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .child_alignment = .{ .y = .center } },
    })({
        clay.text(edit.text(), .{ .font_size = cfg.font_size, .color = color, .wrap_mode = .none });
        // Kein `return` im Block: der Block ist das Argument des schließenden Aufrufs,
        // ein return würde ihn überspringen und das Clay-Layout offen lassen.
        if (show_caret) {
            clay.UI()(.{
                .id = clay.ElementId.ID(cfg.id ++ "_caret"),
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_center, .parent = .left_center },
                    .offset = .{ .x = ui.measureTextWidth(edit.textBeforeCursor(), cfg.font_size), .y = 0 },
                    .z_index = 10,
                    .pointer_capture_mode = .passthrough,
                },
                .layout = .{ .sizing = .{ .w = .fixed(2), .h = .fixed(cfg.font_size) } },
                .background_color = theme.text,
            })({});
        }
    });
}
