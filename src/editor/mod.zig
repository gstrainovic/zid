//! Editor Modul für vulkan-ed
//!
//! Code Editor mit Line Numbers und Syntax Highlighting.

const std = @import("std");

pub const CodeEditor = @import("code_editor.zig").CodeEditor;
pub const Highlighter = @import("highlighter.zig").Highlighter;
pub const Token = @import("highlighter.zig").Token;
pub const TokenType = @import("highlighter.zig").TokenType;

pub const actions = @import("actions.zig");
pub const keymap = @import("keymap.zig");
