//! Editor Modul für zid
//!
//! Code Editor mit Line Numbers und Syntax Highlighting.

const std = @import("std");

pub const CodeEditor = @import("code_editor.zig").CodeEditor;

pub const actions = @import("actions.zig");
pub const keymap = @import("keymap.zig");
