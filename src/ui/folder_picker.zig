//! "Open Folder"-Dialog (modal): editierbarer Pfad, Liste der Unterordner,
//! ↑ zum Elternordner, Open/Cancel. Die Logik steckt in folder_ops.Picker,
//! hier sind nur Darstellung (Clay) und die Zuordnung von Klicks/Tasten.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const folder_ops = @import("folder_ops.zig");
const Theme = @import("theme.zig").Theme;
const svg = @import("components/svg.zig");
const tooltip = @import("components/tooltip.zig");
const line_edit = @import("line_edit.zig");

/// Pfadfeld (Textelement-ID, Schriftgröße)
const path_field: line_edit.Config = .{ .id = "fp_input_text", .font_size = 20 };

const log = std.log.scoped(.folder_picker);

pub const ROW_HEIGHT: f32 = 34;
const LIST_HEIGHT: f32 = 12 * ROW_HEIGHT;
const BOX_WIDTH: f32 = 640;

pub const FolderPicker = struct {
    model: folder_ops.Picker,
    visible: bool = false,
    /// Bestätigter Ordner (owned), von der UI per takeResult abzuholen
    result: ?[]u8 = null,
    scroll_y: f32 = 0,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .model = folder_ops.Picker.init(alloc) };
    }

    pub fn deinit(self: *Self) void {
        if (self.result) |r| self.model.alloc.free(r);
        self.result = null;
        self.model.deinit();
    }

    /// Dialog im Startordner öffnen.
    pub fn open(self: *Self, start_dir: []const u8) void {
        self.model.start(start_dir) catch |err| {
            log.warn("folder picker start '{s}' failed: {}", .{ start_dir, err });
        };
        self.scroll_y = 0;
        self.visible = true;
    }

    pub fn close(self: *Self) void {
        self.visible = false;
    }

    pub fn takeResult(self: *Self) ?[]u8 {
        const r = self.result orelse return null;
        self.result = null;
        return r;
    }

    fn confirm(self: *Self) void {
        const chosen = self.model.confirm() orelse return;
        if (self.result) |old| self.model.alloc.free(old);
        self.result = chosen;
        self.visible = false;
    }

    pub fn handleKey(self: *Self, key: wio.Button, mods: line_edit.Mods, clip: ?line_edit.Clipboard) void {
        switch (key) {
            .enter, .kp_enter => self.confirm(),
            .escape => self.close(),
            else => if (line_edit.handleKey(&self.model.edit, key, mods, clip) == .edited) self.model.clearError(),
        }
    }

    /// Maus mit gedrückter Taste: Auswahl im Pfadfeld ziehen.
    pub fn handleMouseMove(self: *Self, x: f32) void {
        line_edit.handleDrag(&self.model.edit, path_field, x);
    }

    pub fn handleMouseUp(self: *Self) void {
        line_edit.handleRelease(&self.model.edit);
    }

    pub fn handleChar(self: *Self, cp: u21) void {
        if (cp < 32 or cp == 127) return;
        self.model.insertCodepoint(cp);
    }

    pub fn handleScroll(self: *Self, lines: i32) void {
        const content = @as(f32, @floatFromInt(self.model.entries.len)) * ROW_HEIGHT;
        const max_scroll = @max(0, content - LIST_HEIGHT);
        self.scroll_y = std.math.clamp(self.scroll_y - @as(f32, @floatFromInt(lines)) * ROW_HEIGHT, 0, max_scroll);
    }

    /// Klick im Dialog auswerten (Hover-Zustand des letzten Layouts, `x` in Fensterkoordinaten).
    pub fn handleMouseDown(self: *Self, x: f32, shift: bool) void {
        if (line_edit.handleClick(&self.model.edit, path_field, x, shift)) return;
        if (clay.pointerOver(clay.ElementId.ID("fp_cancel"))) return self.close();
        if (clay.pointerOver(clay.ElementId.ID("fp_open"))) return self.confirm();
        if (clay.pointerOver(clay.ElementId.ID("fp_up"))) {
            self.model.up() catch |err| log.warn("folder picker up failed: {}", .{err});
            self.scroll_y = 0;
            return;
        }
        if (!clay.pointerOver(clay.ElementId.ID("fp_list"))) return;
        for (0..self.model.entries.len) |i| {
            if (clay.pointerOver(entryId(i))) {
                self.model.enter(i) catch |err| log.warn("folder picker enter failed: {}", .{err});
                self.scroll_y = 0;
                return;
            }
        }
    }

    fn entryId(index: usize) clay.ElementId {
        return clay.ElementId.IDI("fp_entry", @intCast(index));
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme) void {
        if (!self.visible) return;
        const t = theme;

        clay.UI()(.{
            .id = clay.ElementId.ID("fp_backdrop"),
            .floating = .{ .attach_to = .to_root, .z_index = 2000 },
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = .{ 0, 0, 0, 150 },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("fp_box"),
                .layout = .{
                    .sizing = .{ .w = .fixed(BOX_WIDTH) },
                    .padding = .all(20),
                    .direction = .top_to_bottom,
                    .child_gap = 12,
                },
                .background_color = t.surface,
                .border = .{ .width = .all(1), .color = t.border },
                .corner_radius = .all(8),
            })({
                clay.text("Open Folder", .{ .font_size = 26, .color = t.text });

                // Pfadzeile: ↑ und editierbarer Pfad
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .left_to_right,
                        .child_gap = 8,
                        .child_alignment = .{ .y = .center },
                    },
                })({
                    const up_id = clay.ElementId.ID("fp_up");
                    const up_hover = clay.pointerOver(up_id);
                    clay.UI()(.{
                        .id = up_id,
                        .layout = .{
                            .sizing = .{ .w = .fixed(36), .h = .fixed(36) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = if (up_hover) t.secondary else t.overlay,
                        .border = .{ .width = .all(1), .color = t.border },
                        .corner_radius = .all(4),
                    })({
                        svg.Svg(arena, "fp_up_icon", svg.Lucide.arrow_up, 18, t.text);
                        tooltip.attach(t, up_id, "Parent Folder");
                    });

                    clay.UI()(.{
                        .id = clay.ElementId.ID("fp_input"),
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fixed(36) },
                            .padding = .axes(0, 10),
                            .child_alignment = .{ .x = .left, .y = .center },
                        },
                        .clip = .{ .horizontal = true },
                        .background_color = t.overlay,
                        .border = .{ .width = .all(1), .color = t.border_focus },
                        .corner_radius = .all(4),
                    })({
                        line_edit.render(&self.model.edit, path_field, t.text, true, t);
                    });
                });

                if (self.model.error_msg) |msg| {
                    clay.text(msg, .{ .font_size = 18, .color = t.danger });
                }

                // Unterordner-Liste
                clay.UI()(.{
                    .id = clay.ElementId.ID("fp_list"),
                    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(LIST_HEIGHT) } },
                    .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -self.scroll_y } },
                    .background_color = t.bg,
                    .border = .{ .width = .all(1), .color = t.border },
                    .corner_radius = .all(4),
                })({
                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fit },
                            .direction = .top_to_bottom,
                            .padding = .all(4),
                        },
                    })({
                        if (self.model.entries.len == 0) {
                            clay.UI()(.{ .layout = .{ .padding = .all(10) } })({
                                clay.text("No subfolders", .{ .font_size = 18, .color = t.muted });
                            });
                        }
                        for (self.model.entries, 0..) |name, i| {
                            const id = entryId(i);
                            const hover = clay.pointerOver(id);
                            clay.UI()(.{
                                .id = id,
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) },
                                    .padding = .axes(0, 10),
                                    .child_gap = 10,
                                    .child_alignment = .{ .y = .center },
                                },
                                .background_color = if (hover) t.primary else .{ 0, 0, 0, 0 },
                                .corner_radius = .all(3),
                            })({
                                const icon_id = std.fmt.allocPrint(arena, "fp_icon_{d}", .{i}) catch "fp_icon";
                                svg.Svg(arena, icon_id, svg.Lucide.folder, 18, if (hover) t.text_on_primary else t.accent);
                                clay.text(name, .{ .font_size = 20, .color = if (hover) t.text_on_primary else t.text });
                            });
                        }
                    });
                });

                // Buttons
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .left_to_right,
                        .child_alignment = .{ .x = .right, .y = .center },
                        .child_gap = 12,
                    },
                })({
                    renderButton("Cancel", "fp_cancel", false, t);
                    renderButton("Open", "fp_open", true, t);
                });
            });
        });
    }

    fn renderButton(label: []const u8, id: []const u8, primary: bool, t: Theme) void {
        const btn_id = clay.ElementId.ID(id);
        const hover = clay.pointerOver(btn_id);
        const bg = if (primary) (if (hover) t.secondary else t.primary) else (if (hover) t.secondary else t.overlay);
        clay.UI()(.{
            .id = btn_id,
            .layout = .{ .padding = .{ .left = 18, .right = 18, .top = 8, .bottom = 8 } },
            .background_color = bg,
            .border = .{ .width = .all(1), .color = t.border },
            .corner_radius = .all(4),
        })({
            clay.text(label, .{ .font_size = 20, .color = if (primary or hover) t.text_on_primary else t.text });
        });
    }
};
