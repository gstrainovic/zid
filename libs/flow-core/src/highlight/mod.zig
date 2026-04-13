//! Syntax-Highlighter basierend auf flow-syntax (tree-sitter).
//!
//! Wrap flow-syntax in UI-agnostische API. Callers halten einen
//! SyntaxHighlighter pro Buffer, rufen updateFromString() bei jeder
//! Änderung und tagsForLine() beim Rendern.

const std = @import("std");
const syntax = @import("syntax");

pub const ColorTag = struct {
    /// Byte-Offset in Zeilen-Text (Start).
    start: usize,
    /// Byte-Offset in Zeilen-Text (Ende, exklusiv).
    end: usize,
    /// Vordergrund-Farbe als 0xRRGGBB.
    fg: u32,
};

pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,
    query_cache: *syntax.QueryCache,
    syn: *syntax,
    /// Zero-terminated Content-Kopie (treez braucht [:0]const u8).
    content_z: ?[:0]u8 = null,

    pub fn create(allocator: std.mem.Allocator, lang_name: []const u8) !*SyntaxHighlighter {
        const qc = try syntax.QueryCache.create(allocator, .{});
        errdefer qc.deinit();
        const syn = try syntax.create_file_type_static(allocator, lang_name, qc);
        errdefer syn.destroy();

        const self = try allocator.create(SyntaxHighlighter);
        self.* = .{
            .allocator = allocator,
            .query_cache = qc,
            .syn = syn,
        };
        return self;
    }

    /// Erkenne Sprache via Dateipfad (Extension) + Inhalt (Shebang/First-Line).
    /// Gibt `error.NotFound` zurück, wenn keine Sprache passt.
    pub fn createByPath(
        allocator: std.mem.Allocator,
        file_path: ?[]const u8,
        content: []const u8,
    ) !*SyntaxHighlighter {
        const qc = try syntax.QueryCache.create(allocator, .{});
        errdefer qc.deinit();
        const syn = try syntax.create_guess_file_type_static(allocator, content, file_path, qc);
        errdefer syn.destroy();

        const self = try allocator.create(SyntaxHighlighter);
        self.* = .{
            .allocator = allocator,
            .query_cache = qc,
            .syn = syn,
        };
        return self;
    }

    pub fn destroy(self: *SyntaxHighlighter) void {
        if (self.content_z) |c| self.allocator.free(c);
        self.syn.destroy();
        self.query_cache.deinit();
        self.allocator.destroy(self);
    }

    /// Re-parse full content. Kopiert content mit Null-Terminator.
    /// Erst-Parse ODER voller Reparse (z.B. bei Sprachwechsel).
    pub fn updateFromString(self: *SyntaxHighlighter, content: []const u8) !void {
        if (self.content_z) |c| self.allocator.free(c);
        self.content_z = null;

        const buf = try self.allocator.allocSentinel(u8, content.len, 0);
        @memcpy(buf, content);
        self.content_z = buf;

        try self.syn.refresh_from_string(buf);
    }

    /// Inkrementeller Reparse: berechnet Single-Edit-Diff zwischen letzter
    /// Content-Kopie und `new_content`, meldet `syn.edit(…)` an tree-sitter
    /// (markiert Subtree als dirty), und re-parst. Tree-sitter reused
    /// unveränderte Subtrees → O(edit-size) statt O(datei-size).
    ///
    /// Falls noch kein Baum existiert (erster Call), fällt auf
    /// `updateFromString` zurück (voller Parse).
    pub fn reparseIncremental(self: *SyntaxHighlighter, new_content: []const u8) !void {
        const old = self.content_z orelse {
            return self.updateFromString(new_content);
        };

        // Single-Edit Diff: common prefix + common suffix, Rest = Edit-Range.
        var prefix: usize = 0;
        const min_len = @min(old.len, new_content.len);
        while (prefix < min_len and old[prefix] == new_content[prefix]) : (prefix += 1) {}

        var old_end = old.len;
        var new_end = new_content.len;
        while (old_end > prefix and new_end > prefix and old[old_end - 1] == new_content[new_end - 1]) {
            old_end -= 1;
            new_end -= 1;
        }

        // Wenn identisch: nichts tun.
        if (prefix == old.len and prefix == new_content.len) return;

        const ed: syntax.Edit = .{
            .start_byte = @intCast(prefix),
            .old_end_byte = @intCast(old_end),
            .new_end_byte = @intCast(new_end),
            .start_point = pointAtByte(old, prefix),
            .old_end_point = pointAtByte(old, old_end),
            .new_end_point = pointAtByte(new_content, new_end),
        };
        self.syn.edit(ed);

        // Neue Content-Kopie und reparse (nutzt old_tree = inkrementell).
        const buf = try self.allocator.allocSentinel(u8, new_content.len, 0);
        @memcpy(buf, new_content);
        self.allocator.free(old);
        self.content_z = buf;
        try self.syn.refresh_from_string(buf);
    }

    /// ColorTags für eine Zeile. Byte-Offsets relativ zum Zeilenanfang.
    /// Multi-Line-Captures werden auf die Zeile geclampt.
    pub fn tagsForLine(
        self: *SyntaxHighlighter,
        line_idx: usize,
        line_byte_len: usize,
        allocator: std.mem.Allocator,
    ) ![]ColorTag {
        var tags: std.ArrayListUnmanaged(ColorTag) = .{};
        errdefer tags.deinit(allocator);

        const Ctx = struct {
            tags: *std.ArrayListUnmanaged(ColorTag),
            alloc: std.mem.Allocator,
            line: u32,
            line_len: usize,

            fn cb(
                ctx: *@This(),
                sel: syntax.Range,
                scope: []const u8,
                _: u32,
                _: usize,
                _: *const syntax.Node,
            ) error{Stop}!void {
                // Skip captures nicht auf dieser Zeile.
                if (sel.end_point.row < ctx.line) return;
                if (sel.start_point.row > ctx.line) return;

                const start: usize = if (sel.start_point.row < ctx.line)
                    0
                else
                    @min(@as(usize, sel.start_point.column), ctx.line_len);
                const end: usize = if (sel.end_point.row > ctx.line)
                    ctx.line_len
                else
                    @min(@as(usize, sel.end_point.column), ctx.line_len);

                if (start >= end) return;

                const fg = mapScopeToColor(scope);
                ctx.tags.append(ctx.alloc, .{
                    .start = start,
                    .end = end,
                    .fg = fg,
                }) catch return error.Stop;
            }
        };

        var ctx: Ctx = .{
            .tags = &tags,
            .alloc = allocator,
            .line = @intCast(line_idx),
            .line_len = line_byte_len,
        };

        const range: syntax.Range = .{
            .start_point = .{ .row = @intCast(line_idx), .column = 0 },
            .end_point = .{ .row = @intCast(line_idx + 1), .column = 0 },
            .start_byte = 0,
            .end_byte = 0,
        };

        self.syn.render(&ctx, Ctx.cb, range) catch |err| switch (err) {
            error.Stop => {},
            else => return err,
        };

        return tags.toOwnedSlice(allocator);
    }
};

/// Byte-Offset → tree-sitter Point (row, column). Zählt '\n' in Text bis zum
/// Offset. O(byte) — akzeptabel da nur einmal pro Reparse.
fn pointAtByte(text: []const u8, byte: usize) syntax.Point {
    var row: u32 = 0;
    var last_nl: usize = 0;
    const limit = @min(byte, text.len);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (text[i] == '\n') {
            row += 1;
            last_nl = i + 1;
        }
    }
    return .{ .row = row, .column = @intCast(limit - last_nl) };
}

/// Mappe tree-sitter Scope-Namen zu Catppuccin-Macchiato RGB.
/// Scope kann hierarchisch sein (z.B. "keyword.control.return") —
/// wir prüfen Prefixe, spezifischste zuerst.
fn mapScopeToColor(scope: []const u8) u32 {
    // Catppuccin Macchiato
    const mauve: u32 = 0xc6a0f6;
    const green: u32 = 0xa6da95;
    const peach: u32 = 0xf5a97f;
    const overlay1: u32 = 0x6e738d;
    const yellow: u32 = 0xeed49f;
    const blue: u32 = 0x8aadf4;
    const sky: u32 = 0x91d7e3;
    const red: u32 = 0xed8796;
    const teal: u32 = 0x8bd5ca;
    const text: u32 = 0xcad3f5;

    if (std.mem.startsWith(u8, scope, "comment")) return overlay1;
    if (std.mem.startsWith(u8, scope, "string")) return green;
    if (std.mem.startsWith(u8, scope, "character")) return green;
    if (std.mem.startsWith(u8, scope, "number")) return peach;
    if (std.mem.startsWith(u8, scope, "boolean")) return peach;
    if (std.mem.startsWith(u8, scope, "constant.builtin")) return peach;
    if (std.mem.startsWith(u8, scope, "constant")) return peach;
    if (std.mem.startsWith(u8, scope, "keyword")) return mauve;
    if (std.mem.startsWith(u8, scope, "conditional")) return mauve;
    if (std.mem.startsWith(u8, scope, "repeat")) return mauve;
    if (std.mem.startsWith(u8, scope, "include")) return mauve;
    if (std.mem.startsWith(u8, scope, "type.builtin")) return yellow;
    if (std.mem.startsWith(u8, scope, "type")) return yellow;
    if (std.mem.startsWith(u8, scope, "function.builtin")) return teal;
    if (std.mem.startsWith(u8, scope, "function")) return blue;
    if (std.mem.startsWith(u8, scope, "method")) return blue;
    if (std.mem.startsWith(u8, scope, "operator")) return sky;
    if (std.mem.startsWith(u8, scope, "punctuation")) return text;
    if (std.mem.startsWith(u8, scope, "variable.builtin")) return red;
    if (std.mem.startsWith(u8, scope, "variable.parameter")) return text;
    if (std.mem.startsWith(u8, scope, "variable")) return text;
    if (std.mem.startsWith(u8, scope, "attribute")) return yellow;
    if (std.mem.startsWith(u8, scope, "label")) return sky;
    if (std.mem.startsWith(u8, scope, "tag")) return mauve;
    return text;
}
