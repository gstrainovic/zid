//! File Explorer Sidebar für vulkan-ed
//!
//! Zeigt Verzeichnisbaum an (Tree-Widget).
//! Von Gooey's tree_list.zig adaptiert für Clay + wgpu.

const std = @import("std");
const clay = @import("clay");
const ui = @import("../ui/mod.zig");
const Theme = ui.Theme;

const log = std.log.scoped(.file_explorer);

/// Maximaltiefe des Baums
const MAX_TREE_DEPTH = 32;
/// Standard-Einrückung pro Ebene in Pixeln
const DEFAULT_INDENT_PX = 16.0;

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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .nodes = std.ArrayList(TreeNode).empty,
            .visible_entries = std.ArrayList(TreeEntry).empty,
            .expanded_nodes = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes.items) |*node| {
            self.allocator.free(node.name);
            self.allocator.free(node.path);
        }
        self.nodes.deinit(self.allocator);
        self.visible_entries.deinit(self.allocator);
        self.expanded_nodes.deinit();
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
    // Sidebar Container
    clay.UI()(.{
        .id = clay.ElementId.ID("file_explorer"),
        .layout = .{
            .sizing = .{ .w = .fixed(300), .h = .grow },
            .direction = .top_to_bottom,
            .child_gap = 0,
        },
        .background_color = theme.surface,
        .border = .{ .width = .{ .right = 1 }, .color = theme.border },
    })({
        // Tree Content
        clay.UI()(.{
            .id = clay.ElementId.ID("file_tree_content"),
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .child_gap = 0,
            },
            .background_color = theme.surface,
        })({
            for (state.visible_entries.items, 0..) |entry, i| {
                renderTreeEntry(arena, state, entry, i, theme, mouse_pressed);
            }
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
) void {
    const node = state.nodes.items[entry.node_index];
    const is_selected = state.selected_index == index;
    const indent = @as(f32, @floatFromInt(entry.depth)) * DEFAULT_INDENT_PX + 8.0;

    const entry_id_str = std.fmt.allocPrint(arena, "tree_entry_{d}", .{index}) catch return;
    const element_id = clay.ElementId.ID(entry_id_str);
    const is_hovered = clay.pointerOver(element_id);

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
            .sizing = .{ .w = .grow, .h = .fixed(36) },
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

        // Dateiname
        clay.text(node.name, .{
            .font_size = 24,
            .color = if (is_selected) theme.text_on_primary else theme.text,
        });
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
    if (std.mem.eql(u8, ext, ".log")) return svg.Lucide.clipboard;
    return svg.Lucide.file;
}
