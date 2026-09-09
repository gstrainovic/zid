//! File Explorer Sidebar für zid
//!
//! Zeigt Verzeichnisbaum an (Tree-Widget). Von Gooey's tree_list.zig adaptiert für Clay + wgpu.
//! Auswahl ist eine Menge von Knoten (Ctrl+Klick toggelt, Shift+Klick Bereich), `selected_index`
//! ist der Cursor für Tastaturnavigation. Dateisystem-Aktionen liegen in explorer_ops.zig.

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const explorer_ops = @import("explorer_ops.zig");
const shortcuts = @import("shortcuts");
const ctx_menu = @import("context_menu");
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
    .collapse_all,     .toggle_hidden_files, .filter_explorer,
};
const context_menu_height: f32 = ctx_menu.height(context_menu_items.len);

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

/// Laufendes Ziehen eines Eintrags (Drag & Drop zum Verschieben)
pub const DragState = struct { node: u32, start_x: f32, start_y: f32, moved: bool = false, over: ?u32 = null };

/// Vom Drop angefordertes Verschieben; die UI fragt nach und ruft performMove
pub const PendingMove = struct {
    src: []u8,
    dst_dir: []u8,
    pub fn deinit(self: PendingMove, alloc: std.mem.Allocator) void {
        alloc.free(self.src);
        alloc.free(self.dst_dir);
    }
};

/// Eingabepuffer des Filterfelds
pub const FilterEdit = explorer_ops.EditBuffer(64);

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
    /// Öffnen als Vorschau-Tab (Einfachklick/Space) statt fest (Doppelklick/Enter)
    /// Uhr für Doppelklick-Erkennung (von der UI hochgezählt)
    now_ms: f32 = 0,
    last_click_ms: f32 = -10_000,
    last_click_index: ?usize = null,
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
    /// Letzte Erfolgsmeldung (Toast in der UI, owned)
    last_info: ?[]u8 = null,
    /// Versteckte Einträge (`.name`) anzeigen (Taste `.`)
    show_hidden: bool = false,
    /// Filterfeld (Taste `/`): nur Einträge, deren Name den Text enthält, plus ihre Elternordner
    filter: FilterEdit = .{},
    filter_active: bool = false,
    /// Tooltip: Zeile, über der die Maus steht, und seit wann
    hover_index: ?usize = null,
    hover_since_ms: f32 = 0,
    /// Drag & Drop
    drag: ?DragState = null,
    pending_move: ?PendingMove = null,
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
        if (self.pending_move) |m| m.deinit(self.allocator);
        for (self.pending_fs_changes.items) |c| c.deinit(self.allocator);
        self.pending_fs_changes.deinit(self.allocator);
        self.clearClipboard();
        if (self.last_error) |e| self.allocator.free(e);
        if (self.last_info) |e| self.allocator.free(e);
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

        // "root:<abs>" nennt die Repo-Wurzel; die Pfade sind relativ dazu (Projektordner kann tiefer liegen)
        var root: []const u8 = repo_root;
        if (std.mem.startsWith(u8, payload, "root:")) {
            const end = std.mem.indexOfScalar(u8, payload, '\n') orelse payload.len;
            root = payload["root:".len..end];
        }
        var lines = std.mem.splitScalar(u8, payload, '\n');
        while (lines.next()) |line| {
            if (line.len < 3) continue;
            const code = line[0];
            if (code == 'b' or code == 'r') continue; // "branch:..." / "root:..." überspringen
            if (line[1] != ':') continue;
            const rel = line[2..];
            const abs = std.fs.path.join(self.allocator, &.{ root, rel }) catch continue;
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
            // Versteckte Einträge nur mit show_hidden (Taste `.`)
            if (!self.show_hidden and std.mem.startsWith(u8, entry.name, ".")) continue;

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
        // Kürzere Liste (Filter, Zuklappen): Scroll-Versatz einfangen, sonst steht alles über dem Viewport
        const content = @as(f32, @floatFromInt(self.visible_entries.items.len)) * ROW_HEIGHT;
        const max_scroll = @max(0, content - self.viewport_height);
        if (self.scroll_offset_y > max_scroll) self.scroll_offset_y = max_scroll;
    }

    /// Filter: Name enthält den Text (Groß/Klein egal) oder ein geladener Nachfahre passt.
    fn nodeMatchesFilter(self: *const Self, node_index: u32) bool {
        const needle = self.filter.text();
        if (needle.len == 0) return true;
        const node = self.nodes.items[node_index];
        if (std.ascii.indexOfIgnoreCase(node.name, needle) != null) return true;
        if (!node.is_folder) return false;
        var child = node.first_child orelse return false;
        var k: u32 = 0;
        while (k < node.child_count) : ({ k += 1; child += 1; }) {
            if (child >= self.nodes.items.len) break;
            if (self.nodeMatchesFilter(child)) return true;
        }
        return false;
    }

    /// Einen Knoten und seine sichtbaren Nachfahren flattieren
    fn flattenNode(self: *Self, node_index: u32, depth: u32, has_next_sibling: bool, ancestry_mask: u32) void {
        if (node_index >= self.nodes.items.len) return;
        if (depth >= MAX_TREE_DEPTH) return;

        const node = &self.nodes.items[node_index];
        const filtering = self.filter.text().len > 0;
        if (filtering and node_index != 0 and !self.nodeMatchesFilter(node_index)) return;
        // Mit Filter: Ordner mit Treffern aufgeklappt zeigen
        const is_expanded = self.expanded_nodes.contains(node_index) or (filtering and node.is_folder);

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

    /// Markierte Datei öffnen (setzt file_to_open; main.zig öffnet den Tab)
    pub fn openSelectedFile(self: *Self) void {
        if (self.selected_index) |idx| {
            if (idx < self.visible_entries.items.len) {
                const entry = self.visible_entries.items[idx];
                const node = self.nodes.items[entry.node_index];
                if (!node.is_folder) self.file_to_open = node.path;
            }
        }
    }

    /// Eintrag mit diesem Pfad sichtbar machen: Elternordner aufklappen, markieren, hinscrollen.
    /// Pfade außerhalb des Roots werden ignoriert.
    pub fn revealPath(self: *Self, path: []const u8) void {
        if (self.nodes.items.len == 0) return;
        if (!explorer_ops.isPathOrUnder(path, self.nodes.items[0].path)) return;
        var current: u32 = 0;
        var guard: usize = 0;
        while (!std.mem.eql(u8, self.nodes.items[current].path, path) and guard < MAX_TREE_DEPTH) : (guard += 1) {
            if (!self.expanded_nodes.contains(current)) self.expandNode(current, self.nodes.items[current].path) catch return;
            const parent = self.nodes.items[current];
            var child = parent.first_child orelse return;
            var found: ?u32 = null;
            var k: u32 = 0;
            while (k < parent.child_count) : ({ k += 1; child += 1; }) {
                if (child >= self.nodes.items.len) break;
                if (explorer_ops.isPathOrUnder(path, self.nodes.items[child].path)) {
                    found = child;
                    break;
                }
            }
            current = found orelse return;
        }
        if (self.visibleIndexOfNode(current)) |i| {
            self.selectEntry(i);
            self.scrollToIndex(i);
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

    /// Umbenennen, Anlegen oder Filtern läuft: alle Tasten gehören dem Eingabefeld.
    pub fn isEditing(self: *const Self) bool {
        return self.rename != null or self.creating != null or self.filter_active;
    }

    /// Taste `/`: Filterfeld fokussieren (Enter behält den Filter, Escape leert ihn).
    pub fn startFilter(self: *Self) void {
        self.rename = null;
        self.creating = null;
        self.filter_active = true;
    }

    pub fn clearFilter(self: *Self) void {
        self.filter = .{};
        self.filter_active = false;
        self.rebuildVisible();
    }

    pub fn toggleHidden(self: *Self) void {
        self.show_hidden = !self.show_hidden;
        self.refreshKeepSelection();
    }

    /// Drop angefordert: die UI fragt nach und ruft performMove (owned, Aufrufer gibt frei).
    pub fn takePendingMove(self: *Self) ?PendingMove {
        const m = self.pending_move;
        self.pending_move = null;
        return m;
    }

    /// Verschieben nach bestätigtem Drop.
    pub fn performMove(self: *Self, src: []const u8, dst_dir: []const u8) void {
        const dst = explorer_ops.movePath(self.allocator, src, dst_dir) catch |err| {
            self.setError("move '{s}' failed: {s}", .{ std.fs.path.basename(src), @errorName(err) });
            return;
        };
        defer self.allocator.free(dst);
        if (!std.mem.eql(u8, src, dst)) self.pushFsChange(.renamed, src, dst);
        self.refresh(dst);
    }

    /// Von .gitignore ausgeschlossen: der Eintrag selbst oder ein Vorfahr steht als `I` im Status.
    pub fn isIgnored(self: *const Self, path: []const u8) bool {
        var it = self.git_status.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* == 'I' and explorer_ops.isPathOrUnder(path, kv.key_ptr.*)) return true;
        }
        return false;
    }

    /// Git-Status eines Ordners aus seinen Nachfahren (C > M > A > ?), null wenn nichts.
    /// Ignorierte Einträge zählen nicht (sie grauen nur ihren eigenen Teilbaum aus).
    pub fn folderStatus(self: *const Self, dir_path: []const u8) ?u8 {
        var best: ?u8 = null;
        var it = self.git_status.iterator();
        while (it.next()) |kv| {
            if (!explorer_ops.isPathOrUnder(kv.key_ptr.*, dir_path) or kv.key_ptr.*.len == dir_path.len) continue;
            const code = kv.value_ptr.*;
            if (code == 'I') continue;
            const rank_new = statusRank(code);
            if (best == null or rank_new > statusRank(best.?)) best = code;
        }
        return best;
    }

    fn statusRank(code: u8) u8 {
        return switch (code) {
            'C' => 4,
            'M' => 3,
            'A' => 2,
            '?' => 1,
            else => 0,
        };
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
        if (self.filter_active) {
            switch (key) {
                .enter, .kp_enter => self.filter_active = false,
                .escape => self.clearFilter(),
                .backspace => {
                    self.filter.backspace();
                    self.rebuildVisible();
                },
                .up, .down => {
                    self.filter_active = false;
                    _ = self.handleNavKey(key, false);
                },
                else => {},
            }
            return;
        }
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
        if (self.filter_active) {
            self.filter.insertCodepoint(cp);
            self.rebuildVisible();
            return;
        }
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

    fn setInfo(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (self.last_info) |e| self.allocator.free(e);
        self.last_info = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    /// Letzte Erfolgsmeldung abholen (owned, Aufrufer gibt frei).
    pub fn takeInfo(self: *Self) ?[]u8 {
        const e = self.last_info;
        self.last_info = null;
        return e;
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
        if (paths.len == 1) self.setInfo("Moved to trash: {s}", .{std.fs.path.basename(paths[0])}) else self.setInfo("Moved {d} items to trash", .{paths.len});
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
            if (ctx_menu.hit("fx_menu", &context_menu_items, ctx_menu.none)) |cmd| self.pending_command = cmd;
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

/// Mausposition und -taste des Frames (Drag & Drop, Tooltip)
pub const MouseState = struct { x: f32 = 0, y: f32 = 0, down: bool = false };

/// File Explorer Sidebar rendern
pub fn renderFileExplorer(
    arena: std.mem.Allocator,
    state: *FileExplorerState,
    theme: Theme,
    mouse_pressed: bool,
    focused: bool,
    mods: ClickMods,
    mouse: MouseState,
) void {
    // Drag & Drop: Bewegung erkennen, Ziel bestimmen, beim Loslassen Verschieben anfordern
    if (state.drag) |*d| {
        if (!d.moved and (@abs(mouse.x - d.start_x) > 6 or @abs(mouse.y - d.start_y) > 6)) d.moved = true;
        d.over = null;
        if (d.moved) {
            if (state.entryAt(mouse.x, mouse.y)) |idx| {
                const target = state.visible_entries.items[idx].node_index;
                const target_dir: u32 = if (state.nodes.items[target].is_folder) target else (state.nodes.items[target].parent orelse 0);
                const src = state.nodes.items[d.node];
                const dst = state.nodes.items[target_dir];
                const same_parent = if (src.parent) |p| p == target_dir else false;
                if (target_dir != d.node and !same_parent and !explorer_ops.isPathOrUnder(dst.path, src.path)) d.over = target_dir;
            }
        }
        if (!mouse.down) {
            if (d.moved) {
                if (d.over) |dst_dir| {
                    const src_dup = state.allocator.dupe(u8, state.nodes.items[d.node].path) catch null;
                    const dst_dup = state.allocator.dupe(u8, state.nodes.items[dst_dir].path) catch null;
                    if (src_dup != null and dst_dup != null) {
                        if (state.pending_move) |old| old.deinit(state.allocator);
                        state.pending_move = .{ .src = src_dup.?, .dst_dir = dst_dup.? };
                    } else {
                        if (src_dup) |p| state.allocator.free(p);
                        if (dst_dup) |p| state.allocator.free(p);
                    }
                }
            }
            state.drag = null;
        }
    }
    if (!clay.pointerOver(clay.ElementId.ID("file_explorer"))) state.hover_index = null;

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
        if (state.filter_active or state.filter.text().len > 0) renderFilterRow(arena, state, theme);
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
                    renderTreeEntry(arena, state, entry, i, theme, effective_press, in_sidebar, mods, mouse);
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

/// Filterfeld über dem Baum (Taste `/`)
fn renderFilterRow(arena: std.mem.Allocator, state: *FileExplorerState, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("fx_filter_row"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(ROW_HEIGHT) },
            .padding = .{ .left = 8, .right = 8 },
            .child_alignment = .{ .y = .center },
            .child_gap = 6,
        },
        .background_color = theme.surface,
    })({
        clay.text("Filter", .{ .font_size = 16, .color = theme.muted, .wrap_mode = .none });
        clay.UI()(.{
            .id = clay.ElementId.ID("fx_filter_box"),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(28) }, .padding = .{ .left = 6, .right = 6 }, .child_alignment = .{ .y = .center } },
            .clip = .{ .horizontal = true },
            .background_color = theme.overlay,
            .border = .{ .width = .all(1), .color = if (state.filter_active) theme.border_focus else theme.border },
            .corner_radius = .all(3),
        })({
            const shown = if (state.filter_active)
                std.fmt.allocPrint(arena, "{s}|", .{state.filter.text()}) catch state.filter.text()
            else
                state.filter.text();
            clay.text(shown, .{ .font_size = 18, .color = theme.text, .wrap_mode = .none });
        });
    });
}

/// Name auf `max_width` kürzen („…“ am Ende), wenn er nicht in die Sidebar passt.
fn ellipsize(arena: std.mem.Allocator, name: []const u8, font_size: f32, max_width: f32) []const u8 {
    if (max_width <= 0) return name;
    if (ui.measureTextWidth(name, font_size) <= max_width) return name;
    const ell_w = ui.measureTextWidth("…", font_size);
    var end: usize = 0;
    var last_fit: usize = 0;
    while (end < name.len) {
        var next = end + 1;
        while (next < name.len and (name[next] & 0xC0) == 0x80) next += 1;
        if (ui.measureTextWidth(name[0..next], font_size) + ell_w > max_width) break;
        last_fit = next;
        end = next;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{name[0..last_fit]}) catch name;
}

/// Kontextmenü (`context_menu_items`, IDs `fx_menu_<command>`) im gemeinsamen Stil.
fn renderContextMenu(menu: ContextMenu, theme: Theme) void {
    _ = ctx_menu.render("fx_menu", &context_menu_items, menu.x, menu.y, ctx_menu.none, ctx_menu.Colors.fromTheme(theme));
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
    mouse: MouseState,
) void {
    const node = state.nodes.items[entry.node_index];
    const is_selected = state.isNodeSelected(entry.node_index);
    const is_cursor = state.selected_index == index;
    const is_cut = state.isCut(node.path);
    const is_hidden = node.name.len > 0 and node.name[0] == '.';
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
            state.last_click_ms = state.now_ms;
            state.last_click_index = index;
            // Ziehen beginnt hier (Root nie); ob es ein Klick bleibt, entscheidet die Bewegung
            if (entry.node_index != 0) state.drag = .{ .node = entry.node_index, .start_x = mouse.x, .start_y = mouse.y };
        }
    }
    if (is_hovered) {
        if (state.hover_index != index) {
            state.hover_index = index;
            state.hover_since_ms = state.now_ms;
        }
    }
    const drag_source = if (state.drag) |d| (d.node == entry.node_index and d.moved) else false;
    const drop_target = if (state.drag) |d| (d.moved and d.over == entry.node_index) else false;

    const is_ignored = state.isIgnored(node.path);
    const fg: clay.Color = if (is_selected) theme.text_on_primary else if (is_cut or is_hidden or is_ignored) theme.muted else theme.text;
    const bg: clay.Color = if (is_selected)
        theme.primary
    else if (drop_target)
        .{ theme.accent[0], theme.accent[1], theme.accent[2], 90.0 }
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
        // Cursor ohne Markierung (nach Ctrl+Klick-Abwahl) bleibt als Rahmen sichtbar; gezogener Eintrag in Akzent
        .border = .{ .width = .all(1), .color = if (drag_source) theme.accent else if (is_cursor and !is_selected) theme.border_focus else .{ 0, 0, 0, 0 } },
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

        // Git-Status Indikator (vorne); Ordner erben den Status ihrer Nachfahren
        const git_code: ?u8 = state.git_status.get(node.path) orelse (if (node.is_folder) state.folderStatus(node.path) else null);
        if (git_code) |code| if (code != 'I') {
            const git_color: [4]f32 = switch (code) {
                'A' => theme.success,
                'M' => theme.warning,
                'C' => theme.danger,
                '?' => theme.muted,
                'S' => theme.muted,
                else => theme.muted,
            };
            // Kein `&.{code}`: das wäre ein Zeiger auf ein Stack-Temporary, das beim
            // Zeichnen (nach dem Layout) längst überschrieben ist.
            const code_str: []const u8 = switch (code) {
                'A' => "A",
                'M' => "M",
                'C' => "C",
                'D' => "D",
                'R' => "R",
                'U' => "U",
                '?' => "?",
                'S' => "S",
                else => "•",
            };
            clay.text(code_str, .{
                .font_size = 20,
                .color = if (is_selected) theme.text_on_primary else git_color,
            });
            clay.text(" ", .{
                .font_size = 20,
                .color = fg,
            });
        };

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
            // Verfügbare Breite: Sidebar minus Einrückung, Chevron, Icon, Git-Marker, Abstände, Scrollbar
            const used = indent + 24 + 24 + 4 * 3 + 8 + state.scrollbar_width + (if (git_code != null) @as(f32, 30) else 0);
            const shown = ellipsize(arena, node.name, 24, state.viewport_width - used);
            clay.text(shown, .{
                .font_size = 24,
                .color = fg,
                .wrap_mode = .none,
            });
        }
    });

    // Tooltip mit vollem Pfad nach 700 ms über derselben Zeile
    if (state.hover_index == index and state.drag == null and (state.now_ms - state.hover_since_ms) > 700) {
        clay.UI()(.{
            .id = clay.ElementId.ID("fx_tooltip"),
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = element_id.id,
                .attach_points = .{ .element = .left_top, .parent = .left_bottom },
                .offset = .{ .x = 24, .y = 2 },
                .z_index = 1500,
            },
            .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 } },
            .background_color = theme.overlay,
            .border = .{ .width = .all(1), .color = theme.border },
            .corner_radius = .all(3),
        })({
            clay.text(node.path, .{ .font_size = 16, .color = theme.text, .wrap_mode = .none });
        });
    }
}

/// Datei-Icon basierend auf Extension
fn fileIcon(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    const svg = @import("components/svg.zig");
    const L = svg.Lucide;
    const Row = struct { []const u8, []const u8 };
    const table = [_]Row{
        .{ ".zig", L.zap },          .{ ".md", L.file_text },     .{ ".txt", L.file_text },   .{ ".rst", L.file_text },
        .{ ".json", L.braces },      .{ ".json5", L.braces },     .{ ".toml", L.settings },   .{ ".yaml", L.settings },
        .{ ".yml", L.settings },     .{ ".ini", L.settings },     .{ ".conf", L.settings },   .{ ".cfg", L.settings },
        .{ ".svg", L.palette },      .{ ".png", L.image },        .{ ".jpg", L.image },       .{ ".jpeg", L.image },
        .{ ".gif", L.image },        .{ ".bmp", L.image },        .{ ".webp", L.image },      .{ ".ico", L.image },
        .{ ".pdf", L.book_open },    .{ ".log", L.clipboard },    .{ ".sh", L.terminal },     .{ ".bash", L.terminal },
        .{ ".zsh", L.terminal },     .{ ".fish", L.terminal },    .{ ".ps1", L.terminal },    .{ ".sql", L.database },
        .{ ".db", L.database },      .{ ".sqlite", L.database },  .{ ".lock", L.lock },       .{ ".zip", L.archive },
        .{ ".tar", L.archive },      .{ ".gz", L.archive },       .{ ".xz", L.archive },      .{ ".7z", L.archive },
        .{ ".rar", L.archive },      .{ ".gguf", L.binary },      .{ ".bin", L.binary },      .{ ".wasm", L.binary },
        .{ ".so", L.binary },        .{ ".o", L.binary },         .{ ".a", L.binary },        .{ ".ppm", L.image },
        .{ ".py", L.file_code },     .{ ".js", L.file_code },     .{ ".ts", L.file_code },    .{ ".tsx", L.file_code },
        .{ ".jsx", L.file_code },    .{ ".rs", L.file_code },     .{ ".go", L.file_code },    .{ ".c", L.file_code },
        .{ ".h", L.file_code },      .{ ".cpp", L.file_code },    .{ ".hpp", L.file_code },   .{ ".java", L.file_code },
        .{ ".kt", L.file_code },     .{ ".rb", L.file_code },     .{ ".lua", L.file_code },   .{ ".html", L.file_code },
        .{ ".css", L.file_code },    .{ ".xml", L.file_code },    .{ ".glsl", L.file_code },  .{ ".wgsl", L.file_code },
        .{ ".zon", L.package },      .{ ".nix", L.package },      .{ ".cbor", L.binary },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    const base = std.fs.path.basename(filename);
    if (std.ascii.eqlIgnoreCase(base, "Makefile") or std.ascii.eqlIgnoreCase(base, "Dockerfile")) return L.file_cog;
    return L.file;
}
