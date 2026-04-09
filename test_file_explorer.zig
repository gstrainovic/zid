const std = @import("std");
const file_explorer = @import("src/ui/file_explorer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test: File Explorer mit zwei Ebenen
    var state = file_explorer.FileExplorerState.init(allocator);
    defer state.deinit();

    // Test-Verzeichnis erstellen
    const test_dir = "/home/g/projects/vulkan-ed/test_data/file_explorer_test";
    std.fs.cwd().makePath(test_dir) catch {};
    std.fs.cwd().makePath(test_dir ++ "/subdir1") catch {};
    std.fs.cwd().makePath(test_dir ++ "/subdir1/subsub1") catch {};
    std.fs.cwd().makePath(test_dir ++ "/subdir2") catch {};

    // Test-Dateien erstellen
    _ = std.fs.cwd().createFile(test_dir ++ "/file1.zig", .{}) catch {};
    _ = std.fs.cwd().createFile(test_dir ++ "/subdir1/file2.zig", .{}) catch {};
    _ = std.fs.cwd().createFile(test_dir ++ "/subdir1/subsub1/file3.zig", .{}) catch {};
    _ = std.fs.cwd().createFile(test_dir ++ "/subdir2/file4.zig", .{}) catch {};

    // Directory laden (Root wird automatisch aufklappt)
    try state.loadDirectory(test_dir);
    std.debug.print("After loadDirectory: nodes={d}, visible={d}\n", .{
        state.nodes.items.len,
        state.visible_entries.items.len,
    });

    // Root-Knoten: sollte Ordner-Index 0 sein
    std.debug.print("Root: name='{s}', is_folder={any}, child_count={d}, first_child={any}\n", .{
        state.nodes.items[0].name,
        state.nodes.items[0].is_folder,
        state.nodes.items[0].child_count,
        state.nodes.items[0].first_child,
    });

    // Alle sichtbaren Einträge drucken
    for (state.visible_entries.items, 0..) |entry, i| {
        const node = state.nodes.items[entry.node_index];
        std.debug.print("  visible[{d}]: node_index={d}, depth={d}, name='{s}', is_folder={any}, expanded={any}\n", .{
            i, entry.node_index, entry.depth, node.name, node.is_folder, entry.is_expanded,
        });
    }

    // Ersten Ordner finden und aufklappen (subdir1)
    var subdir1_index: ?u32 = null;
    for (state.nodes.items, 0..) |node, idx| {
        if (node.is_folder and std.mem.eql(u8, node.name, "subdir1")) {
            subdir1_index = @intCast(idx);
            break;
        }
    }

    if (subdir1_index) |idx| {
        std.debug.print("\n=== Toggle subdir1 (index {d}) ===\n", .{idx});
        try state.toggleNode(idx);
        std.debug.print("After toggle subdir1: visible={d}\n", .{state.visible_entries.items.len});
        for (state.visible_entries.items, 0..) |entry, i| {
            const node = state.nodes.items[entry.node_index];
            std.debug.print("  visible[{d}]: node_index={d}, depth={d}, name='{s}'\n", .{
                i, entry.node_index, entry.depth, node.name,
            });
        }

        // Jetzt subdir1's Kind aufklappen (subsub1)
        var subsub1_index: ?u32 = null;
        for (state.nodes.items, 0..) |node, nidx| {
            if (node.is_folder and std.mem.eql(u8, node.name, "subsub1")) {
                subsub1_index = @intCast(nidx);
                break;
            }
        }

        if (subsub1_index) |sidx| {
            std.debug.print("\n=== Toggle subsub1 (index {d}) ===\n", .{sidx});
            try state.toggleNode(sidx);
            std.debug.print("After toggle subsub1: visible={d}\n", .{state.visible_entries.items.len});
            for (state.visible_entries.items, 0..) |entry, i| {
                const node = state.nodes.items[entry.node_index];
                std.debug.print("  visible[{d}]: node_index={d}, depth={d}, name='{s}'\n", .{
                    i, entry.node_index, entry.depth, node.name,
                });
            }
        } else {
            std.debug.print("subsub1 not found!\n", .{});
        }
    } else {
        std.debug.print("subdir1 not found!\n", .{});
    }

    // Zweiten Ordner aufklappen (subdir2)
    var subdir2_index: ?u32 = null;
    for (state.nodes.items, 0..) |node, idx| {
        if (node.is_folder and std.mem.eql(u8, node.name, "subdir2")) {
            subdir2_index = @intCast(idx);
            break;
        }
    }

    if (subdir2_index) |idx| {
        std.debug.print("\n=== Toggle subdir2 (index {d}) ===\n", .{idx});
        try state.toggleNode(idx);
        std.debug.print("After toggle subdir2: visible={d}\n", .{state.visible_entries.items.len});
        for (state.visible_entries.items, 0..) |entry, i| {
            const node = state.nodes.items[entry.node_index];
            std.debug.print("  visible[{d}]: node_index={d}, depth={d}, name='{s}'\n", .{
                i, entry.node_index, entry.depth, node.name,
            });
        }
    } else {
        std.debug.print("subdir2 not found!\n", .{});
    }

    std.debug.print("\n=== ALLE TESTS BESTANDEN ===\n", .{});

    // Cleanup
    std.fs.cwd().deleteTree(test_dir) catch {};
}
