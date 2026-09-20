//! Datei herunterladen, mit Fortschritt und ohne Halbfertiges liegen zu lassen.
//!
//! Geschrieben wird in `<ziel>.part`; erst nach vollständigem Empfang wird
//! umbenannt. Ein Abbruch hinterlässt damit nie eine Datei, die wie ein fertiges
//! Modell aussieht. Bricht ein Lauf ab, setzt der nächste über einen Range-Header
//! auf der Teildatei auf — bei 2,7 GB ist das kein Luxus.

const std = @import("std");

/// Fortschritt für die Oberfläche. Wird aus dem Ladethread geschrieben und aus dem
/// Zeichenthread gelesen, deshalb atomar.
pub const Progress = struct {
    received: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),

    pub fn percent(self: *const Progress) u8 {
        const total = self.total.load(.monotonic);
        if (total == 0) return 0;
        const got = self.received.load(.monotonic);
        if (got >= total) return 100;
        return @intCast(got * 100 / total);
    }
};

pub const Error = error{DownloadFailed} || std.mem.Allocator.Error;

/// Pfad der Teildatei. Der Aufrufer gibt ihn frei.
pub fn partPath(allocator: std.mem.Allocator, dest: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.part", .{dest});
}

/// Lädt `url` nach `dest`. Legt fehlende Verzeichnisse an, setzt auf einer
/// vorhandenen `.part`-Datei auf und benennt erst am Ende um.
pub fn toFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest: []const u8,
    progress: *Progress,
) !void {
    if (std.fs.path.dirname(dest)) |dir| try std.fs.cwd().makePath(dir);

    const part = try partPath(allocator, dest);
    defer allocator.free(part);

    // Schon Geladenes behalten und per Range-Header fortsetzen.
    const have: u64 = if (std.fs.cwd().statFile(part)) |st| st.size else |_| 0;
    var file = if (have > 0)
        try std.fs.cwd().openFile(part, .{ .mode = .write_only })
    else
        try std.fs.cwd().createFile(part, .{});
    defer file.close();
    progress.received.store(have, .monotonic);

    var range_buf: [64]u8 = undefined;
    const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have});
    const extra: []const std.http.Header = if (have > 0)
        &.{.{ .name = "range", .value = range }}
    else
        &.{};

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Datei-Writer der Standardbibliothek statt eines eigenen: ein selbstgebauter
    // Writer muss Zigs Pufferprotokoll bedienen (erst `w.buffer[0..w.end]`, dann
    // `data`, Rückgabe = aus `data` verbrauchte Bytes). Ein Writer, der das nicht
    // tut, meldet nie Fortschritt und `fetch` dreht sich endlos.
    var buf: [256 * 1024]u8 = undefined;
    var fw = file.writer(&buf);
    // `File.Writer` schreibt positional und beginnt bei 0. Ohne diese Zeile
    // überschreibt eine fortgesetzte Übertragung die schon geladenen Bytes von
    // vorn, und die Teildatei wächst nie über ihren alten Stand hinaus.
    fw.pos = have;

    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &fw.interface,
        .extra_headers = extra,
    }) catch |err| {
        std.log.scoped(.ai_setup).err("Download {s}: {s}", .{ url, @errorName(err) });
        return Error.DownloadFailed;
    };
    fw.interface.flush() catch return Error.DownloadFailed;

    if (res.status != .ok and res.status != .partial_content) {
        std.log.scoped(.ai_setup).err("Download {s}: HTTP {d}", .{ url, @intFromEnum(res.status) });
        return Error.DownloadFailed;
    }

    try std.fs.cwd().rename(part, dest);
    const st = try std.fs.cwd().statFile(dest);
    progress.received.store(st.size, .monotonic);
    progress.total.store(st.size, .monotonic);
}

/// Stand der laufenden Übertragung: Grösse der Teildatei. Die Oberfläche fragt das
/// im Zeichentakt ab — der Ladethread selbst schreibt nur Anfang und Ende, damit
/// hier kein eigener Writer mit Zählwerk nötig ist.
pub fn receivedSoFar(allocator: std.mem.Allocator, dest: []const u8) u64 {
    const part = partPath(allocator, dest) catch return 0;
    defer allocator.free(part);
    if (std.fs.cwd().statFile(part)) |st| return st.size else |_| {}
    if (std.fs.cwd().statFile(dest)) |st| return st.size else |_| {}
    return 0;
}

const testing = std.testing;

test "partPath hängt .part an" {
    const p = try partPath(testing.allocator, "/x/modell.gguf");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/x/modell.gguf.part", p);
}

test "percent rechnet erst, wenn die Gesamtgrösse bekannt ist" {
    var p = Progress{};
    try testing.expectEqual(@as(u8, 0), p.percent());
    p.total.store(200, .monotonic);
    p.received.store(50, .monotonic);
    try testing.expectEqual(@as(u8, 25), p.percent());
    p.received.store(1000, .monotonic);
    try testing.expectEqual(@as(u8, 100), p.percent());
}
