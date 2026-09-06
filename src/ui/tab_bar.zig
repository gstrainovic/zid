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
    /// Vorschau-Tab (Einfachklick im Explorer): wird vom nächsten Vorschau-Öffnen ersetzt,
    /// Doppelklick, Enter oder eine Änderung machen ihn fest.
    preview: bool = false,
    /// Angepinnt: kein Schließen-Kreuz, von „Close Others/All/Saved“ ausgenommen
    pinned: bool = false,
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
    /// Horizontaler Versatz der Tab-Reihe, damit der aktive Tab sichtbar bleibt
    scroll_x: f32 = 0,
    /// Laufendes Ziehen eines Tabs (Umordnen)
    drag: ?struct { index: usize, start_x: f32, moved: bool = false } = null,

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

    /// Neuen Tab öffnen (fester Tab)
    pub fn openFile(self: *Self, path: []const u8) !void {
        return self.openFileAs(path, false);
    }

    /// Index des Vorschau-Tabs in dieser Leiste, falls vorhanden
    pub fn previewIndex(self: *const Self) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.preview) return i;
        }
        return null;
    }

    /// Tab öffnen; `preview` = Vorschau-Tab (ersetzt einen vorhandenen Vorschau-Tab).
    pub fn openFileAs(self: *Self, path: []const u8, preview: bool) !void {
        // Prüfen ob Datei bereits offen ist
        for (self.tabs.items, 0..) |*tab, i| {
            if (std.mem.eql(u8, tab.path, path)) {
                // Bereits offen → aktivieren; fest öffnen macht einen Vorschau-Tab fest
                if (!preview) tab.preview = false;
                self.setActive(i);
                return;
            }
        }
        // Vorschau ersetzt die alte Vorschau an derselben Stelle
        const slot: ?usize = if (preview) self.previewIndex() else null;
        if (slot) |idx| {
            self.closeTab(idx);
        }
        try self.appendFileTab(path, preview);
        if (slot) |idx| {
            if (idx < self.tabs.items.len - 1) self.moveTab(self.tabs.items.len - 1, idx);
            self.setActive(idx);
        }
    }

    /// Tab von `from` nach `to` verschieben (Drag & Drop, Vorschau-Slot); aktiver Tab bleibt aktiv.
    pub fn moveTab(self: *Self, from: usize, to: usize) void {
        const n = self.tabs.items.len;
        if (from >= n or to >= n or from == to) return;
        const active_path: ?[]const u8 = if (self.active_index) |ai| self.tabs.items[ai].path else null;
        const tab = self.tabs.orderedRemove(from);
        self.tabs.insert(self.allocator, to, tab) catch {
            self.tabs.append(self.allocator, tab) catch {};
        };
        if (active_path) |p| {
            for (self.tabs.items, 0..) |t, i| {
                if (t.path.ptr == p.ptr) {
                    self.active_index = i;
                    break;
                }
            }
        }
    }

    /// Tab unter (x, y) anhand der Clay-Bounds des letzten Layouts.
    pub fn tabIndexAt(self: *const Self, x: f32, y: f32) ?usize {
        for (self.tabs.items, 0..) |_, i| {
            const data = clay.getElementData(tabId(self, i));
            if (!data.found) continue;
            const bb = data.bounding_box;
            if (x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height) return i;
        }
        return null;
    }

    pub fn togglePin(self: *Self, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.tabs.items[index].pinned = !self.tabs.items[index].pinned;
        if (self.tabs.items[index].pinned) self.tabs.items[index].preview = false;
    }

    /// Vorschau-Tab fest machen (Doppelklick, Enter, Änderung)
    pub fn makePermanent(self: *Self, index: usize) void {
        if (index < self.tabs.items.len) self.tabs.items[index].preview = false;
    }

    fn appendFileTab(self: *Self, path: []const u8, preview: bool) !void {

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

        // Endung + Dateianfang: Binärdateien bekommen einen Hinweis-Tab statt eines Buffers
        var kind = file_types.detectFileKind(path);
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
            // Terminal/Chat/Preview sind nie Vorschau
            .preview = preview and (kind == .text or kind == .image or kind == .pdf or kind == .binary),
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
                .preview = tab.preview,
                .pinned = tab.pinned,
            });
        }
        self.active_index = other.active_index;
    }

    /// Open a new terminal tab
    pub fn openTerminal(self: *Self) void {
        self.openTerminalIn(null);
    }

    /// Terminal mit Shell im Ordner `cwd` öffnen (null = Prozess-Arbeitsverzeichnis).
    pub fn openTerminalIn(self: *Self, cwd: ?[]const u8) void {
        self.terminal_counter += 1;
        const name = std.fmt.allocPrint(self.allocator, "Terminal {d}", .{self.terminal_counter}) catch return;
        const path_copy = self.allocator.dupe(u8, name) catch {
            self.allocator.free(name);
            return;
        };

        // Create terminal instance (80x24 default)
        const term = TerminalInstance.initIn(self.allocator, 80, 24, cwd) catch |err| {
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

    /// Chat2: Split mit Markdown Preview oben und TextArea unten
    pub fn openChat2(self: *Self) void {
        self.terminal_counter += 1;
        const name = std.fmt.allocPrint(self.allocator, "Chat2 {d}", .{self.terminal_counter}) catch return;
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
            .kind = .chat2,
        }) catch {
            _ = self.textarea_instances.remove(path_copy);
            textarea.deinit();
            self.allocator.destroy(textarea);
            self.allocator.free(name);
            self.allocator.free(path_copy);
            return;
        };

        self.setActive(self.tabs.items.len - 1);
        log.info("Chat2 tab opened: {s}", .{name});
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
                // Geschlossener Tab war aktiv → neuen aktiven wählen und den
                // Buffer-Wechsel anstoßen, sonst zeigt der Editor weiter den alten Buffer.
                self.setActive(@min(active, self.tabs.items.len - 1));
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
pub fn tabId(state: *const TabBarState, index: usize) clay.ElementId {
    return clay.ElementId.IDI("tab", @as(u32, @truncate(@intFromPtr(state))) ^ @as(u32, @intCast(index)));
}

/// Anzeigename: bei gleichem Dateinamen in zwei Tabs kommt der Elternordner davor (a/mod.zig).
fn tabLabel(arena: std.mem.Allocator, state: *const TabBarState, index: usize) []const u8 {
    const tab = state.tabs.items[index];
    var duplicate = false;
    for (state.tabs.items, 0..) |other, i| {
        if (i != index and std.mem.eql(u8, other.display_name, tab.display_name)) duplicate = true;
    }
    if (!duplicate) return tab.display_name;
    const dir = std.fs.path.dirname(tab.path) orelse return tab.display_name;
    const parent = std.fs.path.basename(dir);
    if (parent.len == 0) return tab.display_name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, tab.display_name }) catch tab.display_name;
}

/// Breite eines Tabs wie in renderTab (für das Scrollen zum aktiven Tab)
fn tabWidth(label: []const u8, modified: bool) f32 {
    const text_width = ui.measureTextWidth(label, 24.0) + (if (modified) ui.measureTextWidth("• ", 24.0) else 0);
    return 8.0 + text_width + 8.0 + 8.0 + 24.0;
}

pub fn renderTabBar(
    arena: std.mem.Allocator,
    state: *TabBarState,
    theme: Theme,
    mouse_pressed: bool,
    mouse_down: bool,
    mouse_x: f32,
    mouse_y: f32,
) ?TabRequest {
    // Tab-Schließen und Tab-Wechsel NACH der Schleife verarbeiten (vermeidet Use-After-Free und endloses Re-Laden)
    var tab_to_close: ?usize = null;
    var tab_to_switch: ?usize = null;

    const container_id = clay.ElementId.IDI("tab_bar_container", @as(u32, @truncate(@intFromPtr(state))));
    const strip_id = clay.ElementId.IDI("tab_strip", @as(u32, @truncate(@intFromPtr(state))));

    // Aktiven Tab in den Sichtbereich scrollen (Breite des Streifens aus dem letzten Layout)
    const strip_data = clay.getElementData(strip_id);
    if (strip_data.found and strip_data.bounding_box.width > 0) {
        const avail = strip_data.bounding_box.width;
        var x0: f32 = 0;
        var total: f32 = 0;
        var active_w: f32 = 0;
        for (state.tabs.items, 0..) |tab, i| {
            const w = tabWidth(tabLabel(arena, state, i), tab.modified);
            if (state.active_index != null and i < state.active_index.?) x0 += w;
            if (state.active_index == i) active_w = w;
            total += w;
        }
        if (state.active_index != null) {
            if (x0 < state.scroll_x) state.scroll_x = x0;
            if (x0 + active_w > state.scroll_x + avail) state.scroll_x = x0 + active_w - avail;
        }
        const max_scroll = @max(0, total - avail);
        state.scroll_x = @max(0, @min(state.scroll_x, max_scroll));
    }

    // Drag & Drop: loslassen → Tab an die Position unter der Maus verschieben
    if (state.drag) |d| {
        if (!mouse_down) {
            state.drag = null;
            if (d.moved) {
                if (state.tabIndexAt(mouse_x, mouse_y)) |target| {
                    if (target != d.index) state.moveTab(d.index, target);
                }
            }
        } else if (@abs(mouse_x - d.start_x) > 6) {
            state.drag.?.moved = true;
        }
    }

    clay.UI()(.{
        .id = container_id,
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(44) },
            .direction = .left_to_right,
            .child_gap = 0,
            .padding = .{ .left = 0, .right = 8, .top = 4, .bottom = 4 },
        },
        .background_color = theme.surface,
    })({
        clay.UI()(.{
            .id = strip_id,
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .left_to_right, .child_gap = 0 },
            .clip = .{ .horizontal = true, .child_offset = .{ .x = -state.scroll_x, .y = 0 } },
        })({
            for (state.tabs.items, 0..) |*tab, i| {
                const is_active = state.active_index == i;
                const req = renderTab(
                    arena,
                    state,
                    tab.*,
                    tabLabel(arena, state, i),
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
        });

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
    var create_new_chat2 = false;

    if (state.show_new_menu) {
        const dropdown_id = clay.ElementId.IDI("add_tab_dropdown", @truncate(@intFromPtr(state)));
        const file_id = clay.ElementId.IDI("menu_new_file", @truncate(@intFromPtr(state)));
        const term_id = clay.ElementId.IDI("menu_new_term", @truncate(@intFromPtr(state)));
        const chat_id = clay.ElementId.IDI("menu_new_chat", @truncate(@intFromPtr(state)));
        const textarea_id = clay.ElementId.IDI("menu_new_textarea", @truncate(@intFromPtr(state)));
        const chat2_id = clay.ElementId.IDI("menu_new_chat2", @truncate(@intFromPtr(state)));

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

            const chat2_hover = clay.pointerOver(chat2_id);
            clay.UI()(.{
                .id = chat2_id,
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(32) },
                    .padding = .{ .left = 8, .right = 8 },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
                .background_color = if (chat2_hover) .{ 80, 80, 100, 255 } else theme.surface,
                .corner_radius = .all(2),
            })({
                clay.text("New Chat2 (Split)", .{ .font_size = 18, .color = theme.text, .wrap_mode = .none });
            });
        });

        const dropdown_hover = clay.pointerOver(dropdown_id);
        const file_hover = clay.pointerOver(file_id);
        const term_hover = clay.pointerOver(term_id);
        const chat_hover = clay.pointerOver(chat_id);
        const textarea_hover = clay.pointerOver(textarea_id);
        const chat2_hover = clay.pointerOver(chat2_id);

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
            } else if (chat2_hover) {
                create_new_chat2 = true;
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
    if (create_new_chat2) {
        state.openChat2();
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
    label: []const u8,
    index: usize,
    is_active: bool,
    theme: Theme,
    mouse_pressed: bool,
    mouse_x: f32,
    mouse_y: f32,
) ?TabRequest {
    const state_id_base = @as(u32, @truncate(@intFromPtr(state)));
    const tab_id = tabId(state, index);
    const close_id = clay.ElementId.IDI("tab_close", state_id_base ^ @as(u32, @intCast(index)));

    var is_tab_hovered = false;
    var is_close_hovered = false;

    var request: ?TabRequest = null;

    // Label: Punkt für ungespeichert (wie VS Code/Zed), Ordner-Präfix bei Namensgleichheit
    const label_str = if (tab.modified)
        std.fmt.allocPrint(arena, "• {s}", .{label}) catch label
    else
        label;

    // Gemessene Breite + Puffer
    const text_width = ui.measureTextWidth(label_str, 24.0);
    const total_width: f32 = 8.0 + text_width + 8.0 + 8.0 + 24.0;

    // Tab-Element erstellen - mit aktiven/hover Farben
    // Farben basieren auf letztem Frame's hover state (immediate mode üblich)
    const dragging = if (state.drag) |d| (d.index == index and d.moved) else false;
    const bg_color = if (is_active) theme.bg else if (is_tab_hovered) [4]f32{ theme.bg[0], theme.bg[1], theme.bg[2], 128.0 } else theme.surface;
    // Vorschau-Tab: gedämpfte Farbe statt Kursiv (nur eine Font-Face); angepinnt: Akzent
    const text_color = if (tab.pinned) theme.accent else if (tab.preview) theme.subtext else if (is_active) theme.text else theme.muted;
    const border_color = if (dragging) theme.primary else if (is_active) theme.accent else .{ 0.0, 0.0, 0.0, 0.0 };

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

        // Close Button (X) - Element immer erstellen, Text nur bei hover/aktiv; angepinnt: nie
        const close_icon_color = if (is_close_hovered) theme.danger else text_color;
        clay.UI()(.{
            .id = close_id,
            .layout = .{
                .sizing = .{ .w = .fixed(24), .h = .fixed(24) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            if ((is_tab_hovered or is_active) and !tab.pinned) {
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
        if (is_close_hovered and !tab.pinned) {
            request = TabRequest{ .index = index, .close = true };
        } else if (is_tab_hovered) {
            if (!is_active) request = TabRequest{ .index = index, .do_switch = true };
            // Ziehen beginnt hier; ob es ein Klick bleibt, entscheidet die Bewegung
            state.drag = .{ .index = index, .start_x = mouse_x };
        }
    }

    return request;
}
