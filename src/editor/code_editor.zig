//! Code Editor Component für vulkan-ed
//!
//! Code Editor mit Line Numbers, Syntax Highlighting, Cursor und Text Input.
//! Verwendet flow_core.Buffer für Text-Speicherung.

const std = @import("std");
const clay = @import("clay");
const flow_core = @import("flow_core");
const wio = @import("wio");

const actions = @import("actions.zig");
const keymap = @import("keymap.zig");

/// Measurement function type: returns width of text in pixels.
pub const MeasureFn = *const fn (ptr: [*c]const u8, len: usize) f32;

/// Writer adapter: writes into ArrayListUnmanaged(u8), compatible with write_range
pub fn ArrayListWriter(comptime WriterError: type) type {
    return struct {
        allocator: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(u8),

        const AWriter = @This();
        pub const Error = WriterError;

        pub fn init(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8)) AWriter {
            return .{ .allocator = allocator, .list = list };
        }

        pub fn write(self: *AWriter, data: []const u8) Error!usize {
            self.list.appendSlice(self.allocator, data) catch return Error.OutOfMemory;
            return data.len;
        }

        pub fn writeAll(self: *AWriter, data: []const u8) Error!void {
            try self.write(data);
        }
    };
}

fn colorFromTag(fg: u32) clay.Color {
    return .{
        @floatFromInt((fg >> 16) & 0xff),
        @floatFromInt((fg >> 8) & 0xff),
        @floatFromInt(fg & 0xff),
        255,
    };
}

fn lessThanTag(_: void, a: flow_core.highlight.ColorTag, b: flow_core.highlight.ColorTag) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end; // längere zuerst bei gleichem Start
}

fn renderHighlightedLine(
    arena: std.mem.Allocator,
    hl: *flow_core.highlight.SyntaxHighlighter,
    line_idx: usize,
    line: []const u8,
    font_size: u16,
    plain_color: clay.Color,
) void {
    const tags = hl.tagsForLine(line_idx, line.len, arena) catch {
        const persistent = arena.dupe(u8, line) catch "";
        clay.text(persistent, .{ .font_size = font_size, .color = plain_color });
        return;
    };
    std.sort.insertion(flow_core.highlight.ColorTag, tags, {}, lessThanTag);

    var pos: usize = 0;
    for (tags) |tag| {
        if (tag.end > line.len) continue;
        if (tag.start >= tag.end) continue;
        if (tag.start < pos) continue; // überlappender Sub-Capture — überspringen
        if (tag.start > pos) {
            const seg = arena.dupe(u8, line[pos..tag.start]) catch "";
            clay.text(seg, .{ .font_size = font_size, .color = plain_color });
        }
        const seg = arena.dupe(u8, line[tag.start..tag.end]) catch "";
        clay.text(seg, .{ .font_size = font_size, .color = colorFromTag(tag.fg) });
        pos = tag.end;
    }
    if (pos < line.len) {
        const seg = arena.dupe(u8, line[pos..]) catch "";
        clay.text(seg, .{ .font_size = font_size, .color = plain_color });
    }
}

pub const CodeEditor = struct {
    allocator: std.mem.Allocator,

    /// flow-core Buffer for text storage
    buffer: *flow_core.Buffer,

    /// Aktuelle Zeile (1-based, für Highlight)
    current_line: usize = 1,

    /// Cursor Position (flow_core.Cursor: row/col in display columns)
    cursor: flow_core.Cursor,

    /// Selection Anchor, null = keine Selektion
    selection_anchor: ?flow_core.Cursor = null,

    /// Modifier-State (Bitmaske)
    mods: actions.Mods = .{},

    /// Keymap für Command-Dispatching
    keymap: ?keymap.Keymap = null,

    /// Maus-State für Drag-Selektion
    mouse_down: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    /// Double-Click Erkennung
    last_mouse_click_ms: f32 = 0,
    last_mouse_click_line: usize = 0,
    last_mouse_click_col: usize = 0,

    /// View for scrolling
    view: flow_core.View,

    /// Scrollbar-Dragging State
    scrollbar_dragging: bool = false,
    scrollbar_drag_start_y: f32 = 0,
    scrollbar_scroll_offset_at_drag_start: f32 = 0,

    /// Scrollbar Bounds
    scrollbar_track_x: f32 = 0,
    scrollbar_track_y: f32 = 0,
    scrollbar_thumb_y: f32 = 0,
    scrollbar_thumb_height: f32 = 0,
    scrollbar_container_width: f32 = 0,

    typing_in_progress: bool = false,

    /// Zeitpunkt der letzten Cursor-Bewegung (für Blink-Delay)
    last_cursor_movement_ms: f32 = 0,

    /// Layout
    height: f32 = 400,
    gutter_width: f32 = 50,
    scrollbar_width: f32 = 10,

    /// Content-Offset vom Fenster-Top
    content_origin_y: f32 = 0,
    content_origin_x: f32 = 0,

    /// Text-Messung
    measure_fn: ?MeasureFn = null,

    font_size: u16 = 24,
    time_ms: f32 = 0,

    /// Farben
    bg_color: clay.Color = .{ 30, 30, 46, 255 },
    gutter_color: clay.Color = .{ 24, 24, 37, 255 },
    line_number_color: clay.Color = .{ 108, 112, 134, 255 },
    current_line_number_color: clay.Color = .{ 138, 173, 244, 255 },
    current_line_highlight: clay.Color = .{ 60, 70, 100, 200 },
    cursor_color: clay.Color = .{ 249, 226, 175, 255 },
    selection_color: clay.Color = .{ 100, 120, 200, 160 },

    /// Referenz auf das Fenster
    window: ?*wio.Window = null,

    /// Kontextmenü-State
    show_context_menu: bool = false,
    context_menu_x: f32 = 0,
    context_menu_y: f32 = 0,

    /// Aktueller Mauszeiger-Typ
    desired_cursor: wio.Cursor = .arrow,

    /// Reusable line buffer for getLine — contents valid only until next getLine call.
    line_scratch: std.Io.Writer.Allocating,

    /// Syntax-Highlighter (flow-syntax / tree-sitter). null = kein Highlighting
    /// (z.B. unbekannte Dateiendung oder leerer Editor).
    highlighter: ?*flow_core.highlight.SyntaxHighlighter = null,

    /// Rope-Root der letzten Parser-Run — wird pro Render verglichen,
    /// um nur bei Buffer-Änderungen neu zu parsen.
    last_parsed_root: ?flow_core.Buffer.Root = null,

    const Self = @This();

    /// Metrics for flow_core - uses monospace assumption
    fn metrics(_: *const Self) flow_core.Buffer.Metrics {
        const Ctx = struct {
            fn egc_length(_: flow_core.Buffer.Metrics, egcs: []const u8, colcount: *usize, _: usize) usize {
                if (egcs.len == 0) return 0;
                if (egcs[0] == '\n') { colcount.* = 1; return 1; }
                if (egcs[0] == '\t') { colcount.* = 4; return 1; }
                colcount.* = 1;
                return 1;  // ASCII: jedes Zeichen ist 1 Byte und Breite 1
            }
            fn egc_chunk_width(_: flow_core.Buffer.Metrics, chunk_: []const u8, _: usize) usize {
                if (chunk_.len == 0) return 0;
                if (chunk_[0] == '\n') return 1;
                if (chunk_[0] == '\t') return 4;
                return 1;
            }
            fn egc_last(_: flow_core.Buffer.Metrics, egcs: []const u8) []const u8 {
                return egcs;
            }
        };
        return .{
            .ctx = undefined,
            .egc_length = Ctx.egc_length,
            .egc_chunk_width = Ctx.egc_chunk_width,
            .egc_last = Ctx.egc_last,
            .tab_width = 4,
        };
    }

    pub fn init(allocator: std.mem.Allocator, file_path: ?[]const u8) Self {
        _ = file_path;
        const buf = flow_core.Buffer.create(allocator) catch @panic("OOM Buffer.create");
        // Start with empty buffer
        const empty_text: [0]u8 = .{};
        buf.root = buf.load_from_string(&empty_text, &buf.file_eol_mode, &buf.file_utf8_sanitized) catch @panic("OOM load_from_string");

        const view: flow_core.View = .{
            .rows = 20,
            .cols = 80,
            .row = 0,
            .col = 0,
        };

        const cursor: flow_core.Cursor = .{
            .row = 0,
            .col = 0,
            .target = 0,
        };

        return Self{
            .allocator = allocator,
            .buffer = buf,
            .cursor = cursor,
            .view = view,
            .keymap = keymap.Keymap.initDefault(allocator) catch null,
            .desired_cursor = .arrow,
            .line_scratch = .init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.highlighter) |hl| {
            hl.destroy();
            self.highlighter = null;
        }
        self.buffer.deinit();
        if (self.keymap) |*km| km.deinit();
        self.line_scratch.deinit();
    }

    fn destroyHighlighter(self: *Self) void {
        if (self.highlighter) |hl| {
            hl.destroy();
            self.highlighter = null;
        }
        self.last_parsed_root = null;
    }

    /// Sprache anhand Dateipfad (Extension / Shebang) wählen.
    /// Erkennt nichts → Highlighter bleibt null, Fallback = Plain-Color.
    pub fn setLanguageFromPath(self: *Self, file_path: []const u8) void {
        const log = std.log.scoped(.highlight);
        self.destroyHighlighter();
        const content = self.buffer.store_to_string_cached(self.buffer.root, self.buffer.file_eol_mode);
        const hl = flow_core.highlight.SyntaxHighlighter.createByPath(
            self.allocator,
            file_path,
            content,
        ) catch |err| {
            log.warn("no highlighter for '{s}': {s}", .{ file_path, @errorName(err) });
            return;
        };
        self.highlighter = hl;
        // last_parsed_root = null erzwingt ersten Parse in ensureHighlightFresh.
        self.last_parsed_root = null;
        log.info("highlighter active for '{s}'", .{file_path});
    }

    /// Re-parse Highlighter, wenn der Rope-Root seit letztem Parse getauscht
    /// wurde. Pro Render-Frame am Anfang aufrufen. Nutzt inkrementelle
    /// tree-sitter Reparse (wie Flow/Zed) — O(edit-size) statt O(datei).
    pub fn ensureHighlightFresh(self: *Self) void {
        const hl = self.highlighter orelse return;
        if (self.last_parsed_root) |lpr| {
            if (lpr == self.buffer.root) return;
        }
        const content = self.buffer.store_to_string_cached(self.buffer.root, self.buffer.file_eol_mode);
        hl.reparseIncremental(content) catch |err| {
            std.log.scoped(.highlight).err("reparse failed: {s}", .{@errorName(err)});
            return;
        };
        self.last_parsed_root = self.buffer.root;
    }

    /// Get a single line via rope. Returned slice points into `line_scratch`
    /// and is invalidated by the next getLine call. Dupe into arena if needed.
    fn getLine(self: *Self, line_idx: usize) []const u8 {
        self.line_scratch.clearRetainingCapacity();
        self.buffer.root.get_line(line_idx, &self.line_scratch.writer, self.metrics()) catch {};
        return self.line_scratch.written();
    }

    /// Total number of lines
    fn lineCount(self: *const Self) usize {
        return self.buffer.root.lines();
    }

    /// Get line width in display columns
    fn lineWidth(self: *const Self, line_idx: usize) usize {
        return self.buffer.root.line_width(line_idx, self.metrics()) catch 0;
    }

    pub fn setText(self: *Self, text: []const u8) void {
        // Alten Highlighter wegwerfen — setLanguageFromPath setzt danach neu.
        self.destroyHighlighter();
        var eol_mode: flow_core.Buffer.EolMode = .lf;
        var utf8_sanitized: bool = false;
        const new_root = self.buffer.load_from_string(text, &eol_mode, &utf8_sanitized) catch {
            // Fallback: empty buffer
            self.buffer.root = self.buffer.load_from_string("", &self.buffer.file_eol_mode, &self.buffer.file_utf8_sanitized) catch @panic("OOM");
            self.cursor = .{};
            self.selection_anchor = null;
            return;
        };
        self.buffer.root = new_root;
        self.buffer.file_eol_mode = eol_mode;
        self.buffer.file_utf8_sanitized = utf8_sanitized;

        self.cursor = .{};
        self.selection_anchor = null;
    }

    fn recordCursorMovement(self: *Self) void {
        self.last_cursor_movement_ms = self.time_ms;
        self.ensureCursorVisible();
    }

    // =========================================================================
    // UTF-8 Navigation Helpers (adapted for buffer text)
    // =========================================================================

    fn prevCharBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos - 1;
        while (i > 0 and (text[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        return i;
    }

    fn nextCharBoundary(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var i = pos + 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) {
            i += 1;
        }
        return i;
    }

    fn snapToCharBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        if (pos >= text.len) return text.len;
        if ((text[pos] & 0xC0) != 0x80) return pos;
        return prevCharBoundary(text, pos);
    }

    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn prevWordBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos;
        while (i > 0) {
            const prev = prevCharBoundary(text, i);
            if (!std.ascii.isWhitespace(text[prev])) break;
            i = prev;
        }
        if (i == 0) return 0;
        const start_is_word = isWordChar(text[prevCharBoundary(text, i)]);
        while (i > 0) {
            const prev = prevCharBoundary(text, i);
            if (isWordChar(text[prev]) != start_is_word or std.ascii.isWhitespace(text[prev])) break;
            i = prev;
        }
        return i;
    }

    fn nextWordBoundary(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var i = pos;
        if (std.ascii.isWhitespace(text[i])) {
            while (i < text.len and std.ascii.isWhitespace(text[i])) {
                i = nextCharBoundary(text, i);
            }
        } else {
            const start_is_word = isWordChar(text[i]);
            while (i < text.len) {
                if (isWordChar(text[i]) != start_is_word or std.ascii.isWhitespace(text[i])) break;
                i = nextCharBoundary(text, i);
            }
        }
        return i;
    }

    // =========================================================================
    // Selection Helpers
    // =========================================================================

    pub fn hasSelection(self: *const Self) bool {
        if (self.selection_anchor) |anchor| {
            return !anchor.eql(self.cursor);
        }
        return false;
    }

    fn clearSelection(self: *Self) void {
        self.selection_anchor = null;
    }

    fn startSelection(self: *Self) void {
        self.selection_anchor = self.cursor;
    }

    fn selectionRange(self: *const Self) ?flow_core.Selection {
        if (!self.hasSelection()) return null;
        const anchor = self.selection_anchor.?;
        return .{ .begin = if (anchor.row < self.cursor.row or (anchor.row == self.cursor.row and anchor.col < self.cursor.col)) anchor else self.cursor, .end = if (anchor.row < self.cursor.row or (anchor.row == self.cursor.row and anchor.col < self.cursor.col)) self.cursor else anchor };
    }

    pub fn getSelectedText(self: *const Self, alloc: std.mem.Allocator) !?[]u8 {
        const range = self.selectionRange() orelse return null;

        var sel_list = std.ArrayListUnmanaged(u8){};
        errdefer sel_list.deinit(alloc);

        var writer = ArrayListWriter(std.mem.Allocator.Error).init(alloc, &sel_list);
        self.buffer.root.write_range(range, &writer, null, self.metrics()) catch return error.WriteFailed;

        if (sel_list.items.len == 0) {
            sel_list.deinit(alloc);
            return null;
        }
        const owned = try sel_list.toOwnedSlice(alloc);
        return owned;
    }

    /// Insert a string at the current cursor position.
    pub fn insertString(self: *Self, text: []const u8) !void {
        if (text.len == 0) return;

        // Delete selection first
        if (self.hasSelection()) {
            const range = self.selectionRange().?;
            const m = self.metrics();
            const new_root = self.buffer.root.delete_range(range, self.buffer.allocator, null, m) catch return error.Stop;
            self.buffer.root = new_root;
            self.cursor = range.begin;
            self.clearSelection();
        }

        // Insert chars at cursor
        const m = self.metrics();
        const result = self.buffer.root.insert_chars(
            self.cursor.row,
            self.cursor.col,
            text,
            self.buffer.allocator,
            m,
        ) catch return error.Stop;
        self.buffer.root = result[2];
        self.cursor.row = result[0];
        self.cursor.col = result[1];
        self.cursor.target = result[1];

        // Re-tokenize affected lines
        // self.retokenizeAround(self.cursor.row);

        self.last_cursor_movement_ms = self.time_ms;
    }

    pub fn dispatchAction(self: *Self, action: actions.Action) void {
        switch (action) {
            .InsertNewline, .InsertTab,
            .DeleteBack, .DeleteForward, .DeleteWordBack, .DeleteWordForward, .DeleteLine,
            .Cut, .Paste => {
                self.typing_in_progress = false;
                self.snapshotForUndo();
            },
            else => {},
        }

        const m = self.metrics();
        const line_count = self.lineCount();

        switch (action) {
            .MoveLeft => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.begin;
                    self.clearSelection();
                } else {
                    self.cursor.move_left(self.buffer.root, m) catch {};
                }
            },
            .MoveRight => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.end;
                    self.clearSelection();
                } else {
                    self.cursor.move_right(self.buffer.root, m) catch {};
                }
            },
            .MoveUp => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.begin;
                    self.clearSelection();
                } else {
                    self.cursor.move_up(self.buffer.root, m) catch {};
                }
            },
            .MoveDown => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.end;
                    self.clearSelection();
                } else {
                    self.cursor.move_down(self.buffer.root, m) catch {};
                }
            },
            .MoveWordLeft => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.begin;
                    self.clearSelection();
                } else {
                    // Manual word-left using line text
                    const line_text = self.getLine(self.cursor.row);
                    if (self.cursor.col > 0) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = prevWordBoundary(line_text, byte_pos);
                        self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch 0;
                    } else if (self.cursor.row > 0) {
                        self.cursor.row -= 1;
                        self.cursor.col = self.lineWidth(self.cursor.row);
                    }
                }
            },
            .MoveWordRight => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.end;
                    self.clearSelection();
                } else {
                    const line_text = self.getLine(self.cursor.row);
                    const line_w = self.lineWidth(self.cursor.row);
                    if (self.cursor.col < line_w) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = nextWordBoundary(line_text, byte_pos);
                        self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch line_w;
                    } else if (self.cursor.row + 1 < line_count) {
                        self.cursor.row += 1;
                        self.cursor.col = 0;
                    }
                }
            },
            .SelectLeft => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_left(self.buffer.root, m) catch {};
            },
            .SelectRight => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_right(self.buffer.root, m) catch {};
            },
            .SelectUp => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_up(self.buffer.root, m) catch {};
            },
            .SelectDown => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_down(self.buffer.root, m) catch {};
            },
            .SelectWordLeft => {
                if (!self.hasSelection()) self.startSelection();
                const line_text = self.getLine(self.cursor.row);
                if (self.cursor.col > 0) {
                    const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                    const new_byte_pos = prevWordBoundary(line_text, byte_pos);
                    self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch 0;
                } else if (self.cursor.row > 0) {
                    self.cursor.row -= 1;
                    self.cursor.col = self.lineWidth(self.cursor.row);
                }
            },
            .SelectWordRight => {
                if (!self.hasSelection()) self.startSelection();
                const line_text = self.getLine(self.cursor.row);
                const line_w = self.lineWidth(self.cursor.row);
                if (self.cursor.col < line_w) {
                    const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                    const new_byte_pos = nextWordBoundary(line_text, byte_pos);
                    self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch line_w;
                } else if (self.cursor.row + 1 < line_count) {
                    self.cursor.row += 1;
                    self.cursor.col = 0;
                }
            },
            .MoveLineStart => {
                self.cursor.move_begin();
            },
            .MoveLineEnd => {
                self.cursor.move_end(self.buffer.root, m);
            },
            .SelectLineStart => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_begin();
            },
            .SelectLineEnd => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_end(self.buffer.root, m);
            },
            .MoveFileStart => {
                self.clearSelection();
                self.cursor.move_buffer_begin();
            },
            .MoveFileEnd => {
                self.clearSelection();
                self.cursor.move_buffer_end(self.buffer.root, m);
            },
            .SelectFileStart => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_buffer_begin();
            },
            .SelectFileEnd => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_buffer_end(self.buffer.root, m);
            },
            .MovePageUp => {
                if (self.hasSelection()) {
                    self.cursor.move_page_up(self.buffer.root, &self.view, m);
                    self.clearSelection();
                } else {
                    self.cursor.move_page_up(self.buffer.root, &self.view, m);
                }
            },
            .MovePageDown => {
                if (self.hasSelection()) {
                    self.cursor.move_page_down(self.buffer.root, &self.view, m);
                    self.clearSelection();
                } else {
                    self.cursor.move_page_down(self.buffer.root, &self.view, m);
                }
            },
            .SelectPageUp => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_page_up(self.buffer.root, &self.view, m);
            },
            .SelectPageDown => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_page_down(self.buffer.root, &self.view, m);
            },
            .DeleteBack => {
                if (!self.deleteSelection()) {
                    if (self.cursor.col == 0 and self.cursor.row > 0) {
                        // Join with previous line
                        const prev_row = self.cursor.row - 1;
                        const prev_len = self.lineWidth(prev_row);
                        // Insert current line content at end of prev line — dupe
                        // into buffer arena because insert_chars stores the slice
                        // directly in a Leaf (no copy).
                        const cur_text = self.buffer.allocator.dupe(u8, self.getLine(self.cursor.row)) catch return;
                        const result = self.buffer.root.insert_chars(
                            prev_row, prev_len, cur_text, self.buffer.allocator, m,
                        ) catch return;
                        self.buffer.root = result[2];
                        // Delete current line
                        const sel: flow_core.Selection = .{
                            .begin = .{ .row = self.cursor.row, .col = 0 },
                            .end = .{ .row = self.cursor.row, .col = self.lineWidth(self.cursor.row) + 1 },
                        };
                        const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                        self.buffer.root = result2;
                        self.cursor.row = prev_row;
                        self.cursor.col = prev_len;
                    } else if (self.cursor.col > 0) {
                        const line_text = self.getLine(self.cursor.row);
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const char_start = prevCharBoundary(line_text, byte_pos);
                        const char_bytes = byte_pos - char_start;
                        if (char_bytes > 0) {
                            const sel: flow_core.Selection = .{
                                .begin = .{ .row = self.cursor.row, .col = self.cursor.col - 1 },
                                .end = self.cursor,
                            };
                            const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                            self.buffer.root = result2;
                            self.cursor.col -= 1;
                            self.cursor.target = self.cursor.col;
                        }
                    }
                }
            },
            .DeleteForward => {
                if (!self.deleteSelection()) {
                    const line_w = self.lineWidth(self.cursor.row);
                    if (self.cursor.col < line_w) {
                        const sel: flow_core.Selection = .{
                            .begin = self.cursor,
                            .end = .{ .row = self.cursor.row, .col = self.cursor.col + 1 },
                        };
                        const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                        self.buffer.root = result2;
                    } else if (self.cursor.row + 1 < line_count) {
                        // Join with next line — dupe into buffer arena (Leaf.new
                        // stores the slice without copying).
                        const next_text = self.buffer.allocator.dupe(u8, self.getLine(self.cursor.row + 1)) catch return;
                        const result = self.buffer.root.insert_chars(
                            self.cursor.row, self.cursor.col, next_text, self.buffer.allocator, m,
                        ) catch return;
                        self.buffer.root = result[2];
                        // Delete next line
                        const sel: flow_core.Selection = .{
                            .begin = .{ .row = self.cursor.row + 1, .col = 0 },
                            .end = .{ .row = self.cursor.row + 1, .col = self.lineWidth(self.cursor.row + 1) + 1 },
                        };
                        const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                        self.buffer.root = result2;
                    }
                }
            },
            .DeleteWordBack => {
                if (!self.deleteSelection()) {
                    const line_text = self.getLine(self.cursor.row);
                    if (self.cursor.col > 0) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = prevWordBoundary(line_text, byte_pos);
                        const new_col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch 0;
                        if (new_col < self.cursor.col) {
                            const sel: flow_core.Selection = .{
                                .begin = .{ .row = self.cursor.row, .col = new_col },
                                .end = self.cursor,
                            };
                            const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                            self.buffer.root = result2;
                            self.cursor.col = new_col;
                            self.cursor.target = new_col;
                        }
                    } else if (self.cursor.row > 0) {
                        self.dispatchAction(.DeleteBack);
                        return;
                    }
                }
            },
            .DeleteWordForward => {
                if (!self.deleteSelection()) {
                    const line_text = self.getLine(self.cursor.row);
                    const line_w = self.lineWidth(self.cursor.row);
                    if (self.cursor.col < line_w) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = nextWordBoundary(line_text, byte_pos);
                        const new_col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch line_w;
                        if (new_col > self.cursor.col) {
                            const sel: flow_core.Selection = .{
                                .begin = self.cursor,
                                .end = .{ .row = self.cursor.row, .col = new_col },
                            };
                            const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                            self.buffer.root = result2;
                        }
                    } else if (self.cursor.row + 1 < line_count) {
                        self.dispatchAction(.DeleteForward);
                        return;
                    }
                }
            },
            .DeleteLine => {
                const line_w = self.lineWidth(self.cursor.row);
                const sel: flow_core.Selection = .{
                    .begin = .{ .row = self.cursor.row, .col = 0 },
                    .end = .{ .row = self.cursor.row, .col = line_w + 1 },
                };
                const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                self.buffer.root = result2;
                self.cursor.col = 0;
            },
            .InsertNewline => {
                if (self.deleteSelection()) {}
                const result = self.buffer.root.insert_chars(
                    self.cursor.row, self.cursor.col, "\n", self.buffer.allocator, m,
                ) catch return;
                self.buffer.root = result[2];
                self.cursor.row += 1;
                self.cursor.col = 0;
                self.cursor.target = 0;
            },
            .InsertTab => {
                if (self.deleteSelection()) {}
                const result = self.buffer.root.insert_chars(
                    self.cursor.row, self.cursor.col, "    ", self.buffer.allocator, m,
                ) catch return;
                self.buffer.root = result[2];
                self.cursor.col += 4;
                self.cursor.target = self.cursor.col;
            },
            .SelectAll => {
                self.selection_anchor = .{ .row = 0, .col = 0 };
                self.cursor.row = line_count - 1;
                self.cursor.col = self.lineWidth(self.cursor.row);
                self.cursor.target = self.cursor.col;
            },
            .ScrollUp => {
                self.scrollLines(1);
            },
            .ScrollDown => {
                self.scrollLines(-1);
            },
            .Copy => {
                if (self.getSelectedText(self.allocator)) |text_opt| {
                    if (text_opt) |text| {
                        defer self.allocator.free(text);
                        if (self.window) |win| {
                            win.setClipboardText(text);
                        }
                    }
                } else |err| {
                    std.log.err("Failed to copy text: {}", .{err});
                }
            },
            .Cut => {
                if (self.getSelectedText(self.allocator)) |text_opt| {
                    if (text_opt) |text| {
                        defer self.allocator.free(text);
                        if (self.window) |win| {
                            win.setClipboardText(text);
                        }
                        _ = self.deleteSelection();
                    }
                } else |err| {
                    std.log.err("Failed to cut text: {}", .{err});
                }
            },
            .Paste => {
                if (self.window) |win| {
                    if (win.getClipboardText(self.allocator)) |text| {
                        defer self.allocator.free(text);
                        self.insertString(text) catch |err| {
                            std.log.err("Failed to paste text: {}", .{err});
                        };
                    }
                }
            },
            .ShowContextMenu => {
                self.show_context_menu = true;
                self.context_menu_x = self.mouse_x;
                self.context_menu_y = self.mouse_y;
            },
            .Undo => {
                const meta = self.buffer.undo() catch return;
                _ = meta;
                self.cursor = .{};
                self.selection_anchor = null;
                return;
            },
            .Redo => {
                const meta = self.buffer.redo() catch return;
                _ = meta;
                self.cursor = .{};
                self.selection_anchor = null;
                return;
            },
            else => {},
        }
        self.recordCursorMovement();
        self.current_line = self.cursor.row + 1;
    }

    /// Delete selected text. Returns true if text was deleted.
    fn deleteSelection(self: *Self) bool {
        if (!self.hasSelection()) return false;
        const range = self.selectionRange() orelse return false;
        const m = self.metrics();
        const new_root = self.buffer.root.delete_range(range, self.buffer.allocator, null, m) catch return false;
        self.buffer.root = new_root;
        self.cursor = range.begin;
        self.clearSelection();
        return true;
    }

    /// Snapshot for undo (simplified - uses flow_core's built-in undo)
    fn snapshotForUndo(self: *Self) void {
        // flow_core handles its own undo/redo
        _ = self;
    }

    pub fn handleKeyPress(self: *Self, key: wio.Button) void {
        if (self.keymap) |km| {
            if (km.lookup(key, self.mods)) |action| {
                self.dispatchAction(action);
                return;
            }
        }
    }

    pub fn setShiftState(self: *Self, pressed: bool) void {
        self.mods.shift = pressed;
    }

    pub fn setCtrlState(self: *Self, pressed: bool) void {
        self.mods.ctrl = pressed;
    }

    pub fn setAltState(self: *Self, pressed: bool) void {
        self.mods.alt = pressed;
    }

    // =========================================================================
    // Mouse Handling
    // =========================================================================

    pub fn updateMousePosition(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.mouse_down = true;

        if (self.show_context_menu) {
            if (clay.pointerOver(clay.getElementId("Cut"))) {
                self.dispatchAction(.Cut);
                self.show_context_menu = false;
                return;
            }
            if (clay.pointerOver(clay.getElementId("Copy"))) {
                self.dispatchAction(.Copy);
                self.show_context_menu = false;
                return;
            }
            if (clay.pointerOver(clay.getElementId("Paste"))) {
                self.dispatchAction(.Paste);
                self.show_context_menu = false;
                return;
            }
            self.show_context_menu = false;
        }

        if (self.handleScrollbarMouseDown(x, y)) return;

        const line_idx = self.lineFromY(y);
        const col = self.colFromX(x, line_idx);

        const is_double_click = (self.time_ms - self.last_mouse_click_ms < 500.0) and
            self.last_mouse_click_line == line_idx and
            self.last_mouse_click_col == col;

        if (is_double_click) {
            const line_text = self.getLine(line_idx);
            const line_w = self.lineWidth(line_idx);
            const m = self.metrics();
            const byte_pos = if (col < line_w)
                self.buffer.root.get_line_width_to_pos(line_idx, col, m) catch 0
            else
                line_text.len;

            var ws: usize = byte_pos;
            while (ws > 0 and isWordChar(line_text[ws - 1])) : (ws -= 1) {}
            var we: usize = byte_pos;
            while (we < line_text.len and isWordChar(line_text[we])) : (we += 1) {}

            const word_start_col = self.buffer.root.pos_to_width(line_idx, ws, m) catch 0;
            const word_end_col = self.buffer.root.pos_to_width(line_idx, we, m) catch line_w;

            self.cursor.row = line_idx;
            self.cursor.col = word_start_col;
            self.selection_anchor = .{ .row = line_idx, .col = word_end_col };
        } else {
            self.cursor.row = line_idx;
            self.cursor.col = col;
            self.cursor.target = col;
            self.selection_anchor = .{ .row = line_idx, .col = col };
        }

        self.mouse_down = true;
        self.last_mouse_click_ms = self.time_ms;
        self.last_mouse_click_line = line_idx;
        self.last_mouse_click_col = col;
        self.recordCursorMovement();
        self.current_line = self.cursor.row + 1;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;

        if (self.scrollbar_dragging) {
            self.handleScrollbarMouseMove(x, y);
            return;
        }

        if (!self.mouse_down) return;
        const line_idx = self.lineFromY(y);
        const col = self.colFromX(x, line_idx);
        self.cursor.row = line_idx;
        self.cursor.col = col;
        self.ensureCursorVisible();
        self.current_line = self.cursor.row + 1;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.mouse_down = false;
        self.scrollbar_dragging = false;
    }

    fn lineFromY(self: *const Self, y: f32) usize {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return 0;
        const rel_y = y - self.content_origin_y;
        if (rel_y < 0) return 0;
        const raw_line = @as(isize, @intFromFloat(@floor(rel_y / line_height)));
        const line = raw_line + @as(isize, @intCast(self.view.row));
        if (line < 0) return 0;
        const total = self.lineCount();
        return @min(@as(usize, @intCast(line)), if (total > 0) total - 1 else 0);
    }

    fn colFromX(self: *Self, x: f32, line_idx: usize) usize {
        const rel_x = x - self.content_origin_x - self.gutter_width - 12;
        if (rel_x <= 0) return 0;

        const line_text = self.getLine(line_idx);
        if (line_text.len == 0) return 0;

        if (self.measure_fn) |measure| {
            var x_accum: f32 = 0.0;
            var byte_offset: usize = 0;
            while (byte_offset < line_text.len) {
                var next_offset = byte_offset + 1;
                while (next_offset < line_text.len and (line_text[next_offset] & 0xC0) == 0x80) {
                    next_offset += 1;
                }
                const char_w = measure(@ptrCast(line_text.ptr + byte_offset), next_offset - byte_offset);
                if (rel_x < x_accum + char_w) {
                    return self.buffer.root.pos_to_width(line_idx, byte_offset, self.metrics()) catch 0;
                }
                x_accum += char_w;
                byte_offset = next_offset;
            }
            return self.lineWidth(line_idx);
        }

        const char_width: f32 = @as(f32, @floatFromInt(self.font_size)) * 0.6;
        if (char_width <= 0) return 0;
        const col_f = @as(isize, @intFromFloat(@floor(rel_x / char_width)));
        if (col_f < 0) return 0;
        return @min(@as(usize, @intCast(col_f)), self.lineWidth(line_idx));
    }

    // =========================================================================
    // Scrolling
    // =========================================================================

    pub fn scrollLines(self: *Self, delta: i32) void {
        if (delta > 0) {
            const amount = @as(usize, @intCast(delta));
            self.view.row = if (amount > self.view.row) 0 else self.view.row - amount;
        } else if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            const total = self.lineCount();
            const visible = self.visibleLineCount();
            const max_offset = if (total > visible) total - visible else 0;
            self.view.row = @min(self.view.row + amount, max_offset);
        }
    }

    fn visibleLineCount(self: *const Self) usize {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return 10;
        const available = self.height;
        if (available <= 0) return 10;
        return @max(1, @as(usize, @intFromFloat(@floor(available / line_height))));
    }

    pub fn ensureCursorVisible(self: *Self) void {
        self.view.rows = self.visibleLineCount();
        self.view.cols = 200; // reasonable default
        self.view.clamp(&self.cursor, true);
    }

    pub fn handleChar(self: *Self, char_code: u21) void {
        if (char_code < 32 or char_code == 127) return;
        if (self.mods.ctrl and !self.mods.alt) return;

        if (!self.typing_in_progress) {
            self.snapshotForUndo();
            self.typing_in_progress = true;
        }

        if (self.deleteSelection()) {}

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char_code, &buf) catch return;

        const m = self.metrics();
        const result = self.buffer.root.insert_chars(
            self.cursor.row, self.cursor.col, buf[0..len], self.buffer.allocator, m,
        ) catch return;
        self.buffer.root = result[2];
        self.cursor.col += @as(usize, @intCast(len));
        self.cursor.target = self.cursor.col;
        self.recordCursorMovement();
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    pub fn render(self: *Self, arena: std.mem.Allocator) void {
        self.desired_cursor = .arrow;
        self.ensureHighlightFresh();

        clay.UI()(.{
            .id = clay.ElementId.ID("code_editor"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right,
            },
            .background_color = self.bg_color,
        })({
            if (clay.hovered()) {
                self.desired_cursor = .text;
            }
            clay.UI()(.{
                .id = clay.ElementId.ID("editor_scroll"),
                .layout = .{ .sizing = .grow },
                .background_color = self.bg_color,
                .clip = .{ .vertical = true, .horizontal = true },
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("editor_content"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                    },
                })({
                    const total = self.lineCount();
                    const visible_count = self.visibleLineCount();
                    const start_line = @min(self.view.row, total);
                    const end_line = @min(start_line + visible_count + 1, total);

                    var i: usize = start_line;
                    while (i < end_line) : (i += 1) {
                        const line_text = arena.dupe(u8, self.getLine(i)) catch "";
                        const is_current = (i == self.cursor.row);

                        const is_selected = if (self.hasSelection()) blk: {
                            const range = self.selectionRange().?;
                            break :blk i >= range.begin.row and i <= range.end.row;
                        } else false;

                        clay.UI()(.{
                            .id = clay.ElementId.IDI("row", @intCast(i)),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                .direction = .left_to_right,
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            clay.UI()(.{
                                .id = clay.ElementId.IDI("gutter", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .fixed(self.gutter_width), .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                    .padding = .{ .left = 8, .right = 16 },
                                    .child_alignment = .{ .x = .right, .y = .center },
                                },
                                .background_color = if (is_selected) self.selection_color else if (is_current) self.current_line_highlight else self.gutter_color,
                            })({
                                const color = if (is_current)
                                    self.current_line_number_color
                                else
                                    self.line_number_color;

                                var buf: [16]u8 = undefined;
                                const line_num_str = std.fmt.bufPrint(&buf, "{d}", .{i + 1}) catch "?";
                                const persistent_str = arena.dupe(u8, line_num_str) catch "";
                                clay.text(persistent_str, .{ .font_size = self.font_size, .color = color });
                            });

                            clay.UI()(.{
                                .id = clay.ElementId.IDI("code", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                    .padding = .{ .left = 12 },
                                    .child_alignment = .{ .x = .left, .y = .center },
                                },
                                .background_color = if (is_current) self.current_line_highlight else .{ 0, 0, 0, 0 },
                            })({
                                self.renderLine(arena, i, line_text);
                            });
                        });
                    }
                });
            });

            if (self.lineCount() > self.visibleLineCount()) {
                self.renderScrollbar();
            }
        });

        if (self.show_context_menu) {
            self.renderContextMenu(arena);
        }
    }

    fn renderLine(self: *Self, arena: std.mem.Allocator, line_idx: usize, line: []const u8) void {
        clay.UI()(.{
            .layout = .{ .direction = .left_to_right, .child_alignment = .{ .x = .left, .y = .center } },
        })({
            if (self.hasSelection()) {
                self.renderSelection(arena, line_idx);
            }

            const plain_color: clay.Color = .{ 202, 211, 245, 255 };

            if (self.highlighter) |hl| {
                renderHighlightedLine(arena, hl, line_idx, line, self.font_size, plain_color);
            } else {
                const persistent = arena.dupe(u8, line) catch "";
                clay.text(persistent, .{ .font_size = self.font_size, .color = plain_color });
            }

            if (line_idx == self.cursor.row) {
                self.renderCursor(arena);
            }
        });
    }

    fn renderSelection(self: *Self, arena: std.mem.Allocator, line_idx: usize) void {
        const range = self.selectionRange() orelse return;
        if (line_idx < range.begin.row or line_idx > range.end.row) return;

        const line = self.getLine(line_idx);

        const start_col = if (line_idx == range.begin.row) range.begin.col else 0;
        const end_col = if (line_idx == range.end.row) range.end.col else self.lineWidth(line_idx);

        const start_byte = self.buffer.root.get_line_width_to_pos(line_idx, start_col, self.metrics()) catch 0;
        const end_byte = self.buffer.root.get_line_width_to_pos(line_idx, end_col, self.metrics()) catch line.len;

        const start_clamped = @min(start_byte, line.len);
        const end_clamped = @min(end_byte, line.len);

        if (start_clamped >= end_clamped and line_idx < range.end.row) {
            // Selection extends to end of line
            const prefix = line[0..start_clamped];
            const selected_text = line[start_clamped..];

            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(@floatFromInt(self.font_size + 16)) } },
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                    .offset = .{ .x = 0, .y = 0 },
                },
            })({
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fit, .h = .grow }, .direction = .left_to_right },
                })({
                    const p = arena.dupe(u8, prefix) catch "";
                    clay.text(p, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });

                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fit, .h = .grow } },
                        .background_color = self.selection_color,
                    })({
                        const s = arena.dupe(u8, selected_text) catch "";
                        clay.text(s, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(10), .h = .grow } } })({});
                    });
                });
            });
        } else if (start_clamped < end_clamped) {
            const prefix = line[0..start_clamped];
            const selected_text = line[start_clamped..end_clamped];

            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(@floatFromInt(self.font_size + 16)) } },
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                    .offset = .{ .x = 0, .y = 0 },
                },
            })({
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fit, .h = .grow }, .direction = .left_to_right },
                })({
                    const p = arena.dupe(u8, prefix) catch "";
                    clay.text(p, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });

                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fit, .h = .grow } },
                        .background_color = self.selection_color,
                    })({
                        const s = arena.dupe(u8, selected_text) catch "";
                        clay.text(s, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });
                        if (line_idx < range.end.row) {
                            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(10), .h = .grow } } })({});
                        }
                    });
                });
            });
        }
    }

    fn renderCursor(self: *Self, arena: std.mem.Allocator) void {
        const blink_ms: f32 = 500.0;
        const blink_delay_ms: f32 = 400.0;

        const time_since_movement = self.time_ms - self.last_cursor_movement_ms;
        const is_moving = time_since_movement < blink_delay_ms;
        const visible = is_moving or (@mod(self.time_ms, blink_ms * 2.0) < blink_ms);
        if (!visible) return;

        const line = self.getLine(self.cursor.row);
        const m = self.metrics();
        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch line.len;
        const text_before_cursor = if (byte_pos <= line.len) line[0..byte_pos] else line;

        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(@floatFromInt(self.font_size + 16)) } },
            .floating = .{
                .attach_to = .to_parent,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = .{ .x = 0, .y = 0 },
            },
        })({
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fit, .h = .grow }, .direction = .left_to_right },
            })({
                const persistent = arena.dupe(u8, text_before_cursor) catch "";
                clay.text(persistent, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });

                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fixed(2), .h = .grow } },
                    .background_color = self.cursor_color,
                })({});
            });
        });
    }

    fn renderScrollbar(self: *Self) void {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total <= visible) return;

        const track_data = clay.getElementData(clay.ElementId.ID("scrollbar_track"));
        if (track_data.found) {
            self.scrollbar_track_x = track_data.bounding_box.x;
            self.scrollbar_track_y = track_data.bounding_box.y;
        }

        const track_height = self.height;
        const thumb_ratio: f32 = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
        const thumb_height = @max(20.0, track_height * thumb_ratio);
        const max_offset: usize = total - visible;
        const scroll_frac: f32 = if (max_offset > 0)
            @as(f32, @floatFromInt(self.view.row)) / @as(f32, @floatFromInt(max_offset))
        else
            0.0;
        const thumb_y = scroll_frac * (track_height - thumb_height);

        self.scrollbar_thumb_y = self.scrollbar_track_y + thumb_y;
        self.scrollbar_thumb_height = thumb_height;

        const track_color: clay.Color = .{ 30, 30, 46, 100 };
        const thumb_color: clay.Color = .{ 88, 88, 120, 180 };

        clay.UI()(.{
            .id = clay.ElementId.ID("scrollbar_track"),
            .layout = .{
                .sizing = .{ .w = .fixed(self.scrollbar_width), .h = .grow },
                .direction = .top_to_bottom,
            },
            .background_color = track_color,
        })({
            if (clay.hovered()) self.desired_cursor = .arrow;
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_y) } },
            })({});
            clay.UI()(.{
                .id = clay.ElementId.ID("scrollbar_thumb"),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_height) } },
                .background_color = thumb_color,
                .corner_radius = .all(3),
            })({
                if (clay.hovered()) self.desired_cursor = .arrow;
            });
        });
    }

    fn handleScrollbarMouseDown(self: *Self, x: f32, y: f32) bool {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total <= visible) return false;

        if (x < self.scrollbar_track_x) return false;
        if (x > self.scrollbar_track_x + self.scrollbar_width) return false;
        if (y < self.scrollbar_track_y) return false;
        if (y > self.scrollbar_track_y + self.height) return false;

        if (y >= self.scrollbar_thumb_y and y <= self.scrollbar_thumb_y + self.scrollbar_thumb_height) {
            self.scrollbar_dragging = true;
            self.scrollbar_drag_start_y = y;
            self.scrollbar_scroll_offset_at_drag_start = @as(f32, @floatFromInt(self.view.row));
            return true;
        }

        if (y < self.scrollbar_thumb_y) {
            self.scrollLines(@as(i32, @intCast(visible)));
        } else {
            self.scrollLines(-@as(i32, @intCast(visible)));
        }
        return true;
    }

    fn handleScrollbarMouseMove(self: *Self, _: f32, y: f32) void {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total <= visible) return;

        const track_height = self.height;
        const thumb_ratio: f32 = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
        const thumb_height = @max(20.0, track_height * thumb_ratio);
        const max_offset: usize = total - visible;
        const scrollable_height = track_height - thumb_height;

        if (scrollable_height <= 0) return;

        const delta_y = y - self.scrollbar_drag_start_y;
        const scroll_delta_frac = delta_y / scrollable_height;
        const scroll_delta_lines = scroll_delta_frac * @as(f32, @floatFromInt(max_offset));
        const scroll_delta_int: i32 = @intFromFloat(@round(scroll_delta_lines));

        var new_offset: isize = @as(isize, @intFromFloat(self.scrollbar_scroll_offset_at_drag_start)) + @as(isize, scroll_delta_int);
        new_offset = @max(0, @min(new_offset, @as(isize, @intCast(max_offset))));

        self.view.row = @as(usize, @intCast(new_offset));
    }

    fn renderContextMenu(self: *Self, arena: std.mem.Allocator) void {
        const item_height = @as(f32, @floatFromInt(self.font_size)) + 16;
        const menu_width: f32 = 120;
        const menu_height = item_height * 3;

        clay.UI()(.{
            .id = clay.ElementId.ID("context_menu_anchor"),
            .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(0) } },
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = .{ .x = self.context_menu_x, .y = self.context_menu_y },
                .z_index = 1000,
            },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("context_menu_container"),
                .layout = .{
                    .sizing = .{ .w = .fixed(menu_width), .h = .fixed(menu_height) },
                    .direction = .top_to_bottom,
                    .padding = .all(4),
                },
                .background_color = .{ 45, 45, 60, 255 },
                .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
                .corner_radius = .all(4),
            })({
                if (clay.hovered()) {
                    self.desired_cursor = .arrow;
                }
                self.renderContextMenuItem("Cut", .Cut, arena);
                self.renderContextMenuItem("Copy", .Copy, arena);
                self.renderContextMenuItem("Paste", .Paste, arena);
            });
        });
    }

    fn renderContextMenuItem(self: *Self, label: []const u8, _action: actions.Action, arena: std.mem.Allocator) void {
        _ = _action;
        const item_id = clay.getElementId(label);
        const is_hovered = clay.pointerOver(item_id);
        if (is_hovered) {
            self.desired_cursor = .arrow;
        }

        clay.UI()(.{
            .id = item_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 12)) },
                .padding = .{ .left = 8, .right = 8 },
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = if (is_hovered) .{ 80, 80, 100, 255 } else .{ 0, 0, 0, 0 },
            .corner_radius = .all(2),
        })({
            const persistent = arena.dupe(u8, label) catch "";
            clay.text(persistent, .{ .font_size = self.font_size - 2, .color = .{ 220, 220, 240, 255 } });
        });
    }

    pub fn getLineByteLen(self: *Self, line_idx: usize) usize {
        return self.getLine(line_idx).len;
    }
};

// =========================================================================
// Tests (adapted for flow_core.Buffer)
// =========================================================================

test "setText: CRLF wird zu LF normalisiert" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("line1\r\nline2\r\nline3");
    try std.testing.expectEqual(@as(usize, 3), ed.lineCount());
    try std.testing.expectEqualStrings("line1", ed.getLine(0));
    try std.testing.expectEqualStrings("line2", ed.getLine(1));
    try std.testing.expectEqualStrings("line3", ed.getLine(2));
}

test "setText: leerer String erzeugt eine leere Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("");
    try std.testing.expectEqual(@as(usize, 1), ed.lineCount());
    try std.testing.expectEqualStrings("", ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "Enter mitten in der Zeile splittet korrekt" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("abcdef");
    const m = ed.metrics();
    const byte_pos = ed.buffer.root.get_line_width_to_pos(0, 3, m) catch 0;
    ed.cursor.col = byte_pos;
    ed.handleKeyPress(.enter);

    try std.testing.expectEqual(@as(usize, 2), ed.lineCount());
    try std.testing.expectEqualStrings("abc", ed.getLine(0));
    try std.testing.expectEqualStrings("def", ed.getLine(1));
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.row);
}

test "Backspace am Zeilenanfang mergt mit vorheriger Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 1;
    ed.cursor.col = 0;
    ed.handleKeyPress(.backspace);

    try std.testing.expectEqual(@as(usize, 1), ed.lineCount());
    try std.testing.expectEqualStrings("abcdef", ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "Delete am Zeilenende mergt mit nächster Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 0;
    const m = ed.metrics();
    const lw = ed.buffer.root.line_width(0, m) catch 0;
    ed.cursor.col = lw;
    ed.handleKeyPress(.delete);

    try std.testing.expectEqual(@as(usize, 1), ed.lineCount());
    try std.testing.expectEqualStrings("abcdef", ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "Navigation: Left am Zeilenanfang springt ans Ende der vorherigen Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 1;
    ed.cursor.col = 0;
    ed.handleKeyPress(.left);

    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "Navigation: Right bewegt Cursor um EINE Position weiter" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("abcdef");
    ed.cursor.row = 0;
    ed.cursor.col = 0;
    const m = ed.metrics();
    
    // Erster Right: col=0 → col=1
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
    
    // Zweiter Right: col=1 → col=2
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.col);
    
    // Dritter Right: col=2 → col=3
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);
    
    // Am Zeilenende (col=6): Right springt zur nächsten Zeile
    ed.cursor.col = 6;
    ed.cursor.row = 0;
    ed.setText("abcdef\nxyz");
    ed.cursor.col = 6;
    ed.cursor.row = 0;
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "Navigation: Right am Zeilenende springt an Anfang der nächsten Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator, null);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 0;
    const m = ed.metrics();
    const lw = ed.buffer.root.line_width(0, m) catch 0;
    ed.cursor.col = lw;
    ed.handleKeyPress(.right);

    try std.testing.expectEqual(@as(usize, 1), ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}
