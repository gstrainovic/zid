//! Einfacher Syntax Highlighter für Zig-Code
//!
//! Tokenisiert eine Zeile und weist Farben zu.

const std = @import("std");
const clay = @import("clay");

/// Token Typ
pub const TokenType = enum {
    keyword,
    string,
    comment,
    number,
    builtin,
    punctuation,
    plain,
};

/// Ein Token mit Typ und Bereich
pub const Token = struct {
    start: usize,
    end: usize,
    token_type: TokenType,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Highlighter mit Theme-Farben
pub const Highlighter = struct {
    keyword_color: clay.Color,
    string_color: clay.Color,
    comment_color: clay.Color,
    number_color: clay.Color,
    builtin_color: clay.Color,
    punctuation_color: clay.Color,
    plain_color: clay.Color,

    const Self = @This();

    // Zig Keywords (comptime)
    const keywords = [_][]const u8{
        "const", "var", "fn", "pub", "return", "if", "else", "for", "while",
        "switch", "case", "break", "continue", "defer", "errdefer", "try",
        "catch", "orelse", "struct", "enum", "union", "extern", "export",
        "inline", "noinline", "comptime", "test", "usingnamespace",
        "and", "or", "not", "true", "false", "null", "undefined",
        "void", "bool", "comptime_int", "comptime_float", "type",
        "anytype", "anyframe", "anyerror",
    };

    // Zig Builtins (comptime)
    const builtins = [_][]const u8{
        "std",
    };

    pub fn init(
        keyword_color: clay.Color,
        string_color: clay.Color,
        comment_color: clay.Color,
        number_color: clay.Color,
        builtin_color: clay.Color,
        punctuation_color: clay.Color,
        plain_color: clay.Color,
    ) Self {
        return Self{
            .keyword_color = keyword_color,
            .string_color = string_color,
            .comment_color = comment_color,
            .number_color = number_color,
            .builtin_color = builtin_color,
            .punctuation_color = punctuation_color,
            .plain_color = plain_color,
        };
    }

    /// Eine Zeile tokenisieren
    pub fn tokenize(self: Self, line: []const u8, allocator: std.mem.Allocator) ![]Token {
        _ = self;
        var tokens = std.ArrayList(Token).init(allocator);
        errdefer tokens.deinit();

        var i: usize = 0;
        while (i < line.len) {
            // Whitespace überspringen
            if (std.ascii.isWhitespace(line[i])) {
                i += 1;
                continue;
            }

            // String Literal
            if (line[i] == '"') {
                const start = i;
                i += 1;
                while (i < line.len and line[i] != '"') {
                    if (line[i] == '\\' and i + 1 < line.len) i += 1;
                    i += 1;
                }
                if (i < line.len) i += 1; // Closing quote
                try tokens.append(Token{ .start = start, .end = i, .token_type = .string });
                continue;
            }

            // Char Literal
            if (line[i] == '\'') {
                const start = i;
                i += 1;
                while (i < line.len and line[i] != '\'') {
                    if (line[i] == '\\' and i + 1 < line.len) i += 1;
                    i += 1;
                }
                if (i < line.len) i += 1;
                try tokens.append(Token{ .start = start, .end = i, .token_type = .string });
                continue;
            }

            // Comment
            if (line[i] == '/' and i + 1 < line.len and line[i + 1] == '/') {
                try tokens.append(Token{ .start = i, .end = line.len, .token_type = .comment });
                break;
            }

            // Number
            if (std.ascii.isDigit(line[i])) {
                const start = i;
                while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_' or line[i] == '.')) {
                    i += 1;
                }
                // Hex prefix check
                if (i < line.len and (line[i] == 'x' or line[i] == 'b' or line[i] == 'o')) {
                    i += 1;
                    while (i < line.len and std.ascii.isHex(line[i])) {
                        i += 1;
                    }
                }
                try tokens.append(Token{ .start = start, .end = i, .token_type = .number });
                continue;
            }

            // Punctuation
            if (std.mem.indexOfScalar(u8, &[_]u8{ '(', ')', '{', '}', '[', ']', ',', ';', '.', ':', '!', '?', '+', '-', '*', '/', '=', '<', '>', '|', '&', '^', '%', '~', '@' }, line[i])) |_| {
                const start = i;
                // Double-char operators
                if (i + 1 < line.len) {
                    const two_char = line[i .. i + 2];
                    if (std.mem.eql(u8, two_char, "=>") or
                        std.mem.eql(u8, two_char, "->") or
                        std.mem.eql(u8, two_char, "||") or
                        std.mem.eql(u8, two_char, "&&") or
                        std.mem.eql(u8, two_char, "++") or
                        std.mem.eql(u8, two_char, "--") or
                        std.mem.eql(u8, two_char, "==") or
                        std.mem.eql(u8, two_char, "!=") or
                        std.mem.eql(u8, two_char, ">=") or
                        std.mem.eql(u8, two_char, "<=") or
                        std.mem.eql(u8, two_char, "<<") or
                        std.mem.eql(u8, two_char, ">>") or
                        std.mem.eql(u8, two_char, ".*") or
                        std.mem.eql(u8, two_char, ".*"))
                    {
                        i += 2;
                        try tokens.append(Token{ .start = start, .end = i, .token_type = .punctuation });
                        continue;
                    }
                }
                i += 1;
                try tokens.append(Token{ .start = start, .end = i, .token_type = .punctuation });
                continue;
            }

            // Identifier oder Keyword
            if (std.ascii.isAlphabetic(line[i]) or line[i] == '_') {
                const start = i;
                while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) {
                    i += 1;
                }
                const word = line[start..i];

                // Check if keyword
                var is_keyword = false;
                for (keywords) |kw| {
                    if (std.mem.eql(u8, word, kw)) {
                        is_keyword = true;
                        break;
                    }
                }

                if (is_keyword) {
                    try tokens.append(Token{ .start = start, .end = i, .token_type = .keyword });
                } else {
                    // Check for builtin
                    var is_builtin = false;
                    for (builtins) |bi| {
                        if (std.mem.eql(u8, word, bi)) {
                            is_builtin = true;
                            break;
                        }
                    }
                    if (is_builtin) {
                        try tokens.append(Token{ .start = start, .end = i, .token_type = .builtin });
                    } else {
                        try tokens.append(Token{ .start = start, .end = i, .token_type = .plain });
                    }
                }
                continue;
            }

            // Unknown character - just skip
            i += 1;
        }

        return tokens.toOwnedSlice();
    }

    /// Farbe für Token Typ holen
    pub fn colorForType(self: Self, token_type: TokenType) clay.Color {
        return switch (token_type) {
            .keyword => self.keyword_color,
            .string => self.string_color,
            .comment => self.comment_color,
            .number => self.number_color,
            .builtin => self.builtin_color,
            .punctuation => self.punctuation_color,
            .plain => self.plain_color,
        };
    }
};
