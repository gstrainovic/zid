//! Umgebungsvariablen plattformübergreifend lesen. `std.posix.getenv` ist unter
//! Windows ein Compile-Fehler (die Umgebung liegt dort als WTF-16 vor). Hier geht
//! der Weg über `std.process.getEnvVarOwned` in eine prozessweite Arena, damit
//! der Rückgabewert wie bei getenv ohne Freigabe weiterverwendet werden kann.
//! Auf POSIX bleibt es beim direkten getenv ohne Kopie.
const std = @import("std");
const builtin = @import("builtin");

var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var arena_lock: std.Thread.Mutex = .{};

/// Wert von `name` oder null, wenn nicht gesetzt.
pub fn get(name: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return std.posix.getenv(name);
    arena_lock.lock();
    defer arena_lock.unlock();
    return std.process.getEnvVarOwned(arena.allocator(), name) catch null;
}

/// Home-Verzeichnis: `HOME`, unter Windows ersatzweise `USERPROFILE`.
pub fn home() ?[]const u8 {
    if (get("HOME")) |h| return h;
    if (comptime builtin.os.tag == .windows) return get("USERPROFILE");
    return null;
}
