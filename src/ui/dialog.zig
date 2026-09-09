//! Simple Modal Dialog for zid

const std = @import("std");
const clay = @import("clay");
const ui_mod = @import("mod.zig");

pub const DialogResult = enum {
    yes,
    no,
    cancel,
};

pub const DialogAction = struct {
    label: []const u8,
    result: DialogResult,
};

pub const Dialog = struct {
    title: []const u8,
    message: []const u8,
    actions: []const DialogAction,
    
    pub fn render(
        self: @This(),
        theme: ui_mod.Theme,
        mouse_pressed: bool,
        focused: usize,
    ) ?DialogResult {
        var result: ?DialogResult = null;

        // Backdrop
        clay.UI()(.{
            .id = clay.ElementId.ID("DialogBackdrop"),
            .floating = .{
                .attach_to = .to_root,
                .z_index = 2000,
            },
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = .{ 0, 0, 0, 150 },
        })({
            // Dialog Box
            clay.UI()(.{
                .id = clay.ElementId.ID("DialogBox"),
                .layout = .{
                    .sizing = .{ .w = .fixed(400) },
                    .padding = .{ .left = 24, .right = 24, .top = 24, .bottom = 24 },
                    .direction = .top_to_bottom,
                    .child_gap = 16,
                },
                .background_color = theme.surface,
                .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = theme.border },
                .corner_radius = .{ .top_left = 8, .top_right = 8, .bottom_left = 8, .bottom_right = 8 },
            })({
                // Title
                clay.text(self.title, .{ .font_size = 28, .color = theme.text });

                // Message
                clay.text(self.message, .{ .font_size = 20, .color = theme.muted });
                clay.text("Enter bestätigt · Esc bricht ab · Tab wechselt · Anfangsbuchstabe wählt", .{ .font_size = 14, .color = theme.muted });

                // Actions
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .left_to_right,
                        .child_alignment = .{ .x = .right, .y = .center },
                        .child_gap = 12,
                    },
                })({
                    for (self.actions, 0..) |action, i| {
                        const btn_id = clay.ElementId.ID(action.label);
                        const is_hovered = clay.pointerOver(btn_id);
                        const is_focused = i == focused;

                        clay.UI()(.{
                            .id = btn_id,
                            .layout = .{ .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 } },
                            .background_color = if (is_hovered) theme.secondary else theme.primary,
                            .border = .{ .width = .all(2), .color = if (is_focused) theme.border_focus else .{ 0, 0, 0, 0 } },
                            .corner_radius = .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 },
                        })({
                            clay.text(action.label, .{ .font_size = 18, .color = theme.text });
                        });

                        if (is_hovered and mouse_pressed) {
                            result = action.result;
                        }
                    }
                });
            });
        });

        return result;
    }
};
