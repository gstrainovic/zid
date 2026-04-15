//! Terminal module for vulkan-ed
//!
//! Integrates ghostty-vt for VT emulation with platform PTY for
//! actual shell process management. Provides a high-level API for
//! creating terminals, reading output, sending input, and getting
//! render state for display.

const std = @import("std");
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");

pub const ConPty = @import("conpty.zig");
pub const TerminalInstance = @import("terminal_instance.zig").TerminalInstance;

const log = std.log.scoped(.terminal);

test {
    _ = ConPty;
    _ = @import("terminal_instance.zig");
}
