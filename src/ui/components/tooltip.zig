//! Tooltips für Icon-Schaltflächen wie in VS Code: erscheinen nach 700 ms über demselben
//! Element unter dem Element. Zustand ist modulweit (eine Maus, ein UI-Thread):
//! `beginFrame`/`endFrame` rahmen das Zeichnen ein, `attach` meldet ein überfahrenes Element
//! und zeichnet den Tooltip, `iconButton` ist der gemeinsame Knopf mit Beschriftung.
//! Der Text muss den Frame überleben (Literal oder Frame-Arena).

const std = @import("std");
const clay = @import("clay");
const ui = @import("../mod.zig");
const Theme = ui.Theme;
const svg = @import("svg.zig");
const hover_delay = @import("hover_delay");

pub const DELAY_MS: f32 = 700;
pub const FONT: u16 = 14;

var hover: hover_delay.Hover = .{};
var now_ms: f32 = 0;
/// Text des in diesem Frame gezeichneten Tooltips (E2E: `ui_state.tooltip`)
var shown: ?[]const u8 = null;

pub fn beginFrame(time_ms: f32) void {
    now_ms = time_ms;
    hover.beginFrame();
    shown = null;
}

pub fn endFrame() void {
    hover.endFrame();
}

pub fn currentText() ?[]const u8 {
    return shown;
}

/// Tooltip steht aus: main.zig rendert weiter, statt auf das nächste Ereignis zu warten.
pub fn pending() bool {
    return hover.pending(now_ms, DELAY_MS);
}

/// Tooltip `label` für das Element `id`, das der Aufrufer selbst zeichnet. Innerhalb oder nach
/// dessen Block aufrufen; `pointerOver` nutzt das Layout des Vorframes.
pub fn attach(theme: Theme, id: clay.ElementId, label: []const u8) void {
    if (clay.pointerOver(id)) hover.note(id.id, now_ms);
    if (!hover.visible(id.id, now_ms, DELAY_MS)) return;
    shown = label;
    clay.UI()(.{
        .id = clay.ElementId.ID("tooltip"),
        .floating = .{
            .attach_to = .to_element_with_id,
            .parentId = id.id,
            .attach_points = .{ .element = .left_top, .parent = .left_bottom },
            .offset = .{ .x = 0, .y = 4 },
            .z_index = 1600,
            .pointer_capture_mode = .passthrough,
        },
        .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 } },
        .background_color = theme.overlay,
        .border = .{ .width = .all(1), .color = theme.border },
        .corner_radius = .all(4),
    })({
        clay.text(label, .{ .font_size = FONT, .color = theme.text, .wrap_mode = .none });
    });
}

pub const Options = struct {
    size: f32 = 24,
    icon_size: f32 = 16,
    /// Eingeschalteter Umschalter (Pin, Collapse Unchanged): Primärfarbe hinterlegt
    toggled: bool = false,
};

/// Icon-Schaltfläche: Hintergrund beim Überfahren, Tooltip `label` nach der Verzögerung.
/// Klicks wertet der Aufrufer über die Bounds von `id` aus.
pub fn iconButton(arena: std.mem.Allocator, theme: Theme, id: clay.ElementId, icon_id: []const u8, icon: []const u8, label: []const u8, opts: Options) void {
    const hovered = clay.pointerOver(id);
    clay.UI()(.{
        .id = id,
        .layout = .{ .sizing = .{ .w = .fixed(opts.size), .h = .fixed(opts.size) }, .child_alignment = .{ .x = .center, .y = .center } },
        .background_color = if (opts.toggled) tint(theme.primary, 60) else if (hovered) tint(theme.text, 30) else .{ 0, 0, 0, 0 },
        .corner_radius = .all(4),
    })({
        // Kontur statt Füllung: Häkchen, Pfeile, Pin sind Linienpfade und blieben gefüllt
        // unsichtbar oder wurden zu Klecksen
        svg.SvgStroke(arena, icon_id, icon, opts.icon_size, theme.text);
        attach(theme, id, label);
    });
}

fn tint(c: clay.Color, alpha: f32) clay.Color {
    return .{ c[0], c[1], c[2], alpha };
}
