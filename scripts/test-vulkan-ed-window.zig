const std = @import("std");
const wio = @import("wio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try wio.init(allocator, .{});
    defer wio.deinit();

    var window = try wio.createWindow(.{
        .title = "Flow (vulkan-ed renderer)",
        .size = .{ .width = 800, .height = 600 },
        .scale = 1.0,
    });
    defer window.destroy();

    // Keep window alive for screenshot
    const deadline = std.time.nanoTimestamp() + 10_000_000_000; // 10 seconds
    while (std.time.nanoTimestamp() < deadline) {
        wio.update();
        while (window.getEvent()) |event| {
            switch (event) {
                .close => return,
                else => {},
            }
        }
        wio.wait(.{});
    }
}
