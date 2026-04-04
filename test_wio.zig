const std = @import("std");
const wio = @import("wio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // wio initialisieren
    try wio.init(allocator, .{});
    defer wio.deinit();

    // Window erstellen
    window = try wio.createWindow(.{
        .title = "WIO Test",
        .size = .{ .width = 800, .height = 600 },
        .scale = 1,
    });

    std.debug.print("✅ wio initialisiert! Fenster erstellt.\n", .{});
    
    // Event Loop mit wio.run
    return wio.run(loop);
}

fn loop() !bool {
    while (window.getEvent()) |event| {
        switch (event) {
            .close => {
                std.debug.print("✅ wio Event Loop funktioniert!\n", .{});
                window.destroy();
                std.debug.print("✅ wio Test erfolgreich abgeschlossen!\n", .{});
                return false;
            },
            else => {},
        }
    }
    
    // Kurz warten
    wio.wait(.{ .timeout_ns = 10 * std.time.ns_per_ms });
    
    return true;
}

var window: wio.Window = undefined;
