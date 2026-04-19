//! Tab-Bar Component für vulkan-ed
//!
//! Von Gooey's tabs.zig adaptiert für Clay + wgpu.
//! Zeigt offene Dateien als Tabs mit Schließen-Button.

const std = @import("std");
const clay = @import("clay");
const ui = @import("../ui/mod.zig");
const Theme = ui.Theme;
const terminal_mod = @import("../terminal/terminal_instance.zig");
const TerminalInstance = terminal_mod.TerminalInstance;
const textarea_mod = @import("components/textarea.zig");
const TextAreaState = textarea_mod.TextAreaState;
const flow_core = @import("flow_core");

const log = std.log.scoped(.tab_bar);

const file_types = @import("file_types.zig");
const FileKind = file_types.FileKind;

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
    /// Art der Datei (Text/Bild)
    kind: FileKind = .text,
    /// Optional: cached buffer for text files to preserve modified state
    buffer: ?*@import("flow_core").Buffer = null,
};

/// Tab-Bar State
pub const TabBarState = struct {
    allocator: std.mem.Allocator,
    /// Liste der offenen Tabs
    tabs: std.ArrayListUnmanaged(Tab),
    /// Index des aktiven Tabs (null = keine Datei offen)
    active_index: ?usize = null,
    /// Pending Pfad für Tab-Wechsel (wird von main.zig abgefragt)
    pending_switch_path: ?[]const u8 = null,
    /// Menü für neuen Tab anzeigen?
    show_new_menu: bool = false,
    /// Active terminal instances (keyed by tab path like "Terminal 1")
    terminal_instances: std.StringHashMap(*TerminalInstance),
    /// Active textarea instances (keyed by tab path like "TextArea 1")
    textarea_instances: std.StringHashMap(*TextAreaState),
    /// Counter for terminal tab naming
    terminal_counter: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .tabs = .empty,
            .terminal_instances = std.StringHashMap(*TerminalInstance).init(allocator),
            .textarea_instances = std.StringHashMap(*TextAreaState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        log.debug("TabBarState.deinit: starting", .{});
        // Cleanup all terminal instances
        var term_iter = self.terminal_instances.iterator();
        while (term_iter.next()) |entry| {
            log.debug("TabBarState.deinit: cleaning up terminal {s}", .{entry.key_ptr.*});
            entry.value_ptr.*.deinit();
            log.debug("TabBarState.deinit: terminal {s} done", .{entry.key_ptr.*});
        }
        self.terminal_instances.deinit();
        log.debug("TabBarState.deinit: terminal_instances hashmap done", .{});

        // Cleanup all textarea instances
        var textarea_iter = self.textarea_instances.iterator();
        while (textarea_iter.next()) |entry| {
            log.debug("TabBarState.deinit: cleaning up textarea {s}", .{entry.key_ptr.*});
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.textarea_instances.deinit();
        log.debug("TabBarState.deinit: textarea_instances hashmap done", .{});

        for (self.tabs.items, 0..) |*tab, i| {
            log.debug("TabBarState.deinit: cleaning up tab {d}: {s}", .{ i, tab.path });
            // Buffer will be deinitialized by UI.open_buffers
            self.allocator.free(tab.path);
            self.allocator.free(tab.display_name);
        }
        self.tabs.deinit(self.allocator);
        log.debug("TabBarState.deinit: tabs list done", .{});

        if (self.pending_switch_path) |p| {
            self.allocator.free(p);
        }
        log.debug("TabBarState.deinit: finished", .{});
    }

    /// Get the currently active tab
    pub fn getActiveTab(self: *Self) ?*Tab {
        if (self.active_index) |idx| {
            if (idx < self.tabs.items.len) {
                return &self.tabs.items[idx];
            }
        }
        return null;
    }

    /// Neuen Tab öffnen
    pub fn openFile(self: *Self, path: []const u8) !void {
        // Prüfen ob Datei bereits offen ist
        for (self.tabs.items, 0..) |tab, i| {
            if (std.mem.eql(u8, tab.path, path)) {
                // Bereits offen → aktivieren
                self.setActive(i);
                return;
            }
        }

        // Check if it's an existing terminal
        if (self.terminal_instances.contains(path)) {
            // It's a terminal but not in tabs? (Shouldn't happen with current logic, but for safety)
            try self.tabs.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, path),
                .display_name = try self.allocator.dupe(u8, path),
                .modified = false,
                .is_active = false,
                .kind = .terminal,
            });
            self.setActive(self.tabs.items.len - 1);
            return;
        }

        var kind = file_types.getFileKind(path);
        var display_name = std.fs.path.basename(path);

        if (std.mem.startsWith(u8, path, "preview://")) {
            kind = .markdown_preview;
            display_name = std.fs.path.basename(path["preview://".len..]);
        }

        // Dupe strings for tab
        const path_copy = try self.allocator.dupe(u8, path);
        const name_copy = try self.allocator.dupe(u8, display_name);

        try self.tabs.append(self.allocator, .{
            .path = path_copy,
            .display_name = name_copy,
            .modified = false,
            .is_active = false,
            .kind = kind,
        });

        // Neuen Tab aktivieren
        self.setActive(self.tabs.items.len - 1);
    }

    pub fn cloneFrom(self: *Self, other: *const TabBarState) !void {
        // Clear current tabs
        for (self.tabs.items) |tab| {
            self.allocator.free(tab.path);
            self.allocator.free(tab.display_name);
        }
        self.tabs.clearRetainingCapacity();

        // Copy tabs from other
        for (other.tabs.items) |tab| {
            try self.tabs.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, tab.path),
                .display_name = try self.allocator.dupe(u8, tab.display_name),
                .kind = tab.kind,
                .modified = tab.modified,
                .is_active = tab.is_active,
                .buffer = tab.buffer,
            });
        }
        self.active_index = other.active_index;
    }

    /// Open a new terminal tab
    pub fn openTerminal(self: *Self) void {
        self.terminal_counter += 1;
        const name = std.fmt.allocPrint(self.allocator, "Terminal {d}", .{self.terminal_counter}) catch return;
        const path_copy = self.allocator.dupe(u8, name) catch {
            self.allocator.free(name);
            return;
        };

        // Create terminal instance (80x24 default)
        const term = TerminalInstance.init(self.allocator, 80, 24) catch |err| {
            log.err("Failed to create terminal: {}", .{err});
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };

        // Store terminal instance
        self.terminal_instances.put(path_copy, term) catch {
            term.deinit();
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };

        // Add tab
        self.tabs.append(self.allocator, .{
            .path = path_copy,
            .display_name = name,
            .modified = false,
            .is_active = false,
            .kind = .terminal,
        }) catch {
            _ = self.terminal_instances.remove(path_copy);
            term.deinit();
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };

        self.setActive(self.tabs.items.len - 1);
        log.info("Terminal tab opened: {s}", .{name});
    }

    pub fn openChat(self: *Self) void {
        self.terminal_counter += 1;
        const name = std.fmt.allocPrint(self.allocator, "Chat {d}", .{self.terminal_counter}) catch return;
        const path_copy = self.allocator.dupe(u8, name) catch {
            self.allocator.free(name);
            return;
        };

        self.tabs.append(self.allocator, .{
            .path = path_copy,
            .display_name = name,
            .modified = false,
            .is_active = false,
            .kind = .chat,
        }) catch {
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };

        self.setActive(self.tabs.items.len - 1);
        log.info("Chat tab opened: {s}", .{name});
    }

    pub fn openTextArea(self: *Self) void {
        self.terminal_counter += 1;
        const name = std.fmt.allocPrint(self.allocator, "TextArea {d}", .{self.terminal_counter}) catch return;
        const path_copy = self.allocator.dupe(u8, name) catch {
            self.allocator.free(name);
            return;
        };

        // Create textarea state instance
        const textarea = self.allocator.create(TextAreaState) catch {
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };
        // Create a buffer for the textarea
        const buffer = flow_core.Buffer.create(self.allocator) catch {
            self.allocator.destroy(textarea);
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };
        buffer.root = buffer.load_from_string("", &buffer.file_eol_mode, &buffer.file_utf8_sanitized) catch {
            buffer.deinit();
            self.allocator.destroy(textarea);
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };
        textarea.* = TextAreaState.init(self.allocator, buffer);
        textarea.is_textarea = true;

        // Store in instances map
        self.textarea_instances.put(path_copy, textarea) catch {
            textarea.deinit();
            self.allocator.destroy(textarea);
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };

        self.tabs.append(self.allocator, .{
            .path = path_copy,
            .display_name = name,
            .modified = false,
            .is_active = false,
            .kind = .textarea,
        }) catch {
            _ = self.textarea_instances.remove(path_copy);
            textarea.deinit();
            self.allocator.destroy(textarea);
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };

        self.setActive(self.tabs.items.len - 1);
        log.info("TextArea tab opened: {s}", .{name});
    }

    /// Tab schließen (nach Index)
    pub fn closeTab(self: *Self, index: usize) void {
        if (index >= self.tabs.items.len) return;

        const tab = self.tabs.orderedRemove(index);

        // Ownership of buffer is in UI.open_buffers

        // Cleanup terminal instance if this was a terminal tab
        if (tab.kind == .terminal) {
            if (self.terminal_instances.fetchRemove(tab.path)) |kv| {
                kv.value.deinit();
            }
        }

        // Cleanup textarea instance if this was a textarea tab
        if (tab.kind == .textarea) {
            if (self.textarea_instances.fetchRemove(tab.path)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
        }

        self.allocator.free(tab.path);
        self.allocator.free(tab.display_name);

        // Active Index anpassen
        if (self.active_index) |active| {
            if (self.tabs.items.len == 0) {
                self.active_index = null;
                if (self.pending_switch_path) |p| {
                    self.allocator.free(p);
                    self.pending_switch_path = null;
                }
            } else if (active == index) {
                // Geschlossener Tab war aktiv → neuen aktiven wählen
                self.active_index = @min(active, self.tabs.items.len - 1);
            } else if (active > index) {
                // Aktiver Tab war nach dem geschlossenen → Index dekrementieren
                self.active_index = active - 1;
            }
        }
    }

    /// Aktiven Tab setzen – setzt pending_switch_path für main.zig
    pub fn setActive(self: *Self, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.active_index = index;
        // Pfad duplizieren damit main.zig ihn owned
        if (self.pending_switch_path) |old| {
            self.allocator.free(old);
        }
        self.pending_switch_path = self.allocator.dupe(u8, self.tabs.items[index].path) catch null;
    }

    /// Anzahl offener Tabs
    pub fn count(self: *const Self) usize {
        return self.tabs.items.len;
    }
};

pub const TabRequest = struct {
    index: usize,
    close: bool = false,
    do_switch: bool = false,
};

/// Tab-Bar für Clay rendern
pub fn renderTabBar(
    arena: std.mem.Allocator,
    state: *TabBarState,
    theme: Theme,
    mouse_pressed: bool,
    mouse_x: f32,
    mouse_y: f32,
) ?TabRequest {
    // Tab-Schließen und Tab-Wechsel NACH der Schleife verarbeiten (vermeidet Use-After-Free und endloses Re-Laden)
    var tab_to_close: ?usize = null;
    var tab_to_switch: ?usize = null;

    // Tab-Bar Container — horizontal scrollbar wenn Tabs nicht passen
    clay.UI()(.{
        .id = clay.ElementId.IDI("tab_bar_container", @as(u32, @truncate(@intFromPtr(state)))),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(44) },
            .direction = .left_to_right,
            .child_gap = 0,
            .padding = .{ .left = 0, .right = 8, .top = 4, .bottom = 4 },
        },
        .background_color = theme.surface,
    })({
        for (state.tabs.items, 0..) |*tab, i| {
            const is_active = state.active_index == i;
            const req = renderTab(
                arena,
                state,
                tab.*,
                i,
                is_active,
                theme,
                mouse_pressed,
                mouse_x,
                mouse_y,
            );
            if (req) |r| {
                if (r.close) tab_to_close = r.index;
                if (r.do_switch) tab_to_switch = r.index;
            }
        }

        const add_btn_id = clay.ElementId.IDI("add_tab_btn", @truncate(@intFromPtr(state)));

        clay.UI()(.{
            .id = add_btn_id,
            .layout = .{
                .sizing = .{ .w = .fixed(32), .h = .fixed(32) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = theme.surface,
            .corner_radius = .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 },
        })({
            clay.text("+", .{
                .font_size = 24,
                .color = theme.muted,
                .wrap_mode = .none,
            });
        });
    });

    // Bounding-Box Check für add_btn (nach clay.UI())
    const add_btn_id_check = clay.ElementId.IDI("add_tab_btn", @as(u32, @truncate(@intFromPtr(state))));
    const add_btn_data = clay.getElementData(add_btn_id_check);
    const add_btn_hover = if (add_btn_data.found) blk: {
        const bb = add_btn_data.bounding_box;
        break :blk mouse_x >= bb.x and mouse_x < bb.x + bb.width and mouse_y >= bb.y and mouse_y < bb.y + bb.height;
    } else false;

    if (mouse_pressed and add_btn_hover) {
        state.show_new_menu = !state.show_new_menu;
    }

    var create_new_file = false;
    var create_new_term = false;
    var create_new_chat = false;
    var create_new_text_area = false;

    if (state.show_new_menu) {
        const dropdown_id = clay.ElementId.IDI("add_tab_dropdown", @truncate(@intFromPtr(state)));
        const file_id = clay.ElementId.IDI("menu_new_file", @truncate(@intFromPtr(state)));
        const term_id = clay.ElementId.IDI("menu_new_term", @truncate(@intFromPtr(state)));
        const chat_id = clay.ElementId.IDI("menu_new_chat", @truncate(@intFromPtr(state)));
        const textarea_id = clay.ElementId.IDI("menu_new_textarea", @truncate(@intFromPtr(state)));

        clay.UI()(.{
            .id = dropdown_id,
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = add_btn_id_check.id,
                .attach_points = .{ .element = .left_top, .parent = .left_bottom },
                .z_index = 1000,
                .offset = .{ .x = 0, .y = 4 },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(200) },
                .direction = .top_to_bottom,
                .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
                .child_gap = 2,
            },
            .background_color = theme.surface,
            .border = .{ .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 }, .color = theme.border },
            .corner_radius = .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 },
        })({
            const file_hover = clay.pointerOver(file_id);
            clay.UI()(.{
                .id = file_id,
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(32) },
                    .padding = .{ .left = 8, .right = 8 },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
                .background_color = if (file_hover) .{ 80, 80, 100, 255 } else theme.surface,
                .corner_radius = .all(2),
            })({
                clay.text("New File", .{ .font_size = 18, .color = theme.text, .wrap_mode = .none });
            });

            const term_hover = clay.pointerOver(term_id);
            clay.UI()(.{
                .id = term_id,
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(32) },
                    .padding = .{ .left = 8, .right = 8 },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
                .background_color = if (term_hover) .{ 80, 80, 100, 255 } else theme.surface,
                .corner_radius = .all(2),
            })({
                clay.text("New Terminal", .{ .font_size = 18, .color = theme.text, .wrap_mode = .none });
            });

            const chat_hover = clay.pointerOver(chat_id);
            clay.UI()(.{
                .id = chat_id,
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(32) },
                    .padding = .{ .left = 8, .right = 8 },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
                .background_color = if (chat_hover) .{ 80, 80, 100, 255 } else theme.surface,
                .corner_radius = .all(2),
            })({
                clay.text("New Chat", .{ .font_size = 18, .color = theme.text, .wrap_mode = .none });
            });

            const textarea_hover = clay.pointerOver(textarea_id);
            clay.UI()(.{
                .id = textarea_id,
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(32) },
                    .padding = .{ .left = 8, .right = 8 },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
                .background_color = if (textarea_hover) .{ 80, 80, 100, 255 } else theme.surface,
                .corner_radius = .all(2),
            })({
                clay.text("New TextArea", .{ .font_size = 18, .color = theme.text, .wrap_mode = .none });
            });
        });

        const dropdown_hover = clay.pointerOver(dropdown_id);
        const file_hover = clay.pointerOver(file_id);
        const term_hover = clay.pointerOver(term_id);
        const chat_hover = clay.pointerOver(chat_id);
        const textarea_hover = clay.pointerOver(textarea_id);

        if (mouse_pressed) {
            if (file_hover) {
                create_new_file = true;
                state.show_new_menu = false;
            } else if (term_hover) {
                create_new_term = true;
                state.show_new_menu = false;
            } else if (chat_hover) {
                create_new_chat = true;
                state.show_new_menu = false;
            } else if (textarea_hover) {
                create_new_text_area = true;
                state.show_new_menu = false;
            } else if (!dropdown_hover and !add_btn_hover) {
                state.show_new_menu = false;
            }
        }
    }

    if (create_new_file) {
        state.openFile("New File.txt") catch {};
    }
    if (create_new_term) {
        state.openTerminal();
    }
    if (create_new_chat) {
        state.openChat();
    }
    if (create_new_text_area) {
        state.openTextArea();
    }

    if (tab_to_close) |idx| return .{ .index = idx, .close = true };
    if (tab_to_switch) |idx| return .{ .index = idx, .do_switch = true };

    return null;
}

/// Einzelnen Tab rendern
/// Gibt optional Request zurück (deferred close oder switch)
fn renderTab(
    arena: std.mem.Allocator,
    state: *TabBarState,
    tab: Tab,
    index: usize,
    is_active: bool,
    theme: Theme,
    mouse_pressed: bool,
    mouse_x: f32,
    mouse_y: f32,
) ?TabRequest {
    const state_id_base = @as(u32, @truncate(@intFromPtr(state)));
    const tab_id = clay.ElementId.IDI("tab", state_id_base ^ @as(u32, @intCast(index)));
    const close_id = clay.ElementId.IDI("tab_close", state_id_base ^ @as(u32, @intCast(index)));

    var is_tab_hovered = false;
    var is_close_hovered = false;

    var request: ?TabRequest = null;

    // Label vorab erzeugen (für modified-Indikator)
    const label_str = if (tab.modified)
        std.fmt.allocPrint(arena, "{s} *", .{tab.display_name}) catch tab.display_name
    else
        tab.display_name;

    // Gemessene Breite + Puffer
    const text_width = ui.measureTextWidth(label_str, 24.0);
    const total_width: f32 = 8.0 + text_width + 8.0 + 8.0 + 24.0;

    // Tab-Element erstellen - mit aktiven/hover Farben
    // Farben basieren auf letztem Frame's hover state (immediate mode üblich)
    const bg_color = if (is_active) theme.bg else if (is_tab_hovered) [4]f32{ theme.bg[0], theme.bg[1], theme.bg[2], 128.0 } else theme.surface;
    const text_color = if (is_active) theme.text else theme.muted;
    const border_color = if (is_active) theme.accent else .{ 0.0, 0.0, 0.0, 0.0 };

    clay.UI()(.{
        .id = tab_id,
        .layout = .{
            .sizing = .{ .w = .fixed(total_width), .h = .fixed(36) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .padding = .{ .left = 8, .right = 8 },
        },
        .background_color = bg_color,
        .border = .{
            .width = .{ .bottom = 2 },
            .color = border_color,
        },
        .corner_radius = .{ .top_left = 4, .top_right = 4 },
    })({
        // Tab-Name
        clay.UI()(.{
            .id = clay.ElementId.IDI("tab_text_container", state_id_base ^ @as(u32, @intCast(index))),
            .layout = .{
                .sizing = .{ .w = .fixed(text_width + 8.0), .h = .fixed(32) },
                .child_alignment = .{ .y = .center },
            },
        })({
            clay.text(label_str, .{
                .font_size = 24,
                .color = text_color,
                .wrap_mode = .none,
            });
        });

        // Close Button (X) - Element immer erstellen, Text nur bei hover/aktiv
        const close_icon_color = if (is_close_hovered) theme.danger else text_color;
        clay.UI()(.{
            .id = close_id,
            .layout = .{
                .sizing = .{ .w = .fixed(24), .h = .fixed(24) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            if (is_tab_hovered or is_active) {
                clay.text("x", .{
                    .font_size = 20,
                    .color = close_icon_color,
                    .wrap_mode = .none,
                });
            }
        });
    });

    // Bounding-Box Checks für hover detection (für nächsten frame)
    const tab_data = clay.getElementData(tab_id);
    if (tab_data.found) {
        const bb = tab_data.bounding_box;
        is_tab_hovered = mouse_x >= bb.x and mouse_x < bb.x + bb.width and mouse_y >= bb.y and mouse_y < bb.y + bb.height;
    }

    const close_data = clay.getElementData(close_id);
    if (close_data.found) {
        const cb = close_data.bounding_box;
        is_close_hovered = mouse_x >= cb.x and mouse_x < cb.x + cb.width and mouse_y >= cb.y and mouse_y < cb.y + cb.height;
    }

    // Mouse-Event Processing
    if (mouse_pressed) {
        if (is_close_hovered) {
            request = TabRequest{ .index = index, .close = true };
        } else if (is_tab_hovered and !is_active) {
            request = TabRequest{ .index = index, .do_switch = true };
        }
    }

    return request;
}
