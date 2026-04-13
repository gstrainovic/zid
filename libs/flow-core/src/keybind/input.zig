/// Minimal input types for keybind parsers.
/// No vaxis, no thespian — just the bare types the parsers need.

pub const Key = u21;
pub const Mods = u8;

pub const ModSet = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _pad1: bool = false,
    _pad2: bool = false,
};

pub const mod = struct {
    pub const shift: Mods = @bitCast(ModSet{ .shift = true });
    pub const alt: Mods = @bitCast(ModSet{ .alt = true });
    pub const ctrl: Mods = @bitCast(ModSet{ .ctrl = true });
    pub const super: Mods = @bitCast(ModSet{ .super = true });
    pub const caps_lock: Mods = @bitCast(ModSet{ .caps_lock = true });
    pub const num_lock: Mods = @bitCast(ModSet{ .num_lock = true });
};

pub const key = struct {
    pub const tab: Key = '\t';
    pub const enter: Key = '\r';
    pub const escape: Key = 27;
    pub const space: Key = ' ';
    pub const backspace: Key = 8;
    pub const delete: Key = 127;
    pub const insert: Key = 200;
    pub const up: Key = 201;
    pub const down: Key = 202;
    pub const left: Key = 203;
    pub const right: Key = 204;
    pub const home: Key = 205;
    pub const end: Key = 206;
    pub const f1: Key = 300;
};

pub const Event = u8;
pub const event = struct {
    pub const press: Event = 1;
    pub const repeat: Event = 2;
    pub const release: Event = 3;
};

pub const KeyEvent = struct {
    event: Event = 0,
    key: Key,
    key_unshifted: Key,
    modifiers: Mods = 0,
    text: []const u8 = "",

    pub fn from_key(keypress: Key) @This() {
        return .{
            .key = keypress,
            .key_unshifted = keypress,
        };
    }

    pub fn from_key_mods(keypress: Key, modifiers: Mods) @This() {
        return .{
            .key = keypress,
            .key_unshifted = keypress,
            .modifiers = modifiers,
        };
    }

    pub fn from_key_modset(keypress: Key, modifiers: ModSet) @This() {
        return from_key_mods(keypress, @bitCast(modifiers));
    }
};
