/// Performance-Benchmark für Editor-Highlighting
///
/// Misst die Zeit für:
/// 1. Vollständiges Reparse (aktueller Zustand)
/// 2. Inkrementelles Reparse (nach Optimierung)
/// 3. tagsForLine für sichtbare Zeilen

const std = @import("std");
const flow_core = @import("flow_core");
const syntax = @import("syntax");

fn asciiMetrics() flow_core.Buffer.Metrics {
    const Ctx = struct {
        fn egc_length(_: flow_core.Buffer.Metrics, egcs: []const u8, colcount: *usize, _: usize) usize {
            if (egcs.len == 0) return 0;
            if (egcs[0] == '\n') { colcount.* = 1; return 1; }
            if (egcs[0] == '\t') { colcount.* = 4; return 1; }
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
    return .{
        .ctx = undefined,
        .egc_length = Ctx.egc_length,
        .egc_chunk_width = Ctx.egc_chunk_width,
        .egc_last = Ctx.egc_last,
        .tab_width = 4,
    };
}

/// Generiere eine große Testdatei mit wiederholtem Zig-Code
fn generateLargeZigFile(allocator: std.mem.Allocator, target_lines: usize) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    const sample_line =
        \\pub fn exampleFunction(x: i32, y: i32) i32 {
        \\    const result = x + y;
        \\    if (result > 100) {
        \\        return result * 2;
        \\    } else {
        \\        return result - 1;
        \\    }
        \\}
        \\
    ;

    var lines_written: usize = 0;
    while (lines_written < target_lines) {
        try buffer.appendSlice(allocator, sample_line);
        lines_written += 9; // 9 lines per sample
    }

    return buffer.toOwnedSlice(allocator);
}

/// Miss die Zeit für einen vollständigen Reparse
fn benchmarkFullReparse(allocator: std.mem.Allocator, large_file: []const u8, num_iterations: usize) !void {
    std.debug.print("\n========== BENCHMARK: FULL REPARSE ==========\n", .{});
    std.debug.print("File size: {d} bytes\n", .{large_file.len});

    var total_time_ns: u64 = 0;

    var i: usize = 0;
    while (i < num_iterations) : (i += 1) {
        var buffer = try flow_core.Buffer.create(allocator);
        defer buffer.deinit();

        var eol_mode: flow_core.Buffer.EolMode = .lf;
        var utf8_sanitized: bool = false;
        const root = try buffer.load_from_string(large_file, &eol_mode, &utf8_sanitized);

        const metrics = asciiMetrics();

        var highlighter = try flow_core.highlight.SyntaxHighlighter.create(allocator, "zig");
        defer highlighter.destroy();

        const start = std.time.nanoTimestamp();
        try highlighter.reparseFromBuffer(root, metrics);
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        total_time_ns += elapsed;

        std.debug.print("  Iteration {d}: {d:.3} ms\n", .{ i + 1, @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 });
    }

    const avg_time_ns = total_time_ns / num_iterations;
    std.debug.print("\n  AVERAGE: {d:.3} ms\n", .{ @as(f64, @floatFromInt(avg_time_ns)) / 1_000_000.0 });
    std.debug.print("========== END BENCHMARK ==========\n\n", .{});
}

/// Miss die Zeit für inkrementelle Updates
fn benchmarkIncrementalEdit(allocator: std.mem.Allocator, large_file: []const u8, num_edits: usize) !void {
    std.debug.print("\n========== BENCHMARK: INCREMENTAL EDIT ==========\n", .{});
    std.debug.print("File size: {d} bytes\n", .{large_file.len});
    std.debug.print("Number of edits: {d}\n", .{num_edits});

    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();

    var eol_mode: flow_core.Buffer.EolMode = .lf;
    var utf8_sanitized: bool = false;
    const root = try buffer.load_from_string(large_file, &eol_mode, &utf8_sanitized);

    const metrics = asciiMetrics();

    var highlighter = try flow_core.highlight.SyntaxHighlighter.create(allocator, "zig");
    defer highlighter.destroy();

    buffer.root = root;
    // Initial parse
    try highlighter.reparseFromBuffer(root, metrics);
    std.debug.print("  Initial parse complete\n", .{});

    var total_time_ns: u64 = 0;
    var edit_times = std.ArrayListUnmanaged(u64){};
    defer edit_times.deinit(allocator);

    // Simuliere Edits in der Mitte der Datei
    var e: usize = 0;
    while (e < num_edits) : (e += 1) {
        // Finde eine Zeile in der Mitte
        const mid_line = buffer.root.lines() / 2 + e;
        if (mid_line >= buffer.root.lines()) break;

        var line_buf: std.Io.Writer.Allocating = .init(allocator);
        defer line_buf.deinit();

        try buffer.root.get_line(mid_line, &line_buf.writer, metrics);
        const line_text = line_buf.written();

        if (line_text.len == 0) continue;

        // Simuliere einen kleinen Insert (ein Zeichen in der Mitte der Zeile)
        const insert_pos = line_text.len / 2;
        const insert_text = "x";

        // Edit für tree-sitter vorbereiten
        const line_start = buffer.root.line_start_byte(mid_line, metrics);
        const col_byte = insert_pos; // vereinfacht

        const start_byte = line_start + col_byte;
        const old_end_byte = start_byte;
        const new_end_byte = start_byte + insert_text.len;

        const edit: syntax.Edit = .{
            .start_byte = @intCast(start_byte),
            .old_end_byte = @intCast(old_end_byte),
            .new_end_byte = @intCast(new_end_byte),
            .start_point = .{ .row = @intCast(mid_line), .column = @intCast(col_byte) },
            .old_end_point = .{ .row = @intCast(mid_line), .column = @intCast(col_byte) },
            .new_end_point = .{ .row = @intCast(mid_line), .column = @intCast(col_byte + insert_text.len) },
        };

        // Inkrementelles Edit
        const start = std.time.nanoTimestamp();
        highlighter.pushEdit(edit);
        try highlighter.reparseFromBuffer(buffer.root, metrics);
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        total_time_ns += elapsed;
        try edit_times.append(allocator, elapsed);

        // Tatsächlichen Edit im Buffer durchführen
        // (Für den Benchmark reicht es, den Highlighter zu messen)

        std.debug.print("  Edit {d} (line {d}): {d:.3} ms\n", .{
            e + 1,
            mid_line,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        });
    }

    if (edit_times.items.len > 0) {
        const avg_time_ns = total_time_ns / edit_times.items.len;
        std.debug.print("\n  AVERAGE per edit: {d:.3} ms\n", .{ @as(f64, @floatFromInt(avg_time_ns)) / 1_000_000.0 });
    }
    std.debug.print("========== END BENCHMARK ==========\n\n", .{});
}

/// Miss die Zeit für tagsForLine (Rendering)
fn benchmarkTagsForLine(allocator: std.mem.Allocator, large_file: []const u8, num_lines: usize) !void {
    std.debug.print("\n========== BENCHMARK: TAGS FOR LINE ==========\n", .{});

    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();

    var eol_mode: flow_core.Buffer.EolMode = .lf;
    var utf8_sanitized: bool = false;
    const root = try buffer.load_from_string(large_file, &eol_mode, &utf8_sanitized);

    const metrics = asciiMetrics();

    var highlighter = try flow_core.highlight.SyntaxHighlighter.create(allocator, "zig");
    defer highlighter.destroy();

    buffer.root = root;
    try highlighter.reparseFromBuffer(root, metrics);
    std.debug.print("  Parse complete\n", .{});

    var total_time_ns: u64 = 0;
    const lines_to_test = @min(num_lines, buffer.root.lines());

    var i: usize = 0;
    while (i < lines_to_test) : (i += 1) {
        var line_buf: std.Io.Writer.Allocating = .init(allocator);
        defer line_buf.deinit();

        try buffer.root.get_line(i, &line_buf.writer, metrics);
        const line_len = line_buf.written().len;

        const start = std.time.nanoTimestamp();
        const tags = try highlighter.tagsForLine(i, line_len, allocator);
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        total_time_ns += elapsed;

        if (i % 100 == 0) {
            std.debug.print("  Line {d}: {d:.3} ms ({d} tags)\n", .{
                i,
                @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
                tags.len,
            });
        }
    }

    const avg_time_ns = total_time_ns / lines_to_test;
    std.debug.print("\n  AVERAGE per line: {d:.3} ms\n", .{ @as(f64, @floatFromInt(avg_time_ns)) / 1_000_000.0 });
    std.debug.print("  Total for {d} lines: {d:.3} ms\n", .{
        lines_to_test,
        @as(f64, @floatFromInt(total_time_ns)) / 1_000_000.0,
    });
    std.debug.print("========== END BENCHMARK ==========\n\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments
    var num_lines: usize = 5000; // Default: 5000 Zeilen
    var num_iterations: usize = 3;
    var num_edits: usize = 10;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--lines")) {
            if (i + 1 < args.len) {
                num_lines = try std.fmt.parseUnsigned(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--iterations")) {
            if (i + 1 < args.len) {
                num_iterations = try std.fmt.parseUnsigned(usize, args[i + 1], 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--edits")) {
            if (i + 1 < args.len) {
                num_edits = try std.fmt.parseUnsigned(usize, args[i + 1], 10);
                i += 1;
            }
        }
    }

    std.debug.print("Generating test file with {d} lines...\n", .{num_lines});
    const large_file = try generateLargeZigFile(allocator, num_lines);
    defer allocator.free(large_file);

    std.debug.print("Generated file: {d} bytes, {d} lines\n\n", .{ large_file.len, num_lines });

    // Benchmark 1: Full Reparse
    try benchmarkFullReparse(allocator, large_file, num_iterations);

    // Benchmark 2: Incremental Edit
    try benchmarkIncrementalEdit(allocator, large_file, num_edits);

    // Benchmark 3: tagsForLine
    try benchmarkTagsForLine(allocator, large_file, 100); // Test 100 lines
}
