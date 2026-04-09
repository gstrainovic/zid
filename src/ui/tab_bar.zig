//! Tab-Bar Component für vulkan-ed
//!
//! Von Gooey's tabs.zig adaptiert für Clay + wgpu.
//! Zeigt offene Dateien als Tabs mit Schließen-Button.

const std = @import("std");
const clay = @import("clay");
const ui = @import("../ui/mod.zig");
const Theme = ui.Theme;

const log = std.log.scoped(.tab_bar);

/// Ein geöffneter Tab (Datei)
pub const Tab = struct {
    /// Dateipfad (owned)
    path: []const u8,
    /// Dateiname (nur der letzte Pfad-Segment, für Anzeige)
    display_name: []const u8,
    /// Wurde die Datei modifiziert? (für * Indikator)
    modified: bool = false,
    /// Ist dieser Tab aktiv?
    is_active: bool = false,
};

/// Tab-Bar State
pub const TabBarState = struct {
    allocator: std.mem.Allocator,
    /// Liste der offenen Tabs
    tabs: std.ArrayList(Tab),
    /// Index des aktiven Tabs (null = keine Datei offen)
    active_index: ?usize = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .tabs = std.ArrayList(Tab).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tabs.items) |*tab| {
            self.allocator.free(tab.path);
            self.allocator.free(tab.display_name);
        }
        self.tabs.deinit(self.allocator);
    }

    /// Neuen Tab öffnen
    pub fn openFile(self: *Self, path: []const u8) !void {
        // Prüfen ob Datei bereits offen ist
        for (self.tabs.items, 0..) |tab, i| {
            if (std.mem.eql(u8, tab.path, path)) {
                // Bereits offen → aktivieren
                self.active_index = i;
                return;
            }
        }

        // Dateiname extrahieren
        const display_name = std.fs.path.basename(path);
        const path_copy = try self.allocator.dupe(u8, path);
        const name_copy = try self.allocator.dupe(u8, display_name);

        try self.tabs.append(self.allocator, .{
            .path = path_copy,
            .display_name = name_copy,
            .modified = false,
            .is_active = false,
        });

        // Neuen Tab aktivieren
        self.active_index = self.tabs.items.len - 1;
    }

    /// Tab schließen (nach Index)
    pub fn closeTab(self: *Self, index: usize) void {
        if (index >= self.tabs.items.len) return;

        const tab = self.tabs.orderedRemove(index);
        self.allocator.free(tab.path);
        self.allocator.free(tab.display_name);

        // Active Index anpassen
        if (self.active_index) |active| {
            if (active == index) {
                // Geschlossener Tab war aktiv → neuen aktiven wählen
                if (self.tabs.items.len > 0) {
                    self.active_index = @min(active, self.tabs.items.len - 1);
                } else {
                    self.active_index = null;
                }
            } else if (active > index) {
                // Aktiver Tab war nach dem geschlossenen → Index dekrementieren
                self.active_index = active - 1;
            }
        }
    }

    /// Aktiven Tab setzen
    pub fn setActive(self: *Self, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.active_index = index;
    }

    /// Anzahl offener Tabs
    pub fn count(self: *const Self) usize {
        return self.tabs.items.len;
    }
};

/// Tab-Bar rendern (Clay Layout)
pub fn renderTabBar(
    arena: std.mem.Allocator,
    state: *TabBarState,
    theme: Theme,
    mouse_pressed: bool,
) void {
    if (state.tabs.items.len == 0) return;

    // Tab-Bar Container
    clay.UI()(.{
        .id = clay.ElementId.ID("tab_bar_container"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(36) },
            .direction = .left_to_right,
            .child_gap = 2,
            .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
        },
        .background_color = theme.surface,
    })({
        for (state.tabs.items, 0..) |*tab, i| {
            const is_active = state.active_index == i;
            renderTab(
                arena,
                state,
                tab.*,
                i,
                is_active,
                theme,
                mouse_pressed,
            );
        }
    });
}

/// Einzelnen Tab rendern
fn renderTab(
    arena: std.mem.Allocator,
    state: *TabBarState,
    tab: Tab,
    index: usize,
    is_active: bool,
    theme: Theme,
    mouse_pressed: bool,
) void {
    var tab_id_buf: [32]u8 = undefined;
    const tab_id_str = std.fmt.bufPrint(&tab_id_buf, "tab_{d}", .{index}) catch return;
    var close_id_buf: [32]u8 = undefined;
    const close_id_str = std.fmt.bufPrint(&close_id_buf, "tab_close_{d}", .{index}) catch return;

    const tab_id = clay.ElementId.ID(tab_id_str);
    const close_id = clay.ElementId.ID(close_id_str);

    const is_tab_hovered = clay.pointerOver(tab_id);
    const is_close_hovered = clay.pointerOver(close_id);

    if (mouse_pressed) {
        if (is_close_hovered) {
            state.closeTab(index);
            return;
        } else if (is_tab_hovered) {
            state.setActive(index);
            // Wir könnten hier on_file_open triggern, um die Datei in den Editor zu laden.
            // Aber eigentlich sollte setActive auch die Datei wechseln im State, das muss
            // vermutlich später von main.zig abgefragt werden.
        }
    }

    // Tab-Background
    const bg_color = if (is_active) theme.bg else if (is_tab_hovered) [4]f32{ theme.bg[0], theme.bg[1], theme.bg[2], 128.0 } else theme.surface;
    const text_color = if (is_active) theme.text else theme.muted;
    const border_color = if (is_active) theme.accent else .{ 0.0, 0.0, 0.0, 0.0 };

    clay.UI()(.{
        .id = tab_id,
        .layout = .{
            .sizing = .{ .w = .fitMinMax(.{ .min = 80, .max = 200 }), .h = .grow },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 6,
            .padding = .{ .left = 10, .right = 6, .top = 4, .bottom = 4 },
        },
        .background_color = bg_color,
        .border = .{
            .width = .{ .bottom = 2 },
            .color = border_color,
        },
        .corner_radius = .{ .top_left = 4, .top_right = 4 },
    })({
        // Tab Label
        var label_buf: [256]u8 = undefined;
        const label_str = if (tab.modified)
            std.fmt.bufPrint(&label_buf, "{s} *", .{tab.display_name}) catch tab.display_name
        else
            tab.display_name;

        clay.text(label_str, .{
            .font_size = 13,
            .color = text_color,
        });

        // Close Button (X)
        clay.UI()(.{
            .id = close_id,
            .layout = .{
                .sizing = .{ .w = .fixed(18), .h = .fixed(18) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = if (is_close_hovered) .{ 255.0, 0.0, 0.0, 100.0 } else .{ 0.0, 0.0, 0.0, 0.0 },
            .corner_radius = .all(2),
        })({
            var close_svg_id_buf: [40]u8 = undefined;
            const close_svg_id = std.fmt.bufPrint(&close_svg_id_buf, "tab_close_svg_{d}", .{index}) catch "close_svg";
            const svg = @import("components/svg.zig");
            svg.Svg(arena, close_svg_id, svg.Lucide.x, 14, theme.muted);
        });
    });
}
