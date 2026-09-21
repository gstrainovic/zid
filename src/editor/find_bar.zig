//! Suchleiste (Ctrl+F) für Editor und Markdown-Vorschau: Zustand, Bearbeiten des Begriffs,
//! Optionen und Zeichnen. Die Suche selbst liegt in `find_ops.zig`; was ein Treffer ist und
//! wohin gesprungen wird, entscheidet der Aufrufer. Die Ersetzen-Zeile gibt es nur im Editor.

const std = @import("std");
const clay = @import("clay");
const find_ops = @import("find_ops.zig");

pub const FindState = struct {
    active: bool = false,
    query: [256]u8 = undefined,
    len: usize = 0,
    /// Letzter Treffer; Ausgangspunkt für weiter/zurück
    last_match: ?find_ops.Match = null,
    not_found: bool = false,
    /// Ersetzen-Zeile sichtbar (Ctrl+H); Tab wechselt das Feld
    replace_mode: bool = false,
    focus_replace: bool = false,
    replacement: [256]u8 = undefined,
    replacement_len: usize = 0,
    /// Letzte Ersetzen-alle-Anzahl für die Anzeige
    replaced_count: ?usize = null,
    /// Nach dem Öffnen ersetzt das erste getippte Zeichen den alten Begriff (wie VS Code)
    replace_on_type: bool = false,
    /// Optionen (Alt+C, Alt+W, Alt+R)
    case_sensitive: bool = false,
    whole_word: bool = false,
    use_regex: bool = false,

    pub fn text(self: *const FindState) []const u8 {
        return self.query[0..self.len];
    }

    pub fn replacementText(self: *const FindState) []const u8 {
        return self.replacement[0..self.replacement_len];
    }

    pub fn options(self: *const FindState) find_ops.Options {
        return .{ .case_sensitive = self.case_sensitive, .whole_word = self.whole_word, .regex = self.use_regex };
    }

    /// Leiste öffnen; ein einzeiliger markierter Text wird Suchbegriff.
    pub fn open(self: *FindState, selected: ?[]const u8) void {
        self.active = true;
        self.not_found = false;
        self.replace_on_type = true;
        if (selected) |t| self.setQuery(t);
    }

    pub fn setQuery(self: *FindState, t: []const u8) void {
        const n = @min(t.len, self.query.len);
        @memcpy(self.query[0..n], t[0..n]);
        self.len = n;
    }

    /// Alt+C/W/R schaltet die Option um. Liefert false für andere Tasten.
    pub fn toggleOption(self: *FindState, letter: u8) bool {
        switch (letter) {
            'c' => self.case_sensitive = !self.case_sensitive,
            'w' => self.whole_word = !self.whole_word,
            'r' => self.use_regex = !self.use_regex,
            else => return false,
        }
        self.last_match = null;
        self.not_found = false;
        return true;
    }

    /// Letztes Zeichen des Begriffs löschen (UTF-8-sicher).
    pub fn backspaceQuery(self: *FindState) void {
        if (self.len > 0) {
            var i = self.len - 1;
            while (i > 0 and (self.query[i] & 0xC0) == 0x80) i -= 1;
            self.len = i;
        }
        self.last_match = null;
        self.not_found = false;
    }

    /// Zeichen an den Begriff hängen; das erste nach dem Öffnen ersetzt den alten Begriff.
    /// Liefert false, wenn der Begriff voll ist.
    pub fn appendQuery(self: *FindState, cp: u21) bool {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return false;
        if (self.replace_on_type) {
            self.len = 0;
            self.last_match = null;
            self.replace_on_type = false;
        }
        if (self.len + n > self.query.len) return false;
        @memcpy(self.query[self.len .. self.len + n], tmp[0..n]);
        self.len += n;
        return true;
    }
};

pub const Ids = struct { widget: clay.ElementId, input: clay.ElementId };

/// Die Leiste, schwebend oben rechts am Element `parent_id`. `status` steht hinter dem
/// Eingabefeld („Line 12“, „3 of 12“, „No results“).
pub fn render(state: *const FindState, arena: std.mem.Allocator, ids: Ids, parent_id: u32, status: []const u8) void {
    clay.UI()(.{
        .id = ids.widget,
        .floating = .{
            .attach_to = .to_element_with_id,
            .parentId = parent_id,
            .attach_points = .{ .element = .right_top, .parent = .right_top },
            .offset = .{ .x = -24, .y = 8 },
            .z_index = 500,
        },
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fit },
            .direction = .left_to_right,
            .padding = .all(8),
            .child_gap = 10,
            .child_alignment = .{ .y = .center },
        },
        .background_color = .{ 45, 45, 60, 255 },
        .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
        .corner_radius = .all(4),
    })({
        clay.text("Find", .{ .font_size = 18, .color = .{ 150, 150, 170, 255 }, .wrap_mode = .none });
        clay.UI()(.{
            .id = ids.input,
            .layout = .{
                .sizing = .{ .w = .fixed(260), .h = .fixed(30) },
                .padding = .axes(0, 8),
                .child_alignment = .{ .y = .center },
            },
            .clip = .{ .horizontal = true },
            .background_color = .{ 30, 30, 46, 255 },
            .border = .{ .width = .all(1), .color = if (state.not_found) .{ 220, 90, 90, 255 } else .{ 120, 140, 220, 255 } },
            .corner_radius = .all(3),
        })({
            const shown = std.fmt.allocPrint(arena, "{s}|", .{state.text()}) catch state.text();
            clay.text(shown, .{ .font_size = 18, .color = .{ 220, 220, 240, 255 }, .wrap_mode = .none });
        });
        if (status.len > 0) clay.text(status, .{ .font_size = 16, .color = if (state.not_found) .{ 220, 90, 90, 255 } else .{ 150, 150, 170, 255 }, .wrap_mode = .none });
        renderToggle("Aa", state.case_sensitive);
        renderToggle("W", state.whole_word);
        renderToggle(".*", state.use_regex);
        clay.text("Enter ↓  Shift+Enter ↑  Alt+C/W/R  Esc", .{ .font_size = 14, .color = .{ 120, 120, 140, 255 }, .wrap_mode = .none });
    });
}

fn renderToggle(label: []const u8, on: bool) void {
    clay.UI()(.{
        .layout = .{ .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 } },
        .background_color = if (on) .{ 120, 140, 220, 255 } else .{ 60, 60, 80, 255 },
        .corner_radius = .all(3),
    })({
        clay.text(label, .{ .font_size = 14, .color = if (on) .{ 20, 20, 30, 255 } else .{ 170, 170, 190, 255 }, .wrap_mode = .none });
    });
}
