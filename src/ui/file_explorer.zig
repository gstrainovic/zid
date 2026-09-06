//! File Explorer Sidebar für vulkan-ed
//!
//! Zeigt Verzeichnisbaum an (Tree-Widget). Von Gooey's tree_list.zig adaptiert für Clay + wgpu.
//! Auswahl ist eine Menge von Knoten (Ctrl+Klick toggelt, Shift+Klick Bereich), `selected_index`
//! ist der Cursor für Tastaturnavigation. Dateisystem-Aktionen liegen in explorer_ops.zig.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const explorer_ops = @import("explorer_ops.zig");
const shortcuts = @import("shortcuts");
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

/// Einträge des Kontextmenüs, in dieser Reihenfolge (Labels/Kürzel aus shortcuts.zig)
pub const context_menu_items = [_]shortcuts.Command{
    .new_file_entry,   .new_folder_entry, .rename_entry,      .delete_entry,
    .cut_entry,        .copy_entry,       .paste_entry,       .duplicate_entry,
    .copy_path,        .copy_relative_path, .reveal_in_file_manager, .open_in_terminal,
    .collapse_all,
};
const context_menu_row: f32 = 30;
const context_menu_height: f32 = context_menu_items.len * (context_menu_row + 2) + 8;

/// Laufendes Inline-Umbenennen
pub const RenameState = struct { node_index: u32, edit: explorer_ops.RenameEdit };

/// Laufendes Anlegen einer Datei / eines Ordners unter `parent`
pub const CreateState = struct { parent: u32, is_folder: bool, edit: explorer_ops.RenameEdit };

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

/// Zwischenablage des Explorers (Kopieren/Ausschneiden von Einträgen)
pub const Clipboard = struct { paths: [][]u8, cut: bool };

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
    /// Cursor der Tastaturnavigation (Index in visible_entries)
    selected_index: ?usize = null,
    /// Anker für Shift-Bereichsauswahl (Index in visible_entries)
    anchor_index: ?usize = null,
    /// Markierte Knoten (Node-Indizes); der Cursor ist normalerweise enthalten
    selected_nodes: std.AutoHashMap(u32, void),
    /// Datei die geöffnet werden soll (wird von main.zig abgefragt und zurückgesetzt)
    file_to_open: ?[]const u8 = null,
    /// Deferred Action: Folder-Toggle pending (wird nach Rendering ausgeführt)
    pending_toggle: ?u32 = null,
    /// Kontextmenü (Rechtsklick auf Eintrag)
    context_menu: ?ContextMenu = null,
    /// Vom Kontextmenü gewähltes Kommando; die UI holt es per takePendingCommand ab
    pending_command: ?shortcuts.Command = null,
    /// Inline-Umbenennen
    rename: ?RenameState = null,
    /// Inline-Anlegen
    creating: ?CreateState = null,
    /// Vom Kontextmenü angefordert; UI zeigt den Bestätigungsdialog
    pending_delete: ?u32 = null,
    /// Vom Dialog bestätigt; wird im nächsten Frame vor dem Layout ausgeführt
    confirmed_delete: bool = false,
    /// Ausgeführte Änderungen, von der UI abzuholen (takeFsChange, eine pro Aufruf)
    pending_fs_changes: std.ArrayList(FsChange),
    /// Zwischenablage (Kopieren/Ausschneiden)
    clipboard: ?Clipboard = null,
    /// Letzter Fehler einer Dateisystem-Aktion (Anzeige in der UI)
    last_error: ?[]u8 = null,
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
            .selected_nodes = std.AutoHashMap(u32, void).init(allocator),
            .pending_fs_changes = std.ArrayList(FsChange).empty,
            .git_status = std.StringHashMap(u8).init(allocator),
            .width = 250.0,
            .is_resizing = false,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pending_fs_changes.items) |c| c.deinit(self.allocator);
        self.pending_fs_changes.deinit(self.allocator);
        self.clearClipboard();
        if (self.last_error) |e| self.allocator.free(e);
        for (self.nodes.items) |*node| {
            self.allocator.free(node.name);
            self.allocator.free(node.path);
        }
        self.nodes.deinit(self.allocator);
        self.visible_entries.deinit(self.allocator);
        self.expanded_nodes.deinit();
        self.selected_nodes.deinit();
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
        self.selected_nodes.clearRetainingCapacity();
        self.selected_index = null;
        self.anchor_index = null;
        self.rename = null;
        self.creating = null;
        self.context_menu = null;

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

    /// Alle Ordner außer dem Root zuklappen; Cursor auf den Root.
    pub fn collapseAll(self: *Self) void {
        self.expanded_nodes.clearRetainingCapacity();
        self.expanded_nodes.put(0, {}) catch {};
        self.rebuildVisible();
        self.selected_nodes.clearRetainingCapacity();
        if (self.visible_entries.items.len > 0) self.selectEntry(0);
        self.scroll_offset_y = 0;
    }

    /// Sichtbare Einträge neu berechnen (DFS wie Gooey's flattenNode). Der Cursor bleibt
    /// auf demselben Knoten, sofern er noch sichtbar ist.
    fn rebuildVisible(self: *Self) void {
        const cursor_node: ?u32 = self.selectedNodeIndex();
        self.visible_entries.clearRetainingCapacity();
        if (self.nodes.items.len == 0) return;

        // Root durchlaufen
        self.flattenNode(0, 0, false, 0);

        self.selected_index = null;
        if (cursor_node) |cn| {
            self.selected_index = self.visibleIndexOfNode(cn);
        }
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

    fn visibleIndexOfNode(self: *const Self, node_index: u32) ?usize {
        for (self.visible_entries.items, 0..) |e, i| {
            if (e.node_index == node_index) return i;
        }
        return null;
    }

    // ───────────────────────────── Auswahl ─────────────────────────────

    /// Eintrag allein markieren (Cursor + Anker + Auswahlmenge)
    pub fn selectEntry(self: *Self, index: usize) void {
        if (index >= self.visible_entries.items.len) return;
        self.selected_index = index;
        self.anchor_index = index;
        self.selected_nodes.clearRetainingCapacity();
        self.selected_nodes.put(self.visible_entries.items[index].node_index, {}) catch {};
    }

    /// Ctrl+Klick: Eintrag zur Auswahl hinzufügen oder entfernen; Cursor wandert dorthin.
    pub fn toggleSelect(self: *Self, index: usize) void {
        if (index >= self.visible_entries.items.len) return;
        const node = self.visible_entries.items[index].node_index;
        if (self.selected_nodes.contains(node)) {
            _ = self.selected_nodes.remove(node);
        } else {
            self.selected_nodes.put(node, {}) catch {};
        }
        self.selected_index = index;
        self.anchor_index = index;
    }

    /// Shift+Klick / Shift+Pfeil: Bereich vom Anker bis `index` markieren.
    pub fn selectRangeTo(self: *Self, index: usize) void {
        if (index >= self.visible_entries.items.len) return;
        const anchor = self.anchor_index orelse index;
        const lo = @min(anchor, index);
        const hi = @max(anchor, index);
        self.selected_nodes.clearRetainingCapacity();
        for (self.visible_entries.items[lo .. hi + 1]) |e| self.selected_nodes.put(e.node_index, {}) catch {};
        self.selected_index = index;
    }

    /// Alle sichtbaren Einträge außer dem Root markieren.
    pub fn selectAll(self: *Self) void {
        self.selected_nodes.clearRetainingCapacity();
        for (self.visible_entries.items, 0..) |e, i| {
            if (i == 0) continue;
            self.selected_nodes.put(e.node_index, {}) catch {};
        }
        if (self.selected_index == null and self.visible_entries.items.len > 1) self.selected_index = 1;
    }

    pub fn isNodeSelected(self: *const Self, node_index: u32) bool {
        return self.selected_nodes.contains(node_index);
    }

    pub fn selectionCount(self: *const Self) usize {
        return self.selected_nodes.count();
    }

    /// Knoten des Cursors (für F2/Entf, Kontextmenü).
    pub fn selectedNodeIndex(self: *const Self) ?u32 {
        const idx = self.selected_index orelse return null;
        if (idx >= self.visible_entries.items.len) return null;
        return self.visible_entries.items[idx].node_index;
    }

    /// Absolute Pfade aller markierten Knoten (owned, Aufrufer gibt Liste und Einträge frei).
    /// Root ist nie dabei. Knoten, deren Elternordner ebenfalls markiert ist, fallen weg
    /// (der Ordner nimmt sie mit).
    pub fn selectedPaths(self: *const Self, alloc: std.mem.Allocator) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |p| alloc.free(p);
            out.deinit(alloc);
        }
        var it = self.selected_nodes.keyIterator();
        while (it.next()) |k| {
            const idx = k.*;
            if (idx == 0 or idx >= self.nodes.items.len) continue;
            var parent = self.nodes.items[idx].parent;
            var covered = false;
            while (parent) |p| : (parent = self.nodes.items[p].parent) {
                if (p != 0 and self.selected_nodes.contains(p)) {
                    covered = true;
                    break;
                }
            }
            if (covered) continue;
            try out.append(alloc, try alloc.dupe(u8, self.nodes.items[idx].path));
        }
        return out.toOwnedSlice(alloc);
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

    // ───────────────────────────── Tastatur ─────────────────────────────

    /// Cursor so scrollen, dass die Zeile `index` im Viewport liegt.
    pub fn scrollToIndex(self: *Self, index: usize) void {
        if (self.viewport_height <= 0) return;
        const top = @as(f32, @floatFromInt(index)) * ROW_HEIGHT;
        const bottom = top + ROW_HEIGHT;
        if (top < self.scroll_offset_y) {
            self.scroll_offset_y = top;
        } else if (bottom > self.scroll_offset_y + self.viewport_height) {
            self.scroll_offset_y = bottom - self.viewport_height;
        }
    }

    fn moveCursor(self: *Self, target: usize, extend: bool) void {
        if (self.visible_entries.items.len == 0) return;
        const idx = @min(target, self.visible_entries.items.len - 1);
        if (extend) self.selectRangeTo(idx) else self.selectEntry(idx);
        self.scrollToIndex(idx);
    }

    /// Tastaturnavigation bei Fokus im Explorer. true = Taste verbraucht.
    /// ↑/↓ (Shift erweitert), ←/→ zu-/aufklappen bzw. Eltern/erstes Kind, Enter/Space öffnet,
    /// Home/End, PageUp/PageDown.
    pub fn handleNavKey(self: *Self, key: wio.Button, shift: bool) bool {
        const n = self.visible_entries.items.len;
        if (n == 0) return false;
        const cur = self.selected_index orelse 0;
        const page: usize = @max(1, @as(usize, @intFromFloat(@max(0, self.viewport_height) / ROW_HEIGHT)));
        switch (key) {
            .up => self.moveCursor(if (self.selected_index == null) 0 else cur -| 1, shift),
            .down => self.moveCursor(if (self.selected_index == null) 0 else cur + 1, shift),
            .home => self.moveCursor(0, shift),
            .end => self.moveCursor(n - 1, shift),
            .page_up => self.moveCursor(cur -| page, shift),
            .page_down => self.moveCursor(cur + page, shift),
            .left => {
                if (self.selected_index == null) return true;
                const entry = self.visible_entries.items[cur];
                if (entry.is_folder and entry.is_expanded and cur != 0) {
                    self.collapseNode(entry.node_index);
                    self.moveCursor(cur, false);
                } else if (entry.depth > 0) {
                    // Elternordner: rückwärts bis zur nächsten flacheren Zeile
                    var i = cur;
                    while (i > 0) : (i -= 1) {
                        if (self.visible_entries.items[i - 1].depth < entry.depth) {
                            self.moveCursor(i - 1, false);
                            break;
                        }
                    }
                }
            },
            .right => {
                if (self.selected_index == null) return true;
                const entry = self.visible_entries.items[cur];
                if (entry.is_folder) {
                    if (!entry.is_expanded) {
                        self.toggleNode(entry.node_index) catch {};
                        self.moveCursor(cur, false);
                    } else if (cur + 1 < n and self.visible_entries.items[cur + 1].depth > entry.depth) {
                        self.moveCursor(cur + 1, false);
                    }
                } else {
                    self.openSelectedFile();
                }
            },
            .enter, .kp_enter, .space => {
                if (self.selected_index == null) return true;
                const entry = self.visible_entries.items[cur];
                if (entry.is_folder) {
                    self.toggleNode(entry.node_index) catch {};
                    self.moveCursor(cur, false);
                } else {
                    self.openSelectedFile();
                }
            },
            else => return false,
        }
        return true;
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

    pub fn inSidebar(self: *const Self, x: f32) bool {
        return self.viewport_width > 0 and x >= self.viewport_x and x < self.viewport_x + self.viewport_width;
    }

    // ───────────────────────────── Kontextmenü ─────────────────────────────

    pub fn openContextMenu(self: *Self, x: f32, y: f32, entry_index: usize) void {
        if (entry_index >= self.visible_entries.items.len) return;
        const node = self.visible_entries.items[entry_index].node_index;
        // Rechtsklick auf einen markierten Eintrag behält die Mehrfachauswahl
        if (!self.selected_nodes.contains(node)) self.selectEntry(entry_index) else self.selected_index = entry_index;
        // Am unteren Rand nach oben verschieben, damit das Menü sichtbar bleibt
        const bottom = self.viewport_y + self.viewport_height;
        const menu_y = if (y + context_menu_height > bottom) @max(self.viewport_y, bottom - context_menu_height) else y;
        self.context_menu = .{ .x = x, .y = menu_y, .node_index = node };
    }

    /// Vom Kontextmenü gewähltes Kommando abholen (einmal).
    pub fn takePendingCommand(self: *Self) ?shortcuts.Command {
        const c = self.pending_command;
        self.pending_command = null;
        return c;
    }

    // ───────────────────────────── Umbenennen / Anlegen ─────────────────────────────

    pub fn startRename(self: *Self, node_index: u32) void {
        if (node_index == 0 or node_index >= self.nodes.items.len) return;
        self.creating = null;
        self.rename = .{ .node_index = node_index, .edit = explorer_ops.RenameEdit.init(self.nodes.items[node_index].name) };
    }

    pub fn isRenaming(self: *const Self) bool {
        return self.rename != null;
    }

    pub fn isCreating(self: *const Self) bool {
        return self.creating != null;
    }

    /// Umbenennen oder Anlegen läuft: alle Tasten gehören dem Eingabefeld.
    pub fn isEditing(self: *const Self) bool {
        return self.rename != null or self.creating != null;
    }

    /// Zielordner für neue Einträge und Einfügen: markierter Ordner, sonst dessen Elternordner, sonst Root.
    pub fn targetFolder(self: *const Self) u32 {
        const node = self.selectedNodeIndex() orelse return 0;
        if (node >= self.nodes.items.len) return 0;
        if (self.nodes.items[node].is_folder) return node;
        return self.nodes.items[node].parent orelse 0;
    }

    /// Inline-Eingabe für eine neue Datei / einen neuen Ordner im Zielordner öffnen.
    pub fn startCreate(self: *Self, is_folder: bool) void {
        const parent = self.targetFolder();
        if (!self.expanded_nodes.contains(parent)) self.toggleNode(parent) catch {};
        self.rename = null;
        self.creating = .{ .parent = parent, .is_folder = is_folder, .edit = explorer_ops.RenameEdit.init("") };
        if (self.visibleIndexOfNode(parent)) |i| self.scrollToIndex(i + 1);
    }

    pub fn handleRenameKey(self: *Self, key: wio.Button) void {
        if (self.creating != null) {
            const st = &self.creating.?;
            switch (key) {
                .enter, .kp_enter => self.commitCreate(),
                .escape => self.creating = null,
                .backspace => st.edit.backspace(),
                else => {},
            }
            return;
        }
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
        if (self.creating) |*st| st.edit.insertCodepoint(cp);
        if (self.rename) |*st| st.edit.insertCodepoint(cp);
    }

    fn commitRename(self: *Self) void {
        const st = self.rename orelse return;
        self.rename = null;
        if (st.node_index >= self.nodes.items.len) return;
        const node = self.nodes.items[st.node_index];
        const new_path = explorer_ops.renamePath(self.allocator, node.path, st.edit.text()) catch |err| {
            self.setError("rename '{s}' failed: {s}", .{ node.name, @errorName(err) });
            return;
        };
        defer self.allocator.free(new_path);
        log.info("renamed '{s}' -> '{s}'", .{ node.path, new_path });
        self.pushFsChange(.renamed, node.path, new_path);
        self.refresh(new_path);
    }

    fn commitCreate(self: *Self) void {
        const st = self.creating orelse return;
        self.creating = null;
        if (st.parent >= self.nodes.items.len) return;
        const parent = self.nodes.items[st.parent];
        const new_path = explorer_ops.createEntry(self.allocator, parent.path, st.edit.text(), st.is_folder) catch |err| {
            self.setError("create '{s}' failed: {s}", .{ st.edit.text(), @errorName(err) });
            return;
        };
        defer self.allocator.free(new_path);
        log.info("created '{s}'", .{new_path});
        self.refresh(new_path);
        if (!st.is_folder) self.openSelectedFile();
    }

    // ───────────────────────────── Zwischenablage ─────────────────────────────

    fn clearClipboard(self: *Self) void {
        if (self.clipboard) |cb| {
            for (cb.paths) |p| self.allocator.free(p);
            self.allocator.free(cb.paths);
        }
        self.clipboard = null;
    }

    /// Markierte Einträge in die Explorer-Zwischenablage (Ausschneiden = später verschieben).
    pub fn copySelection(self: *Self, cut: bool) void {
        const paths = self.selectedPaths(self.allocator) catch return;
        if (paths.len == 0) {
            self.allocator.free(paths);
            return;
        }
        self.clearClipboard();
        self.clipboard = .{ .paths = paths, .cut = cut };
    }

    pub fn isCut(self: *const Self, path: []const u8) bool {
        const cb = self.clipboard orelse return false;
        if (!cb.cut) return false;
        for (cb.paths) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    /// Zwischenablage in den Zielordner einfügen (kopieren oder verschieben).
    pub fn paste(self: *Self) void {
        const cb = self.clipboard orelse return;
        const target = self.nodes.items[self.targetFolder()].path;
        var last: ?[]u8 = null;
        defer if (last) |l| self.allocator.free(l);
        for (cb.paths) |src| {
            const dst = if (cb.cut)
                explorer_ops.movePath(self.allocator, src, target)
            else
                explorer_ops.copyPath(self.allocator, src, target);
            const dst_path = dst catch |err| {
                self.setError("paste '{s}' failed: {s}", .{ std.fs.path.basename(src), @errorName(err) });
                continue;
            };
            if (cb.cut and !std.mem.eql(u8, src, dst_path)) self.pushFsChange(.renamed, src, dst_path);
            if (last) |l| self.allocator.free(l);
            last = dst_path;
        }
        if (cb.cut) self.clearClipboard();
        self.refresh(last);
    }

    /// Markierte Einträge im selben Ordner duplizieren („name copy.ext“).
    pub fn duplicateSelection(self: *Self) void {
        const paths = self.selectedPaths(self.allocator) catch return;
        defer {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }
        var last: ?[]u8 = null;
        defer if (last) |l| self.allocator.free(l);
        for (paths) |src| {
            const dir = std.fs.path.dirname(src) orelse continue;
            const dst = explorer_ops.copyPath(self.allocator, src, dir) catch |err| {
                self.setError("duplicate '{s}' failed: {s}", .{ std.fs.path.basename(src), @errorName(err) });
                continue;
            };
            if (last) |l| self.allocator.free(l);
            last = dst;
        }
        self.refresh(last);
    }

    // ───────────────────────────── Änderungen / Fehler ─────────────────────────────

    fn pushFsChange(self: *Self, kind: @FieldType(FsChange, "kind"), old_path: []const u8, new_path: ?[]const u8) void {
        const old_dup = self.allocator.dupe(u8, old_path) catch return;
        const new_dup: ?[]u8 = if (new_path) |p| (self.allocator.dupe(u8, p) catch {
            self.allocator.free(old_dup);
            return;
        }) else null;
        self.pending_fs_changes.append(self.allocator, .{ .kind = kind, .old_path = old_dup, .new_path = new_dup }) catch {
            self.allocator.free(old_dup);
            if (new_dup) |p| self.allocator.free(p);
        };
    }

    /// Von der UI pro Frame in einer Schleife abholen; der Aufrufer gibt das Ergebnis frei.
    pub fn takeFsChange(self: *Self) ?FsChange {
        if (self.pending_fs_changes.items.len == 0) return null;
        return self.pending_fs_changes.orderedRemove(0);
    }

    fn setError(self: *Self, comptime fmt: []const u8, args: anytype) void {
        log.err(fmt, args);
        if (self.last_error) |e| self.allocator.free(e);
        self.last_error = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    /// Letzten Fehler abholen (owned, Aufrufer gibt frei).
    pub fn takeError(self: *Self) ?[]u8 {
        const e = self.last_error;
        self.last_error = null;
        return e;
    }

    // ───────────────────────────── Löschen (Papierkorb) ─────────────────────────────

    /// Vom Dialog-Callback: Löschen vormerken (Ausführung im nächsten Frame vor dem Layout,
    /// weil Render-Commands noch auf Knotennamen zeigen).
    pub fn takePendingDelete(self: *Self) ?u32 {
        const v = self.pending_delete;
        self.pending_delete = null;
        return v;
    }

    /// Löschen der aktuellen Auswahl anfordern (Cursor auf `node_index`, falls nicht markiert).
    pub fn requestDelete(self: *Self, node_index: u32) void {
        if (node_index == 0 or node_index >= self.nodes.items.len) return;
        if (!self.selected_nodes.contains(node_index)) {
            if (self.visibleIndexOfNode(node_index)) |i| self.selectEntry(i);
        }
        self.pending_delete = node_index;
    }

    /// Anzahl der Einträge, die ein bestätigtes Löschen trifft (ohne Root, ohne abgedeckte Kinder).
    pub fn deleteCount(self: *const Self) usize {
        const paths = self.selectedPaths(self.allocator) catch return 0;
        defer {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }
        return paths.len;
    }

    pub fn confirmDelete(self: *Self, node_index: u32) void {
        _ = node_index;
        self.confirmed_delete = true;
    }

    /// Einmal pro Frame vor dem Layout aufrufen.
    pub fn processPending(self: *Self) void {
        if (self.confirmed_delete) {
            self.confirmed_delete = false;
            self.deleteSelection();
        }
    }

    /// In den Papierkorb verschieben; Fallback `gio trash`. Nie endgültig löschen.
    fn trashOrFail(self: *Self, path: []const u8) !void {
        const root = explorer_ops.defaultTrashRoot(self.allocator) catch return error.NoTrash;
        defer self.allocator.free(root);
        if (explorer_ops.trashPath(self.allocator, path, root)) |name| {
            self.allocator.free(name);
            return;
        } else |err| {
            log.warn("trash '{s}' via {s} failed: {s}, trying gio", .{ path, root, @errorName(err) });
        }
        var child = std.process.Child.init(&.{ "gio", "trash", "--", path }, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch return error.NoTrash;
        if (term != .Exited or term.Exited != 0) return error.NoTrash;
    }

    /// Alle markierten Einträge in den Papierkorb verschieben.
    pub fn deleteSelection(self: *Self) void {
        const paths = self.selectedPaths(self.allocator) catch return;
        defer {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }
        for (paths) |p| {
            self.trashOrFail(p) catch |err| {
                self.setError("trash '{s}' failed: {s}", .{ std.fs.path.basename(p), @errorName(err) });
                continue;
            };
            log.info("moved to trash '{s}'", .{p});
            self.pushFsChange(.deleted, p, null);
        }
        self.refresh(null);
    }

    /// Alter Einzelknoten-Pfad (Agent, Tests): Knoten markieren und löschen.
    pub fn deleteNode(self: *Self, node_index: u32) void {
        if (node_index == 0 or node_index >= self.nodes.items.len) return;
        if (self.visibleIndexOfNode(node_index)) |i| self.selectEntry(i) else {
            self.selected_nodes.clearRetainingCapacity();
            self.selected_nodes.put(node_index, {}) catch return;
        }
        self.deleteSelection();
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
        self.selected_nodes.clearRetainingCapacity();
        if (sel) |p| {
            for (self.visible_entries.items, 0..) |e, idx| {
                if (std.mem.eql(u8, self.nodes.items[e.node_index].path, p)) {
                    self.selectEntry(idx);
                    self.scrollToIndex(idx);
                    break;
                }
            }
        }
    }

    /// Baum neu laden und den Cursor auf demselben Pfad halten (Taste R).
    pub fn refreshKeepSelection(self: *Self) void {
        const node = self.selectedNodeIndex();
        const keep: ?[]u8 = if (node) |n| (self.allocator.dupe(u8, self.nodes.items[n].path) catch null) else null;
        defer if (keep) |k| self.allocator.free(k);
        self.refresh(keep);
    }

    // ───────────────────────────── Maus ─────────────────────────────

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, button: wio.Button) bool {
        // Offenes Kontextmenü: Eintrag ausführen oder Menü schließen
        if (self.context_menu) |_| {
            self.context_menu = null;
            inline for (context_menu_items) |cmd| {
                if (clay.pointerOver(contextItemId(cmd))) {
                    self.pending_command = cmd;
                    return true;
                }
            }
            return true;
        }
        // Laufendes Umbenennen/Anlegen: jeder Klick bricht ab
        self.rename = null;
        self.creating = null;

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

/// Klick-Modifier des Frames (Ctrl toggelt, Shift markiert Bereich)
pub const ClickMods = struct { ctrl: bool = false, shift: bool = false };

/// File Explorer Sidebar rendern
pub fn renderFileExplorer(
    arena: std.mem.Allocator,
    state: *FileExplorerState,
    theme: Theme,
    mouse_pressed: bool,
    focused: bool,
    mods: ClickMods,
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
        // Fokus sichtbar: Tastatur (↑↓, d, r, a …) wirkt hier, nicht im Editor
        .border = .{ .width = .{ .right = 1, .left = 2 }, .color = if (focused) theme.border_focus else theme.border },
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
                    renderTreeEntry(arena, state, entry, i, theme, effective_press, in_sidebar, mods);
                    if (state.creating) |cs| {
                        if (cs.parent == entry.node_index) renderCreateRow(arena, cs, entry.depth + 1, theme);
                    }
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

fn contextItemId(comptime cmd: shortcuts.Command) clay.ElementId {
    return clay.ElementId.ID("fx_menu_" ++ @tagName(cmd));
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
            inline for (context_menu_items) |cmd| {
                renderContextMenuItem(shortcuts.label(cmd), shortcuts.shortcutText(cmd), contextItemId(cmd), theme);
            }
        });
    });
}

fn renderContextMenuItem(label: []const u8, shortcut: []const u8, item_id: clay.ElementId, theme: Theme) void {
    const hovered = clay.pointerOver(item_id);
    clay.UI()(.{
        .id = item_id,
        .layout = .{
            .sizing = .{ .w = .fixed(330), .h = .fixed(context_menu_row) },
            .padding = .{ .left = 12, .right = 12 },
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 8,
        },
        .background_color = if (hovered) theme.primary else .{ 0, 0, 0, 0 },
        .corner_radius = .all(3),
    })({
        clay.text(label, .{ .font_size = 18, .color = if (hovered) theme.text_on_primary else theme.text, .wrap_mode = .none });
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
        clay.text(shortcut, .{ .font_size = 14, .color = if (hovered) theme.text_on_primary else theme.muted, .wrap_mode = .none });
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

/// Eingabezeile für „neue Datei / neuer Ordner“ unter dem Elternordner
fn renderCreateRow(arena: std.mem.Allocator, cs: CreateState, depth: u32, theme: Theme) void {
    const indent = @as(f32, @floatFromInt(depth)) * DEFAULT_INDENT_PX + 8.0 + 24.0;
    clay.UI()(.{
        .id = clay.ElementId.ID("fx_create_row"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 4,
            .padding = .{ .left = 0, .right = 8 },
        },
    })({
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(indent), .h = .grow } } })({});
        const svg = @import("components/svg.zig");
        svg.Svg(arena, "fx_create_icon", if (cs.is_folder) svg.Lucide.folder else svg.Lucide.file, 24, theme.muted);
        clay.UI()(.{
            .id = clay.ElementId.ID("fx_create_box"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(30) },
                .padding = .{ .left = 6, .right = 6 },
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = theme.overlay,
            .border = .{ .width = .all(1), .color = theme.border_focus },
            .corner_radius = .all(3),
        })({
            const shown = std.fmt.allocPrint(arena, "{s}|", .{cs.edit.text()}) catch cs.edit.text();
            clay.text(shown, .{ .font_size = 22, .color = theme.text, .wrap_mode = .none });
        });
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
    mods: ClickMods,
) void {
    const node = state.nodes.items[entry.node_index];
    const is_selected = state.isNodeSelected(entry.node_index);
    const is_cursor = state.selected_index == index;
    const is_cut = state.isCut(node.path);
    const indent = @as(f32, @floatFromInt(entry.depth)) * DEFAULT_INDENT_PX + 8.0;

    const entry_id_str = std.fmt.allocPrint(arena, "tree_entry_{d}", .{index}) catch return;
    const element_id = clay.ElementId.ID(entry_id_str);
    const is_hovered = in_sidebar and clay.pointerOver(element_id);

    // Klick-Handling: visible_entries darf NICHT während der Iteration geändert werden!
    // Wir setzen pending_toggle und führen es nach dem Rendering aus.
    if (is_hovered and mouse_pressed) {
        if (mods.ctrl) {
            state.toggleSelect(index);
        } else if (mods.shift) {
            state.selectRangeTo(index);
        } else {
            state.selectEntry(index);
            if (node.is_folder) {
                state.pending_toggle = entry.node_index;
            } else {
                state.openSelectedFile();
            }
        }
    }

    const fg: clay.Color = if (is_selected) theme.text_on_primary else if (is_cut) theme.muted else theme.text;
    const bg: clay.Color = if (is_selected)
        theme.primary
    else if (is_hovered)
        .{ theme.primary[0], theme.primary[1], theme.primary[2], 50.0 }
    else
        .{ 0.0, 0.0, 0.0, 0.0 };

    clay.UI()(.{
        .id = element_id,
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 4,
            .padding = .{ .left = 0, .right = 8 },
        },
        .background_color = bg,
        // Cursor ohne Markierung (nach Ctrl+Klick-Abwahl) bleibt als Rahmen sichtbar
        .border = .{ .width = .all(1), .color = if (is_cursor and !is_selected) theme.border_focus else .{ 0, 0, 0, 0 } },
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
        svg.Svg(arena, icon_id, icon_path, 24, fg);

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
                .color = fg,
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
                .color = fg,
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
