//! Zentrale Tabelle aller Tastenkürzel. Einzige Quelle für die Tastenverarbeitung
//! (mod.zig), die Menüs im Header, das Editor-Kontextmenü und den Shortcut-Dialog.
//! Ohne wio-Abhängigkeit (eigene Key-Enum), damit alles unit-testbar bleibt.

const std = @import("std");


/// Tasten, die Kürzel verwenden. Spiegel der nötigen wio.Button-Werte, damit
/// diese Datei ohne wio testbar bleibt; mod.zig übersetzt per keyFromButton.
pub const Key = enum {
    a, b, c, d, e, f, g, h, j, k, n, o, p, r, s, t, v, w, x, y, z,
    n0, n1, n2, n3, n4, n5, n6, n7, n8, n9, equals, minus,
    kp_0, kp_plus, kp_minus,
    tab, grave, backslash, slash, dot, f1, f2, f5, f12, delete, escape, enter, page_up, page_down, left, right, up, down,
};

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
    /// Ctrl+Tab: Tabs in „zuletzt benutzt“-Reihenfolge (Umschalter bleibt offen, solange Ctrl gehalten wird)
    recent_tab_next,
    recent_tab_prev,
    /// Picker über die offenen Tabs
    open_tab_picker,
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
    md_export_pdf,
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
    toggle_hidden_files,
    filter_explorer,
    // Tab-Leiste
    close_other_tabs,
    close_tabs_right,
    close_all_tabs,
    close_saved_tabs,
    copy_tab_path,
    reveal_in_explorer,
    pin_tab,
    reopen_closed_tab,
    goto_tab_1,
    goto_tab_2,
    goto_tab_3,
    goto_tab_4,
    goto_tab_5,
    goto_tab_6,
    goto_tab_7,
    goto_tab_8,
    goto_tab_9,
    // Editor (Keymap in src/editor/keymap.zig)
    toggle_comment,
    move_line_up,
    move_line_down,
    duplicate_line,
    goto_line,
    replace,
    outdent_lines,
    goto_definition,
    select_next_occurrence,
    add_cursor_above,
    add_cursor_below,
    // Panes / Fokus
    focus_pane_left,
    focus_pane_right,
    focus_pane_up,
    focus_pane_down,
    focus_explorer,
    toggle_terminal,
    quick_open,
    command_palette,
    toggle_theme,
    zoom_in,
    zoom_out,
    zoom_reset,
    toggle_autosave,
    toggle_minimap,
    toggle_whitespace,
    toggle_indent_guides,
    toggle_word_wrap,
    /// Verlauf des Repos (Tab `git-history://repo:…`)
    git_history,
    /// Verlauf der Datei des Tabs bzw. Editors; `_entry` für den markierten Explorer-Eintrag
    file_history,
    file_history_entry,
    show_shortcuts,
    /// Terminal-Kontextmenü: Auswahl kopieren / Zwischenablage einfügen (ohne Kürzel)
    terminal_copy,
    terminal_paste,
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
    .{ .command = .save, .key = .s, .mods = .{ .ctrl = true } }, // global: auch mit Fokus im Explorer
    .{ .command = .open_folder, .key = .o, .mods = .{ .ctrl = true } },
    .{ .command = .close_tab, .key = .w, .mods = .{ .ctrl = true } },
    .{ .command = .recent_tab_next, .key = .tab, .mods = .{ .ctrl = true } },
    .{ .command = .recent_tab_prev, .key = .tab, .mods = .{ .ctrl = true, .shift = true } },
    .{ .command = .open_tab_picker, .key = .e, .mods = .{ .ctrl = true } },
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
    .{ .command = .toggle_hidden_files, .key = .dot, .scope = .explorer },
    .{ .command = .filter_explorer, .key = .slash, .scope = .explorer },
    // Tab-Leiste
    .{ .command = .reopen_closed_tab, .key = .t, .mods = .{ .ctrl = true, .shift = true } },
    .{ .command = .next_tab, .key = .page_down, .mods = .{ .ctrl = true } },
    .{ .command = .prev_tab, .key = .page_up, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_1, .key = .n1, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_2, .key = .n2, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_3, .key = .n3, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_4, .key = .n4, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_5, .key = .n5, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_6, .key = .n6, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_7, .key = .n7, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_8, .key = .n8, .mods = .{ .ctrl = true } },
    .{ .command = .goto_tab_9, .key = .n9, .mods = .{ .ctrl = true } },
    // Editor-Bearbeitung
    .{ .command = .toggle_comment, .key = .slash, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .toggle_word_wrap, .key = .z, .mods = .{ .alt = true } },
    .{ .command = .move_line_up, .key = .up, .mods = .{ .alt = true }, .scope = .editor },
    .{ .command = .move_line_down, .key = .down, .mods = .{ .alt = true }, .scope = .editor },
    .{ .command = .duplicate_line, .key = .d, .mods = .{ .ctrl = true, .shift = true }, .scope = .editor },
    .{ .command = .goto_line, .key = .g, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .replace, .key = .h, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .outdent_lines, .key = .tab, .mods = .{ .shift = true }, .scope = .editor },
    .{ .command = .goto_definition, .key = .f12, .scope = .editor },
    .{ .command = .select_next_occurrence, .key = .d, .mods = .{ .ctrl = true }, .scope = .editor },
    .{ .command = .add_cursor_above, .key = .up, .mods = .{ .ctrl = true, .alt = true }, .scope = .editor },
    .{ .command = .add_cursor_below, .key = .down, .mods = .{ .ctrl = true, .alt = true }, .scope = .editor },
    // Panes / Fokus (Ctrl+K + Pfeil geht zusätzlich als Chord, siehe UI.handleKeyPress)
    .{ .command = .split_vertical, .key = .backslash, .mods = .{ .ctrl = true } },
    .{ .command = .focus_pane_left, .key = .left, .mods = .{ .ctrl = true, .alt = true } },
    .{ .command = .focus_pane_right, .key = .right, .mods = .{ .ctrl = true, .alt = true } },
    .{ .command = .focus_explorer, .key = .e, .mods = .{ .ctrl = true, .shift = true } },
    .{ .command = .toggle_terminal, .key = .j, .mods = .{ .ctrl = true } },
    .{ .command = .quick_open, .key = .p, .mods = .{ .ctrl = true } },
    .{ .command = .command_palette, .key = .p, .mods = .{ .ctrl = true, .shift = true } },
    .{ .command = .zoom_in, .key = .equals, .mods = .{ .ctrl = true } },
    .{ .command = .zoom_out, .key = .minus, .mods = .{ .ctrl = true } },
    .{ .command = .zoom_reset, .key = .n0, .mods = .{ .ctrl = true } },
    // Zweitbelegungen: Ziffernblock und Ctrl+Shift+= (auf US-Layout liegt "+" auf Shift+=).
    .{ .command = .zoom_in, .key = .equals, .mods = .{ .ctrl = true, .shift = true } },
    .{ .command = .zoom_in, .key = .kp_plus, .mods = .{ .ctrl = true } },
    .{ .command = .zoom_out, .key = .kp_minus, .mods = .{ .ctrl = true } },
    .{ .command = .zoom_reset, .key = .kp_0, .mods = .{ .ctrl = true } },
    .{ .command = .show_shortcuts, .key = .f1 },
};

/// Kontextmenü eines Tabs (Rechtsklick auf den Tab-Kopf), in dieser Reihenfolge.
/// `md_preview` und `md_export_pdf` blendet die UI bei Nicht-Markdown-Tabs aus.
pub const tab_menu_items = [_]Command{
    .close_tab,      .close_other_tabs,  .close_tabs_right,  .close_all_tabs, .close_saved_tabs,
    .pin_tab,        .copy_tab_path,     .reveal_in_explorer, .md_preview,    .md_export_pdf,
    .file_history,   .split_vertical,    .split_horizontal,
};

/// Kontextmenü im Editor-Text (`md_preview` nur bei .md, im Chat-Eingabefeld nur Cut/Copy/Paste)
pub const editor_menu_items = [_]Command{ .cut, .copy, .paste, .md_preview, .md_export_pdf, .file_history, .split_vertical, .split_horizontal };

/// Kontextmenü eines Explorer-Eintrags, in dieser Reihenfolge
pub const explorer_menu_items = [_]Command{
    .new_file_entry, .new_folder_entry,    .rename_entry,           .delete_entry,
    .cut_entry,      .copy_entry,          .paste_entry,            .duplicate_entry,
    .copy_path,      .copy_relative_path,  .reveal_in_file_manager, .open_in_terminal,
    .file_history_entry, .collapse_all,    .toggle_hidden_files,    .filter_explorer,
};

/// Kontextmenü der Markdown-Vorschau
pub const markdown_menu_items = [_]Command{ .md_export_pdf, .split_vertical, .split_horizontal };

/// Kontextmenü des Terminals (eigene Commands: Ctrl+C/V gehen dort an die Shell)
pub const terminal_menu_items = [_]Command{ .terminal_copy, .terminal_paste };

pub const Menu = struct { title: []const u8, items: []const Command };

/// Menüleiste im Header, in dieser Reihenfolge.
pub const menus = [_]Menu{
    .{ .title = "File", .items = &.{ .new_file, .quick_open, .save, .toggle_autosave, .open_folder, .close_tab, .close_all_tabs, .reopen_closed_tab } },
    .{ .title = "Edit", .items = &.{ .undo, .redo, .cut, .copy, .paste, .select_all, .delete_line, .duplicate_line, .move_line_up, .move_line_down, .toggle_comment, .find, .replace, .goto_line, .goto_definition, .select_next_occurrence, .add_cursor_above, .add_cursor_below } },
    .{ .title = "View", .items = &.{ .toggle_explorer, .focus_explorer, .split_vertical, .split_horizontal, .md_preview, .md_export_pdf, .new_terminal, .toggle_terminal, .toggle_theme, .zoom_in, .zoom_out, .zoom_reset, .toggle_minimap, .toggle_whitespace, .toggle_indent_guides, .toggle_word_wrap, .git_history } },
    .{ .title = "Help", .items = &.{ .command_palette, .show_shortcuts } },
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
        .recent_tab_next => "Switch to Recent Tab",
        .recent_tab_prev => "Switch to Recent Tab (Backwards)",
        .open_tab_picker => "Open Tabs…",
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
        .md_export_pdf => "Export to PDF",
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
        .toggle_hidden_files => "Toggle Hidden Files",
        .filter_explorer => "Filter…",
        .close_other_tabs => "Close Others",
        .close_tabs_right => "Close to the Right",
        .close_all_tabs => "Close All",
        .close_saved_tabs => "Close Saved",
        .copy_tab_path => "Copy Path",
        .reveal_in_explorer => "Reveal in Explorer",
        .pin_tab => "Pin / Unpin",
        .reopen_closed_tab => "Reopen Closed Tab",
        .goto_tab_1 => "Go to Tab 1",
        .goto_tab_2 => "Go to Tab 2",
        .goto_tab_3 => "Go to Tab 3",
        .goto_tab_4 => "Go to Tab 4",
        .goto_tab_5 => "Go to Tab 5",
        .goto_tab_6 => "Go to Tab 6",
        .goto_tab_7 => "Go to Tab 7",
        .goto_tab_8 => "Go to Tab 8",
        .goto_tab_9 => "Go to Tab 9",
        .toggle_comment => "Toggle Line Comment",
        .move_line_up => "Move Line Up",
        .move_line_down => "Move Line Down",
        .duplicate_line => "Duplicate Line",
        .goto_line => "Go to Line…",
        .replace => "Replace",
        .outdent_lines => "Outdent Lines",
        .goto_definition => "Go to Definition",
        .select_next_occurrence => "Add Next Occurrence to Selection",
        .add_cursor_above => "Add Cursor Above",
        .add_cursor_below => "Add Cursor Below",
        .focus_pane_left => "Focus Pane Left",
        .focus_pane_right => "Focus Pane Right",
        .focus_pane_up => "Focus Pane Up",
        .focus_pane_down => "Focus Pane Down",
        .focus_explorer => "Focus Explorer",
        .toggle_terminal => "Toggle Terminal",
        .quick_open => "Go to File…",
        .command_palette => "Command Palette…",
        .toggle_theme => "Toggle Light/Dark Theme",
        .zoom_in => "Zoom In",
        .zoom_out => "Zoom Out",
        .zoom_reset => "Reset Zoom",
        .toggle_autosave => "Toggle Autosave",
        .toggle_minimap => "Toggle Minimap",
        .toggle_whitespace => "Toggle Render Whitespace",
        .toggle_word_wrap => "Toggle Word Wrap",
        .toggle_indent_guides => "Toggle Indent Guides",
        .git_history => "Git History",
        .file_history, .file_history_entry => "File History",
        .show_shortcuts => "Keyboard Shortcuts",
        .terminal_copy => "Terminal Copy",
        .terminal_paste => "Terminal Paste",
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
        .a => "A", .b => "B", .c => "C", .d => "D", .e => "E", .f => "F", .g => "G", .h => "H", .j => "J",
        .k => "K", .n => "N", .o => "O", .p => "P", .r => "R", .s => "S", .t => "T", .v => "V", .w => "W",
        .x => "X", .y => "Y", .z => "Z",
        .n0 => "0", .equals => "=", .minus => "-", .n1 => "1", .n2 => "2", .n3 => "3", .n4 => "4", .n5 => "5", .n6 => "6", .n7 => "7", .n8 => "8", .n9 => "9",
        .kp_0 => "Num0", .kp_plus => "Num+", .kp_minus => "Num-",
        .tab => "Tab", .grave => "`", .backslash => "\\", .slash => "/", .dot => ".", .f1 => "F1", .f2 => "F2", .f5 => "F5", .f12 => "F12", .delete => "Del",
        .escape => "Esc", .enter => "Enter", .page_up => "PgUp", .page_down => "PgDn",
        .left => "←", .right => "→", .up => "↑", .down => "↓",
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "lookup: Zoom auch über Ziffernblock und Shift+= (US-Layout)" {
    try testing.expectEqual(Command.zoom_in, lookup(.kp_plus, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.zoom_out, lookup(.kp_minus, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.zoom_reset, lookup(.kp_0, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.zoom_in, lookup(.equals, .{ .ctrl = true, .shift = true }, .global).?);
}

test "shortcutText: Zoom zeigt weiterhin die Haupttastatur-Variante" {
    try testing.expectEqualStrings("Ctrl+=", shortcutText(.zoom_in));
    try testing.expectEqualStrings("Ctrl+-", shortcutText(.zoom_out));
}

test "lookup: Ctrl+O global ist open_folder, ohne Ctrl nichts" {
    try testing.expectEqual(Command.open_folder, lookup(.o, .{ .ctrl = true }, .global).?);
    try testing.expect(lookup(.o, .{}, .global) == null);
}

test "lookup: Modifier müssen exakt passen (Ctrl+Shift+Tab ist nicht Ctrl+Tab)" {
    try testing.expectEqual(Command.recent_tab_next, lookup(.tab, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.recent_tab_prev, lookup(.tab, .{ .ctrl = true, .shift = true }, .global).?);
    try testing.expectEqual(Command.next_tab, lookup(.page_down, .{ .ctrl = true }, .global).?);
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
    try testing.expectEqualStrings("Ctrl+PgUp", shortcutText(.prev_tab));
    try testing.expectEqualStrings("Ctrl+Shift+Tab", shortcutText(.recent_tab_prev));
    try testing.expectEqualStrings("Ctrl+`", shortcutText(.new_terminal));
    try testing.expectEqualStrings("F2", shortcutText(.rename_entry));
    try testing.expectEqualStrings("Del", shortcutText(.delete_entry));
    try testing.expectEqualStrings("Ctrl+\\", shortcutText(.split_vertical));
    try testing.expectEqualStrings("", shortcutText(.md_preview));
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

test "Tab-Kürzel: Ctrl+Shift+T, Ctrl+PgUp/PgDn, Ctrl+1..9" {
    try testing.expectEqual(Command.reopen_closed_tab, lookup(.t, .{ .ctrl = true, .shift = true }, .global).?);
    try testing.expectEqual(Command.next_tab, lookup(.page_down, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.prev_tab, lookup(.page_up, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.goto_tab_1, lookup(.n1, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.goto_tab_9, lookup(.n9, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.save, lookup(.s, .{ .ctrl = true }, .global).?);
    for (tab_menu_items) |cmd| try testing.expect(label(cmd).len > 0);
}

test "Editor- und Pane-Kürzel stehen in der Tabelle" {
    try testing.expectEqual(Command.toggle_comment, lookup(.slash, .{ .ctrl = true }, .editor).?);
    try testing.expectEqual(Command.move_line_down, lookup(.down, .{ .alt = true }, .editor).?);
    try testing.expectEqual(Command.goto_line, lookup(.g, .{ .ctrl = true }, .editor).?);
    try testing.expectEqual(Command.replace, lookup(.h, .{ .ctrl = true }, .editor).?);
    try testing.expectEqual(Command.split_vertical, lookup(.backslash, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.focus_pane_right, lookup(.right, .{ .ctrl = true, .alt = true }, .global).?);
    try testing.expectEqual(Command.focus_explorer, lookup(.e, .{ .ctrl = true, .shift = true }, .global).?);
    try testing.expectEqual(Command.toggle_terminal, lookup(.j, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.quick_open, lookup(.p, .{ .ctrl = true }, .global).?);
    try testing.expectEqual(Command.command_palette, lookup(.p, .{ .ctrl = true, .shift = true }, .global).?);
    try testing.expectEqualStrings("Ctrl+/", shortcutText(.toggle_comment));
    try testing.expectEqualStrings("Alt+↑", shortcutText(.move_line_up));
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

test "Git History: Repo im View-Menü, Datei-History in Tab-, Editor- und Explorer-Menü" {
    const view = for (menus) |m| {
        if (std.mem.eql(u8, m.title, "View")) break m;
    } else unreachable;
    try testing.expect(std.mem.indexOfScalar(Command, view.items, .git_history) != null);
    try testing.expect(std.mem.indexOfScalar(Command, &tab_menu_items, .file_history) != null);
    try testing.expect(std.mem.indexOfScalar(Command, &editor_menu_items, .file_history) != null);
    try testing.expect(std.mem.indexOfScalar(Command, &explorer_menu_items, .file_history_entry) != null);
    try testing.expectEqualStrings("Git History", label(.git_history));
    try testing.expectEqualStrings("File History", label(.file_history));
    try testing.expectEqualStrings("File History", label(.file_history_entry));
}

test "Kontextmenüs: Tab-Kopf hat Markdown Preview, jede Liste hat Labels, Terminal ohne Ctrl+C" {
    try testing.expect(std.mem.indexOfScalar(Command, &tab_menu_items, .md_preview) != null);
    for (tab_menu_items) |cmd| try testing.expect(label(cmd).len > 0);
    for (editor_menu_items) |cmd| try testing.expect(label(cmd).len > 0);
    for (markdown_menu_items) |cmd| try testing.expect(label(cmd).len > 0);
    for (terminal_menu_items) |cmd| try testing.expect(label(cmd).len > 0);
    // Im Terminal ist Ctrl+C kein Kopieren: eigene Commands ohne Kürzel
    try testing.expectEqualStrings("", shortcutText(.terminal_copy));
    try testing.expectEqualStrings("", shortcutText(.terminal_paste));
    try testing.expectEqual(Command.md_preview, editor_menu_items[3]);
}
