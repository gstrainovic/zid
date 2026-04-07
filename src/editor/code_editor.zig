//! Code Editor Component für vulkan-ed
//!
//! Code Editor mit Line Numbers, Syntax Highlighting, Cursor und Text Input.

const std = @import("std");
const clay = @import("clay");
const Highlighter = @import("highlighter.zig").Highlighter;
const Token = @import("highlighter.zig").Token;
const TokenType = @import("highlighter.zig").TokenType;
const wio = @import("wio");

/// Measurement function type: returns width of text in pixels.
/// C-kompatibel: ptr + len statt Slice.
pub const MeasureFn = *const fn (ptr: [*c]const u8, len: usize) f32;

pub const CodeEditor = struct {
    allocator: std.mem.Allocator,

    /// Code-Zeilen dynamisch (Unmanaged für präzise Speicherrolle)
    lines: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)),

    /// Tokenisierte Zeilen
    line_tokens: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Token)),

    /// Highlighter
    highlighter: Highlighter,

    /// Aktuelle Zeile (für Highlight)
    current_line: usize = 1,

    /// Cursor Position (Zeile/Spalte als Byte-Offset)
    cursor_line: usize = 0,
    cursor_col: usize = 0,

    /// Selection Anchor (Zeile/Spalte), null = keine Selektion
    selection_anchor_line: ?usize = null,
    selection_anchor_col: ?usize = null,

    /// Modifier-State für Shift+Navigation
    shift_pressed: bool = false,
    ctrl_pressed: bool = false,

    /// Maus-State für Drag-Selektion
    mouse_down: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    /// Double-Click Erkennung
    last_mouse_click_ms: f32 = 0,
    last_mouse_click_line: usize = 0,
    last_mouse_click_col: usize = 0,

    /// Scrolling: Erste sichtbare Zeile (Viewport Culling)
    scroll_offset_first_line: usize = 0,

    /// Zeitpunkt der letzten Cursor-Bewegung (für Blink-Delay)
    last_cursor_movement_ms: f32 = 0,

    /// Layout
    height: f32 = 400,
    gutter_width: f32 = 50,
    scrollbar_width: f32 = 10,

    /// Content-Offset vom Fenster-Top (für Maus→Zeile Konversion)
    content_origin_y: f32 = 0,

    /// X-Offset vom Fenster-Left (für Maus→Spalte Konversion)
    content_origin_x: f32 = 0,

    /// Text-Messung (width in px für gegebene String)
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
    selection_color: clay.Color = .{ 137, 180, 250, 100 },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .allocator = allocator,
            .lines = .{},
            .line_tokens = .{},
            .highlighter = Highlighter.init(
                .{ 199, 146, 234, 255 }, // keyword - lila
                .{ 166, 209, 137, 255 }, // string - grün
                .{ 108, 112, 134, 255 }, // comment - grau
                .{ 250, 179, 135, 255 }, // number - orange
                .{ 138, 173, 244, 255 }, // builtin - blau
                .{ 138, 173, 244, 255 }, // punctuation - blau
                .{ 202, 211, 245, 255 }, // plain - weiß
            ),
        };
        // Initialisiere mit einer leeren Zeile
        const first_line = std.ArrayListUnmanaged(u8){};
        self.lines.append(allocator, first_line) catch {};
        const first_tokens = std.ArrayListUnmanaged(Token){};
        self.line_tokens.append(allocator, first_tokens) catch {};
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        for (self.line_tokens.items) |*tokens| tokens.deinit(self.allocator);
        self.line_tokens.deinit(self.allocator);
    }

    pub fn setText(self: *Self, text: []const u8) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.clearRetainingCapacity();
        for (self.line_tokens.items) |*tokens| tokens.deinit(self.allocator);
        self.line_tokens.clearRetainingCapacity();

        var lines_iter = std.mem.splitScalar(u8, text, '\n');
        while (lines_iter.next()) |raw_line| {
            var line = std.ArrayListUnmanaged(u8){};
            const trimmed = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
            line.appendSlice(self.allocator, trimmed) catch continue;
            self.lines.append(self.allocator, line) catch continue;

            const tokens = std.ArrayListUnmanaged(Token){};
            self.line_tokens.append(self.allocator, tokens) catch continue;
            self.tokenizeLine(self.lines.items.len - 1);
        }
        if (self.lines.items.len == 0) {
            const line = std.ArrayListUnmanaged(u8){};
            self.lines.append(self.allocator, line) catch {};
            const tokens = std.ArrayListUnmanaged(Token){};
            self.line_tokens.append(self.allocator, tokens) catch {};
        }
        self.cursor_line = 0;
        self.cursor_col = 0;
        self.scroll_offset_first_line = 0;
        self.last_cursor_movement_ms = self.time_ms;
        self.current_line = 1;
    }

    /// Cursor-Bewegung registrieren (setzt Blink-Delay zurück, scrollt falls nötig)
    fn recordCursorMovement(self: *Self) void {
        self.last_cursor_movement_ms = self.time_ms;
        self.ensureCursorVisible();
    }

    fn tokenizeLine(self: *Self, line_idx: usize) void {
        if (line_idx >= self.lines.items.len) return;
        var tokens = &self.line_tokens.items[line_idx];
        tokens.clearRetainingCapacity();

        const line_text = self.lines.items[line_idx].items;
        const len = line_text.len;
        var ti: usize = 0;

        while (ti < len) {
            // Whitespace
            if (std.ascii.isWhitespace(line_text[ti])) {
                const tok_start = ti;
                while (ti < len and std.ascii.isWhitespace(line_text[ti])) {
                    ti += 1;
                }
                tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .plain }) catch {};
                continue;
            }

            // String Literal
            if (line_text[ti] == '"') {
                const tok_start = ti;
                ti += 1;
                while (ti < len and line_text[ti] != '"') {
                    if (line_text[ti] == '\\' and ti + 1 < len) ti += 1;
                    ti += 1;
                }
                if (ti < len) ti += 1;
                tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .string }) catch {};
                continue;
            }

            // Comment
            if (line_text[ti] == '/' and ti + 1 < len and line_text[ti + 1] == '/') {
                tokens.append(self.allocator, Token{ .start = ti, .end = len, .token_type = .comment }) catch {};
                break;
            }

            // Number
            if (std.ascii.isDigit(line_text[ti])) {
                const tok_start = ti;
                while (ti < len and (std.ascii.isDigit(line_text[ti]) or line_text[ti] == '_' or line_text[ti] == '.')) {
                    ti += 1;
                }
                tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .number }) catch {};
                continue;
            }

            // Punctuation
            if (std.mem.indexOfScalar(u8, &[_]u8{ '(', ')', '{', '}', '[', ']', ',', ';', '.', ':', '!', '?', '+', '-', '*', '/', '=', '<', '>', '|', '&', '^', '%', '~', '@' }, line_text[ti])) |_| {
                const tok_start = ti;
                if (ti + 1 < len) {
                    const two = line_text[ti .. ti + 2];
                    if (std.mem.eql(u8, two, "=>") or std.mem.eql(u8, two, "->") or std.mem.eql(u8, two, "||") or std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "++") or std.mem.eql(u8, two, "--") or std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "!=") or std.mem.eql(u8, two, ">=") or std.mem.eql(u8, two, "<=")) {
                        ti += 2;
                        tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .punctuation }) catch {};
                        continue;
                    }
                }
                ti += 1;
                tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .punctuation }) catch {};
                continue;
            }

            // Identifier oder Keyword (ASCII oder UTF-8 Multibyte)
            if (std.ascii.isAlphabetic(line_text[ti]) or line_text[ti] == '_' or (line_text[ti] & 0x80) != 0) {
                const tok_start = ti;
                while (ti < len and (std.ascii.isAlphanumeric(line_text[ti]) or line_text[ti] == '_' or (line_text[ti] & 0x80) != 0)) {
                    ti += 1;
                }
                const word = line_text[tok_start..ti];
                const keywords = [_][]const u8{ "const", "var", "fn", "pub", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "struct", "enum", "union", "extern", "export", "inline", "noinline", "comptime", "test", "usingnamespace", "and", "or", "not", "true", "false", "null", "undefined", "void", "bool", "type", "anytype", "anyframe", "anyerror" };
                var is_kw = false;
                for (keywords) |kw| {
                    if (std.mem.eql(u8, word, kw)) {
                        is_kw = true;
                        break;
                    }
                }
                if (is_kw) {
                    tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .keyword }) catch {};
                } else if (std.mem.eql(u8, word, "std")) {
                    tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .builtin }) catch {};
                } else {
                    tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .plain }) catch {};
                }
                continue;
            }

            // Unbekanntes Zeichen — trotzdem als Token erfassen, damit es gerendert wird.
            const tok_start = ti;
            ti += 1;
            tokens.append(self.allocator, Token{ .start = tok_start, .end = ti, .token_type = .plain }) catch {};
        }
    }

    // =========================================================================
    // UTF-8 Navigation Helpers
    // =========================================================================

    /// Find the previous UTF-8 character boundary (byte offset).
    fn prevCharBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos - 1;
        // Skip continuation bytes (10xxxxxx pattern).
        while (i > 0 and (text[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        return i;
    }

    /// Find the next UTF-8 character boundary (byte offset).
    fn nextCharBoundary(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var i = pos + 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) {
            i += 1;
        }
        return i;
    }

    /// Snap a byte offset to a valid UTF-8 character boundary.
    /// Moves backward if pos lands on a continuation byte.
    fn snapToCharBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        if (pos >= text.len) return text.len;
        if ((text[pos] & 0xC0) != 0x80) return pos;
        return prevCharBoundary(text, pos);
    }

    /// Find previous word boundary (byte offset).
    fn prevWordBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i = prevCharBoundary(text, pos);
        // If currently on whitespace, skip to non-whitespace.
        const in_ws = std.ascii.isWhitespace(text[i]);
        while (i > 0) {
            const prev = prevCharBoundary(text, i);
            const is_ws = std.ascii.isWhitespace(text[prev]);
            if (is_ws != in_ws) break;
            i = prev;
        }
        return i;
    }

    /// Find next word boundary (byte offset).
    fn nextWordBoundary(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var i = nextCharBoundary(text, pos);
        // If currently on whitespace, skip to non-whitespace.
        const in_ws = if (i < text.len) std.ascii.isWhitespace(text[i]) else true;
        while (i < text.len) {
            const next = nextCharBoundary(text, i);
            const is_ws = if (next < text.len) std.ascii.isWhitespace(text[next]) else true;
            if (is_ws != in_ws) break;
            i = next;
        }
        return i;
    }

    // =========================================================================
    // Selection Helpers
    // =========================================================================

    /// Returns true if there's an active selection (anchor != cursor).
    pub fn hasSelection(self: *const Self) bool {
        if (self.selection_anchor_line == null) return false;
        const al = self.selection_anchor_line.?;
        const ac = self.selection_anchor_col.?;
        return al != self.cursor_line or ac != self.cursor_col;
    }

    /// Returns the selection start as {line, col} (min of anchor/cursor in document order).
    pub fn selectionStartLine(self: *const Self) usize {
        if (self.selection_anchor_line == null) return self.cursor_line;
        const al = self.selection_anchor_line.?;
        if (al < self.cursor_line) return al;
        if (al > self.cursor_line) return self.cursor_line;
        // Same line
        return self.cursor_line;
    }

    pub fn selectionStartCol(self: *const Self) usize {
        if (self.selection_anchor_line == null) return self.cursor_col;
        const al = self.selection_anchor_line.?;
        if (al < self.cursor_line) return self.selection_anchor_col.?;
        if (al > self.cursor_line) return self.cursor_col;
        return @min(self.selection_anchor_col.?, self.cursor_col);
    }

    /// Returns the selection end as {line, col} (max of anchor/cursor in document order).
    pub fn selectionEndLine(self: *const Self) usize {
        if (self.selection_anchor_line == null) return self.cursor_line;
        const al = self.selection_anchor_line.?;
        if (al > self.cursor_line) return al;
        return self.cursor_line;
    }

    pub fn selectionEndCol(self: *const Self) usize {
        if (self.selection_anchor_line == null) return self.cursor_col;
        const al = self.selection_anchor_line.?;
        if (al > self.cursor_line) return self.selection_anchor_col.?;
        if (al < self.cursor_line) return self.cursor_col;
        return @max(self.selection_anchor_col.?, self.cursor_col);
    }

    /// Clear the current selection (set anchor to null).
    fn clearSelection(self: *Self) void {
        self.selection_anchor_line = null;
        self.selection_anchor_col = null;
    }

    /// Start a selection at the current cursor position.
    fn startSelection(self: *Self) void {
        self.selection_anchor_line = self.cursor_line;
        self.selection_anchor_col = self.cursor_col;
    }

    /// Delete selected text. Returns true if text was deleted.
    fn deleteSelection(self: *Self) bool {
        if (!self.hasSelection()) return false;

        const start_line = self.selectionStartLine();
        const start_col = self.selectionStartCol();
        const end_line = self.selectionEndLine();
        const end_col = self.selectionEndCol();

        if (start_line == end_line) {
            // Single-line selection: remove bytes from start_col to end_col.
            const line = &self.lines.items[start_line];
            var removed: usize = 0;
            const count = end_col - start_col;
            while (removed < count) : (removed += 1) {
                _ = line.orderedRemove(start_col);
            }
            self.tokenizeLine(start_line);
        } else {
            // Multi-line selection: merge start_line prefix with end_line suffix.
            const start_line_buf = &self.lines.items[start_line];
            const end_line_buf = &self.lines.items[end_line];

            // Build merged content: prefix of start_line + suffix of end_line.
            var merged = std.ArrayListUnmanaged(u8){};
            merged.appendSlice(self.allocator, start_line_buf.items[0..start_col]) catch {};
            merged.appendSlice(self.allocator, end_line_buf.items[end_col..]) catch {};

            // Replace start_line with merged content.
            start_line_buf.clearRetainingCapacity();
            start_line_buf.appendSlice(self.allocator, merged.items) catch {};
            merged.deinit(self.allocator);

            // Remove lines between start_line+1 and end_line (inclusive).
            var i: usize = end_line;
            while (i > start_line) : (i -= 1) {
                var removed_line = self.lines.orderedRemove(i);
                removed_line.deinit(self.allocator);
                var removed_tokens = self.line_tokens.orderedRemove(i);
                removed_tokens.deinit(self.allocator);
            }

            // Remove tokens for deleted lines.
            self.tokenizeLine(start_line);
        }

        // Move cursor to selection start.
        self.cursor_line = start_line;
        self.cursor_col = start_col;
        self.clearSelection();
        return true;
    }

    pub fn handleKeyPress(self: *Self, key: wio.Button) void {
        const line = &self.lines.items[self.cursor_line];
        switch (key) {
            .left => {
                // Ctrl+Left: zum vorherigen Wort springen
                if (self.ctrl_pressed) {
                    if (self.shift_pressed) {
                        if (!self.hasSelection()) self.startSelection();
                    } else {
                        if (self.hasSelection()) {
                            self.cursor_line = self.selectionStartLine();
                            self.cursor_col = self.selectionStartCol();
                            self.clearSelection();
                            self.recordCursorMovement();
                            self.current_line = self.cursor_line + 1;
                            return;
                        }
                    }
                    if (self.cursor_col > 0) {
                        self.cursor_col = prevWordBoundary(line.items, self.cursor_col);
                    } else if (self.cursor_line > 0) {
                        self.cursor_line -= 1;
                        self.cursor_col = self.lines.items[self.cursor_line].items.len;
                    }
                } else if (self.shift_pressed) {
                    if (!self.hasSelection()) self.startSelection();
                    if (self.cursor_col > 0) {
                        self.cursor_col = prevCharBoundary(line.items, self.cursor_col);
                    } else if (self.cursor_line > 0) {
                        self.cursor_line -= 1;
                        self.cursor_col = self.lines.items[self.cursor_line].items.len;
                    }
                } else {
                    if (self.hasSelection()) {
                        self.cursor_line = self.selectionStartLine();
                        self.cursor_col = self.selectionStartCol();
                        self.clearSelection();
                        self.recordCursorMovement();
                        self.current_line = self.cursor_line + 1;
                        return;
                    }
                    if (self.cursor_col > 0) {
                        self.cursor_col = prevCharBoundary(line.items, self.cursor_col);
                    } else if (self.cursor_line > 0) {
                        self.cursor_line -= 1;
                        self.cursor_col = self.lines.items[self.cursor_line].items.len;
                    }
                }
            },
            .right => {
                // Ctrl+Right: zum nächsten Wort springen
                if (self.ctrl_pressed) {
                    if (self.shift_pressed) {
                        if (!self.hasSelection()) self.startSelection();
                    } else {
                        if (self.hasSelection()) {
                            self.cursor_line = self.selectionEndLine();
                            self.cursor_col = self.selectionEndCol();
                            self.clearSelection();
                            self.recordCursorMovement();
                            self.current_line = self.cursor_line + 1;
                            return;
                        }
                    }
                    if (self.cursor_col < line.items.len) {
                        self.cursor_col = nextWordBoundary(line.items, self.cursor_col);
                    } else if (self.cursor_line + 1 < self.lines.items.len) {
                        self.cursor_line += 1;
                        self.cursor_col = 0;
                    }
                } else if (self.shift_pressed) {
                    if (!self.hasSelection()) self.startSelection();
                    if (self.cursor_col < line.items.len) {
                        self.cursor_col = nextCharBoundary(line.items, self.cursor_col);
                    } else if (self.cursor_line + 1 < self.lines.items.len) {
                        self.cursor_line += 1;
                        self.cursor_col = 0;
                    }
                } else {
                    if (self.hasSelection()) {
                        self.cursor_line = self.selectionEndLine();
                        self.cursor_col = self.selectionEndCol();
                        self.clearSelection();
                        self.recordCursorMovement();
                        self.current_line = self.cursor_line + 1;
                        return;
                    }
                    if (self.cursor_col < line.items.len) {
                        self.cursor_col = nextCharBoundary(line.items, self.cursor_col);
                    } else if (self.cursor_line + 1 < self.lines.items.len) {
                        self.cursor_line += 1;
                        self.cursor_col = 0;
                    }
                }
            },
            .up => {
                if (self.shift_pressed) {
                    if (!self.hasSelection()) self.startSelection();
                } else {
                    if (self.hasSelection()) {
                        self.cursor_line = self.selectionStartLine();
                        self.cursor_col = self.selectionStartCol();
                        self.clearSelection();
                        self.recordCursorMovement();
                        self.current_line = self.cursor_line + 1;
                        return;
                    }
                }
                if (self.cursor_line > 0) {
                    self.cursor_line -= 1;
                    const target = self.lines.items[self.cursor_line].items;
                    self.cursor_col = snapToCharBoundary(target, @min(self.cursor_col, target.len));
                }
            },
            .down => {
                if (self.shift_pressed) {
                    if (!self.hasSelection()) self.startSelection();
                } else {
                    if (self.hasSelection()) {
                        self.cursor_line = self.selectionEndLine();
                        self.cursor_col = self.selectionEndCol();
                        self.clearSelection();
                        self.recordCursorMovement();
                        self.current_line = self.cursor_line + 1;
                        return;
                    }
                }
                if (self.cursor_line + 1 < self.lines.items.len) {
                    self.cursor_line += 1;
                    const target = self.lines.items[self.cursor_line].items;
                    self.cursor_col = snapToCharBoundary(target, @min(self.cursor_col, target.len));
                }
            },
            .home => {
                if (self.shift_pressed) {
                    if (!self.hasSelection()) self.startSelection();
                } else {
                    if (self.hasSelection()) {
                        self.cursor_col = self.selectionStartCol();
                        self.clearSelection();
                        self.recordCursorMovement();
                        self.current_line = self.cursor_line + 1;
                        return;
                    }
                }
                self.cursor_col = 0;
            },
            .end => {
                if (self.shift_pressed) {
                    if (!self.hasSelection()) self.startSelection();
                } else {
                    if (self.hasSelection()) {
                        self.cursor_col = self.selectionEndCol();
                        self.clearSelection();
                        self.recordCursorMovement();
                        self.current_line = self.cursor_line + 1;
                        return;
                    }
                }
                self.cursor_col = self.lines.items[self.cursor_line].items.len;
            },
            .backspace => {
                if (self.deleteSelection()) {
                    self.recordCursorMovement();
                    self.current_line = self.cursor_line + 1;
                } else if (self.cursor_col > 0) {
                    // Remove entire UTF-8 character before cursor.
                    const char_start = prevCharBoundary(line.items, self.cursor_col);
                    const byte_count = self.cursor_col - char_start;
                    var removed: usize = 0;
                    while (removed < byte_count) : (removed += 1) {
                        _ = line.orderedRemove(char_start);
                    }
                    self.cursor_col = char_start;
                    self.tokenizeLine(self.cursor_line);
                    self.recordCursorMovement();
                    self.current_line = self.cursor_line + 1;
                } else if (self.cursor_line > 0) {
                    // Merge with previous line.
                    const prev_line_idx = self.cursor_line - 1;
                    const prev_len = self.lines.items[prev_line_idx].items.len;
                    self.lines.items[prev_line_idx].appendSlice(self.allocator, line.items) catch {};
                    var removed_line = self.lines.orderedRemove(self.cursor_line);
                    removed_line.deinit(self.allocator);

                    var removed_tokens = self.line_tokens.orderedRemove(self.cursor_line);
                    removed_tokens.deinit(self.allocator);

                    self.cursor_line = prev_line_idx;
                    self.cursor_col = prev_len;
                    self.tokenizeLine(self.cursor_line);
                    self.recordCursorMovement();
                    self.current_line = self.cursor_line + 1;
                }
            },
            .delete => {
                if (self.deleteSelection()) {
                    self.recordCursorMovement();
                    self.current_line = self.cursor_line + 1;
                } else if (self.cursor_col < line.items.len) {
                    // Remove entire UTF-8 character at cursor.
                    const char_end = nextCharBoundary(line.items, self.cursor_col);
                    const byte_count = char_end - self.cursor_col;
                    var removed: usize = 0;
                    while (removed < byte_count) : (removed += 1) {
                        _ = line.orderedRemove(self.cursor_col);
                    }
                    self.tokenizeLine(self.cursor_line);
                } else if (self.cursor_line + 1 < self.lines.items.len) {
                    // Merge with next line.
                    const next_line_idx = self.cursor_line + 1;
                    line.appendSlice(self.allocator, self.lines.items[next_line_idx].items) catch {};
                    var removed_line = self.lines.orderedRemove(next_line_idx);
                    removed_line.deinit(self.allocator);

                    var removed_tokens = self.line_tokens.orderedRemove(next_line_idx);
                    removed_tokens.deinit(self.allocator);

                    self.tokenizeLine(self.cursor_line);
                }
            },
            .enter, .kp_enter => {
                // Split line
                var new_line = std.ArrayListUnmanaged(u8){};
                new_line.appendSlice(self.allocator, line.items[self.cursor_col..]) catch {};
                line.shrinkRetainingCapacity(self.cursor_col);

                self.lines.insert(self.allocator, self.cursor_line + 1, new_line) catch return;
                const new_tokens = std.ArrayListUnmanaged(Token){};
                self.line_tokens.insert(self.allocator, self.cursor_line + 1, new_tokens) catch return;

                self.tokenizeLine(self.cursor_line);
                self.tokenizeLine(self.cursor_line + 1);

                self.cursor_line += 1;
                self.cursor_col = 0;
            },
            else => {},
        }
        self.recordCursorMovement();
        self.current_line = self.cursor_line + 1;
    }

    /// Modifier-State aktualisieren (wird von main.zig aufgerufen)
    pub fn setShiftState(self: *Self, pressed: bool) void {
        self.shift_pressed = pressed;
    }

    pub fn setCtrlState(self: *Self, pressed: bool) void {
        self.ctrl_pressed = pressed;
    }

    // =========================================================================
    // Mouse Handling
    // =========================================================================

    /// Mausposition aktualisieren (wird von main.zig aufgerufen)
    pub fn updateMousePosition(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
    }

    /// Maus-Down Event verarbeiten
    pub fn handleMouseDown(self: *Self, x: f32, y: f32) void {
        const line_idx = self.lineFromY(y);
        const col = self.colFromX(x, line_idx);

        // Double-Click Erkennung (innerhalb 500ms)
        const is_double_click = (self.time_ms - self.last_mouse_click_ms < 500.0) and
            self.last_mouse_click_line == line_idx and
            self.last_mouse_click_col == col;

        if (is_double_click) {
            // Wort am Klickpunkt selektieren
            const line = self.lines.items[line_idx].items;
            const word_start = if (col < line.len and std.ascii.isAlphanumeric(line[col]))
                prevWordBoundary(line, col)
            else if (col > 0 and std.ascii.isAlphanumeric(line[col - 1]))
                prevWordBoundary(line, col)
            else
                col;
            const word_end = if (col < line.len and std.ascii.isAlphanumeric(line[col]))
                nextWordBoundary(line, col)
            else if (col > 0 and std.ascii.isAlphanumeric(line[col - 1]))
                nextWordBoundary(line, word_start)
            else
                col;

            self.cursor_line = line_idx;
            self.cursor_col = word_start;
            self.selection_anchor_line = line_idx;
            self.selection_anchor_col = word_end;
        } else {
            self.cursor_line = line_idx;
            self.cursor_col = col;
            self.selection_anchor_line = line_idx;
            self.selection_anchor_col = col;
        }

        self.mouse_down = true;
        self.last_mouse_click_ms = self.time_ms;
        self.last_mouse_click_line = line_idx;
        self.last_mouse_click_col = col;
        self.recordCursorMovement();
        self.current_line = self.cursor_line + 1;
    }

    /// Maus-Move Event verarbeiten (für Drag-Selektion)
    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        if (!self.mouse_down) return;
        const line_idx = self.lineFromY(y);
        const col = self.colFromX(x, line_idx);
        self.cursor_line = line_idx;
        self.cursor_col = col;
        // Anchor bleibt gesetzt von handleMouseDown
        self.ensureCursorVisible();
        self.current_line = self.cursor_line + 1;
    }

    /// Maus-Release Event verarbeiten
    pub fn handleMouseUp(self: *Self) void {
        self.mouse_down = false;
    }

    /// Y-Koordinate in Zeilen-Index umrechnen (mit Content-Offset und Scroll-Offset).
    fn lineFromY(self: *const Self, y: f32) usize {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return 0;
        // Relativ zum Editor-Content (Fenster-Y minus Content-Offset)
        const rel_y = y - self.content_origin_y;
        if (rel_y < 0) return 0;
        const raw_line = @as(isize, @intFromFloat(@floor(rel_y / line_height)));
        const line = raw_line + @as(isize, @intCast(self.scroll_offset_first_line));
        if (line < 0) return 0;
        return @min(@as(usize, @intCast(line)), self.lines.items.len - 1);
    }

    /// X-Koordinate in Spalte umrechnen (mit Content-Offset, echte Text-Messung).
    fn colFromX(self: *const Self, x: f32, line_idx: usize) usize {
        // Relativ zum Editor-Content, minus Gutter
        const rel_x = x - self.content_origin_x - self.gutter_width;
        if (rel_x <= 0) return 0;

        const line = self.lines.items[line_idx].items;
        if (line.len == 0) return 0;

        // Wenn Messfunktion vorhanden: linearer Scan mit echter Breite
        if (self.measure_fn) |measure| {
            var x_accum: f32 = 0.0;
            var byte_offset: usize = 0;
            while (byte_offset < line.len) {
                // UTF-8: bestimme nächste Byte-Grenze
                var next_offset = byte_offset + 1;
                while (next_offset < line.len and (line[next_offset] & 0xC0) == 0x80) {
                    next_offset += 1;
                }
                const char_w = measure(@ptrCast(line.ptr + byte_offset), next_offset - byte_offset);
                if (rel_x < x_accum + char_w) {
                    return byte_offset;
                }
                x_accum += char_w;
                byte_offset = next_offset;
            }
            // Klick nach letztem Zeichen
            return line.len;
        }

        // Fallback: grobe Schätzung
        const char_width: f32 = @as(f32, @floatFromInt(self.font_size)) * 0.6;
        if (char_width <= 0) return 0;
        const col_f = @as(isize, @intFromFloat(@floor(rel_x / char_width)));
        if (col_f < 0) return 0;
        return @min(@as(usize, @intCast(col_f)), line.len);
    }

    // =========================================================================
    // Scrolling
    // =========================================================================

    /// Scroll-Offset aktualisieren (Mausrad). Zeilen-basiert.
    pub fn scrollLines(self: *Self, delta: i32) void {
        if (delta > 0) {
            // Scroll up: mehr Zeilen oben sichtbar
            const amount = @as(usize, @intCast(delta));
            self.scroll_offset_first_line = if (amount > self.scroll_offset_first_line)
                0
            else
                self.scroll_offset_first_line - amount;
        } else if (delta < 0) {
            // Scroll down: Zeilen unten verschwinden
            const amount = @as(usize, @intCast(-delta));
            const max_offset = if (self.lines.items.len > self.visibleLineCount())
                self.lines.items.len - self.visibleLineCount()
            else
                0;
            const new_offset = self.scroll_offset_first_line + amount;
            self.scroll_offset_first_line = @min(new_offset, max_offset);
        }
    }

    /// Anzahl sichtbarer Zeilen basierend auf Container-Höhe.
    fn visibleLineCount(self: *const Self) usize {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return 10;
        // height ist die Editor-Höhe (ganze Fensterhöhe)
        const available = self.height;
        if (available <= 0) return 10;
        return @max(1, @as(usize, @intFromFloat(@floor(available / line_height))));
    }

    /// Sicherstellen dass der Cursor sichtbar ist (Auto-Scroll).
    pub fn ensureCursorVisible(self: *Self) void {
        const visible = self.visibleLineCount();
        const total = self.lines.items.len;
        if (total <= visible) {
            self.scroll_offset_first_line = 0;
            return;
        }

        // Cursor unterhalb des sichtbaren Bereichs?
        const cursor_visible_line = self.cursor_line;
        if (cursor_visible_line >= self.scroll_offset_first_line + visible) {
            // Nach unten scrollen
            self.scroll_offset_first_line = cursor_visible_line - visible + 1;
        }
        // Cursor oberhalb des sichtbaren Bereichs?
        if (cursor_visible_line < self.scroll_offset_first_line) {
            self.scroll_offset_first_line = cursor_visible_line;
        }

        // Clamp
        const max_offset = total - visible;
        self.scroll_offset_first_line = @min(self.scroll_offset_first_line, max_offset);
    }

    pub fn handleChar(self: *Self, char_code: u21) void {
        // Ignoriere Steuerzeichen
        if (char_code < 32 or char_code == 127) return;

        // Ersetze Selektion falls vorhanden
        if (self.deleteSelection()) {
            // Cursor steht jetzt am Selektionsanfang
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char_code, &buf) catch return;

        const line = &self.lines.items[self.cursor_line];
        line.insertSlice(self.allocator, self.cursor_col, buf[0..len]) catch return;
        self.cursor_col += len;
        self.recordCursorMovement();
        self.tokenizeLine(self.cursor_line);
    }

    pub fn render(self: *Self, arena: std.mem.Allocator) void {
        // Editor Container
        clay.UI()(.{
            .id = clay.ElementId.ID("code_editor"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right,
            },
            .background_color = self.bg_color,
        })({
            // Links: Scrollbarer Content
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
                    const visible_count = self.visibleLineCount();
                    const start_line = @min(self.scroll_offset_first_line, self.lines.items.len);
                    const end_line = @min(start_line + visible_count + 1, self.lines.items.len);

                    var i: usize = start_line;
                    while (i < end_line) : (i += 1) {
                        const line = self.lines.items[i].items;
                        const is_current = (i == self.cursor_line);

                        const is_selected = if (self.hasSelection()) blk: {
                            const sl = self.selectionStartLine();
                            const el = self.selectionEndLine();
                            break :blk i >= sl and i <= el;
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
                                .background_color = if (is_current) self.current_line_highlight else if (is_selected) self.selection_color else self.gutter_color,
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
                                .background_color = if (is_current and !is_selected) self.current_line_highlight else if (is_selected) self.selection_color else .{ 0, 0, 0, 0 },
                            })({
                                self.renderLine(i, line);
                            });
                        });
                    }
                });
            });

            // Rechts: Scrollbar
            if (self.lines.items.len > self.visibleLineCount()) {
                self.renderScrollbar();
            }
        });
    }

    fn renderScrollbar(self: *Self) void {
        const total = self.lines.items.len;
        const visible = self.visibleLineCount();
        if (total <= visible) return;

        const track_height = self.height;
        const thumb_ratio: f32 = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
        const thumb_height = @max(20.0, track_height * thumb_ratio);
        const max_offset: usize = total - visible;
        const scroll_frac: f32 = if (max_offset > 0)
            @as(f32, @floatFromInt(self.scroll_offset_first_line)) / @as(f32, @floatFromInt(max_offset))
        else
            0.0;
        const thumb_y = scroll_frac * (track_height - thumb_height);

        const track_color: clay.Color = .{ 30, 30, 46, 100 };
        const thumb_color: clay.Color = .{ 88, 88, 120, 180 };

        // Track (Hintergrund)
        clay.UI()(.{
            .id = clay.ElementId.ID("scrollbar_track"),
            .layout = .{
                .sizing = .{ .w = .fixed(self.scrollbar_width), .h = .fit },
            },
            .background_color = track_color,
        })({
            // Thumb (beweglicher Teil)
            clay.UI()(.{
                .id = clay.ElementId.ID("scrollbar_thumb"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(thumb_height) },
                    .padding = .{ .top = @intFromFloat(thumb_y) },
                },
                .background_color = thumb_color,
            })({});
        });
    }

    fn renderLine(self: *Self, line_idx: usize, line: []const u8) void {
        const tokens = self.line_tokens.items[line_idx].items;

        clay.UI()(.{
            .layout = .{ .direction = .left_to_right, .child_alignment = .{ .x = .left, .y = .center } },
        })({
            if (tokens.len == 0) {
                clay.text(line, .{ .font_size = self.font_size, .color = .{ 202, 211, 245, 255 } });
                // Cursor bei leerer Zeile
                if (line_idx == self.cursor_line) {
                    self.renderCursor(0);
                }
            } else {
                // WICHTIG: Text NICHT splitten!
                // Alle Tokens komplett rendern
                for (tokens) |token| {
                    const color = self.highlighter.colorForType(token.token_type);
                    const slice = token.slice(line);
                    clay.text(slice, .{ .font_size = self.font_size, .color = color });
                }

                // Cursor als floating element über dem Text
                // Funktioniert nur, wenn der Font monospace ist!
                if (line_idx == self.cursor_line) {
                    self.renderCursor(line.len);
                }
            }
        });
    }

    fn renderCursor(self: *Self, _: usize) void {
        const blink_ms: f32 = 500.0;
        const blink_delay_ms: f32 = 400.0; // Cursor bleibt sichtbar für 400ms nach Bewegung
        
        // Prüfen ob Cursor sich gerade bewegt (Blink-Delay)
        const time_since_movement = self.time_ms - self.last_cursor_movement_ms;
        const is_moving = time_since_movement < blink_delay_ms;
        
        // Blink-Logik: sichtbar wenn sich bewegend ODER in der sichtbaren Blink-Phase
        const visible = is_moving or (@mod(self.time_ms, blink_ms * 2.0) < blink_ms);
        if (!visible) return;

        // Text vor dem Cursor extrahieren
        const line = self.lines.items[self.cursor_line].items;
        const text_before_cursor = if (self.cursor_col <= line.len) 
            line[0..self.cursor_col] 
        else 
            line;

        // Floating Container mit 0 Breite im Parent-Layout
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(@floatFromInt(self.font_size + 16)) } },
            .floating = .{
                .attach_to = .to_parent,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = .{ .x = 0, .y = 0 },
            },
        })({
            // Innerer Container: misst Text-Breite mit .fit
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fit, .h = .grow }, .direction = .left_to_right },
            })({
                // Unsichtbaren Text rendern für das Width-Measuring
                clay.text(text_before_cursor, .{ 
                    .font_size = self.font_size, 
                    .color = .{ 0, 0, 0, 0 },
                });
                
                // Cursor am Ende des gemessenen Textes
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fixed(1), .h = .grow } },
                    .background_color = self.cursor_color,
                })({});
            });
        });
    }
};

test "CodeEditor: basic interaction" {
    const allocator = std.testing.allocator;
    var editor_inst = CodeEditor.init(allocator);
    defer editor_inst.deinit();

    editor_inst.setText("hello");

    // Test char insertion
    editor_inst.cursor_col = 5;
    editor_inst.handleChar('!');
    try std.testing.expectEqualStrings("hello!", editor_inst.lines.items[0].items);

    // Test enter
    editor_inst.handleKeyPress(.enter);
    try std.testing.expectEqual(@as(usize, 2), editor_inst.lines.items.len);
    try std.testing.expectEqualStrings("hello!", editor_inst.lines.items[0].items);
    try std.testing.expectEqualStrings("", editor_inst.lines.items[1].items);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.cursor_line);
    try std.testing.expectEqual(@as(usize, 0), editor_inst.cursor_col);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // This will crash if Clay isn't initialized, but maybe we can just see if it panics?
    // Actually clay is just a C library, calling clay.UI() without init might crash.
    // Let's just tokenizeLine to see if it panics.
    editor_inst.tokenizeLine(0);
    editor_inst.tokenizeLine(1);

    // Test delete/backspace
    editor_inst.handleKeyPress(.backspace);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.lines.items.len);
    try std.testing.expectEqualStrings("hello!", editor_inst.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 0), editor_inst.cursor_line);
    try std.testing.expectEqual(@as(usize, 6), editor_inst.cursor_col);
}

test "CodeEditor: auto-typing simulation" {
    const allocator = std.testing.allocator;
    var editor_inst = CodeEditor.init(allocator);
    defer editor_inst.deinit();

    // Simulation: "pub fn main() {" tippen
    const input = "pub fn main() {";
    for (input) |c| {
        editor_inst.handleChar(c);
    }
    try std.testing.expectEqualStrings("pub fn main() {", editor_inst.lines.items[0].items);

    // Enter drücken
    editor_inst.handleKeyPress(.enter);
    try std.testing.expectEqual(@as(usize, 2), editor_inst.lines.items.len);

    // In der neuen Zeile einrücken und kommentieren
    const line2 = "    // test";
    for (line2) |c| {
        editor_inst.handleChar(c);
    }
    try std.testing.expectEqualStrings("    // test", editor_inst.lines.items[1].items);
}

test "CodeEditor: Umlaut-Eingabe und UTF-8-Navigation" {
    const allocator = std.testing.allocator;
    var editor_inst = CodeEditor.init(allocator);
    defer editor_inst.deinit();

    // "hällo" tippen: h, ä, l, l, o
    editor_inst.handleChar('h');
    editor_inst.handleChar(0xE4); // ä
    editor_inst.handleChar('l');
    editor_inst.handleChar('l');
    editor_inst.handleChar('o');
    // "hällo" = h(1) + ä(2) + l(1) + l(1) + o(1) = 6 Bytes
    try std.testing.expectEqualStrings("h\xC3\xA4llo", editor_inst.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 6), editor_inst.cursor_col);

    // Links navigieren: von Ende(6) zurück zu 'o'(5)
    editor_inst.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 5), editor_inst.cursor_col);

    // Nochmal links: von 'o'(5) zu zweitem 'l'(4)
    editor_inst.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 4), editor_inst.cursor_col);

    // Nochmal links: von zweitem 'l'(4) zu erstem 'l'(3)
    editor_inst.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 3), editor_inst.cursor_col);

    // Nochmal links: über ä (2 Bytes, Pos 1-2) → vor ä(1)
    editor_inst.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.cursor_col);

    // Nochmal links: von ä(1) zu 'h'(0)
    editor_inst.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 0), editor_inst.cursor_col);

    // Rechts: von 'h'(0) über... nein, nextCharBoundary(0) = 1 (ä Start)
    editor_inst.handleKeyPress(.right);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.cursor_col);

    // Rechts: über ä (2 Bytes) zum ersten 'l'(3)
    editor_inst.handleKeyPress(.right);
    try std.testing.expectEqual(@as(usize, 3), editor_inst.cursor_col);

    // Backspace: von 'l'(3) → ä (2 Bytes) löschen
    editor_inst.handleKeyPress(.backspace);
    try std.testing.expectEqualStrings("hllo", editor_inst.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.cursor_col);

    // ö einfügen an Position 1
    editor_inst.handleChar(0xF6); // ö
    try std.testing.expectEqualStrings("h\xC3\xB6llo", editor_inst.lines.items[0].items);

    // Delete: ö mit Delete vorwärts löschen
    // Cursor steht nach ö (Pos 3), zurück navigieren
    editor_inst.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.cursor_col);
    // Delete löscht ö (2 Bytes)
    editor_inst.handleKeyPress(.delete);
    try std.testing.expectEqualStrings("hllo", editor_inst.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.cursor_col);
}

test "CodeEditor: Up/Down mit Umlaut snapped auf Zeichengrenze" {
    const allocator = std.testing.allocator;
    var editor_inst = CodeEditor.init(allocator);
    defer editor_inst.deinit();

    // Zeile 0: "ab" (2 Bytes)
    // Zeile 1: "äx" (3 Bytes: ä=2 + x=1)
    editor_inst.setText("ab\näx");
    try std.testing.expectEqual(@as(usize, 2), editor_inst.lines.items.len);

    // Cursor auf Zeile 0, Spalte 1 (zwischen a und b)
    editor_inst.cursor_line = 0;
    editor_inst.cursor_col = 1;

    // Down: Zeile 1, cursor_col=1 wäre mitten in ä → muss auf 0 snappen
    editor_inst.handleKeyPress(.down);
    try std.testing.expectEqual(@as(usize, 1), editor_inst.cursor_line);
    try std.testing.expectEqual(@as(usize, 0), editor_inst.cursor_col);
}

test "CodeEditor: Tokenizer erfasst UTF-8 Zeichen als Token" {
    const allocator = std.testing.allocator;
    var editor_inst = CodeEditor.init(allocator);
    defer editor_inst.deinit();

    // "ä" eingeben — muss als Token tokenisiert werden, damit es gerendert wird.
    editor_inst.handleChar(0xE4); // ä
    try std.testing.expectEqualStrings("\xC3\xA4", editor_inst.lines.items[0].items);

    const tokens = editor_inst.line_tokens.items[0].items;
    try std.testing.expect(tokens.len > 0);
    // Token muss die gesamten 2 Bytes des Umlauts abdecken.
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 2), tokens[0].end);
}

// =========================================================================
// Phase 8: Erweiterte Tests
// =========================================================================

test "Tokenizer: alle Token-Typen vollständig abgedeckt" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("const x = 42; // hi \"s\" $");
    const tokens = ed.line_tokens.items[0].items;

    // Jedes Byte muss von mindestens einem Token abgedeckt sein.
    const line = ed.lines.items[0].items;
    var covered = try allocator.alloc(bool, line.len);
    defer allocator.free(covered);
    @memset(covered, false);

    for (tokens) |tok| {
        for (tok.start..tok.end) |j| {
            covered[j] = true;
        }
    }
    for (covered, 0..) |c, idx| {
        if (!c) {
            std.debug.print("Byte {d} (0x{X:0>2}) nicht in Token!\n", .{ idx, line[idx] });
        }
        try std.testing.expect(c);
    }
}

test "Tokenizer: Keywords, Strings, Kommentare, Zahlen, Punctuation" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("pub fn main() { return 42; } // done");
    const tokens = ed.line_tokens.items[0].items;

    // Erste Token-Typen prüfen
    // "pub" → keyword
    try std.testing.expectEqual(TokenType.keyword, tokens[0].token_type);
    try std.testing.expectEqualStrings("pub", tokens[0].slice(ed.lines.items[0].items));

    // " " → plain (whitespace)
    try std.testing.expectEqual(TokenType.plain, tokens[1].token_type);

    // "fn" → keyword
    try std.testing.expectEqual(TokenType.keyword, tokens[2].token_type);

    // Finde "42" → number
    var found_number = false;
    for (tokens) |tok| {
        if (tok.token_type == .number) {
            try std.testing.expectEqualStrings("42", tok.slice(ed.lines.items[0].items));
            found_number = true;
        }
    }
    try std.testing.expect(found_number);

    // Finde "// done" → comment (letztes Token)
    const last = tokens[tokens.len - 1];
    try std.testing.expectEqual(TokenType.comment, last.token_type);
    try std.testing.expectEqualStrings("// done", last.slice(ed.lines.items[0].items));
}

test "Tokenizer: Sonderzeichen werden nicht verschluckt" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    // Zeichen die früher im Fallthrough verloren gingen
    ed.setText("$#`\\");
    const tokens = ed.line_tokens.items[0].items;

    // Jedes Zeichen muss ein Token haben
    try std.testing.expect(tokens.len >= 4);

    // Gesamtabdeckung: Start des ersten = 0, Ende des letzten = len
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(ed.lines.items[0].items.len, tokens[tokens.len - 1].end);
}

test "Tokenizer: String-Literal mit Escape-Sequences" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("x = \"hello\\nworld\"");
    const tokens = ed.line_tokens.items[0].items;

    // Finde String-Token — muss komplett sein inkl. Escapes
    var found_string = false;
    for (tokens) |tok| {
        if (tok.token_type == .string) {
            try std.testing.expectEqualStrings("\"hello\\nworld\"", tok.slice(ed.lines.items[0].items));
            found_string = true;
        }
    }
    try std.testing.expect(found_string);
}

test "setText: CRLF wird zu LF normalisiert" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("line1\r\nline2\r\nline3");
    try std.testing.expectEqual(@as(usize, 3), ed.lines.items.len);
    try std.testing.expectEqualStrings("line1", ed.lines.items[0].items);
    try std.testing.expectEqualStrings("line2", ed.lines.items[1].items);
    try std.testing.expectEqualStrings("line3", ed.lines.items[2].items);
}

test "setText: leerer String erzeugt eine leere Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("");
    try std.testing.expectEqual(@as(usize, 1), ed.lines.items.len);
    try std.testing.expectEqualStrings("", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);
}

test "Enter mitten in der Zeile splittet korrekt" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abcdef");
    ed.cursor_col = 3; // zwischen 'c' und 'd'
    ed.handleKeyPress(.enter);

    try std.testing.expectEqual(@as(usize, 2), ed.lines.items.len);
    try std.testing.expectEqualStrings("abc", ed.lines.items[0].items);
    try std.testing.expectEqualStrings("def", ed.lines.items[1].items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);
}

test "Enter bei UTF-8 Zeichen splittet an Byte-Grenze" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("aäb"); // a(1) + ä(2) + b(1) = 4 Bytes
    ed.cursor_col = 3; // nach ä, vor b
    ed.handleKeyPress(.enter);

    try std.testing.expectEqual(@as(usize, 2), ed.lines.items.len);
    try std.testing.expectEqualStrings("a\xC3\xA4", ed.lines.items[0].items);
    try std.testing.expectEqualStrings("b", ed.lines.items[1].items);
}

test "Backspace am Zeilenanfang mergt mit vorheriger Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor_line = 1;
    ed.cursor_col = 0;
    ed.handleKeyPress(.backspace);

    try std.testing.expectEqual(@as(usize, 1), ed.lines.items.len);
    try std.testing.expectEqualStrings("abcdef", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor_col);
}

test "Delete am Zeilenende mergt mit nächster Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor_line = 0;
    ed.cursor_col = 3; // am Ende von "abc"
    ed.handleKeyPress(.delete);

    try std.testing.expectEqual(@as(usize, 1), ed.lines.items.len);
    try std.testing.expectEqualStrings("abcdef", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor_col);
}

test "Navigation: Left am Zeilenanfang springt ans Ende der vorherigen Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor_line = 1;
    ed.cursor_col = 0;
    ed.handleKeyPress(.left);

    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor_col);
}

test "Navigation: Right am Zeilenende springt an Anfang der nächsten Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor_line = 0;
    ed.cursor_col = 3;
    ed.handleKeyPress(.right);

    try std.testing.expectEqual(@as(usize, 1), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);
}

test "Navigation: Home und End" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello world");
    ed.cursor_col = 5;

    ed.handleKeyPress(.home);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);

    ed.handleKeyPress(.end);
    try std.testing.expectEqual(@as(usize, 11), ed.cursor_col);
}

test "Navigation: Left/Right an Dateigrenzen bleiben stehen" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc");

    // Left am Dateianfang → bleibt
    ed.cursor_col = 0;
    ed.cursor_line = 0;
    ed.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);

    // Right am Dateiende → bleibt
    ed.cursor_col = 3;
    ed.handleKeyPress(.right);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor_col);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);
}

test "Navigation: Up/Down an Dateigrenzen bleiben stehen" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc\ndef");

    // Up auf erster Zeile → bleibt
    ed.cursor_line = 0;
    ed.handleKeyPress(.up);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);

    // Down auf letzter Zeile → bleibt
    ed.cursor_line = 1;
    ed.handleKeyPress(.down);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor_line);
}

test "Navigation: Up/Down clamp auf kürzere Zeile" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("longline\nab\nlongline");
    ed.cursor_line = 0;
    ed.cursor_col = 7; // weit rechts

    ed.handleKeyPress(.down); // → "ab" (len=2), col clamp auf 2
    try std.testing.expectEqual(@as(usize, 1), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor_col);

    ed.handleKeyPress(.down); // → "longline" (len=8), col bleibt 2
    try std.testing.expectEqual(@as(usize, 2), ed.cursor_line);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor_col);
}

test "Einfügen am Zeilenanfang und -ende" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("bc");

    // Am Anfang einfügen
    ed.cursor_col = 0;
    ed.handleChar('a');
    try std.testing.expectEqualStrings("abc", ed.lines.items[0].items);

    // Am Ende einfügen
    ed.cursor_col = 3;
    ed.handleChar('d');
    try std.testing.expectEqualStrings("abcd", ed.lines.items[0].items);
}

test "Steuerzeichen werden ignoriert" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc");
    ed.cursor_col = 1;

    // NULL, BEL, DEL — dürfen nichts einfügen
    ed.handleChar(0);
    ed.handleChar(7);
    ed.handleChar(127);
    try std.testing.expectEqualStrings("abc", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor_col);
}

test "Mehrfach-Enter erzeugt leere Zeilen" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("a");
    ed.cursor_col = 1;

    ed.handleKeyPress(.enter);
    ed.handleKeyPress(.enter);
    ed.handleKeyPress(.enter);

    try std.testing.expectEqual(@as(usize, 4), ed.lines.items.len);
    try std.testing.expectEqualStrings("a", ed.lines.items[0].items);
    try std.testing.expectEqualStrings("", ed.lines.items[1].items);
    try std.testing.expectEqualStrings("", ed.lines.items[2].items);
    try std.testing.expectEqualStrings("", ed.lines.items[3].items);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor_line);
}

test "Blink-Delay wird bei Cursor-Bewegung zurückgesetzt" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc");
    ed.time_ms = 1000.0;

    ed.handleChar('x');
    try std.testing.expectEqual(@as(f32, 1000.0), ed.last_cursor_movement_ms);

    ed.time_ms = 2000.0;
    ed.handleKeyPress(.left);
    try std.testing.expectEqual(@as(f32, 2000.0), ed.last_cursor_movement_ms);
}

test "3-Byte UTF-8: Japanische Zeichen" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    // 日 = U+65E5 = 3 Bytes (0xE6, 0x97, 0xA5)
    ed.handleChar(0x65E5);
    ed.handleChar('a');

    try std.testing.expectEqualStrings("\xE6\x97\xA5a", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor_col);

    // Left über 'a' (1 Byte)
    ed.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor_col);

    // Left über 日 (3 Bytes)
    ed.handleKeyPress(.left);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);

    // Right über 日 (3 Bytes)
    ed.handleKeyPress(.right);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor_col);

    // Backspace löscht 日 komplett
    ed.handleKeyPress(.left);
    ed.handleKeyPress(.delete);
    try std.testing.expectEqualStrings("a", ed.lines.items[0].items);
}

test "4-Byte UTF-8: Emoji" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    // 😀 = U+1F600 = 4 Bytes
    ed.handleChar(0x1F600);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor_col);
    try std.testing.expectEqual(@as(usize, 4), ed.lines.items[0].items.len);

    // Backspace löscht alle 4 Bytes
    ed.handleKeyPress(.backspace);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);
    try std.testing.expectEqualStrings("", ed.lines.items[0].items);
}

// =========================================================================
// Selection Tests
// =========================================================================

test "Selection: Shift+Right erweitert Selektion" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello");
    ed.cursor_col = 0;

    ed.setShiftState(true);
    ed.handleKeyPress(.right); // h markiert
    try std.testing.expect(ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), ed.selectionStartCol());
    try std.testing.expectEqual(@as(usize, 1), ed.selectionEndCol());

    ed.handleKeyPress(.right); // he markiert
    try std.testing.expectEqual(@as(usize, 2), ed.selectionEndCol());
    ed.setShiftState(false);
}

test "Selection: Shift+Left erweitert Selektion rückwärts" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello");
    ed.cursor_col = 3; // bei 'l'

    ed.setShiftState(true);
    ed.handleKeyPress(.left); // hel → l markiert
    try std.testing.expect(ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 2), ed.selectionStartCol());
    try std.testing.expectEqual(@as(usize, 3), ed.selectionEndCol());
    ed.setShiftState(false);
}

test "Selection: Navigation ohne Shift löscht Selektion" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello world");
    ed.cursor_col = 0;
    ed.setShiftState(true);
    ed.handleKeyPress(.right);
    ed.handleKeyPress(.right); // "he" markiert
    try std.testing.expect(ed.hasSelection());

    // Ohne Shift: Selektion löschen + bewegen
    ed.setShiftState(false);
    ed.handleKeyPress(.right);
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor_col); // zum Selektionsende gesprungen
}

test "Selection: Backspace löscht markierten Text" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello");
    ed.cursor_col = 1;
    ed.setShiftState(true);
    ed.handleKeyPress(.right);
    ed.handleKeyPress(.right);
    ed.handleKeyPress(.right); // "hell" markiert (col 1-4)
    ed.setShiftState(false);

    ed.handleKeyPress(.backspace);
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqualStrings("ho", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor_col);
}

test "Selection: Delete löscht markierten Text" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello");
    ed.cursor_col = 0;
    ed.setShiftState(true);
    ed.handleKeyPress(.right);
    ed.handleKeyPress(.right); // "he" markiert (col 0-2)
    ed.setShiftState(false);

    ed.handleKeyPress(.delete);
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqualStrings("llo", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_col);
}

test "Selection: Tippen ersetzt markierten Text" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello");
    ed.cursor_col = 0;
    ed.setShiftState(true);
    ed.handleKeyPress(.right);
    ed.handleKeyPress(.right); // "he" markiert (col 0-2)
    ed.setShiftState(false);

    ed.handleChar('x');
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqualStrings("xllo", ed.lines.items[0].items);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor_col);
}

test "Selection: Shift+Up/Down multi-line Selektion" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc\ndef\nghi");
    ed.cursor_line = 0;
    ed.cursor_col = 1; // bei 'b'

    ed.setShiftState(true);
    ed.handleKeyPress(.down); // Zeile 1
    try std.testing.expect(ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), ed.selectionStartLine());
    try std.testing.expectEqual(@as(usize, 1), ed.selectionEndLine());

    ed.handleKeyPress(.down); // Zeile 2
    try std.testing.expectEqual(@as(usize, 2), ed.selectionEndLine());
    ed.setShiftState(false);
}

test "Selection: Mehrzeilige Selektion löschen" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("abc\ndef\nghi");
    ed.cursor_line = 0;
    ed.cursor_col = 1;
    ed.setShiftState(true);
    ed.handleKeyPress(.down); // Zeile 1 ("def"), col wird auf 1 gesnappt (da "abc" col=1)
    ed.handleKeyPress(.down); // Zeile 2 ("ghi"), col wird auf 1 gesnappt
    ed.setShiftState(false);

    // Anchor (0,1), Cursor (2,1) → "bc\ndef\ng" löschen
    ed.handleKeyPress(.backspace);
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 1), ed.lines.items.len);
    // "a" + "hi" = "ahi"
    try std.testing.expectEqualStrings("ahi", ed.lines.items[0].items);
}

test "Selection: Shift+Home und Shift+End" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello world");
    ed.cursor_col = 6; // bei 'w'

    ed.setShiftState(true);
    ed.handleKeyPress(.home);
    try std.testing.expect(ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), ed.selectionStartCol());
    try std.testing.expectEqual(@as(usize, 6), ed.selectionEndCol());

    // Weiter zu End — erweitert Selektion
    ed.handleKeyPress(.end);
    // Anchor bleibt bei 6, Cursor bei 11 → Selektion ist col 6-11
    try std.testing.expectEqual(@as(usize, 6), ed.selectionStartCol());
    try std.testing.expectEqual(@as(usize, 11), ed.selectionEndCol());
    ed.setShiftState(false);
}

test "Selection: Rückwärts selektieren (Anchor > Cursor)" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello");
    ed.cursor_col = 4; // bei erstem 'l' von rechts
    ed.setShiftState(true);
    ed.handleKeyPress(.left);
    ed.handleKeyPress(.left);
    ed.handleKeyPress(.left); // von col 4 auf col 1
    ed.setShiftState(false);

    try std.testing.expect(ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 1), ed.selectionStartCol());
    try std.testing.expectEqual(@as(usize, 4), ed.selectionEndCol());
}

test "Selection: Home ohne Shift auf Selektion springt zum Start" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("hello world");
    ed.cursor_col = 5;
    ed.setShiftState(true);
    ed.handleKeyPress(.end); // " world" markiert
    try std.testing.expect(ed.hasSelection());
    ed.setShiftState(false);

    ed.handleKeyPress(.home); // Soll zum Selektionsanfang (col 5)
    try std.testing.expect(!ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 5), ed.cursor_col);
}

// =========================================================================
// Scrolling Tests
// =========================================================================

test "Scrolling: Viewport Culling rendert nur sichtbare Zeilen" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    // 20 Zeilen erzeugen
    var buf: [16]u8 = undefined;
    var lines_text = std.ArrayList(u8).empty;
    defer lines_text.deinit(allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (i > 0) lines_text.append(allocator, '\n') catch {};
        const s = std.fmt.bufPrint(&buf, "line{}", .{i}) catch "";
        lines_text.appendSlice(allocator, s) catch {};
    }
    ed.setText(lines_text.items);

    // Default: scroll_offset = 0, visible ~9 Zeilen (height=400, line_height=40)
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_offset_first_line);
    const visible = ed.visibleLineCount();
    try std.testing.expect(visible >= 8 and visible <= 12);

    // 5 Zeilen runter scrollen (negatives delta = Content nach oben = offset erhöht)
    ed.scrollLines(-5);
    try std.testing.expectEqual(@as(usize, 5), ed.scroll_offset_first_line);

    // 3 Zeilen hoch scrollen (positives delta = Content nach unten = offset reduziert)
    ed.scrollLines(3);
    try std.testing.expectEqual(@as(usize, 2), ed.scroll_offset_first_line);
}

test "Scrolling: scrollLines clamp an Grenzen" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("a\nb\nc"); // 3 Zeilen

    // Runter scrollen über Ende hinaus
    ed.scrollLines(100);
    // Max offset = 3 - visible (mindestens 1)
    const max_offset = if (ed.lines.items.len > ed.visibleLineCount())
        ed.lines.items.len - ed.visibleLineCount()
    else
        0;
    try std.testing.expectEqual(max_offset, ed.scroll_offset_first_line);

    // Hoch scrollen über Anfang hinaus
    ed.scrollLines(-100);
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_offset_first_line);
}

test "Scrolling: Auto-Scroll wenn Cursor nach unten wandert" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    // Viele Zeilen erzeugen
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        if (i > 0) text.append(allocator, '\n') catch {};
        text.appendSlice(allocator, "x") catch {};
    }
    ed.setText(text.items);

    // Cursor auf Zeile 20 bewegen
    ed.cursor_line = 20;
    ed.ensureCursorVisible();

    // Scroll-Offset sollte jetzt so sein dass Zeile 20 sichtbar ist
    const visible = ed.visibleLineCount();
    try std.testing.expect(ed.scroll_offset_first_line <= 20);
    try std.testing.expect(ed.scroll_offset_first_line + visible > 20);
}

test "Scrolling: Auto-Scroll wenn Cursor nach oben wandert" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        if (i > 0) text.append(allocator, '\n') catch {};
        text.appendSlice(allocator, "x") catch {};
    }
    ed.setText(text.items);

    // Erst runter scrollen (negatives delta = offset erhöht)
    ed.scrollLines(-15);
    try std.testing.expect(ed.scroll_offset_first_line > 0);

    // Cursor nach oben bewegen
    ed.cursor_line = 0;
    ed.ensureCursorVisible();
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_offset_first_line);
}

test "Scrolling: setText reset scroll_offset" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    ed.setText("a\nb\nc\nd\ne");
    ed.scrollLines(10);

    ed.setText("new text");
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_offset_first_line);
}

test "Scrolling: Mouse-Drag Scrollt Auto" {
    const allocator = std.testing.allocator;
    var ed = CodeEditor.init(allocator);
    defer ed.deinit();

    // 30 Zeilen
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        if (i > 0) text.append(allocator, '\n') catch {};
        text.appendSlice(allocator, "x") catch {};
    }
    ed.setText(text.items);
    ed.height = 400; // ~9 visible lines

    // Mouse down bei Zeile 0
    ed.handleMouseDown(100, 20);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor_line);

    // Mouse move zu Zeile 25 (y = 25 * 40 = 1000)
    ed.handleMouseMove(100, 1000);
    try std.testing.expectEqual(@as(usize, 25), ed.cursor_line);

    // Auto-Scroll sollte Zeile 25 sichtbar machen
    const visible = ed.visibleLineCount();
    try std.testing.expect(ed.scroll_offset_first_line + visible > 25);
}
