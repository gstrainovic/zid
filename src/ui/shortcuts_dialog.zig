//! Help → Keyboard Shortcuts: modaler Dialog, der alle Bindungen aus
//! shortcuts.zig gruppiert nach Scope auflistet. Keine eigene Logik, nur Anzeige.
//! Zwei Spalten (Global+Explorer links, Editor rechts), damit es in 800px Höhe passt.

const std = @import("std");
const clay = @import("clay");
const shortcuts = @import("shortcuts");
const Theme = @import("theme.zig").Theme;

pub const BOX_ID = "sc_box";
pub const CLOSE_ID = "sc_close";
pub const CONTENT_ID = "sc_content";
/// Sichtbare Höhe der Liste; darüber hinaus wird gescrollt (Mausrad)
pub const LIST_HEIGHT: f32 = 520;

const COLUMN_WIDTH: f32 = 400;

fn scopeTitle(scope: shortcuts.Scope) []const u8 {
    return switch (scope) {
        .global => "Global",
        .editor => "Editor",
        .explorer => "Explorer (selected entry)",
    };
}

fn renderScope(comptime scope: shortcuts.Scope, t: Theme) void {
    clay.UI()(.{ .layout = .{ .padding = .{ .top = 6, .bottom = 2 } } })({
        clay.text(scopeTitle(scope), .{ .font_size = 18, .color = t.accent });
    });
    inline for (shortcuts.bindings) |b| {
        if (b.scope == scope) {
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fit },
                    .direction = .left_to_right,
                    .padding = .axes(1, 8),
                    .child_alignment = .{ .y = .center },
                },
            })({
                clay.text(shortcuts.label(b.command), .{ .font_size = 19, .wrap_mode = .none, .color = t.text });
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                clay.text(shortcuts.shortcutTextFor(b.key, b.mods), .{ .font_size = 17, .wrap_mode = .none, .color = t.muted });
            });
        }
    }
}

pub fn render(t: Theme, scroll_y: f32) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("sc_backdrop"),
        .floating = .{ .attach_to = .to_root, .z_index = 2000 },
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = .{ 0, 0, 0, 150 },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID(BOX_ID),
            .layout = .{
                .sizing = .{ .w = .fit },
                .padding = .all(20),
                .direction = .top_to_bottom,
                .child_gap = 8,
            },
            .background_color = t.surface,
            .border = .{ .width = .all(1), .color = t.border },
            .corner_radius = .all(8),
        })({
            clay.text("Keyboard Shortcuts", .{ .font_size = 26, .color = t.text });

            clay.UI()(.{
                .id = clay.ElementId.ID("sc_viewport"),
                .layout = .{ .sizing = .{ .w = .fixed(COLUMN_WIDTH * 2 + 32), .h = .fixed(LIST_HEIGHT) } },
                .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -scroll_y } },
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID(CONTENT_ID),
                    .layout = .{ .direction = .left_to_right, .child_gap = 32, .sizing = .{ .w = .grow, .h = .fit } },
                })({
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(COLUMN_WIDTH) }, .direction = .top_to_bottom } })({
                        renderScope(.global, t);
                        renderScope(.explorer, t);
                    });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(COLUMN_WIDTH) }, .direction = .top_to_bottom } })({
                        renderScope(.editor, t);
                    });
                });
            });
            clay.text("Mausrad scrollt", .{ .font_size = 14, .color = t.muted });

            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fit },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .right, .y = .center },
                    .padding = .{ .top = 8 },
                },
            })({
                const close_id = clay.ElementId.ID(CLOSE_ID);
                const hover = clay.pointerOver(close_id);
                clay.UI()(.{
                    .id = close_id,
                    .layout = .{ .padding = .{ .left = 18, .right = 18, .top = 8, .bottom = 8 } },
                    .background_color = if (hover) t.secondary else t.primary,
                    .border = .{ .width = .all(1), .color = t.border },
                    .corner_radius = .all(4),
                })({
                    clay.text("Close", .{ .font_size = 20, .color = t.text_on_primary });
                });
            });
        });
    });
}
