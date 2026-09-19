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

test "Messcache läuft beim Streamen eines wachsenden Absatzes nicht voll" {
    const alloc = std.testing.allocator;
    clay.setMaxElementCount(16384); // wie UI.MAX_CLAY_ELEMENTS
    const memory = try alloc.alloc(u8, clay.minMemorySize());
    defer alloc.free(memory);
    _ = clay.initialize(clay.createArenaWithCapacityAndMemory(memory), .{ .w = 800, .h = 600 }, .{ .error_handler_function = onError });
    clay.setMeasureTextFunction(void, {}, measure);
    capacity_errors = 0;

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
