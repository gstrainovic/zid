//! Zentrale Tabelle aller Tastenkürzel. Einzige Quelle für die Tastenverarbeitung
//! (mod.zig), die Menüs im Header, das Editor-Kontextmenü und den Shortcut-Dialog.
//! Ohne wio-Abhängigkeit (eigene Key-Enum), damit alles unit-testbar bleibt.

const std = @import("std");


/// Tasten, die Kürzel verwenden. Spiegel der nötigen wio.Button-Werte, damit
/// diese Datei ohne wio testbar bleibt; mod.zig übersetzt per keyFromButton.
pub const Key = enum { a, b, c, f, k, n, o, s, v, w, x, y, z, tab, grave, f1, f2, delete, escape, enter };

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
        .delete_entry => "Delete",
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
        .a => "A", .b => "B", .c => "C", .f => "F", .k => "K", .n => "N", .o => "O",
        .s => "S", .v => "V", .w => "W", .x => "X", .y => "Y", .z => "Z",
        .tab => "Tab", .grave => "`", .f1 => "F1", .f2 => "F2", .delete => "Del",
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
