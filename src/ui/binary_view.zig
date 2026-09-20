//! Hinweis-Tab für Binärdateien: kein Buffer, kein Editor, nur Name und Größe.
//! Wie Zed („Binary files are not supported“) — bewusst ohne „Trotzdem öffnen“.

const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const file_types = @import("file_types.zig");

/// ID eines Elements dieser Ansicht. Ein Split kopiert die Tabs, dieselbe Datei
/// steht dann in beiden Panes: ohne Salz meldet Clay `duplicate_id`.
pub fn idi(name: []const u8, salt: u32) clay.ElementId {
    return clay.ElementId.IDI(name, salt);
}

pub fn render(arena: std.mem.Allocator, path: []const u8, theme: Theme, salt: u32) void {
    const size_text = blk: {
        const st = std.fs.cwd().statFile(path) catch break :blk "";
        break :blk file_types.formatFileSize(arena, st.size) catch "";
    };

    clay.UI()(.{
        .id = idi("binary_view_container", salt),
        .layout = .{
            .sizing = .grow,
            .child_alignment = .{ .x = .center, .y = .center },
            .direction = .top_to_bottom,
            .child_gap = 12,
            .padding = .all(32),
        },
        .background_color = theme.bg,
    })({
        clay.text("Binärdatei — wird nicht als Text geöffnet", .{ .font_size = 24, .color = theme.text });
        clay.text(std.fs.path.basename(path), .{ .font_size = 18, .color = theme.subtext });
        if (size_text.len > 0) clay.text(size_text, .{ .font_size = 16, .color = theme.muted });
    });
}
