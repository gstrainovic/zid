//! Schaltfläche mit einheitlichem Aussehen: Farbe nach Rolle, Aufhellen beim
//! Überfahren, Rahmen, runde Ecken.
//!
//! Der Treffer wird gegen die Box aus dem letzten Layout gerechnet, nicht über
//! `clay.pointerOver`: im Frame eines RPC-Klicks kennt Clay die neue Zeigerposition
//! noch nicht, der Klick ginge verloren (dasselbe Problem wie in `pdf_view.zig`).

const std = @import("std");
const clay = @import("clay");
const Theme = @import("../theme.zig").Theme;

/// Rolle der Schaltfläche; bestimmt Farbe und Rahmen.
pub const Variant = enum {
    /// Hauptaktion: Akzentfarbe, heller Text.
    primary,
    /// Nebenaktion: Flächenfarbe, normaler Text.
    secondary,
    /// Unauffällig: kein Hintergrund, bis man darüberfährt.
    ghost,
};

pub const Options = struct {
    variant: Variant = .primary,
    font_size: u16 = 15,
    /// Gesperrt: gedämpft gezeichnet, Klicks zählen nicht.
    disabled: bool = false,
    padding_x: u16 = 16,
    padding_y: u16 = 10,
};

fn brighten(c: clay.Color, amount: f32) clay.Color {
    return .{ @min(255, c[0] + amount), @min(255, c[1] + amount), @min(255, c[2] + amount), c[3] };
}

/// Zeiger über dem Element? Box aus dem letzten Layout.
pub fn hovered(id: clay.ElementId, mouse_x: f32, mouse_y: f32) bool {
    const data = clay.getElementData(id);
    if (!data.found) return false;
    const b = data.bounding_box;
    return mouse_x >= b.x and mouse_x < b.x + b.width and mouse_y >= b.y and mouse_y < b.y + b.height;
}

/// Zeichnet die Schaltfläche. Rückgabe: in diesem Frame angeklickt.
pub fn button(
    id: []const u8,
    text: []const u8,
    theme: Theme,
    mouse_x: f32,
    mouse_y: f32,
    mouse_pressed: bool,
    opts: Options,
) bool {
    const element_id = clay.ElementId.ID(id);
    const is_hovered = !opts.disabled and hovered(element_id, mouse_x, mouse_y);

    const bg: clay.Color = switch (opts.variant) {
        .primary => if (opts.disabled) theme.surface else if (is_hovered) brighten(theme.primary, 30) else theme.primary,
        .secondary => if (is_hovered) theme.border else theme.surface,
        .ghost => if (is_hovered) theme.border else .{ 0, 0, 0, 0 },
    };
    const border: clay.Color = switch (opts.variant) {
        .primary => if (opts.disabled) theme.border else if (is_hovered) theme.border_focus else theme.accent,
        .secondary => theme.border,
        .ghost => if (is_hovered) theme.border else .{ 0, 0, 0, 0 },
    };
    const fg: clay.Color = switch (opts.variant) {
        .primary => if (opts.disabled) theme.muted else theme.text_on_primary,
        .secondary => if (opts.disabled) theme.muted else theme.text,
        .ghost => if (opts.disabled) theme.muted else theme.subtext,
    };

    clay.UI()(.{
        .id = element_id,
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .axes(opts.padding_x, opts.padding_y),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = bg,
        .corner_radius = .all(6),
        .border = .{ .width = .all(2), .color = border },
    })({
        clay.text(text, .{ .font_size = opts.font_size, .color = fg, .wrap_mode = .none });
    });

    return is_hovered and mouse_pressed;
}
