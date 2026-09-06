//! Zentrale Tabelle aller Tastenkürzel. Einzige Quelle für die Tastenverarbeitung
//! (mod.zig), die Menüs im Header, das Editor-Kontextmenü und den Shortcut-Dialog.
//! Ohne wio-Abhängigkeit (eigene Key-Enum), damit alles unit-testbar bleibt.

const std = @import("std");


/// Tasten, die Kürzel verwenden. Spiegel der nötigen wio.Button-Werte, damit
/// diese Datei ohne wio testbar bleibt; mod.zig übersetzt per keyFromButton.
pub const Key = enum { a, b, c, d, f, k, n, o, p, r, s, v, w, x, y, z, tab, grave, f1, f2, f5, delete, escape, enter };

pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

/// Wo eine Bindung gilt. `editor` wird vom Editor-Keymap selbst behandelt und
/// steht hier nur für Menü- und Hilfetexte; `explorer` gilt bei markiertem Eintrag.
pub const Scope = enum { global, editor, explorer };

pub const Command = enum {
    new_file,
    save,
    open_folder,
    close_tab,
    next_tab,
    prev_tab,
    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
    delete_line,
    find,
    toggle_explorer,
    new_terminal,
    split_vertical,
    split_horizontal,
    md_preview,
    rename_entry,
    delete_entry,
    new_file_entry,
    new_folder_entry,
    cut_entry,
    copy_entry,
    paste_entry,
    duplicate_entry,
    copy_path,
    copy_relative_path,
    reveal_in_file_manager,
    open_in_terminal,
    collapse_all,
    refresh_explorer,
    select_all_entries,
    show_shortcuts,
};

pub const Binding = struct {
    command: Command,
    key: Key,
    mods: Mods = .{},
    scope: Scope = .global,
};

/// Die eine Tabelle. Editor-Bindungen müssen zu src/editor/keymap.zig passen.
pub const bindings = [_]Binding{
    .{ .command = .new_file, .key = .n, .mods = .{ .ctrl = true } },
    .{ .command = .save, .key = .s, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .open_folder, .key = .o, .mods = .{ .ctrl = true } },
    .{ .command = .close_tab, .key = .w, .mods = .{ .ctrl = true } },
    .{ .command = .next_tab, .key = .tab, .mods = .{ .ctrl = true } },
    .{ .command = .prev_tab, .key = .tab, .mods = .{ .ctrl = true, .shift = true } },
    .{ .command = .undo, .key = .z, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .redo, .key = .y, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .cut, .key = .x, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .copy, .key = .c, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .paste, .key = .v, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .select_all, .key = .a, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .delete_line, .key = .k, .mods = .{ .ctrl = true, .shift = true }, .scope = .editor },
    .{ .command = .find, .key = .f, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .toggle_explorer, .key = .b, .mods = .{ .ctrl = true } },
    .{ .command = .new_terminal, .key = .grave, .mods = .{ .ctrl = true } },
    .{ .command = .rename_entry, .key = .f2, .scope = .explorer },
    .{ .command = .delete_entry, .key = .delete, .scope = .explorer },
    // Buchstaben-Kürzel im Explorer wie nvim-tree/yazi: erste Bindung je Command liefert den Anzeige-Text
    .{ .command = .rename_entry, .key = .r, .scope = .explorer },
    .{ .command = .delete_entry, .key = .d, .scope = .explorer },
    .{ .command = .new_file_entry, .key = .a, .scope = .explorer },
    .{ .command = .new_folder_entry, .key = .a, .mods = .{ .shift = true }, .scope = .explorer },
    .{ .command = .copy_entry, .key = .y, .scope = .explorer },
    .{ .command = .cut_entry, .key = .x, .scope = .explorer },
    .{ .command = .paste_entry, .key = .p, .scope = .explorer },
    .{ .command = .duplicate_entry, .key = .d, .mods = .{ .ctrl = true }, .scope = .explorer },
    .{ .command = .copy_path, .key = .c, .scope = .explorer },
    .{ .command = .copy_relative_path, .key = .c, .mods = .{ .shift = true }, .scope = .explorer },
    .{ .command = .refresh_explorer, .key = .r, .mods = .{ .shift = true }, .scope = .explorer },
    .{ .command = .refresh_explorer, .key = .f5, .scope = .explorer },
    .{ .command = .collapse_all, .key = .w, .scope = .explorer },
    .{ .command = .select_all_entries, .key = .a, .mods = .{ .ctrl = true }, .scope = .explorer },
    .{ .command = .show_shortcuts, .key = .f1 },
};

pub const Menu = struct { title: []const u8, items: []const Command };

/// Menüleiste im Header, in dieser Reihenfolge.
pub const menus = [_]Menu{
    .{ .title = "File", .items = &.{ .new_file, .save, .open_folder, .close_tab } },
    .{ .title = "Edit", .items = &.{ .undo, .redo, .cut, .copy, .paste, .select_all, .delete_line, .find } },
    .{ .title = "View", .items = &.{ .toggle_explorer, .split_vertical, .split_horizontal, .md_preview, .new_terminal } },
    .{ .title = "Help", .items = &.{.show_shortcuts} },
};

pub fn lookup(key: Key, mods: Mods, scope: Scope) ?Command {
    for (bindings) |b| {
        if (b.scope == scope and b.key == key and std.meta.eql(b.mods, mods)) return b.command;
    }
    return null;
}

pub fn binding(command: Command) ?Binding {
    for (bindings) |b| {
        if (b.command == command) return b;
    }
    return null;
}

pub fn label(command: Command) []const u8 {
    return switch (command) {
        .new_file => "New File",
        .save => "Save",
        .open_folder => "Open Folder…",
        .close_tab => "Close Tab",
        .next_tab => "Next Tab",
        .prev_tab => "Previous Tab",
        .undo => "Undo",
        .redo => "Redo",
        .cut => "Cut",
        .copy => "Copy",
        .paste => "Paste",
        .select_all => "Select All",
        .delete_line => "Delete Line",
        .find => "Find",
        .toggle_explorer => "Toggle Explorer",
        .new_terminal => "New Terminal",
        .split_vertical => "Split Vertically",
        .split_horizontal => "Split Horizontally",
        .md_preview => "Markdown Preview",
        .rename_entry => "Rename",
        .delete_entry => "Move to Trash",
        .new_file_entry => "New File",
        .new_folder_entry => "New Folder",
        .cut_entry => "Cut",
        .copy_entry => "Copy",
        .paste_entry => "Paste",
        .duplicate_entry => "Duplicate",
        .copy_path => "Copy Path",
        .copy_relative_path => "Copy Relative Path",
        .reveal_in_file_manager => "Reveal in File Manager",
        .open_in_terminal => "Open in Terminal",
        .collapse_all => "Collapse All",
        .refresh_explorer => "Refresh",
        .select_all_entries => "Select All Entries",
        .show_shortcuts => "Keyboard Shortcuts",
    };
}

/// Anzeige-Text wie "Ctrl+Shift+Tab"; leer, wenn das Command keine Taste hat.
pub fn shortcutText(command: Command) []const u8 {
    const b = binding(command) orelse return "";
    return shortcutTextFor(b.key, b.mods);
}

pub fn shortcutTextFor(key: Key, mods: Mods) []const u8 {
    // comptime-Tabelle aller Kombinationen, damit Slices statisch sind
    inline for (bindings) |b| {
        if (b.key == key and std.meta.eql(b.mods, mods)) {
            return comptime (if (b.mods.ctrl) "Ctrl+" else "") ++ (if (b.mods.shift) "Shift+" else "") ++ (if (b.mods.alt) "Alt+" else "") ++ keyName(b.key);
        }
    }
    return "";
}

fn keyName(key: Key) []const u8 {
    return switch (key) {
        .a => "A", .b => "B", .c => "C", .d => "D", .f => "F", .k => "K", .n => "N", .o => "O",
        .p => "P", .r => "R", .s => "S", .v => "V", .w => "W", .x => "X", .y => "Y", .z => "Z",
        .tab => "Tab", .grave => "`", .f1 => "F1", .f2 => "F2", .f5 => "F5", .delete => "Del",
        .escape => "Esc", .enter => "Enter",
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "lookup: Ctrl+O global ist open_folder, ohne Ctrl nichts" {
    try testing.expectEqual(Command.open_folder, lookup(.o, .{ .ctrl = true }, .global).?);
    try testing.expect(lookup(.o, .{}, .global) == null);
}

test "lookup: Modifier müssen exakt passen (Ctrl+Shift+Tab ist nicht Ctrl+Tab)" {
    try testing.expectEqual(Command.next_tab, lookup(.tab, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.prev_tab, lookup(.tab, .{ .ctrl = true, .shift = true }, .global).?);
    try testing.expect(lookup(.tab, .{ .ctrl = true, .alt = true }, .global) == null);
}

test "lookup: Scope trennt Explorer-Tasten von globalen" {
    try testing.expectEqual(Command.rename_entry, lookup(.f2, .{}, .explorer).?);
    try testing.expectEqual(Command.delete_entry, lookup(.delete, .{}, .explorer).?);
    try testing.expect(lookup(.f2, .{}, .global) == null);
    try testing.expect(lookup(.delete, .{}, .global) == null);
}

test "shortcutText: Anzeige-Text pro Command, leer wenn ohne Taste" {
    try testing.expectEqualStrings("Ctrl+O", shortcutText(.open_folder));
    try testing.expectEqualStrings("Ctrl+Shift+Tab", shortcutText(.prev_tab));
    try testing.expectEqualStrings("Ctrl+`", shortcutText(.new_terminal));
    try testing.expectEqualStrings("F2", shortcutText(.rename_entry));
    try testing.expectEqualStrings("Del", shortcutText(.delete_entry));
    try testing.expectEqualStrings("", shortcutText(.split_vertical));
}

test "Explorer-Buchstaben: d löscht, r benennt um, a legt an, Shift+A Ordner, y/x/p Zwischenablage" {
    try testing.expectEqual(Command.delete_entry, lookup(.d, .{}, .explorer).?);
    try testing.expectEqual(Command.rename_entry, lookup(.r, .{}, .explorer).?);
    try testing.expectEqual(Command.new_file_entry, lookup(.a, .{}, .explorer).?);
    try testing.expectEqual(Command.new_folder_entry, lookup(.a, .{ .shift = true }, .explorer).?);
    try testing.expectEqual(Command.copy_entry, lookup(.y, .{}, .explorer).?);
    try testing.expectEqual(Command.cut_entry, lookup(.x, .{}, .explorer).?);
    try testing.expectEqual(Command.paste_entry, lookup(.p, .{}, .explorer).?);
    try testing.expectEqual(Command.copy_path, lookup(.c, .{}, .explorer).?);
    try testing.expectEqual(Command.refresh_explorer, lookup(.r, .{ .shift = true }, .explorer).?);
    try testing.expectEqual(Command.select_all_entries, lookup(.a, .{ .ctrl = true }, .explorer).?);
    // Ohne Explorer-Fokus bleiben Buchstaben Text
    try testing.expect(lookup(.d, .{}, .global) == null);
    // Anzeige-Text zeigt die erste Bindung (F2/Del), der Buchstabe steht zusätzlich in der Tabelle
    try testing.expectEqualStrings("F2", shortcutText(.rename_entry));
    try testing.expectEqualStrings("A", shortcutText(.new_file_entry));
    try testing.expectEqualStrings("Shift+A", shortcutText(.new_folder_entry));
}

test "Tabelle: keine doppelte Belegung innerhalb eines Scopes" {
    for (bindings, 0..) |a, i| {
        for (bindings[i + 1 ..]) |b| {
            const same = a.key == b.key and std.meta.eql(a.mods, b.mods) and a.scope == b.scope;
            if (same) {
                std.debug.print("doppelt: {s} und {s}\n", .{ @tagName(a.command), @tagName(b.command) });
                return error.DuplicateBinding;
            }
        }
    }
}

test "menus: jeder Menüeintrag hat ein Label" {
    for (menus) |menu| {
        try testing.expect(menu.title.len > 0);
        for (menu.items) |cmd| try testing.expect(label(cmd).len > 0);
    }
}
