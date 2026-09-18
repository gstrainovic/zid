/// Tests für Highlighting-Performance und inkrementelle Updates

const std = @import("std");
const testing = std.testing;
const flow_core = @import("flow_core");
const syntax = @import("syntax");

const perf = @import("highlight_perf_test.zig");

test "incremental edit is faster than full reparse" {
    var allocator = testing.allocator;

    // Generiere große Testdatei (1000 Zeilen Zig-Code)
    const content = try generateZigFile(allocator, 1000);
    defer allocator.free(content);

    // Full Reparse messen (3 Iterationen)
    var full_reparse_times: [3]u64 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        full_reparse_times[i] = try perf.measureFullReparse(allocator, content);
    }
    const avg_full = (full_reparse_times[0] + full_reparse_times[1] + full_reparse_times[2]) / 3;

    // Incremental Edit messen (10 Iterationen)
    var incr_times: [10]u64 = undefined;
    var j: usize = 0;
    while (j < 10) : (j += 1) {
        incr_times[j] = try perf.measureIncrementalEdit(allocator, content, 500, 10, "x");
    }
    var sum_incr: u64 = 0;
    for (incr_times) |t| {
        sum_incr += t;
    }
    const avg_incr = sum_incr / incr_times.len;

    std.debug.print("\n=== Performance Test: Incremental vs Full ===\n", .{});
    std.debug.print("Full reparse average: {d:.3} ms\n", .{ @as(f64, @floatFromInt(avg_full)) / 1_000_000.0 });
    std.debug.print("Incremental edit average: {d:.3} ms\n", .{ @as(f64, @floatFromInt(avg_incr)) / 1_000_000.0 });
    std.debug.print("Speedup: {d:.1}x\n", .{ @as(f64, @floatFromInt(avg_full)) / @as(f64, @floatFromInt(avg_incr)) });

    // Incremental sollte mindestens 2x schneller sein
    try testing.expect(avg_incr < avg_full / 2);
}

test "tagsForLine performance" {
    var allocator = testing.allocator;

    const content = try generateZigFile(allocator, 500);
    defer allocator.free(content);

    // Miss tagsForLine für mehrere Zeilen
    var times: [20]u64 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        times[i] = try perf.measureTagsForLine(allocator, content, i * 25);
    }

    var sum: u64 = 0;
    for (times) |t| {
        sum += t;
    }
    const avg = sum / times.len;

    std.debug.print("\n=== Performance Test: tagsForLine ===\n", .{});
    std.debug.print("Average time per line: {d:.3} ms\n", .{ @as(f64, @floatFromInt(avg)) / 1_000_000.0 });

    // tagsForLine sollte unter 10ms liegen
    try testing.expect(avg < 10_000_000); // 10ms in ns
}

// tree-sitter liest den Rope über `get_from_pos` (Byte-Metriken); die Tag-Grenzen müssen
// auf Zeichengrenzen liegen — sonst schneidet der Editor beim Zeichnen UTF-8-Sequenzen auf.
test "markdown tags end on codepoint boundaries" {
    const allocator = testing.allocator;
    const content =
        "# Titel\n\n## Positive Befunde\n\n> **Tab 1 \xe2\x80\x93 Positive Befunde (erf\xc3\xbcllt)**\n\n### E01\n\n" ++
        "- **Aspekt / Teil-Feststellung bzw. Teil-Empfehlung:** Zustellung als Reset-Link \xe2\x87\x92 gepr\xc3\xbcft.\n";

    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var eol_mode: flow_core.Buffer.EolMode = .lf;
    var utf8_sanitized: bool = false;
    const root = try buffer.load_from_string(content, &eol_mode, &utf8_sanitized);
    const metrics = createTestMetrics();

    var highlighter = try flow_core.highlight.SyntaxHighlighter.create(allocator, "markdown");
    defer highlighter.destroy();
    try highlighter.reparseFromBuffer(root, metrics);

    var line_buf: std.Io.Writer.Allocating = .init(allocator);
    defer line_buf.deinit();
    var line_idx: usize = 0;
    while (line_idx < root.lines()) : (line_idx += 1) {
        line_buf.clearRetainingCapacity();
        try root.get_line(line_idx, &line_buf.writer, metrics);
        const line = line_buf.written();
        const tags = try highlighter.tagsForLine(line_idx, line.len, allocator);
        for (tags) |tag| {
            for ([_]usize{ tag.start, tag.end }) |b| {
                if (b < line.len and (line[b] & 0xC0) == 0x80) {
                    std.debug.print("line {d}: tag boundary {d} inside UTF-8 sequence\n", .{ line_idx, b });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

/// Generiere eine Testdatei mit Zig-Code
fn generateZigFile(allocator: std.mem.Allocator, num_lines: usize) ![]u8 {
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
    while (lines_written < num_lines) {
        try buffer.appendSlice(allocator, sample_line);
        lines_written += 9;
    }

    return buffer.toOwnedSlice(allocator);
}

/// Erstelle Metrics für Tests
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
