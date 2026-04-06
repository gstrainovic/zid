//! Code Editor Component für vulkan-ed
//!
//! Code Editor mit Line Numbers, Syntax Highlighting und Current Line Highlight.

const std = @import("std");
const clay = @import("clay");
const Highlighter = @import("highlighter.zig").Highlighter;
const Token = @import("highlighter.zig").Token;

const max_lines = 50;
const max_line_len = 256;
const max_tokens_per_line = 64;

pub const CodeEditor = struct {
    /// Code-Zeilen
    lines: [max_lines][max_line_len]u8 = undefined,
    line_lengths: [max_lines]usize = undefined,
    line_count: usize = 0,

    /// Highlighter
    highlighter: Highlighter,

    /// Tokenisierte Zeilen (pro Zeile Tokens)
    line_tokens: [max_lines][max_tokens_per_line]Token = undefined,
    line_token_counts: [max_lines]usize = undefined,

    /// Aktuelle Zeile (für Highlight)
    current_line: usize = 1,

    /// Layout
    height: f32 = 250,
    gutter_width: f32 = 50,
    font_size: u16 = 24,

    /// Farben
    bg_color: clay.Color = .{ 30, 30, 46, 255 },
    gutter_color: clay.Color = .{ 24, 24, 37, 255 },
    line_number_color: clay.Color = .{ 108, 112, 134, 255 },
    current_line_number_color: clay.Color = .{ 138, 173, 244, 255 },
    current_line_highlight: clay.Color = .{ 60, 70, 100, 200 },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        _ = allocator;
        var self = Self{
            .highlighter = Highlighter.init(
                .{ 199, 146, 234, 255 },  // keyword - lila
                .{ 166, 209, 137, 255 },  // string - grün
                .{ 108, 112, 134, 255 },  // comment - grau
                .{ 250, 179, 135, 255 },  // number - orange
                .{ 138, 173, 244, 255 },  // builtin - blau
                .{ 138, 173, 244, 255 },  // punctuation - blau
                .{ 202, 211, 245, 255 },  // plain - weiß
            ),
        };
        @memset(&self.line_lengths, 0);
        @memset(&self.line_token_counts, 0);
        return self;
    }

    pub fn setText(self: *Self, text: []const u8) void {
        self.line_count = 0;
        @memset(&self.line_lengths, 0);
        @memset(&self.line_token_counts, 0);

        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len and self.line_count < max_lines) : (i += 1) {
            if (text[i] == '\n' or i == text.len - 1) {
                const end = if (text[i] == '\n') i else i + 1;
                const len = @min(end - start, max_line_len - 1);
                @memcpy(self.lines[self.line_count][0..len], text[start .. start + len]);
                self.lines[self.line_count][len] = 0;
                self.line_lengths[self.line_count] = len;

                // Tokenisieren
                var token_count: usize = 0;
                if (len > 0) {
                    const line_text = self.lines[self.line_count][0..len];
                    var ti: usize = 0;
                    while (ti < len and token_count < max_tokens_per_line) {
                        // Whitespace als eigenes Token
                        if (std.ascii.isWhitespace(line_text[ti])) {
                            const tok_start = ti;
                            while (ti < len and std.ascii.isWhitespace(line_text[ti])) {
                                ti += 1;
                            }
                            self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .plain };
                            token_count += 1;
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
                            self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .string };
                            token_count += 1;
                            continue;
                        }

                        // Comment
                        if (line_text[ti] == '/' and ti + 1 < len and line_text[ti + 1] == '/') {
                            self.line_tokens[self.line_count][token_count] = Token{ .start = ti, .end = len, .token_type = .comment };
                            token_count += 1;
                            break;
                        }

                        // Number
                        if (std.ascii.isDigit(line_text[ti])) {
                            const tok_start = ti;
                            while (ti < len and (std.ascii.isDigit(line_text[ti]) or line_text[ti] == '_' or line_text[ti] == '.')) {
                                ti += 1;
                            }
                            self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .number };
                            token_count += 1;
                            continue;
                        }

                        // Punctuation
                        if (std.mem.indexOfScalar(u8, &[_]u8{ '(', ')', '{', '}', '[', ']', ',', ';', '.', ':', '!', '?', '+', '-', '*', '/', '=', '<', '>', '|', '&', '^', '%', '~', '@' }, line_text[ti])) |_| {
                            const tok_start = ti;
                            // Double-char operators
                            if (ti + 1 < len) {
                                const two = line_text[ti .. ti + 2];
                                if (std.mem.eql(u8, two, "=>") or std.mem.eql(u8, two, "->") or std.mem.eql(u8, two, "||") or std.mem.eql(u8, two, "&&") or std.mem.eql(u8, two, "++") or std.mem.eql(u8, two, "--") or std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "!=") or std.mem.eql(u8, two, ">=") or std.mem.eql(u8, two, "<=")) {
                                    ti += 2;
                                    self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .punctuation };
                                    token_count += 1;
                                    continue;
                                }
                            }
                            ti += 1;
                            self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .punctuation };
                            token_count += 1;
                            continue;
                        }

                        // Identifier oder Keyword
                        if (std.ascii.isAlphabetic(line_text[ti]) or line_text[ti] == '_') {
                            const tok_start = ti;
                            while (ti < len and (std.ascii.isAlphanumeric(line_text[ti]) or line_text[ti] == '_')) {
                                ti += 1;
                            }
                            const word = line_text[tok_start..ti];
                            // Keywords prüfen
                            const keywords = [_][]const u8{ "const", "var", "fn", "pub", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "struct", "enum", "union", "extern", "export", "inline", "noinline", "comptime", "test", "usingnamespace", "and", "or", "not", "true", "false", "null", "undefined", "void", "bool", "type", "anytype", "anyframe", "anyerror" };
                            var is_kw = false;
                            for (keywords) |kw| {
                                if (std.mem.eql(u8, word, kw)) {
                                    is_kw = true;
                                    break;
                                }
                            }
                            if (is_kw) {
                                self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .keyword };
                            } else if (std.mem.eql(u8, word, "std")) {
                                self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .builtin };
                            } else {
                                self.line_tokens[self.line_count][token_count] = Token{ .start = tok_start, .end = ti, .token_type = .plain };
                            }
                            token_count += 1;
                            continue;
                        }

                        ti += 1;
                    }
                }
                self.line_token_counts[self.line_count] = token_count;

                self.line_count += 1;
                start = i + 1;
            }
        }
    }

    pub fn render(self: *Self) void {
        // Editor Container
        clay.UI()(.{
            .id = clay.ElementId.ID("code_editor"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(self.height) },
                .direction = .left_to_right,
            },
            .background_color = self.bg_color,
            .corner_radius = .all(4),
        })({
            // Line Numbers Gutter
            clay.UI()(.{
                .id = clay.ElementId.ID("line_numbers"),
                .layout = .{
                    .sizing = .{ .w = .fixed(self.gutter_width), .h = .grow },
                    .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
                    .direction = .top_to_bottom,
                    .child_gap = 4,
                },
                .background_color = self.gutter_color,
            })({
                // Line Numbers als comptime-Strings (keine dynamische Formatierung)
                const line_num_strings = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31", "32", "33", "34", "35", "36", "37", "38", "39", "40", "41", "42", "43", "44", "45", "46", "47", "48", "49", "50" };
                var i: usize = 0;
                while (i < self.line_count) : (i += 1) {
                    const color = if (i == self.current_line - 1)
                        self.current_line_number_color
                    else
                        self.line_number_color;
                    const line_num_str = if (i < line_num_strings.len) line_num_strings[i] else "?";
                    clay.text(line_num_str, .{ .font_size = self.font_size, .color = color });
                }
            });

            // Scrollable Editor Content
            clay.UI()(.{
                .id = clay.ElementId.ID("editor_scroll"),
                .layout = .{ .sizing = .grow },
                .background_color = self.bg_color,
                .clip = .{ .vertical = true },
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("editor_content"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = 4,
                    },
                })({
                    var i: usize = 0;
                    while (i < self.line_count) : (i += 1) {
                        const line_len = self.line_lengths[i];
                        if (line_len == 0) {
                            clay.text(" ", .{ .font_size = self.font_size, .color = .{ 202, 211, 245, 255 } });
                            continue;
                        }

                        // Current Line Highlight
                        if (i == self.current_line - 1) {
                            clay.UI()(.{
                                .id = clay.ElementId.ID("current_line"),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(28) },
                                },
                                .background_color = self.current_line_highlight,
                            })({
                                self.renderLine(i, line_len);
                            });
                        } else {
                            self.renderLine(i, line_len);
                        }
                    }
                });
            });
        });
    }

    fn renderLine(self: *Self, line_idx: usize, line_len: usize) void {
        const token_count = self.line_token_counts[line_idx];
        if (token_count == 0) {
            clay.text(self.lines[line_idx][0..line_len], .{ .font_size = self.font_size, .color = .{ 202, 211, 245, 255 } });
            return;
        }

        clay.UI()(.{
            .layout = .{ .direction = .left_to_right },
        })({
            for (self.line_tokens[line_idx][0..token_count]) |token| {
                const color = self.highlighter.colorForType(token.token_type);
                clay.text(token.slice(&self.lines[line_idx]), .{ .font_size = self.font_size, .color = color });
            }
        });
    }
};
