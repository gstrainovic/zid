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
        self.syn.destroy();
        self.query_cache.deinit();
        self.allocator.destroy(self);
    }

    /// Melde einen Edit an tree-sitter. Muss VOR dem nächsten
    /// `reparseFromBuffer` passieren, damit inkrementeller Reparse funktioniert.
    pub fn pushEdit(self: *SyntaxHighlighter, ed: syntax.Edit) void {
        self.syn.edit(ed);
    }

    /// Verwirft den bestehenden Parsebaum — nächster `reparseFromBuffer`
    /// macht einen vollen Parse. Nötig, wenn zwischendurch Edits passiert
    /// sind, für die kein `pushEdit` ausgelöst wurde (sonst würde tree-sitter
    /// den stale Baum wiederverwenden).
    pub fn resetTree(self: *SyntaxHighlighter) void {
        self.syn.reset();
    }

    /// Reparse über Rope-Callback — tree-sitter ruft `buffer.get_from_pos`
    /// chunk-weise auf. Keine Volltext-Materialisierung.
    pub fn reparseFromBuffer(self: *SyntaxHighlighter, buffer: anytype, metrics: anytype) !void {
        const start = std.time.nanoTimestamp();
        try self.syn.refresh_from_buffer(buffer, metrics);
        const end = std.time.nanoTimestamp();
        const ms = @as(f64, @floatFromInt(end - start)) / 1000000.0;
        std.log.scoped(.highlight).debug("reparseFromBuffer took {d:.2}ms", .{ms});
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
