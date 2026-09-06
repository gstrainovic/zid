//! Gemeinsames Kontextmenü für Tab-Kopf, Editor-Text, Markdown-Vorschau, Terminal und
//! Explorer: ein Stil aus dem Theme, Einträge und Kürzel aus `shortcuts`, Clay-IDs
//! `<prefix>_<command>` (stabil für E2E), Anker `<prefix>_anchor`, Rahmen `<prefix>_container`.
//! Eigenes Modul, weil code_editor.zig ein eigenes Test-Root ist (wie `shortcuts`).

const std = @import("std");
const clay = @import("clay");
const shortcuts = @import("shortcuts");

pub const Command = shortcuts.Command;
/// Einträge, die in diesem Zustand nicht gezeigt werden (z.B. Markdown Preview ohne .md)
pub const Hidden = std.EnumSet(Command);
pub const none: Hidden = Hidden.initEmpty();

pub const row_height: f32 = 30;
pub const row_gap: f32 = 2;
pub const padding: f32 = 4;
pub const item_width: f32 = 330;
const label_size: u16 = 18;
const shortcut_size: u16 = 14;

/// Farben des Menüs: Teilmenge des UI-Themes, damit auch der Editor (ohne Theme-Import)
/// zeichnen kann. `fromTheme` nimmt jeden Typ mit den Feldern overlay, border, primary,
/// text, text_on_primary und muted.
pub const Colors = struct {
    bg: clay.Color,
    border: clay.Color,
    hover: clay.Color,
    text: clay.Color,
    text_hover: clay.Color,
    muted: clay.Color,

    pub fn fromTheme(t: anytype) Colors {
        return .{
            .bg = t.overlay,
            .border = t.border,
            .hover = t.primary,
            .text = t.text,
            .text_hover = t.text_on_primary,
            .muted = t.muted,
        };
    }

    /// Catppuccin Macchiato, bis `fromTheme` das echte Theme liefert
    pub const dark: Colors = .{
        .bg = .{ 69, 71, 90, 255 },
        .border = .{ 69, 71, 90, 255 },
        .hover = .{ 138, 173, 244, 255 },
        .text = .{ 202, 211, 245, 255 },
        .text_hover = .{ 30, 30, 46, 255 },
        .muted = .{ 108, 112, 134, 255 },
    };
};

/// Gesamthöhe eines Menüs mit `visible` Einträgen (zum Verschieben am unteren Rand)
pub fn height(visible: usize) f32 {
    if (visible == 0) return 2 * padding;
    const n: f32 = @floatFromInt(visible);
    return n * row_height + (n - 1) * row_gap + 2 * padding;
}

pub fn visibleCount(items: []const Command, hidden: Hidden) usize {
    var n: usize = 0;
    for (items) |cmd| {
        if (!hidden.contains(cmd)) n += 1;
    }
    return n;
}

pub fn itemId(comptime prefix: []const u8, comptime cmd: Command) clay.ElementId {
    return clay.ElementId.ID(prefix ++ "_" ++ @tagName(cmd));
}

/// Menü schwebend an (x, y) zeichnen. Liefert true, wenn der Zeiger über dem Menü steht
/// (Aufrufer setzt dann den Pfeil-Cursor).
pub fn render(comptime prefix: []const u8, comptime items: []const Command, x: f32, y: f32, hidden: Hidden, colors: Colors) bool {
    var over = false;
    clay.UI()(.{
        .id = clay.ElementId.ID(prefix ++ "_anchor"),
        .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(0) } },
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .offset = .{ .x = x, .y = y },
            .z_index = 1000,
        },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID(prefix ++ "_container"),
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .top_to_bottom,
                .padding = .all(padding),
                .child_gap = row_gap,
            },
            .background_color = colors.bg,
            .border = .{ .width = .all(1), .color = colors.border },
            .corner_radius = .all(4),
        })({
            over = clay.hovered();
            inline for (items) |cmd| {
                if (!hidden.contains(cmd)) renderItem(itemId(prefix, cmd), shortcuts.label(cmd), shortcuts.shortcutText(cmd), colors);
            }
        });
    });
    return over;
}

fn renderItem(id: clay.ElementId, label: []const u8, shortcut: []const u8, colors: Colors) void {
    const hovered = clay.pointerOver(id);
    clay.UI()(.{
        .id = id,
        .layout = .{
            .sizing = .{ .w = .fixed(item_width), .h = .fixed(row_height) },
            .padding = .{ .left = 12, .right = 12 },
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 8,
        },
        .background_color = if (hovered) colors.hover else .{ 0, 0, 0, 0 },
        .corner_radius = .all(3),
    })({
        clay.text(label, .{ .font_size = label_size, .color = if (hovered) colors.text_hover else colors.text, .wrap_mode = .none });
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
        if (shortcut.len > 0) clay.text(shortcut, .{ .font_size = shortcut_size, .color = if (hovered) colors.text_hover else colors.muted, .wrap_mode = .none });
    });
}

/// Nach einem Mouse-Down bei offenem Menü: der Eintrag unter dem Zeiger, sonst null.
/// `hidden` muss dem Zustand beim Zeichnen entsprechen.
pub fn hit(comptime prefix: []const u8, comptime items: []const Command, hidden: Hidden) ?Command {
    inline for (items) |cmd| {
        if (!hidden.contains(cmd) and clay.pointerOver(itemId(prefix, cmd))) return cmd;
    }
    return null;
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "height: Zeilen plus Abstände plus Innenrand" {
    try testing.expectEqual(@as(f32, 2 * padding), height(0));
    try testing.expectEqual(@as(f32, row_height + 2 * padding), height(1));
    try testing.expectEqual(@as(f32, 3 * row_height + 2 * row_gap + 2 * padding), height(3));
}

test "visibleCount: ausgeblendete Einträge zählen nicht" {
    var hidden = none;
    hidden.insert(.md_preview);
    try testing.expectEqual(@as(usize, shortcuts.editor_menu_items.len - 1), visibleCount(&shortcuts.editor_menu_items, hidden));
    try testing.expectEqual(@as(usize, shortcuts.editor_menu_items.len), visibleCount(&shortcuts.editor_menu_items, none));
}

test "Colors.fromTheme: nimmt jeden Typ mit den Theme-Feldern" {
    const FakeTheme = struct {
        overlay: clay.Color = .{ 1, 1, 1, 255 },
        border: clay.Color = .{ 2, 2, 2, 255 },
        primary: clay.Color = .{ 3, 3, 3, 255 },
        text: clay.Color = .{ 4, 4, 4, 255 },
        text_on_primary: clay.Color = .{ 5, 5, 5, 255 },
        muted: clay.Color = .{ 6, 6, 6, 255 },
        unused: u8 = 0,
    };
    const c = Colors.fromTheme(FakeTheme{});
    try testing.expectEqual(@as(f32, 1), c.bg[0]);
    try testing.expectEqual(@as(f32, 3), c.hover[0]);
    try testing.expectEqual(@as(f32, 5), c.text_hover[0]);
    try testing.expectEqual(@as(f32, 6), c.muted[0]);
}
