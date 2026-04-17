const std = @import("std");
const ui = @import("src/ui/mod.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Minimaler Mock für UIConfig
    const config = ui.UIConfig{ .font_size = 24.0 };
    
    // Versuche init aufzurufen (wird zur Laufzeit scheitern aber zur Compilezeit gecheckt)
    _ = ui.UI.init(allocator, config, null) catch {};
}
