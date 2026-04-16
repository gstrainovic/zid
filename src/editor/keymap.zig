const std = @import("std");
const wio = @import("wio");
const actions = @import("actions.zig");
const Action = actions.Action;
const Mods = actions.Mods;
const KeyEvent = actions.KeyEvent;

pub const Keymap = struct {
    map: std.AutoHashMap(KeyEvent, Action),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Keymap {
        return .{
            .map = std.AutoHashMap(KeyEvent, Action).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Keymap) void {
        self.map.deinit();
    }

    pub fn bind(self: *Keymap, key: wio.Button, mods: Mods, action: Action) !void {
        try self.map.put(.{ .key = key, .mods = mods }, action);
    }

    pub fn lookup(self: Keymap, key: wio.Button, mods: Mods) ?Action {
        return self.map.get(.{ .key = key, .mods = mods });
    }

    pub fn initDefault(allocator: std.mem.Allocator) !Keymap {
        var km = Keymap.init(allocator);

        // Arrows - Movement
        try km.bind(.left, .{}, .MoveLeft);
        try km.bind(.right, .{}, .MoveRight);
        try km.bind(.up, .{}, .MoveUp);
        try km.bind(.down, .{}, .MoveDown);

        // Arrows - Selection (Shift)
        try km.bind(.left, .{ .shift = true }, .SelectLeft);
        try km.bind(.right, .{ .shift = true }, .SelectRight);
        try km.bind(.up, .{ .shift = true }, .SelectUp);
        try km.bind(.down, .{ .shift = true }, .SelectDown);

        // Word Movement (Ctrl)
        try km.bind(.left, .{ .ctrl = true }, .MoveWordLeft);
        try km.bind(.right, .{ .ctrl = true }, .MoveWordRight);

        // Word Selection (Ctrl + Shift)
        try km.bind(.left, .{ .ctrl = true, .shift = true }, .SelectWordLeft);
        try km.bind(.right, .{ .ctrl = true, .shift = true }, .SelectWordRight);

        // Line Start/End
        try km.bind(.home, .{}, .MoveLineStart);
        try km.bind(.end, .{}, .MoveLineEnd);
        try km.bind(.home, .{ .shift = true }, .SelectLineStart);
        try km.bind(.end, .{ .shift = true }, .SelectLineEnd);

        // File Start/End (Ctrl + Home/End)
        try km.bind(.home, .{ .ctrl = true }, .MoveFileStart);
        try km.bind(.end, .{ .ctrl = true }, .MoveFileEnd);
        try km.bind(.home, .{ .ctrl = true, .shift = true }, .SelectFileStart);
        try km.bind(.end, .{ .ctrl = true, .shift = true }, .SelectFileEnd);

        // Page Up/Down
        try km.bind(.page_up, .{}, .MovePageUp);
        try km.bind(.page_down, .{}, .MovePageDown);
        try km.bind(.page_up, .{ .shift = true }, .SelectPageUp);
        try km.bind(.page_down, .{ .shift = true }, .SelectPageDown);

        // Editing
        try km.bind(.backspace, .{}, .DeleteBack);
        try km.bind(.delete, .{}, .DeleteForward);
        try km.bind(.backspace, .{ .ctrl = true }, .DeleteWordBack);
        try km.bind(.delete, .{ .ctrl = true }, .DeleteWordForward);
        try km.bind(.enter, .{}, .InsertNewline);
        try km.bind(.kp_enter, .{}, .InsertNewline);
        try km.bind(.tab, .{}, .InsertTab);

        // Scrolling
        try km.bind(.up, .{ .ctrl = true }, .ScrollUp);
        try km.bind(.down, .{ .ctrl = true }, .ScrollDown);

        // Clipboard
        try km.bind(.c, .{ .ctrl = true }, .Copy);
        try km.bind(.x, .{ .ctrl = true }, .Cut);
        try km.bind(.v, .{ .ctrl = true }, .Paste);

        // History
        try km.bind(.z, .{ .ctrl = true }, .Undo);
        try km.bind(.y, .{ .ctrl = true }, .Redo);
        try km.bind(.z, .{ .ctrl = true, .shift = true }, .Redo);

        // Selection All
        try km.bind(.a, .{ .ctrl = true }, .SelectAll);

        // Save
        try km.bind(.s, .{ .ctrl = true }, .Save);

        // Context Menu
        try km.bind(.mouse_right, .{}, .ShowContextMenu);

        return km;
    }
};
