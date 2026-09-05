//! Help → Keyboard Shortcuts: modaler Dialog, der alle Bindungen aus
//! shortcuts.zig gruppiert nach Scope auflistet. Keine eigene Logik, nur Anzeige.

const std = @import("std");
const clay = @import("clay");
const shortcuts = @import("shortcuts");
const Theme = @import("theme.zig").Theme;

pub const BOX_ID = "sc_box";
pub const CLOSE_ID = "sc_close";

fn scopeTitle(scope: shortcuts.Scope) []const u8 {
    return switch (scope) {
        .global => "Global",
        .editor => "Editor",
        .explorer => "Explorer (selected entry)",
    };
}

pub fn render(t: Theme) void {
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
                .sizing = .{ .w = .fixed(560) },
                .padding = .all(20),
                .direction = .top_to_bottom,
                .child_gap = 10,
            },
            .background_color = t.surface,
            .border = .{ .width = .all(1), .color = t.border },
            .corner_radius = .all(8),
        })({
            clay.text("Keyboard Shortcuts", .{ .font_size = 26, .color = t.text });

            inline for ([_]shortcuts.Scope{ .global, .editor, .explorer }) |scope| {
                clay.UI()(.{ .layout = .{ .padding = .{ .top = 8 } } })({
                    clay.text(scopeTitle(scope), .{ .font_size = 18, .color = t.accent });
                });
                inline for (shortcuts.bindings) |b| {
                    if (b.scope == scope) {
                        clay.UI()(.{
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fit },
                                .direction = .left_to_right,
                                .padding = .axes(2, 8),
                                .child_alignment = .{ .y = .center },
                            },
                        })({
                            clay.text(shortcuts.label(b.command), .{ .font_size = 20, .wrap_mode = .none, .color = t.text });
                            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                            clay.text(shortcuts.shortcutTextFor(b.key, b.mods), .{ .font_size = 18, .wrap_mode = .none, .color = t.muted });
                        });
                    }
                }
            }

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
