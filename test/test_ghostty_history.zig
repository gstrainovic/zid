const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub fn main() !void {
    var alloc = std.heap.page_allocator;
    var term = try ghostty_vt.Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    
    var stream = term.vtStream();
    
    // Drucke 200 Zeilen Text in das Terminal
    for (0..200) |i| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "Line {d}\r\n", .{i}) catch unreachable;
        stream.nextSlice(s);
    }
    
    std.debug.print("Ghostty-VT Rows nach 200 Zeilen Input:\n", .{});
    std.debug.print("Visible rows: {d}\n", .{term.rows});
    std.debug.print("Total pages rows: {d}\n", .{term.screens.active.pages.total_rows});
    
    // Teste dumpStringAlloc
    const tl = term.screens.active.pages.getTopLeft(.history);
    const br = term.screens.active.pages.getBottomRight(.screen) orelse tl;
    
    var builder: std.Io.Writer.Allocating = .init(alloc);
    try term.screens.active.dumpString(&builder.writer, .{
        .tl = tl,
        .br = br,
        .unwrap = false,
    });
    
    const dump = try builder.toOwnedSlice();
    var lines = std.mem.splitScalar(u8, dump, '\n');
    var count: usize = 0;
    while (lines.next()) |l| {
        if (l.len > 0 or count < 200) count += 1;
    }
    std.debug.print("Dumped lines: {d}\n", .{count});
}
