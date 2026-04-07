//! Code Editor Component für vulkan-ed
//!
//! Code Editor mit Line Numbers, Syntax Highlighting, Cursor und Text Input.

const std = @import("std");
const clay = @import("clay");
const Highlighter = @import("highlighter.zig").Highlighter;
const Token = @import("highlighter.zig").Token;
const wio = @import("wio");

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

    /// Cursor Position
    cursor_line: usize = 0,
    cursor_col: usize = 0,

    /// Zeitpunkt der letzten Cursor-Bewegung (für Blink-Delay)
    last_cursor_movement_ms: f32 = 0,

    /// Layout
    height: f32 = 400,
    gutter_width: f32 = 50,
    font_size: u16 = 24,
    time_ms: f32 = 0,

    /// Farben
    bg_color: clay.Color = .{ 30, 30, 46, 255 },
    gutter_color: clay.Color = .{ 24, 24, 37, 255 },
    line_number_color: clay.Color = .{ 108, 112, 134, 255 },
    current_line_number_color: clay.Color = .{ 138, 173, 244, 255 },
    current_line_highlight: clay.Color = .{ 60, 70, 100, 200 },
    cursor_color: clay.Color = .{ 249, 226, 175, 255 },

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
        self.last_cursor_movement_ms = self.time_ms;
        self.current_line = 1;
    }

    /// Cursor-Bewegung registrieren (setzt Blink-Delay zurück)
    fn recordCursorMovement(self: *Self) void {
        self.last_cursor_movement_ms = self.time_ms;
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

            // Identifier oder Keyword
            if (std.ascii.isAlphabetic(line_text[ti]) or line_text[ti] == '_') {
                const tok_start = ti;
                while (ti < len and (std.ascii.isAlphanumeric(line_text[ti]) or line_text[ti] == '_')) {
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

            ti += 1;
        }
    }

    pub fn handleKeyPress(self: *Self, key: wio.Button) void {
        const line = &self.lines.items[self.cursor_line];
        switch (key) {
            .left => {
                if (self.cursor_col > 0) {
                    self.cursor_col -= 1;
                } else if (self.cursor_line > 0) {
                    self.cursor_line -= 1;
                    self.cursor_col = self.lines.items[self.cursor_line].items.len;
                }
            },
            .right => {
                if (self.cursor_col < line.items.len) {
                    self.cursor_col += 1;
                } else if (self.cursor_line + 1 < self.lines.items.len) {
                    self.cursor_line += 1;
                    self.cursor_col = 0;
                }
            },
            .up => {
                if (self.cursor_line > 0) {
                    self.cursor_line -= 1;
                    self.cursor_col = @min(self.cursor_col, self.lines.items[self.cursor_line].items.len);
                }
            },
            .down => {
                if (self.cursor_line + 1 < self.lines.items.len) {
                    self.cursor_line += 1;
                    self.cursor_col = @min(self.cursor_col, self.lines.items[self.cursor_line].items.len);
                }
            },
            .home => {
                self.cursor_col = 0;
            },
            .end => {
                self.cursor_col = self.lines.items[self.cursor_line].items.len;
            },
            .backspace => {
                if (self.cursor_col > 0) {
                    _ = line.orderedRemove(self.cursor_col - 1);
                    self.cursor_col -= 1;
                    self.tokenizeLine(self.cursor_line);
                } else if (self.cursor_line > 0) {
                    // Merge with previous line
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
                }
            },
            .delete => {
                if (self.cursor_col < line.items.len) {
                    _ = line.orderedRemove(self.cursor_col);
                    self.tokenizeLine(self.cursor_line);
                } else if (self.cursor_line + 1 < self.lines.items.len) {
                    // Merge with next line
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

    pub fn handleChar(self: *Self, char_code: u21) void {
        // Ignoriere Steuerzeichen
        if (char_code < 32 or char_code == 127) return;

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char_code, &buf) catch return;

        const line = &self.lines.items[self.cursor_line];
        line.insertSlice(self.allocator, self.cursor_col, buf[0..len]) catch return;
        self.cursor_col += len;
        self.recordCursorMovement();
        self.tokenizeLine(self.cursor_line);
    }

    pub fn render(self: *Self, arena: std.mem.Allocator) void {
        // Editor Container - fills full available space
        clay.UI()(.{
            .id = clay.ElementId.ID("code_editor"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .top_to_bottom,
            },
            .background_color = self.bg_color,
        })({
            // Scrollable Editor Content
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
                        // .child_gap = 2,
                    },
                })({
                    var i: usize = 0;
                    while (i < self.lines.items.len) : (i += 1) {
                        const line = self.lines.items[i].items;
                        const is_current = (i == self.cursor_line);

                        // Row Container (Gutter + Code)
                        clay.UI()(.{
                            .id = clay.ElementId.IDI("row", @intCast(i)),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                .direction = .left_to_right,
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            // Gutter Element
                            clay.UI()(.{
                                .id = clay.ElementId.IDI("gutter", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .fixed(self.gutter_width), .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                    .padding = .{ .left = 8, .right = 16 },
                                    .child_alignment = .{ .x = .right, .y = .center },
                                },
                                .background_color = if (is_current) self.current_line_highlight else self.gutter_color,
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

                            // Code Element
                            clay.UI()(.{
                                .id = clay.ElementId.IDI("code", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                    .padding = .{ .left = 12 },
                                    .child_alignment = .{ .x = .left, .y = .center },
                                },
                                .background_color = if (is_current) self.current_line_highlight else .{ 0, 0, 0, 0 },
                            })({
                                self.renderLine(i, line);
                            });
                        });
                    }
                });
            });
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
