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

/// Variantenwähler (U+FE00–U+FE0F) steuern nur, ob ein Zeichen als Text oder als
/// Emoji gilt. Sie sind unsichtbar und ohne Breite. NotoColorEmoji kennt sie nicht,
/// FreeType gäbe also das Ersatzzeichen samt Vorschub zurück — eine Lücke mitten
/// im Satz.
pub fn isVariationSelector(cp: u21) bool {
    return cp >= 0xFE00 and cp <= 0xFE0F;
}

/// Setzt dieses Zeichen das vorherige fort, statt für sich zu stehen? Solche
/// Zeichen dürfen nie von ihrem Grundzeichen getrennt werden, sonst formt
/// HarfBuzz die Folge nicht zusammen: aus 1️⃣ würde eine 1 neben einem leeren
/// Kasten.
pub fn continuesCluster(cp: u21) bool {
    return switch (cp) {
        0xFE00...0xFE0F => true, // Variantenwähler
        0x200D => true, // Zero-Width-Joiner (👩‍💻)
        0x20E3 => true, // umschliessende Taste (1️⃣)
        0x1F3FB...0x1F3FF => true, // Hautton
        0xE0020...0xE007F => true, // Tag-Zeichen (Flaggen von Landesteilen)
        0x0300...0x036F => true, // kombinierende Akzente
        else => false,
    };
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

test "isVariationSelector trifft nur die unsichtbaren Wähler" {
    try testing.expect(isVariationSelector(0xFE0F));
    try testing.expect(isVariationSelector(0xFE0E));
    try testing.expect(!isVariationSelector(0x200D)); // ZWJ verbindet, er wird gebraucht
    try testing.expect(!isVariationSelector(0x26A0)); // ⚠ selbst
    try testing.expect(!isVariationSelector('a'));
}

test "continuesCluster erkennt anhängende Zeichen" {
    try testing.expect(continuesCluster(0xFE0F));
    try testing.expect(continuesCluster(0x200D));
    try testing.expect(continuesCluster(0x20E3));
    try testing.expect(continuesCluster(0x1F3FD)); // Hautton
    try testing.expect(!continuesCluster(0x1F469)); // 👩 steht für sich
    try testing.expect(!continuesCluster('1'));
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
