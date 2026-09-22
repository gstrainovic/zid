//! Clay-Kapazitäten über viele Frames (eigenes Test-Root, ohne UI).
//!
//! Beim Streamen einer Chat-Antwort ändert sich der Text jedes Frame; jedes neue Textstück legt
//! einen Eintrag im Messcache an. Veraltete Einträge räumte Clay nur nebenbei auf, eine lange
//! Antwort (1 844 Token) lief in `text_measurement_capacity_exceeded`.
const std = @import("std");
const clay = @import("clay");

var capacity_errors: usize = 0;

fn onError(data: clay.ErrorData) callconv(.c) void {
    switch (data.error_type) {
        .elements_capacity_exceeded, .text_measurement_capacity_exceeded => capacity_errors += 1,
        else => {},
    }
}

fn measure(text: []const u8, _: *clay.TextElementConfig, _: void) clay.Dimensions {
    return .{ .w = @floatFromInt(text.len * 8), .h = 16 };
}

// Clays aktueller Kontext liegt im Arena-Speicher und lässt sich nicht zurücksetzen. Ein Test,
// der seinen Speicher freigibt, lässt den nächsten in freigegebenen Speicher schreiben
// (`setMaxElementCount` segfaultete). Daher ein Puffer für alle Tests, je Test neu initialisiert.
var clay_memory: ?[]u8 = null;

fn initClay() !void {
    if (clay_memory == null) {
        clay.setMaxElementCount(16384); // wie UI.MAX_CLAY_ELEMENTS
        clay_memory = try std.heap.page_allocator.alloc(u8, clay.minMemorySize());
    }
    _ = clay.initialize(clay.createArenaWithCapacityAndMemory(clay_memory.?), .{ .w = 800, .h = 600 }, .{ .error_handler_function = onError });
    clay.setMeasureTextFunction(void, {}, measure);
    capacity_errors = 0;
}

test "Messcache läuft beim Streamen eines wachsenden Absatzes nicht voll" {
    const alloc = std.testing.allocator;
    try initClay();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    // Streaming: ein einziger Absatz wächst jedes Frame um ein Wort (wie `stream_text` im Chat).
    // Jeder Stand ist ein neuer Messcache-Eintrag mit allen Wörtern; bei 300 Frames sind das
    // ~45 000 Wörter, fast drei Mal die Standardgrenze von 16 384.
    var para: std.ArrayListUnmanaged(u8) = .empty;
    defer para.deinit(alloc);
    for (0..300) |frame| {
        _ = arena.reset(.retain_capacity);
        try para.writer(alloc).print("wort{d} ", .{frame});
        const s = try arena.allocator().dupe(u8, para.items);
        clay.beginLayout();
        clay.UI()(.{ .id = clay.ElementId.ID("root"), .layout = .{ .direction = .top_to_bottom } })({
            clay.text(s, .{ .font_size = 16 });
        });
        _ = clay.endLayout();
    }
    try std.testing.expectEqual(@as(usize, 0), capacity_errors);
}

// Absturz 22.09.2026 („applying non-zero offset to non-null pointer 0xffffffffffffffff“ in
// Clay__CalculateFinalLayout): der Umbruch bekam aus dem Messcache die Wortliste eines anderen,
// längeren Texts und las hinter dem eigenen Puffer. Der SIMD-Hash (x86_64) bezieht die Länge
// nicht ein, „a b“ und „a b\0\0\0“ haben denselben Schlüssel.
test "Umbruch nutzt keine Wörter eines kollidierenden längeren Texts" {
    try initClay();

    const long: []const u8 = "a b\x00\x00\x00";
    var short_buf = [_]u8{ 'a', ' ', 'b' };
    const short: []const u8 = &short_buf;
    clay.beginLayout();
    // 20 px breit, „a b“ misst 24: beide Texte laufen durch den Umbruch.
    clay.UI()(.{ .id = clay.ElementId.ID("root"), .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .fixed(20) } } })({
        clay.text(long, .{ .font_size = 16 });
        clay.text(short, .{ .font_size = 16 });
    });
    const commands = clay.endLayout();
    var short_lines: usize = 0;
    for (commands) |cmd| {
        if (cmd.command_type != .text) continue;
        const s = cmd.render_data.text.string_contents;
        if (s.base_chars != short.ptr) continue;
        short_lines += 1;
        // Keine Zeile des kurzen Texts reicht über dessen Ende.
        try std.testing.expect(@intFromPtr(s.chars) + @as(usize, @intCast(s.length)) <= @intFromPtr(short.ptr) + short.len);
    }
    try std.testing.expect(short_lines > 0);
}
