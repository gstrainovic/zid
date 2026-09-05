//! File Explorer Sidebar für vulkan-ed
//!
//! Zeigt Verzeichnisbaum an (Tree-Widget).
//! Von Gooey's tree_list.zig adaptiert für Clay + wgpu.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const explorer_ops = @import("explorer_ops.zig");
const ui = @import("../ui/mod.zig");
const Theme = ui.Theme;

const log = std.log.scoped(.file_explorer);

/// Maximaltiefe des Baums
const MAX_TREE_DEPTH = 32;
/// Standard-Einrückung pro Ebene in Pixeln
const DEFAULT_INDENT_PX = 16.0;

/// Zeilenhöhe eines Eintrags in Pixeln (Hit-Test und Rendering)
pub const ROW_HEIGHT: f32 = 36;

/// Rechtsklick-Menü auf einem Eintrag
pub const ContextMenu = struct { x: f32, y: f32, node_index: u32 };

/// Laufendes Inline-Umbenennen
pub const RenameState = struct { node_index: u32, edit: explorer_ops.RenameEdit };

/// Dateisystem-Änderung durch den Explorer, damit die UI Tabs/Buffer nachzieht.
pub const FsChange = struct {
    kind: enum { renamed, deleted },
    old_path: []u8,
    new_path: ?[]u8,

    pub fn deinit(self: FsChange, alloc: std.mem.Allocator) void {
        alloc.free(self.old_path);
        if (self.new_path) |p| alloc.free(p);
    }
};

/// Ein Knoten im Dateibaum
pub const TreeNode = struct {
    /// Parent-Index (null = Root)
    parent: ?u32 = null,
    /// Index des ersten Kindes
    first_child: ?u32 = null,
    /// Anzahl direkter Kinder
    child_count: u32 = 0,
    /// Ist es ein Ordner?
    is_folder: bool = false,
    /// Dateiname (owned)
    name: []const u8 = "",
    /// Absoluter Pfad (owned)
    path: []const u8 = "",
};

/// Sichtbarer Eintrag (nach Expansion berechnet)
pub const TreeEntry = struct {
    /// Index im nodes-Array
    node_index: u32,
    /// Bitmaske für Tree-Lines
    ancestry_mask: u32 = 0,
    /// Tiefe im Baum (0 = Root)
    depth: u32 = 0,
    /// Ist es ein Ordner?
    is_folder: bool = false,
    /// Ist er aufgeklappt?
    is_expanded: bool = false,
    /// Hat er einen nächsten Sibling?
    has_next_sibling: bool = false,
};

/// File Explorer State
pub const FileExplorerState = struct {
    allocator: std.mem.Allocator,
    /// Alle Knoten
    nodes: std.ArrayList(TreeNode),
    /// Sichtbare Einträge (flache Liste nach Expansion)
    visible_entries: std.ArrayList(TreeEntry),
    /// Aufgeklappte Knoten (Set von Node-Indizes)
    expanded_nodes: std.AutoHashMap(u32, void),
    /// Aktuell selektierter Eintrag (Index in visible_entries)
    selected_index: ?usize = null,
    /// Datei die geöffnet werden soll (wird von main.zig abgefragt und zurückgesetzt)
    file_to_open: ?[]const u8 = null,
    /// Deferred Action: Folder-Toggle pending (wird nach Rendering ausgeführt)
    pending_toggle: ?u32 = null,
    /// Kontextmenü (Rechtsklick auf Eintrag)
    context_menu: ?ContextMenu = null,
    /// Inline-Umbenennen
    rename: ?RenameState = null,
    /// Vom Kontextmenü angefordert; UI zeigt den Bestätigungsdialog
    pending_delete: ?u32 = null,
    /// Vom Dialog bestätigt; wird im nächsten Frame vor dem Layout ausgeführt
    confirmed_delete: ?u32 = null,
    /// Letzte ausgeführte Änderung, von der UI abzuholen (takeFsChange)
    pending_fs_change: ?FsChange = null,
    /// Viewport-Bounds des letzten Frames (Hit-Test für Einträge)
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    viewport_width: f32 = 0,

    /// Aktuelle Breite der Sidebar
    width: f32 = 250.0,
    /// Wird gerade an der Sidebar gezogen?
    is_resizing: bool = false,
    /// Git-Status pro absolutem Pfad: 'A' staged, 'M' modified, '?' untracked, 'C' conflict, 'S' submodule
    git_status: std.StringHashMap(u8),

    /// Scrolling state
    scroll_offset_y: f32 = 0,
    viewport_height: f32 = 0,
    content_height: f32 = 0,

    /// Scrollbar-Dragging State
    scrollbar_dragging: bool = false,
    scrollbar_drag_start_y: f32 = 0,
    scrollbar_scroll_offset_at_drag_start: f32 = 0,

    /// Scrollbar Bounds
    scrollbar_track_x: f32 = 0,
    scrollbar_track_y: f32 = 0,
    scrollbar_thumb_y: f32 = 0,
    scrollbar_thumb_height: f32 = 0,
    scrollbar_width: f32 = 10,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .nodes = std.ArrayList(TreeNode).empty,
            .visible_entries = std.ArrayList(TreeEntry).empty,
            .expanded_nodes = std.AutoHashMap(u32, void).init(allocator),
            .git_status = std.StringHashMap(u8).init(allocator),
            .width = 250.0,
            .is_resizing = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.pending_fs_change) |c| c.deinit(self.allocator);
        for (self.nodes.items) |*node| {
            self.allocator.free(node.name);
            self.allocator.free(node.path);
        }
        self.nodes.deinit(self.allocator);
        self.visible_entries.deinit(self.allocator);
        self.expanded_nodes.deinit();
        // Keys in git_status sind owned (alloziert in updateGitStatus via path.join).
        var it = self.git_status.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.git_status.deinit();
    }

    /// Git-Status aus Payload-Format aktualisieren ("~:src/main.zig\n...")
    /// repo_root: absoluter Pfad des Repo-Wurzelverzeichnisses
    pub fn updateGitStatus(self: *Self, payload: []const u8, repo_root: []const u8) void {
        // Alte Keys freigeben bevor wir die Map leeren
        var it = self.git_status.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.git_status.clearRetainingCapacity();

        var lines = std.mem.splitScalar(u8, payload, '\n');
        while (lines.next()) |line| {
            if (line.len < 3) continue;
            const code = line[0];
            if (code == 'b') continue; // "branch:..." überspringen
            if (line[1] != ':') continue;
            const rel = line[2..];
            const abs = std.fs.path.join(self.allocator, &.{ repo_root, rel }) catch continue;
            self.git_status.put(abs, code) catch {
                self.allocator.free(abs);
            };
        }
    }

    /// Root-Ordner laden
    pub fn loadDirectory(self: *Self, dir_path: []const u8) !void {
        // Alte Daten löschen
        for (self.nodes.items) |*node| {
            self.allocator.free(node.name);
            self.allocator.free(node.path);
        }
        self.nodes.clearRetainingCapacity();
        self.visible_entries.clearRetainingCapacity();
        self.expanded_nodes.clearRetainingCapacity();

        // Root-Knoten erstellen
        const root_name = std.fs.path.basename(dir_path);
        const root_path = try self.allocator.dupe(u8, dir_path);
        const root_name_dup = try self.allocator.dupe(u8, root_name);

        try self.nodes.append(self.allocator, .{
            .parent = null,
            .first_child = null,
            .child_count = 0,
            .is_folder = true,
            .name = root_name_dup,
            .path = root_path,
        });

        // Root automatisch aufklappen und laden
        try self.expandNode(0, dir_path);
    }

    /// Knoten aufklappen
    fn expandNode(self: *Self, node_index: u32, dir_path: []const u8) !void {
        if (self.expanded_nodes.contains(node_index)) return;
        try self.expanded_nodes.put(node_index, {});

        // Ordner-Inhalt lesen
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
            log.warn("Cannot open directory '{s}': {}", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        var child_indices = std.ArrayList(u32).empty;
        defer child_indices.deinit(self.allocator);

        // Kinder sammeln
        while (try iter.next()) |entry| {
            // Versteckte Dateien überspringen (optional)
            if (std.mem.startsWith(u8, entry.name, ".")) continue;

            const child_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            const child_name = try self.allocator.dupe(u8, entry.name);
            const is_dir = entry.kind == .directory;

            const child_index: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .parent = node_index,
                .first_child = null,
                .child_count = 0,
                .is_folder = is_dir,
                .name = child_name,
                .path = child_path,
            });

            try child_indices.append(self.allocator, child_index);
        }

        // Parent-Kind-Beziehung aktualisieren
        const parent = &self.nodes.items[node_index];
        if (child_indices.items.len > 0) {
            parent.first_child = child_indices.items[0];
            parent.child_count = @intCast(child_indices.items.len);
        }

        // Sichtbare Einträge neu berechnen
        self.rebuildVisible();
    }

    /// Knoten zuklappen
    pub fn collapseNode(self: *Self, node_index: u32) void {
        _ = self.expanded_nodes.remove(node_index);
        self.rebuildVisible();
    }

    /// Aufklapp/Zuklapp Toggle
    pub fn toggleNode(self: *Self, node_index: u32) !void {
        if (self.expanded_nodes.contains(node_index)) {
            self.collapseNode(node_index);
        } else {
            // Pfad des Knoten holen
            if (node_index < self.nodes.items.len) {
                try self.expandNode(node_index, self.nodes.items[node_index].path);
            }
        }
    }

    /// Sichtbare Einträge neu berechnen (DFS wie Gooey's flattenNode)
    fn rebuildVisible(self: *Self) void {
        self.visible_entries.clearRetainingCapacity();
        if (self.nodes.items.len == 0) return;

        // Root durchlaufen
        self.flattenNode(0, 0, false, 0);
    }

    /// Einen Knoten und seine sichtbaren Nachfahren flattieren
    fn flattenNode(self: *Self, node_index: u32, depth: u32, has_next_sibling: bool, ancestry_mask: u32) void {
        if (node_index >= self.nodes.items.len) return;
        if (depth >= MAX_TREE_DEPTH) return;

        const node = &self.nodes.items[node_index];
        const is_expanded = self.expanded_nodes.contains(node_index);

        self.visible_entries.append(self.allocator, .{
            .node_index = node_index,
            .ancestry_mask = ancestry_mask,
            .depth = depth,
            .is_folder = node.is_folder,
            .is_expanded = is_expanded,
            .has_next_sibling = has_next_sibling,
        }) catch return;

        // Wenn aufgeklappt und Ordner mit Kindern: Kinder flatten
        if (node.is_folder and is_expanded and node.first_child != null) {
            const child_ancestry = if (has_next_sibling)
                ancestry_mask | (@as(u32, 1) << @intCast(depth))
            else
                ancestry_mask;
            self.flattenChildren(node_index, depth + 1, child_ancestry);
        }
    }

    /// Alle Kinder eines Elternknotens flattieren
    fn flattenChildren(self: *Self, parent_index: u32, depth: u32, ancestry_mask: u32) void {
        const parent = &self.nodes.items[parent_index];
        if (parent.first_child == null) return;

        var child_idx = parent.first_child.?;
        var children_found: u32 = 0;
        while (children_found < parent.child_count) : (children_found += 1) {
            if (child_idx >= self.nodes.items.len) break;

            // Sicherstellen dass es wirklich ein Kind ist
            if (self.nodes.items[child_idx].parent != parent_index) break;

            const has_next = children_found + 1 < parent.child_count;
            self.flattenNode(child_idx, depth, has_next, ancestry_mask);

            // Nächstes sequentielles Kind
            child_idx += 1;
        }
    }

    /// Eintrag selektieren
    pub fn selectEntry(self: *Self, index: usize) void {
        self.selected_index = index;
    }

    /// Datei öffnen (setzt file_to_open)
    pub fn openSelectedFile(self: *Self) void {
        if (self.selected_index) |idx| {
            if (idx < self.visible_entries.items.len) {
                const entry = self.visible_entries.items[idx];
                const node = self.nodes.items[entry.node_index];

                if (!node.is_folder) {
                    self.file_to_open = node.path;
                }
            }
        }
    }

    /// Deferred Toggle ausführen (nach dem Rendering aufrufen)
    pub fn processPendingToggle(self: *Self) void {
        if (self.pending_toggle) |node_index| {
            self.pending_toggle = null;
            self.toggleNode(node_index) catch {};
        }
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        const scroll_speed: f32 = 60.0;
        if (delta > 0) {
            self.scroll_offset_y = @max(0, self.scroll_offset_y - @as(f32, @floatFromInt(delta)) * scroll_speed);
        } else if (delta < 0) {
            const max_scroll = @max(0, self.content_height - self.viewport_height);
            self.scroll_offset_y = @min(max_scroll, self.scroll_offset_y + @as(f32, @floatFromInt(-delta)) * scroll_speed);
        }
    }

    /// Sichtbarer Eintrag unter (x, y), anhand der Viewport-Bounds des letzten Frames.
    pub fn entryAt(self: *const Self, x: f32, y: f32) ?usize {
        if (self.viewport_width <= 0 or self.viewport_height <= 0) return null;
        if (x < self.viewport_x or x >= self.viewport_x + self.viewport_width) return null;
        if (y < self.viewport_y or y >= self.viewport_y + self.viewport_height) return null;
        const rel = y - self.viewport_y + self.scroll_offset_y;
        if (rel < 0) return null;
        const idx: usize = @intFromFloat(rel / ROW_HEIGHT);
        if (idx >= self.visible_entries.items.len) return null;
        return idx;
    }

    fn inSidebar(self: *const Self, x: f32) bool {
        return self.viewport_width > 0 and x >= self.viewport_x and x < self.viewport_x + self.viewport_width;
    }

    /// Höhe des Kontextmenüs (2 Einträge à ~42px + Padding, mit Reserve), zum Einpassen am unteren Rand
    const context_menu_height: f32 = 2 * 42 + 16;

    pub fn openContextMenu(self: *Self, x: f32, y: f32, entry_index: usize) void {
        if (entry_index >= self.visible_entries.items.len) return;
        self.selectEntry(entry_index);
        // Am unteren Rand nach oben verschieben, damit das Menü sichtbar bleibt
        const bottom = self.viewport_y + self.viewport_height;
        const menu_y = if (y + context_menu_height > bottom) @max(self.viewport_y, bottom - context_menu_height) else y;
        self.context_menu = .{ .x = x, .y = menu_y, .node_index = self.visible_entries.items[entry_index].node_index };
    }

    pub fn startRename(self: *Self, node_index: u32) void {
        if (node_index >= self.nodes.items.len) return;
        self.rename = .{ .node_index = node_index, .edit = explorer_ops.RenameEdit.init(self.nodes.items[node_index].name) };
    }

    pub fn isRenaming(self: *const Self) bool {
        return self.rename != null;
    }

    pub fn handleRenameKey(self: *Self, key: wio.Button) void {
        const st = &(self.rename orelse return);
        switch (key) {
            .enter, .kp_enter => self.commitRename(),
            .escape => self.rename = null,
            .backspace => st.edit.backspace(),
            else => {},
        }
    }

    pub fn handleRenameChar(self: *Self, cp: u21) void {
        if (cp < 32 or cp == 127) return;
        if (self.rename) |*st| st.edit.insertCodepoint(cp);
    }

    fn commitRename(self: *Self) void {
        const st = self.rename orelse return;
        self.rename = null;
        if (st.node_index >= self.nodes.items.len) return;
        const node = self.nodes.items[st.node_index];
        const new_path = explorer_ops.renamePath(self.allocator, node.path, st.edit.text()) catch |err| {
            log.err("rename '{s}' -> '{s}' failed: {}", .{ node.path, st.edit.text(), err });
            return;
        };
        defer self.allocator.free(new_path);
        log.info("renamed '{s}' -> '{s}'", .{ node.path, new_path });
        self.setFsChange(.renamed, node.path, new_path);
        self.refresh(new_path);
    }

    fn setFsChange(self: *Self, kind: @FieldType(FsChange, "kind"), old_path: []const u8, new_path: ?[]const u8) void {
        if (self.pending_fs_change) |old| old.deinit(self.allocator);
        self.pending_fs_change = null;
        const old_dup = self.allocator.dupe(u8, old_path) catch return;
        const new_dup: ?[]u8 = if (new_path) |p| (self.allocator.dupe(u8, p) catch {
            self.allocator.free(old_dup);
            return;
        }) else null;
        self.pending_fs_change = .{ .kind = kind, .old_path = old_dup, .new_path = new_dup };
    }

    /// Von der UI einmal pro Frame abholen; der Aufrufer gibt das Ergebnis frei.
    pub fn takeFsChange(self: *Self) ?FsChange {
        const v = self.pending_fs_change;
        self.pending_fs_change = null;
        return v;
    }

    /// Vom Dialog-Callback: Löschen vormerken (Ausführung im nächsten Frame vor dem Layout,
    /// weil Render-Commands noch auf Knotennamen zeigen).
    pub fn takePendingDelete(self: *Self) ?u32 {
        const v = self.pending_delete;
        self.pending_delete = null;
        return v;
    }

    pub fn confirmDelete(self: *Self, node_index: u32) void {
        self.confirmed_delete = node_index;
    }

    /// Einmal pro Frame vor dem Layout aufrufen.
    pub fn processPending(self: *Self) void {
        if (self.confirmed_delete) |idx| {
            self.confirmed_delete = null;
            self.deleteNode(idx);
        }
    }

    pub fn deleteNode(self: *Self, node_index: u32) void {
        if (node_index == 0 or node_index >= self.nodes.items.len) return;
        const node = self.nodes.items[node_index];
        explorer_ops.deletePath(node.path, node.is_folder) catch |err| {
            log.err("delete '{s}' failed: {}", .{ node.path, err });
            return;
        };
        log.info("deleted '{s}'", .{node.path});
        self.setFsChange(.deleted, node.path, null);
        self.refresh(null);
    }

    /// Baum neu laden, zuvor offene Ordner anhand ihrer Pfade wieder aufklappen,
    /// Scroll-Position behalten und optional den Eintrag mit `select_path` selektieren.
    pub fn refresh(self: *Self, select_path: ?[]const u8) void {
        if (self.nodes.items.len == 0) return;

        var expanded_paths: std.ArrayList([]u8) = .empty;
        defer {
            for (expanded_paths.items) |p| self.allocator.free(p);
            expanded_paths.deinit(self.allocator);
        }
        var it = self.expanded_nodes.keyIterator();
        while (it.next()) |k| {
            if (k.* >= self.nodes.items.len) continue;
            const dup = self.allocator.dupe(u8, self.nodes.items[k.*].path) catch continue;
            expanded_paths.append(self.allocator, dup) catch {
                self.allocator.free(dup);
            };
        }
        // Alles, was in Knotenspeicher zeigt, vor loadDirectory kopieren
        const root = self.allocator.dupe(u8, self.nodes.items[0].path) catch return;
        defer self.allocator.free(root);
        const sel: ?[]u8 = if (select_path) |p| (self.allocator.dupe(u8, p) catch null) else null;
        defer if (sel) |p| self.allocator.free(p);
        const scroll = self.scroll_offset_y;

        self.loadDirectory(root) catch |err| {
            log.err("refresh: reload '{s}' failed: {}", .{ root, err });
            return;
        };

        // Ordner wieder aufklappen: Kinder existieren erst nach dem Aufklappen des
        // Elternknotens, daher wiederholen bis nichts mehr dazukommt.
        var changed = true;
        while (changed) {
            changed = false;
            var i: u32 = 0;
            while (i < self.nodes.items.len) : (i += 1) {
                const n = self.nodes.items[i];
                if (!n.is_folder or self.expanded_nodes.contains(i)) continue;
                for (expanded_paths.items) |p| {
                    if (std.mem.eql(u8, p, n.path)) {
                        self.expandNode(i, n.path) catch {};
                        changed = true;
                        break;
                    }
                }
            }
        }

        self.scroll_offset_y = scroll;
        self.selected_index = null;
        if (sel) |p| {
            for (self.visible_entries.items, 0..) |e, idx| {
                if (std.mem.eql(u8, self.nodes.items[e.node_index].path, p)) {
                    self.selected_index = idx;
                    break;
                }
            }
        }
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, button: wio.Button) bool {
        // Offenes Kontextmenü: Eintrag ausführen oder Menü schließen
        if (self.context_menu) |menu| {
            self.context_menu = null;
            if (clay.pointerOver(clay.ElementId.ID("fx_menu_rename"))) {
                self.startRename(menu.node_index);
                return true;
            }
            if (clay.pointerOver(clay.ElementId.ID("fx_menu_delete"))) {
                self.pending_delete = menu.node_index;
                return true;
            }
            return true;
        }
        // Laufendes Umbenennen: jeder Klick bricht ab
        if (self.rename != null) self.rename = null;

        if (button == .mouse_right) {
            if (self.entryAt(x, y)) |idx| self.openContextMenu(x, y, idx);
            return self.inSidebar(x);
        }

        if (self.content_height <= self.viewport_height) return false;

        if (x < self.scrollbar_track_x) return false;
        if (x > self.scrollbar_track_x + self.scrollbar_width) return false;
        if (y < self.scrollbar_track_y) return false;
        if (y > self.scrollbar_track_y + self.viewport_height) return false;

        if (y >= self.scrollbar_thumb_y and y <= self.scrollbar_thumb_y + self.scrollbar_thumb_height) {
            self.scrollbar_dragging = true;
            self.scrollbar_drag_start_y = y;
            self.scrollbar_scroll_offset_at_drag_start = self.scroll_offset_y;
            return true;
        }

        // Jump to position
        const track_height = self.viewport_height;
        const total_height = self.content_height;
        const thumb_height = self.scrollbar_thumb_height;
        const scrollable_height = track_height - thumb_height;

        if (scrollable_height > 0) {
            const click_pos_rel = (y - self.scrollbar_track_y) - (thumb_height / 2.0);
            const scroll_frac = @max(0, @min(1.0, click_pos_rel / scrollable_height));
            self.scroll_offset_y = scroll_frac * (total_height - track_height);
        }

        return true;
    }

    pub fn handleMouseMove(self: *Self, _: f32, y: f32) void {
        if (!self.scrollbar_dragging) return;
        if (self.content_height <= self.viewport_height) return;

        const track_height = self.viewport_height;
        const total_height = self.content_height;
        const thumb_height = self.scrollbar_thumb_height;
        const scrollable_height = track_height - thumb_height;

        if (scrollable_height <= 0) return;

        const delta_y = y - self.scrollbar_drag_start_y;
        const scroll_delta_frac = delta_y / scrollable_height;
        const scroll_delta_px = scroll_delta_frac * (total_height - track_height);

        var new_offset = self.scrollbar_scroll_offset_at_drag_start + scroll_delta_px;
        const max_scroll = total_height - track_height;
        new_offset = @max(0, @min(new_offset, max_scroll));

        self.scroll_offset_y = new_offset;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.scrollbar_dragging = false;
    }
};

/// Tree-Lines zeichnen (│ ├ └)
fn renderTreeLines(
    arena: std.mem.Allocator,
    entry: TreeEntry,
    theme: Theme,
) void {
    _ = arena;
    _ = entry;
    _ = theme;
    // Vereinfacht: Tree-Lines werden später mit Text-Symbolen gerendert
}

/// File Explorer Sidebar rendern
pub fn renderFileExplorer(
    arena: std.mem.Allocator,
    state: *FileExplorerState,
    theme: Theme,
    mouse_pressed: bool,
) void {
    // Update layout info from previous frame
    const clip_data = clay.getElementData(clay.ElementId.ID("file_tree_viewport"));
    const content_data = clay.getElementData(clay.ElementId.ID("file_tree_content"));
    if (clip_data.found) {
        state.viewport_height = clip_data.bounding_box.height;
        state.viewport_x = clip_data.bounding_box.x;
        state.viewport_y = clip_data.bounding_box.y;
        state.viewport_width = clip_data.bounding_box.width;
        state.scrollbar_track_x = clip_data.bounding_box.x + clip_data.bounding_box.width - state.scrollbar_width;
        state.scrollbar_track_y = clip_data.bounding_box.y;
    }
    if (content_data.found) {
        state.content_height = content_data.bounding_box.height;
    }

    // Sidebar-BBox-Gate: pointerOver(file_explorer) prüft nur ob Maus in der
    // 300px-Sidebar steht. Tree-Entry-BBoxen können über Sidebar-Breite
    // hinauswachsen (Font 24 + langer Dateiname), daher reicht Clay's
    // .clip nicht als Hit-Test-Grenze. Nur wenn Klick tatsächlich in
    // Sidebar-BBox → an Tree-Entries weiterleiten.
    const sidebar_id = clay.ElementId.ID("file_explorer");
    const in_sidebar = clay.pointerOver(sidebar_id);
    const effective_press = mouse_pressed and in_sidebar;

    clay.UI()(.{
        .id = sidebar_id,
        .layout = .{
            .sizing = .{ .w = .fixed(state.width), .h = .grow },
            .direction = .top_to_bottom,
            .child_gap = 0,
        },
        .background_color = theme.surface,
        .border = .{ .width = .{ .right = 1 }, .color = theme.border },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("file_tree_viewport"),
            .layout = .{
                .sizing = .grow,
            },
            .clip = .{ .vertical = true, .horizontal = true, .child_offset = .{ .x = 0, .y = -state.scroll_offset_y } },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("file_tree_content"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fit },
                    .direction = .top_to_bottom,
                    .child_gap = 0,
                },
            })({
                for (state.visible_entries.items, 0..) |entry, i| {
                    renderTreeEntry(arena, state, entry, i, theme, effective_press, in_sidebar);
                }
            });
        });

        // Scrollbar
        if (state.content_height > state.viewport_height) {
            renderScrollbar(state, theme);
        }
    });

    if (state.context_menu) |menu| renderContextMenu(menu, theme);
}

fn renderContextMenu(menu: ContextMenu, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("fx_menu_anchor"),
        .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(0) } },
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .offset = .{ .x = menu.x, .y = menu.y },
            .z_index = 1000,
        },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("fx_menu_container"),
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .top_to_bottom,
                .padding = .all(4),
                .child_gap = 2,
            },
            .background_color = theme.overlay,
            .border = .{ .width = .all(1), .color = theme.border },
            .corner_radius = .all(4),
        })({
            renderContextMenuItem("Rename", "fx_menu_rename", theme);
            renderContextMenuItem("Delete", "fx_menu_delete", theme);
        });
    });
}

fn renderContextMenuItem(label: []const u8, id: []const u8, theme: Theme) void {
    const item_id = clay.ElementId.ID(id);
    const hovered = clay.pointerOver(item_id);
    clay.UI()(.{
        .id = item_id,
        .layout = .{
            .sizing = .{ .w = .fixed(180), .h = .fit },
            .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
        },
        .background_color = if (hovered) theme.primary else .{ 0, 0, 0, 0 },
        .corner_radius = .all(3),
    })({
        clay.text(label, .{ .font_size = 20, .color = if (hovered) theme.text_on_primary else theme.text });
    });
}

fn renderScrollbar(state: *FileExplorerState, theme: Theme) void {
    const total = state.content_height;
    const visible = state.viewport_height;
    if (total <= visible) return;

    const track_height = visible;
    const thumb_ratio = visible / total;
    const thumb_height = @max(20.0, track_height * thumb_ratio);
    const max_scroll = total - visible;
    const scroll_frac = if (max_scroll > 0) state.scroll_offset_y / max_scroll else 0;
    const thumb_y = scroll_frac * (track_height - thumb_height);

    state.scrollbar_thumb_y = state.scrollbar_track_y + thumb_y;
    state.scrollbar_thumb_height = thumb_height;

    const track_color: clay.Color = .{ 30, 30, 46, 255 };
    const thumb_color: clay.Color = .{ 88, 88, 120, 200 };

    clay.UI()(.{
        .id = clay.ElementId.ID("file_explorer_scrollbar_track"),
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .right_top, .parent = .right_top },
            .z_index = 1000,
        },
        .layout = .{
            .sizing = .{ .w = .fixed(state.scrollbar_width), .h = .grow },
            .direction = .top_to_bottom,
        },
        .background_color = track_color,
    })({
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_y) } },
        })({});
        clay.UI()(.{
            .id = clay.ElementId.ID("file_explorer_scrollbar_thumb"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_height) } },
            .background_color = if (state.scrollbar_dragging) theme.primary else thumb_color,
            .corner_radius = .all(3),
        })({});
    });
}

/// Einzelnen Tree-Eintrag rendern
fn renderTreeEntry(
    arena: std.mem.Allocator,
    state: *FileExplorerState,
    entry: TreeEntry,
    index: usize,
    theme: Theme,
    mouse_pressed: bool,
    in_sidebar: bool,
) void {
    const node = state.nodes.items[entry.node_index];
    const is_selected = state.selected_index == index;
    const indent = @as(f32, @floatFromInt(entry.depth)) * DEFAULT_INDENT_PX + 8.0;

    const entry_id_str = std.fmt.allocPrint(arena, "tree_entry_{d}", .{index}) catch return;
    const element_id = clay.ElementId.ID(entry_id_str);
    const is_hovered = in_sidebar and clay.pointerOver(element_id);

    // Klick-Handling: visible_entries darf NICHT während der Iteration geändert werden!
    // Wir setzen pending_toggle und führen es nach dem Rendering aus.
    if (is_hovered and mouse_pressed) {
        if (node.is_folder) {
            state.pending_toggle = entry.node_index;
        } else {
            state.selectEntry(index);
            state.openSelectedFile();
        }
    }

    clay.UI()(.{
        .id = element_id,
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 4,
            .padding = .{ .left = 0, .right = 8 },
        },
        .background_color = if (is_selected) theme.primary else if (is_hovered) [4]f32{ theme.primary[0], theme.primary[1], theme.primary[2], 50.0 } else .{ 0.0, 0.0, 0.0, 0.0 },
    })({
        // Indent Spacer
        clay.UI()(.{
            .id = clay.ElementId.ID("indent"),
            .layout = .{
                .sizing = .{ .w = .fixed(indent), .h = .grow },
            },
            .background_color = .{ 0, 0, 0, 0 },
        })({});

        // Chevron (für Ordner)
        const svg = @import("components/svg.zig");
        if (node.is_folder) {
            var chevron_id_buf: [40]u8 = undefined;
            const chevron_id = std.fmt.bufPrint(&chevron_id_buf, "chevron_{d}", .{index}) catch "chevron";
            const chevron_path = if (entry.is_expanded) svg.Lucide.chevron_down else svg.Lucide.chevron_right;
            svg.Svg(arena, chevron_id, chevron_path, 24, if (is_selected) theme.text_on_primary else theme.muted);
        } else {
            // Spacer für Dateien
            var spacer_id_buf: [40]u8 = undefined;
            const spacer_id = std.fmt.bufPrint(&spacer_id_buf, "file_spacer_{d}", .{index}) catch "file_spacer";
            clay.UI()(.{
                .id = clay.ElementId.ID(spacer_id),
                .layout = .{
                    .sizing = .{ .w = .fixed(24), .h = .grow },
                },
                .background_color = .{ 0, 0, 0, 0 },
            })({});
        }

        // Datei-Icon
        var icon_id_buf: [40]u8 = undefined;
        const icon_id = std.fmt.bufPrint(&icon_id_buf, "icon_{d}", .{index}) catch "icon";
        const icon_path = if (node.is_folder) svg.Lucide.folder else fileIcon(node.name);
        svg.Svg(arena, icon_id, icon_path, 24, if (is_selected) theme.text_on_primary else theme.text);

        // Git-Status Indikator (vorne)
        if (state.git_status.get(node.path)) |code| {
            const git_color: [4]f32 = switch (code) {
                'A' => theme.success,
                'M' => theme.warning,
                'C' => theme.danger,
                '?' => theme.muted,
                'S' => theme.muted,
                else => theme.muted,
            };
            clay.text(&.{code}, .{
                .font_size = 20,
                .color = if (is_selected) theme.text_on_primary else git_color,
            });
            clay.text(" ", .{
                .font_size = 20,
                .color = if (is_selected) theme.text_on_primary else theme.text,
            });
        }

        // Dateiname oder Umbenennen-Feld
        const renaming = if (state.rename) |st| st.node_index == entry.node_index else false;
        if (renaming) {
            const edit_text = state.rename.?.edit.text();
            clay.UI()(.{
                .id = clay.ElementId.ID("fx_rename_box"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(30) },
                    .padding = .{ .left = 6, .right = 6 },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
                .background_color = theme.overlay,
                .border = .{ .width = .all(1), .color = theme.border_focus },
                .corner_radius = .all(3),
            })({
                const shown = std.fmt.allocPrint(arena, "{s}|", .{edit_text}) catch edit_text;
                clay.text(shown, .{ .font_size = 22, .color = theme.text });
            });
        } else {
            clay.text(node.name, .{
                .font_size = 24,
                .color = if (is_selected) theme.text_on_primary else theme.text,
            });
        }
    });
}

/// Datei-Icon basierend auf Extension
fn fileIcon(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    const svg = @import("components/svg.zig");
    if (std.mem.eql(u8, ext, ".zig")) return svg.Lucide.zap;
    if (std.mem.eql(u8, ext, ".md")) return svg.Lucide.file_text;
    if (std.mem.eql(u8, ext, ".json")) return svg.Lucide.file_code;
    if (std.mem.eql(u8, ext, ".toml")) return svg.Lucide.settings;
    if (std.mem.eql(u8, ext, ".svg")) return svg.Lucide.palette;
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg")) return svg.Lucide.image;
    if (std.mem.eql(u8, ext, ".pdf")) return svg.Lucide.file_text;
    if (std.mem.eql(u8, ext, ".log")) return svg.Lucide.clipboard;
    return svg.Lucide.file;
}
