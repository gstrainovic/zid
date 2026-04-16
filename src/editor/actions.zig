const std = @import("std");
const wio = @import("wio");

pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    gui: bool = false, // Command/Super
    _padding: u4 = 0,

    pub fn isNone(self: Mods) bool {
        return !self.shift and !self.ctrl and !self.alt and !self.gui;
    }

    pub fn toU8(self: Mods) u8 {
        return @bitCast(self);
    }

    pub fn fromU8(val: u8) Mods {
        return @bitCast(val);
    }
};

pub const Action = enum {
    // Navigation
    MoveLeft,
    MoveRight,
    MoveUp,
    MoveDown,
    MoveWordLeft,
    MoveWordRight,
    MoveLineStart,
    MoveLineEnd,
    MovePageUp,
    MovePageDown,
    MoveFileStart,
    MoveFileEnd,

    // Selection variants
    SelectLeft,
    SelectRight,
    SelectUp,
    SelectDown,
    SelectWordLeft,
    SelectWordRight,
    SelectLineStart,
    SelectLineEnd,
    SelectPageUp,
    SelectPageDown,
    SelectFileStart,
    SelectFileEnd,
    SelectAll,

    // Editing
    InsertNewline,
    InsertTab,
    DeleteBack,
    DeleteForward,
    DeleteWordBack,
    DeleteWordForward,
    DeleteLine,
    
    // Clipboard
    Copy,
    Cut,
    Paste,

    // History
    Undo,
    Redo,

    // Other
    Search,
    Save,
    ScrollUp,
    ScrollDown,
    ShowContextMenu,
    MdPreview,
};

pub const KeyEvent = struct {
    key: wio.Button,
    mods: Mods,

    pub fn hash(self: KeyEvent) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.key));
        h.update(std.mem.asBytes(&self.mods));
        return h.final();
    }

    pub fn eql(a: KeyEvent, b: KeyEvent) bool {
        return a.key == b.key and a.mods.toU8() == b.mods.toU8();
    }
};
