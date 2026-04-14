/// Performance-Messung für Highlighting-Optimierung
/// Wird in Tests aufgerufen, um Vorher/Nachher zu vergleichen

const std = @import("std");
const flow_core = @import("flow_core");
const syntax = @import("syntax");

/// Misst die Zeit für einen vollständigen Reparse
pub fn measureFullReparse(allocator: std.mem.Allocator, content: []const u8) !u64 {
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();

    var eol_mode: flow_core.Buffer.EolMode = .lf;
    var utf8_sanitized: bool = false;
    const root = try buffer.load_from_string(content, &eol_mode, &utf8_sanitized);

    const metrics = createTestMetrics();

    var highlighter = try flow_core.highlight.SyntaxHighlighter.create(allocator, "zig");
    defer highlighter.destroy();

    const start = std.time.nanoTimestamp();
    try highlighter.reparseFromBuffer(root, metrics);
    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

/// Misst die Zeit für ein inkrementelles Edit
pub fn measureIncrementalEdit(
    allocator: std.mem.Allocator,
    content: []const u8,
    edit_line: usize,
    edit_col: usize,
    new_text: []const u8,
) !u64 {
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();

    var eol_mode: flow_core.Buffer.EolMode = .lf;
    var utf8_sanitized: bool = false;
    const root = try buffer.load_from_string(content, &eol_mode, &utf8_sanitized);

    const metrics = createTestMetrics();

    var highlighter = try flow_core.highlight.SyntaxHighlighter.create(allocator, "zig");
    defer highlighter.destroy();

    // Initial parse
    try highlighter.reparseFromBuffer(root, metrics);

    // Edit vorbereiten
    const line_start = buffer.root.line_start_byte(edit_line, metrics);
    const col_byte = edit_col;

    const start_byte = line_start + col_byte;
    const old_end_byte = start_byte;
    const new_end_byte = start_byte + new_text.len;

    const edit: syntax.Edit = .{
        .start_byte = @intCast(start_byte),
        .old_end_byte = @intCast(old_end_byte),
        .new_end_byte = @intCast(new_end_byte),
        .start_point = .{ .row = @intCast(edit_line), .column = @intCast(col_byte) },
        .old_end_point = .{ .row = @intCast(edit_line), .column = @intCast(col_byte) },
        .new_end_point = .{ .row = @intCast(edit_line), .column = @intCast(col_byte + new_text.len) },
    };

    // Inkrementelles Edit messen
    const start = std.time.nanoTimestamp();
    highlighter.pushEdit(edit);
    try highlighter.reparseFromBuffer(buffer.root, metrics);
    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

/// Misst die Zeit für tagsForLine
pub fn measureTagsForLine(
    allocator: std.mem.Allocator,
    content: []const u8,
    line_idx: usize,
) !u64 {
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();

    var eol_mode: flow_core.Buffer.EolMode = .lf;
    var utf8_sanitized: bool = false;
    const root = try buffer.load_from_string(content, &eol_mode, &utf8_sanitized);

    const metrics = createTestMetrics();

    var highlighter = try flow_core.highlight.SyntaxHighlighter.create(allocator, "zig");
    defer highlighter.destroy();

    try highlighter.reparseFromBuffer(root, metrics);

    var line_buf: std.Io.Writer.Allocating = .init(allocator);
    defer line_buf.deinit();

    try buffer.root.get_line(line_idx, &line_buf.writer, metrics);
    const line_len = line_buf.written().len;

    const start = std.time.nanoTimestamp();
    const tags = try highlighter.tagsForLine(line_idx, line_len, allocator);
    defer allocator.free(tags);
    const end = std.time.nanoTimestamp();

    return @intCast(end - start);
}

/// Erstelle Metrics für Tests (vereinfacht)
fn createTestMetrics() flow_core.Buffer.Metrics {
    const Ctx = struct {
        fn egc_length(_: flow_core.Buffer.Metrics, egcs: []const u8, colcount: *usize, _: usize) usize {
            if (egcs.len == 0) return 0;
            if (egcs[0] == '\n') {
                colcount.* = 1;
                return 1;
            }
            if (egcs[0] == '\t') {
                colcount.* = 4;
                return 1;
            }
            colcount.* = 1;
            return 1;
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

    return flow_core.Buffer.Metrics{
        .ctx = undefined,
        .egc_length = Ctx.egc_length,
        .egc_chunk_width = Ctx.egc_chunk_width,
        .egc_last = Ctx.egc_last,
        .tab_width = 4,
    };
}
