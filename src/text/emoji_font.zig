//! Farbige Emoji-Schrift bereitstellen.
//!
//! JetBrains Mono hat keine Emoji; ohne Rückfall zeichnet zid ein leeres Kästchen.
//! zid rastert Emoji über FreeType, und FreeType liefert nur für Bitmap-Schriften
//! (CBDT, etwa NotoColorEmoji) fertige Farbbilder. Die neuere COLRv1-Fassung, die
//! Fedora ausliefert, besteht aus Malanweisungen, die FreeType nicht selbst
//! ausmalt: dort kommt ein leeres Bitmap zurück.
//!
//! Deshalb zwei Wege: passt eine Schrift des Systems, wird sie genommen; sonst
//! lädt zid NotoColorEmoji einmalig in sein Datenverzeichnis. Der Nutzer muss
//! nichts installieren.

const std = @import("std");
const builtin = @import("builtin");
const font_cache = @import("font_cache.zig");
const download = @import("download");

const log = std.log.scoped(.emoji);

/// Bekannte Orte einer Bitmap-Emoji-Schrift. Debian, Ubuntu und Arch liefern sie
/// so aus; Fedora hat nur COLRv1 und fällt deshalb auf den Download zurück.
pub const candidates: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{
        "C:\\Windows\\Fonts\\seguiemj.ttf",
    },
    .macos => &.{
        "/System/Library/Fonts/Apple Color Emoji.ttc",
    },
    else => &.{
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
        "/usr/share/fonts/google-noto-color-emoji-fonts/NotoColorEmoji.ttf",
        "/usr/share/fonts/truetype/twemoji/TwemojiMozilla.ttf",
    },
};

/// Auf diese Fassung festgenagelt: spätere Stände des Repos enthalten die
/// gebaute Schrift nicht mehr, nur noch die Quellen.
pub const download_url = "https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.047/fonts/NotoColorEmoji.ttf";
pub const file_name = "NotoColorEmoji.ttf";
/// Grösse der Datei bei dieser Fassung; dient nur der Anzeige im Log.
pub const download_bytes: u64 = 10_643_852;

/// Erster vorhandener Kandidat des Systems, sonst null. Ob die Schrift auch
/// brauchbar ist (Farbbilder statt Malanweisungen), entscheidet erst das
/// Textsystem beim Laden.
pub fn findSystem() ?[]const u8 {
    for (candidates) |path| {
        if (std.fs.cwd().access(path, .{})) |_| return path else |_| {}
    }
    return null;
}

/// Pfad der selbst geladenen Schrift im Datenverzeichnis. Aufrufer gibt ihn frei.
pub fn cachedPath(allocator: std.mem.Allocator) ![]u8 {
    return font_cache.cachePath(allocator, file_name);
}

/// Liegt die selbst geladene Schrift schon da? Aufrufer gibt den Pfad frei.
pub fn findCached(allocator: std.mem.Allocator) ?[]u8 {
    const path = cachedPath(allocator) catch return null;
    if (std.fs.cwd().access(path, .{})) |_| return path else |_| {
        allocator.free(path);
        return null;
    }
}

/// Zustand des Nachladens. Wird aus dem Ladethread geschrieben.
const State = enum(u8) { idle, running, done, failed, consumed };
var state: std.atomic.Value(u8) = .init(@intFromEnum(State.idle));

/// Schrift im Hintergrund holen, höchstens einmal je Lauf. Schlägt es fehl,
/// bleibt es beim leeren Kästchen — Emoji sind kein Grund für eine Fehlermeldung.
pub fn startFetch() void {
    if (state.cmpxchgStrong(
        @intFromEnum(State.idle),
        @intFromEnum(State.running),
        .monotonic,
        .monotonic,
    ) != null) return;

    const thread = std.Thread.spawn(.{}, fetchThread, .{}) catch {
        state.store(@intFromEnum(State.failed), .monotonic);
        return;
    };
    thread.detach();
}

fn fetchThread() void {
    const allocator = std.heap.page_allocator;
    const path = cachedPath(allocator) catch {
        state.store(@intFromEnum(State.failed), .monotonic);
        return;
    };
    defer allocator.free(path);

    log.info("lade Emoji-Schrift ({d} MB) nach {s}", .{ download_bytes / 1024 / 1024, path });
    var progress: download.Progress = .{};
    download.toFile(allocator, download_url, path, &progress) catch |err| {
        log.warn("Emoji-Schrift nicht ladbar: {s}", .{@errorName(err)});
        state.store(@intFromEnum(State.failed), .monotonic);
        return;
    };
    log.info("Emoji-Schrift geladen", .{});
    state.store(@intFromEnum(State.done), .monotonic);
}

/// Meldet genau einmal, dass das Nachladen fertig ist. Danach false, damit das
/// Textsystem nicht in jedem Frame erneut zu laden versucht.
pub fn takeFinished() bool {
    return state.cmpxchgStrong(
        @intFromEnum(State.done),
        @intFromEnum(State.consumed),
        .monotonic,
        .monotonic,
    ) == null;
}

/// Läuft gerade ein Download?
pub fn fetchRunning() bool {
    return state.load(.monotonic) == @intFromEnum(State.running);
}

const testing = std.testing;

test "Kandidatenliste passt zur Plattform und ist nicht leer" {
    try testing.expect(candidates.len > 0);
    for (candidates) |p| try testing.expect(p.len > 0);
}

test "cachedPath liegt im Datenverzeichnis von zid" {
    const p = try cachedPath(testing.allocator);
    defer testing.allocator.free(p);
    const sep = std.fs.path.sep_str;
    try testing.expect(std.mem.endsWith(u8, p, "zid" ++ sep ++ "fonts" ++ sep ++ file_name));
}

test "takeFinished meldet den Abschluss genau einmal" {
    state.store(@intFromEnum(State.done), .monotonic);
    try testing.expect(takeFinished());
    try testing.expect(!takeFinished());
    state.store(@intFromEnum(State.idle), .monotonic);
}

test "startFetch läuft nur einmal an" {
    state.store(@intFromEnum(State.running), .monotonic);
    startFetch(); // darf den Zustand nicht zurücksetzen
    try testing.expectEqual(@intFromEnum(State.running), state.load(.monotonic));
    state.store(@intFromEnum(State.idle), .monotonic);
}

test "die feste Adresse zeigt auf eine Fassung, nicht auf den Hauptzweig" {
    try testing.expect(std.mem.indexOf(u8, download_url, "/v2.047/") != null);
    try testing.expect(std.mem.endsWith(u8, download_url, file_name));
}
