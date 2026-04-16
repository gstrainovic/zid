//! Pane System for vulkan-ed
//!
//! Implements a recursive binary split-view system.

const std = @import("std");
const clay = @import("clay");
const tab_bar_mod = @import("tab_bar.zig");
const editor_mod = @import("../editor/mod.zig");
const ui_mod = @import("mod.zig");

pub const PaneDirection = enum {
    horizontal,
    vertical,
};

pub const Pane = struct {
    const Self = @This();

    pub const Data = union(enum) {
        leaf: LeafPane,
        split: SplitPane,
    };

    data: Data,
    allocator: std.mem.Allocator,

    pub const LeafPane = struct {
        tab_bar: tab_bar_mod.TabBarState,
        code_editor: *editor_mod.CodeEditor,
    };

    pub const SplitPane = struct {
        direction: PaneDirection,
        ratio: f32 = 0.5,
        children: [2]*Pane,
        is_resizing: bool = false,
    };

    pub fn createLeaf(allocator: std.mem.Allocator, initial_buffer: *@import("flow_core").Buffer) !*Self {
        const self = try allocator.create(Self);
        const editor = try allocator.create(editor_mod.CodeEditor);
        editor.* = editor_mod.CodeEditor.init(allocator, initial_buffer);

        self.* = .{
            .allocator = allocator,
            .data = .{
                .leaf = .{
                    .tab_bar = tab_bar_mod.TabBarState.init(allocator),
                    .code_editor = editor,
                },
            },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        switch (self.data) {
            .leaf => |*l| {
                l.code_editor.deinit();
                self.allocator.destroy(l.code_editor);
                l.tab_bar.deinit();
            },
            .split => |*s| {
                s.children[0].deinit();
                s.children[1].deinit();
            },
        }
        self.allocator.destroy(self);
    }
};
