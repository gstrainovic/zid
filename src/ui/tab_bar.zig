//! Tab-Bar Component für zid
//!
//! Von Gooey's tabs.zig adaptiert für Clay + wgpu.
//! Zeigt offene Dateien als Tabs mit Schließen-Button.

const std = @import("std");
const tab_mru = @import("tab_mru.zig");
const clay = @import("clay");
const ui = @import("../ui/mod.zig");
const Theme = ui.Theme;
const terminal_mod = @import("../terminal/terminal_instance.zig");
const TerminalInstance = terminal_mod.TerminalInstance;
const flow_core = @import("flow_core");

const log = std.log.scoped(.tab_bar);

const file_types = @import("file_types.zig");
const explorer_ops = @import("explorer_ops.zig");
const git_diff = @import("git_diff");
const git_scm = @import("git_scm");
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
    /// Feste Nummer für die „zuletzt benutzt“-Reihenfolge (0 = noch keine vergeben)
    serial: u32 = 0,
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
    /// „Zuletzt benutzt“ (Seriennummern, vorn die jüngste) für Ctrl+Tab und den Tab-Picker
    mru: tab_mru.Mru = .{},
    next_serial: u32 = 1,
    /// Pending Pfad für Tab-Wechsel (wird von main.zig abgefragt)
    pending_switch_path: ?[]const u8 = null,
    /// Menü für neuen Tab anzeigen?
    show_new_menu: bool = false,
    /// Active terminal instances (keyed by tab path like "Terminal 1")
    terminal_instances: std.StringHashMap(*TerminalInstance),
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
        };
    }

    pub fn deinit(self: *Self) void {
        log.debug("TabBarState.deinit: starting", .{});
        self.mru.deinit(self.allocator);
        // Cleanup all terminal instances
        var term_iter = self.terminal_instances.iterator();
        while (term_iter.next()) |entry| {
            log.debug("TabBarState.deinit: cleaning up terminal {s}", .{entry.key_ptr.*});
            entry.value_ptr.*.deinit();
            log.debug("TabBarState.deinit: terminal {s} done", .{entry.key_ptr.*});
        }
        self.terminal_instances.deinit();
        log.debug("TabBarState.deinit: terminal_instances hashmap done", .{});

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

    /// Datei öffnen: schon offen → nur aktivieren, sonst neuer Tab am Ende. Keine Vorschau-Tabs
    /// (bewusst, 06.09.2026): jede Datei bekommt ihren eigenen Tab.
    pub fn openFile(self: *Self, path: []const u8) !void {
        for (self.tabs.items, 0..) |*tab, i| {
            if (std.mem.eql(u8, tab.path, path)) {
                self.setActive(i);
                return;
            }
        }
        try self.appendFileTab(path);
    }

    /// Seriennummer eines Tabs (wird beim ersten Zugriff vergeben).
    fn serialOf(self: *Self, index: usize) u32 {
        const tab = &self.tabs.items[index];
        if (tab.serial == 0) {
            tab.serial = self.next_serial;
            self.next_serial += 1;
        }
        return tab.serial;
    }

    fn indexOfSerial(self: *const Self, serial: u32) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.serial == serial) return i;
        }
        return null;
    }

    /// Tab-Indizes in „zuletzt benutzt“-Reihenfolge (jüngster zuerst); Tabs ohne Eintrag hinten.
    pub fn mruIndices(self: *Self, alloc: std.mem.Allocator) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        errdefer out.deinit(alloc);
        for (self.mru.items()) |serial| {
            if (self.indexOfSerial(serial)) |i| try out.append(alloc, i);
        }
        for (self.tabs.items, 0..) |_, i| {
            var seen = false;
            for (out.items) |o| {
                if (o == i) seen = true;
            }
            if (!seen) try out.append(alloc, i);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Tab von `from` nach `to` verschieben (Drag & Drop); aktiver Tab bleibt aktiv.
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
    }

    fn appendFileTab(self: *Self, path: []const u8) !void {

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

        // Multi-File-Diff: Titel wie VS Code git.viewCommit „kurz - betreff“
        if (git_scm.parseCommitTabPath(path)) |spec| {
            const name = try git_scm.commitTitle(self.allocator, spec.hash, spec.subject);
            errdefer self.allocator.free(name);
            const path_copy = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(path_copy);
            try self.tabs.append(self.allocator, .{ .path = path_copy, .display_name = name, .kind = .git_commit });
            self.setActive(self.tabs.items.len - 1);
            return;
        }

        // Diff-Editor: Titel wie VS Code „name (alt) ↔ name (neu)“
        if (git_diff.parseTabPath(path)) |spec| {
            const name = try git_diff.specTitle(self.allocator, spec);
            errdefer self.allocator.free(name);
            const path_copy = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(path_copy);
            try self.tabs.append(self.allocator, .{ .path = path_copy, .display_name = name, .kind = .git_diff });
            self.setActive(self.tabs.items.len - 1);
            return;
        }

        // Verzeichnisse (auch per Symlink) bekommen nie einen Tab: der Buffer-Load
        // scheitert mit IsDir. Gilt für Explorer, Quick-Open, Agent und E2E gleichermaßen.
        if (explorer_ops.isDirectory(path)) return error.IsDir;

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

        // Copy tabs from other. Chat und Terminal bleiben in der Quell-Pane: ihr Zustand
        // (Chat-Eingabe ist ein CodeEditor, Terminal ein Emulator) würde sonst zweimal je Frame
        // gezeichnet, Clay meldete ~25 duplicate_id pro Frame, und Klicks trafen die falsche Kopie.
        var new_active: ?usize = null;
        for (other.tabs.items, 0..) |tab, i| {
            if (tab.kind == .chat or tab.kind == .terminal) continue;
            if (other.active_index == i) new_active = self.tabs.items.len;
            try self.tabs.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, tab.path),
                .display_name = try self.allocator.dupe(u8, tab.display_name),
                .kind = tab.kind,
                .modified = tab.modified,
                .is_active = false,
                .buffer = tab.buffer,
                .serial = tab.serial,
                .pinned = tab.pinned,
            });
        }
        self.mru.deinit(self.allocator);
        self.mru = try other.mru.clone(self.allocator);
        for (other.tabs.items) |tab| {
            if (tab.kind == .chat or tab.kind == .terminal) self.mru.remove(tab.serial);
        }
        self.next_serial = other.next_serial;
        if (new_active == null and self.tabs.items.len > 0) new_active = self.tabs.items.len - 1;
        self.active_index = new_active;
        if (new_active) |idx| self.tabs.items[idx].is_active = true;
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

    /// Tab schließen (nach Index)
    pub fn closeTab(self: *Self, index: usize) void {
        if (index >= self.tabs.items.len) return;

        const tab = self.tabs.orderedRemove(index);
        if (tab.serial != 0) self.mru.remove(tab.serial);

        // Ownership of buffer is in UI.open_buffers

        // Cleanup terminal instance if this was a terminal tab
        if (tab.kind == .terminal) {
            if (self.terminal_instances.fetchRemove(tab.path)) |kv| {
                kv.value.deinit();
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
        self.mru.touch(self.allocator, self.serialOf(index)) catch {};
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

/// Anzeigename: Vorschau-Tabs heißen „Preview: name“. Gleicher Dateiname in zwei Tabs derselben
/// Art bekommt den Elternordner davor (a/mod.zig). Vorher zählte die Vorschau als Duplikat ihrer
/// Quelle, und beide Tabs hießen gleich „vulkan-ed/README.md“.
pub fn tabLabel(arena: std.mem.Allocator, state: *const TabBarState, index: usize) []const u8 {
    const tab = state.tabs.items[index];
    var duplicate = false;
    for (state.tabs.items, 0..) |other, i| {
        if (i != index and other.kind == tab.kind and std.mem.eql(u8, other.display_name, tab.display_name)) duplicate = true;
    }
    const name = if (!duplicate) tab.display_name else blk: {
        const dir = std.fs.path.dirname(tab.path) orelse break :blk tab.display_name;
        const parent = std.fs.path.basename(dir);
        if (parent.len == 0) break :blk tab.display_name;
        break :blk std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, tab.display_name }) catch tab.display_name;
    };
    if (tab.kind != .markdown_preview) return name;
    return std.fmt.allocPrint(arena, "Preview: {s}", .{name}) catch name;
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

    // Links weggescrollte Tabs liegen unsichtbar unter „+“ und der Sidebar, ihre Bounding-Box
    // reicht aber dorthin: ein Klick zählt nur im sichtbaren Streifen.
    const in_strip = strip_data.found and blk: {
        const sb = strip_data.bounding_box;
        break :blk mouse_x >= sb.x and mouse_x < sb.x + sb.width and mouse_y >= sb.y and mouse_y < sb.y + sb.height;
    };
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
            .child_gap = 4,
            .padding = .{ .left = 4, .right = 8, .top = 4, .bottom = 4 },
        },
        .background_color = theme.surface,
    })({
        // "+" (Neu-Menü) ganz links, vor dem scrollenden Tab-Streifen; rechts wanderte es mit
        // dem wachsenden Streifen an den Fensterrand, wo das Dropdown abgeschnitten wurde.
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
                    mouse_pressed and in_strip,
                    mouse_x,
                    mouse_y,
                );
                if (req) |r| {
                    if (r.close) tab_to_close = r.index;
                    if (r.do_switch) tab_to_switch = r.index;
                }
            }
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

    if (state.show_new_menu) {
        const dropdown_id = clay.ElementId.IDI("add_tab_dropdown", @truncate(@intFromPtr(state)));
        const file_id = clay.ElementId.IDI("menu_new_file", @truncate(@intFromPtr(state)));
        const term_id = clay.ElementId.IDI("menu_new_term", @truncate(@intFromPtr(state)));
        const chat_id = clay.ElementId.IDI("menu_new_chat", @truncate(@intFromPtr(state)));

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
        });

        const dropdown_hover = clay.pointerOver(dropdown_id);
        const file_hover = clay.pointerOver(file_id);
        const term_hover = clay.pointerOver(term_id);
        const chat_hover = clay.pointerOver(chat_id);

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
    const text_color = if (tab.pinned) theme.accent else if (is_active) theme.text else theme.muted;
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
