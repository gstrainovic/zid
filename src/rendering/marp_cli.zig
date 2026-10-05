//! Marp-Deck → PDF über marp-cli, das zid selbst einrichtet.
//!
//! marp-cli ist Marps eigener Konverter: Markdown → HTML/CSS mit Marp Core, gedruckt
//! von einem Browser. Das Ergebnis ist dasselbe wie in VS Code. zid lädt die
//! eigenständige Ausgabe (Node eingebaut, ein Programm) beim ersten Export ins
//! Datenverzeichnis. Als Browser nimmt marp-cli Chrome, Edge oder Firefox; findet es
//! keinen, lädt zid chrome-headless-shell nach und übergibt den Pfad.
//!
//! Ein Export läuft in einem eigenen Thread (Download, dann einige Sekunden Umwandlung);
//! die Oberfläche fragt den Zustand je Frame ab.

const std = @import("std");
const builtin = @import("builtin");
const download = @import("download");
const ai_selfsetup = @import("ai_selfsetup");
const install = ai_selfsetup.install;
const setup = ai_selfsetup.setup;

const log = std.log.scoped(.marp_cli);

/// Gepinnt statt „latest": eine Version, die einmal geprüft wurde, bleibt geprüft.
pub const marp_tag = "v4.5.1";
pub const chrome_version = "154.0.8037.57";

const exe_suffix = setup.exe_suffix;

/// Archiv der eigenständigen marp-cli für diese Plattform. Es enthält nur das
/// Programm `marp` bzw. `marp.exe`, ohne Ordner davor.
pub fn marpAsset() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "marp-cli-" ++ marp_tag ++ "-win.zip",
        .macos => "marp-cli-" ++ marp_tag ++ "-mac.tar.gz",
        else => if (builtin.cpu.arch == .aarch64)
            "marp-cli-" ++ marp_tag ++ "-linux-arm64.tar.gz"
        else
            "marp-cli-" ++ marp_tag ++ "-linux.tar.gz",
    };
}

pub fn marpUrl(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://github.com/marp-team/marp-cli/releases/download/{s}/{s}", .{ marp_tag, marpAsset() });
}

/// Plattformname bei Chrome for Testing; null, wo es keine chrome-headless-shell
/// gibt (Linux auf ARM).
pub fn chromePlatform() ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => if (builtin.cpu.arch == .x86) "win32" else "win64",
        .macos => if (builtin.cpu.arch == .aarch64) "mac-arm64" else "mac-x64",
        .linux => if (builtin.cpu.arch == .x86_64) "linux64" else null,
        else => null,
    };
}

pub fn chromeUrl(allocator: std.mem.Allocator, platform: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://storage.googleapis.com/chrome-for-testing-public/{s}/{s}/chrome-headless-shell-{s}.zip",
        .{ chrome_version, platform, platform },
    );
}

/// Ablage der Werkzeuge: `ZID_TOOLS_DIR`, sonst `<Datenverzeichnis>/tools`. Die
/// Umgebungsvariable nutzen die E2E, damit nicht jeder Lauf neu lädt.
pub fn toolsRoot(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "ZID_TOOLS_DIR")) |dir| return dir else |_| {}
    const data = try setup.dataRoot(allocator);
    defer allocator.free(data);
    return std.fs.path.join(allocator, &.{ data, "tools" });
}

/// `<tools>/marp-cli-<tag>`: die Version im Pfad, damit ein neuer Pin nicht in einem
/// halb ausgetauschten Ordner endet.
pub fn marpDir(allocator: std.mem.Allocator, tools: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ tools, "marp-cli-" ++ marp_tag });
}

pub fn marpExe(allocator: std.mem.Allocator, tools: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ tools, "marp-cli-" ++ marp_tag, "marp" ++ exe_suffix });
}

pub fn chromeDir(allocator: std.mem.Allocator, tools: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ tools, "chrome-headless-shell-" ++ chrome_version });
}

/// Das Zip legt einen Ordner `chrome-headless-shell-<plattform>/` an.
pub fn chromeExe(allocator: std.mem.Allocator, tools: []const u8, platform: []const u8) ![]u8 {
    const sub = try std.fmt.allocPrint(allocator, "chrome-headless-shell-{s}", .{platform});
    defer allocator.free(sub);
    return std.fs.path.join(allocator, &.{ tools, "chrome-headless-shell-" ++ chrome_version, sub, "chrome-headless-shell" ++ exe_suffix });
}

/// Ablage der Vorschau-PDFs: `<tools>/preview/<hash>/<name>.pdf`. Der Hash des Deck-Pfads
/// trennt gleichnamige Decks; der Dateiname bleibt der des Decks, damit der Tab lesbar ist.
/// Neben dem PDF liegt `source.txt` mit dem Pfad des Decks (Wiederaufnahme nach Neustart).
pub fn previewPath(allocator: std.mem.Allocator, tools: []const u8, md_path: []const u8) ![]u8 {
    var hash_buf: [16]u8 = undefined;
    const hash = std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, md_path)}) catch unreachable;
    const stem = std.fs.path.stem(md_path);
    const name = try std.fmt.allocPrint(allocator, "{s}.pdf", .{stem});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ tools, "preview", hash, name });
}

/// Ist `path` ein Vorschau-PDF (`…/preview/<16 Hex-Zeichen>/<name>.pdf`)? Am Pfad erkannt,
/// ohne Datenverzeichnis: die Tab-Leiste braucht das je Tab.
pub fn isPreviewPath(path: []const u8) bool {
    if (!std.ascii.endsWithIgnoreCase(path, ".pdf")) return false;
    const hash_dir = std.fs.path.dirname(path) orelse return false;
    const hash = std.fs.path.basename(hash_dir);
    if (hash.len != 16) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    const parent = std.fs.path.dirname(hash_dir) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(parent), "preview");
}

/// Pfad des Decks zu einem Vorschau-PDF (aus `source.txt` daneben); owned, null ohne Datei.
pub fn previewSource(allocator: std.mem.Allocator, pdf_path: []const u8) ?[]u8 {
    const dir = std.fs.path.dirname(pdf_path) orelse return null;
    const src = std.fs.path.join(allocator, &.{ dir, "source.txt" }) catch return null;
    defer allocator.free(src);
    return std.fs.cwd().readFileAlloc(allocator, src, std.fs.max_path_bytes) catch null;
}

/// Zieldatei neben der Quelle: `deck.md` → `deck.pdf`.
pub fn outputPath(allocator: std.mem.Allocator, md_path: []const u8) ![]u8 {
    const ext = std.fs.path.extension(md_path);
    return std.fmt.allocPrint(allocator, "{s}.pdf", .{md_path[0 .. md_path.len - ext.len]});
}

/// Aufruf von marp-cli. `--no-stdin`: ohne Terminal liest marp sonst die Eingabe
/// als Markdown und wartet. `--allow-local-files` für Bilder neben dem Deck.
pub fn argv(
    allocator: std.mem.Allocator,
    exe: []const u8,
    md_path: []const u8,
    out_path: []const u8,
    browser_path: ?[]const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ exe, "--no-stdin", "--pdf", "--allow-local-files" });
    if (browser_path) |p| try list.appendSlice(allocator, &.{ "--browser", "chrome", "--browser-path", p });
    try list.appendSlice(allocator, &.{ md_path, "-o", out_path });
    return list.toOwnedSlice(allocator);
}

/// marp-cli im Watch-Modus: rendert `md_path` bei jeder Änderung neu nach `out_path`,
/// der Browser bleibt offen (rund 1 s statt 3 s je Durchlauf). Ausgaben werden
/// verworfen: eine volle Pipe hielte den Prozess an.
pub fn spawnWatch(
    allocator: std.mem.Allocator,
    exe: []const u8,
    md_path: []const u8,
    out_path: []const u8,
    browser_path: ?[]const u8,
) !std.process.Child {
    const base = try argv(allocator, exe, md_path, out_path, browser_path);
    defer allocator.free(base);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, base[0]);
    try args.append(allocator, "--watch");
    try args.appendSlice(allocator, base[1..]);

    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = std.fs.path.dirname(md_path);
    // Eigene Prozessgruppe: `stopWatch` beendet marp samt Browser.
    if (builtin.os.tag != .windows) child.pgid = 0;
    try child.spawn();
    return child;
}

/// Watch-Prozess beenden, ohne den Aufrufer (Hauptthread) unbegrenzt zu blockieren.
/// Unter Linux/macOS SIGINT an die Prozessgruppe: Solange der Browser offen ist, fängt
/// puppeteer SIGTERM ab und schliesst nur den Browser, marp liefe weiter; auf SIGINT
/// beendet es Browser (eigene Gruppe) und Prozess. Reagiert marp nicht, SIGKILL.
/// Unter Windows beendet sich der Browser mit marp.
pub fn stopWatch(child: *std.process.Child) void {
    if (builtin.os.tag != .windows) {
        std.posix.kill(-child.id, std.posix.SIG.INT) catch {};
        var waited_ms: u32 = 0;
        while (std.posix.waitpid(child.id, std.posix.W.NOHANG).pid == 0) : (waited_ms += 20) {
            if (waited_ms == 2000) std.posix.kill(-child.id, std.posix.SIG.KILL) catch {};
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
        return;
    }
    _ = child.kill() catch {};
}

/// marp-cli fand keinen Browser (Chrome, Edge, Firefox).
pub fn browserMissing(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "No suitable browser found") != null;
}

/// Die aussagekräftige Zeile aus marp-clis Fehlerausgabe: die mit `[ ERROR ]`,
/// sonst die letzte nicht-leere.
pub fn errorLine(stderr: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "[ ERROR ]")) |i| return std.mem.trim(u8, line[i + "[ ERROR ]".len ..], " ");
        last = line;
    }
    return last;
}

pub const State = enum(u8) { idle, loading_marp, loading_browser, converting, done, failed };

pub const Exporter = struct {
    allocator: std.mem.Allocator,
    progress: download.Progress = .{},
    state: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    thread: ?std.Thread = null,
    md_path: []u8 = &.{},
    out_path: []u8 = &.{},
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,
    /// Nach `done`: der selbst geladene Browser, falls marp-cli ihn brauchte (owned).
    /// Ein Watch-Prozess für dasselbe Deck bekommt ihn mit.
    browser_used: ?[]u8 = null,
    /// Weckt den Frame-Loop, wenn sich der Zustand ändert (im Fenster `wio.cancelWait`).
    wake: ?*const fn () void = null,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.thread) |t| t.join();
        self.allocator.free(self.md_path);
        self.allocator.free(self.out_path);
        if (self.browser_used) |b| self.allocator.free(b);
    }

    pub fn currentState(self: *const Self) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    pub fn busy(self: *const Self) bool {
        return switch (self.currentState()) {
            .loading_marp, .loading_browser, .converting => true,
            else => false,
        };
    }

    /// Fehlertext nach `.failed`.
    pub fn message(self: *const Self) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    /// Ergebnis abgeholt: zurück auf idle.
    pub fn acknowledge(self: *Self) void {
        if (!self.busy()) self.setState(.idle);
    }

    /// Export im Hintergrund starten. Läuft schon einer: error.Busy.
    pub fn start(self: *Self, md_path: []const u8, out_path: []const u8) !void {
        if (self.busy()) return error.Busy;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.allocator.free(self.md_path);
        self.allocator.free(self.out_path);
        self.md_path = &.{};
        self.out_path = &.{};
        self.md_path = try self.allocator.dupe(u8, md_path);
        self.out_path = try self.allocator.dupe(u8, out_path);
        self.message_len = 0;
        self.setState(.converting);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn setState(self: *Self, s: State) void {
        self.state.store(@intFromEnum(s), .release);
        if (self.wake) |w| w();
    }

    fn fail(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message_buf, fmt, args) catch self.message_buf[0..];
        self.message_len = text.len;
        log.err("{s}", .{text});
        self.setState(.failed);
    }

    fn run(self: *Self) void {
        const a = self.allocator;
        const tools = toolsRoot(a) catch |err| return self.fail("Datenverzeichnis: {t}", .{err});
        defer a.free(tools);

        const exe = marpExe(a, tools) catch |err| return self.fail("{t}", .{err});
        defer a.free(exe);
        if (!setup.present(exe)) {
            self.setState(.loading_marp);
            self.installMarp(tools, exe) catch |err|
                return self.fail("marp-cli konnte nicht geladen werden ({t}). Besteht eine Internetverbindung?", .{err});
            self.setState(.converting);
        }

        const platform = chromePlatform();
        var browser: ?[]u8 = null;
        defer if (browser) |b| a.free(b);
        if (platform) |p| {
            const path = chromeExe(a, tools, p) catch |err| return self.fail("{t}", .{err});
            if (setup.present(path)) browser = path else a.free(path);
        }

        var result = self.convert(exe, browser) catch |err| return self.fail("marp-cli ließ sich nicht starten: {t}", .{err});
        defer a.free(result.stderr);

        if (!result.ok and browser == null and browserMissing(result.stderr)) {
            const p = platform orelse
                return self.fail("Kein Browser gefunden: Chrome, Edge oder Firefox installieren.", .{});
            self.setState(.loading_browser);
            const path = self.installChrome(tools, p) catch |err|
                return self.fail("Browser für den Export konnte nicht geladen werden ({t}).", .{err});
            browser = path;
            self.setState(.converting);
            a.free(result.stderr);
            result = self.convert(exe, path) catch |err| {
                result = .{ .ok = false, .stderr = &.{} };
                return self.fail("marp-cli ließ sich nicht starten: {t}", .{err});
            };
        }

        if (!result.ok) return self.fail("marp-cli: {s}", .{errorLine(result.stderr)});
        if (!setup.present(self.out_path)) return self.fail("marp-cli hat kein PDF geschrieben.", .{});
        log.info("PDF geschrieben: {s}", .{self.out_path});
        if (self.browser_used) |b| a.free(b);
        self.browser_used = if (browser) |b| a.dupe(u8, b) catch null else null;
        self.setState(.done);
    }

    const Converted = struct { ok: bool, stderr: []const u8 };

    fn convert(self: *Self, exe: []const u8, browser: ?[]const u8) !Converted {
        const a = self.allocator;
        const args = try argv(a, exe, self.md_path, self.out_path, browser);
        defer a.free(args);

        var child = std.process.Child.init(args, a);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        // Relative Bildpfade löst marp ab dem Deck auf, das Arbeitsverzeichnis ist egal;
        // der Ordner des Decks hält Nebeneffekte aber dort, wo der Nutzer sie erwartet.
        child.cwd = std.fs.path.dirname(self.md_path);
        try child.spawn();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        var err: std.ArrayList(u8) = .empty;
        errdefer err.deinit(a);
        child.collectOutput(a, &out, &err, 1024 * 1024) catch |e| {
            _ = child.kill() catch {};
            return e;
        };
        const term = try child.wait();
        const ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        // marp schreibt auch Fortschritt nach stderr; bei Erfolg nur fürs Log.
        if (!ok) log.warn("marp-cli: {s}", .{err.items});
        return .{ .ok = ok, .stderr = try err.toOwnedSlice(a) };
    }

    fn installMarp(self: *Self, tools: []const u8, exe: []const u8) !void {
        const a = self.allocator;
        const dir = try marpDir(a, tools);
        defer a.free(dir);
        const archive = try std.fs.path.join(a, &.{ dir, marpAsset() });
        defer a.free(archive);
        const url = try marpUrl(a);
        defer a.free(url);

        self.progress.total.store(49_000_000, .monotonic); // Richtwert für die Anzeige
        log.info("lade marp-cli: {s}", .{url});
        try download.toFile(a, url, archive, &self.progress);
        if (std.mem.endsWith(u8, archive, ".zip"))
            try install.extractZip(archive, dir)
        else
            try install.extractTarGz(archive, dir, 0);
        std.fs.cwd().deleteFile(archive) catch {};
        if (!setup.present(exe)) return error.MarpIncomplete;
    }

    /// Lädt chrome-headless-shell; der Aufrufer gibt den Pfad frei.
    fn installChrome(self: *Self, tools: []const u8, platform: []const u8) ![]u8 {
        const a = self.allocator;
        const dir = try chromeDir(a, tools);
        defer a.free(dir);
        const archive = try std.fs.path.join(a, &.{ dir, "chrome-headless-shell.zip" });
        defer a.free(archive);
        const url = try chromeUrl(a, platform);
        defer a.free(url);

        self.progress.total.store(121_000_000, .monotonic);
        log.info("lade chrome-headless-shell: {s}", .{url});
        try download.toFile(a, url, archive, &self.progress);
        try install.extractZip(archive, dir);
        std.fs.cwd().deleteFile(archive) catch {};

        const exe = try chromeExe(a, tools, platform);
        errdefer a.free(exe);
        if (!setup.present(exe)) return error.BrowserIncomplete;
        // Zigs Zip-Entpacker setzt keine Rechte: Programm und Helfer ausführbar machen.
        if (builtin.os.tag != .windows) try makeExecutable(std.fs.path.dirname(exe).?);
        return exe;
    }
};

fn makeExecutable(dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.fs.path.extension(entry.name).len > 0) continue; // .so, .pak, .dat …
        var f = try dir.openFile(entry.name, .{});
        defer f.close();
        try f.chmod(0o755);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "marp-Asset und URL tragen den gepinnten Tag" {
    const url = try marpUrl(testing.allocator);
    defer testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, url, "https://github.com/marp-team/marp-cli/releases/download/" ++ marp_tag ++ "/"));
    try testing.expect(std.mem.endsWith(u8, url, marpAsset()));
    switch (builtin.os.tag) {
        .windows => try testing.expect(std.mem.endsWith(u8, marpAsset(), "-win.zip")),
        else => try testing.expect(std.mem.endsWith(u8, marpAsset(), ".tar.gz")),
    }
}

test "chrome-URL folgt dem Schema von Chrome for Testing" {
    const url = try chromeUrl(testing.allocator, "win64");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/chrome-for-testing-public/" ++ chrome_version ++ "/win64/chrome-headless-shell-win64.zip",
        url,
    );
}

test "Pfade liegen versioniert unter tools" {
    const sep = std.fs.path.sep_str;
    const m = try marpExe(testing.allocator, "/t");
    defer testing.allocator.free(m);
    try testing.expectEqualStrings("/t" ++ sep ++ "marp-cli-" ++ marp_tag ++ sep ++ "marp" ++ exe_suffix, m);
    const c = try chromeExe(testing.allocator, "/t", "linux64");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings(
        "/t" ++ sep ++ "chrome-headless-shell-" ++ chrome_version ++ sep ++ "chrome-headless-shell-linux64" ++ sep ++ "chrome-headless-shell" ++ exe_suffix,
        c,
    );
}

test "previewPath: Hash trennt gleichnamige Decks, Name bleibt lesbar" {
    const a = try previewPath(testing.allocator, "/t", "/x/deck.md");
    defer testing.allocator.free(a);
    const b = try previewPath(testing.allocator, "/t", "/y/deck.md");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqualStrings("deck.pdf", std.fs.path.basename(a));
    try testing.expect(isPreviewPath(a));
    try testing.expect(!isPreviewPath("/x/deck.pdf"));
    try testing.expect(!isPreviewPath("/t/preview/kein-hash/deck.pdf"));
    try testing.expect(!isPreviewPath("/t/anders/935a2a6d65a7e748/deck.pdf"));
}

test "previewSource liest den Deck-Pfad neben dem PDF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const pdf = try previewPath(testing.allocator, base, "/x/deck.md");
    defer testing.allocator.free(pdf);
    try std.fs.cwd().makePath(std.fs.path.dirname(pdf).?);
    try testing.expect(previewSource(testing.allocator, pdf) == null);
    const src = try std.fs.path.join(testing.allocator, &.{ std.fs.path.dirname(pdf).?, "source.txt" });
    defer testing.allocator.free(src);
    try std.fs.cwd().writeFile(.{ .sub_path = src, .data = "/x/deck.md" });
    const got = previewSource(testing.allocator, pdf).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/x/deck.md", got);
}

test "Watch-Funktionen übersetzen auf jeder Plattform" {
    // Nur Analyse erzwingen (Cross-Compile prüft so den Zweig der anderen Plattform).
    _ = &spawnWatch;
    _ = &stopWatch;
}

/// Startet `script` per `sh` in eigener Prozessgruppe wie `spawnWatch`, ruft `stopWatch`
/// und liefert die Dauer in ms.
fn stopWatchMs(script: []const u8) !i64 {
    var child = std.process.Child.init(&.{ "sh", "-c", script }, testing.allocator);
    child.stdin_behavior = .Ignore;
    child.pgid = 0;
    try child.spawn();
    std.Thread.sleep(300 * std.time.ns_per_ms); // trap ist gesetzt
    const t0 = std.time.milliTimestamp();
    stopWatch(&child);
    return std.time.milliTimestamp() - t0;
}

test "stopWatch beendet marp, auch wenn puppeteer SIGTERM abfängt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // puppeteer fängt SIGTERM ab, solange der Browser offen ist, und schliesst nur ihn.
    const ms = try stopWatchMs("trap ':' TERM; while :; do sleep 0.05; done");
    try testing.expect(ms < 1000);
}

test "stopWatch blockiert nicht, wenn der Prozess jedes höfliche Signal ignoriert" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ms = try stopWatchMs("trap '' TERM INT HUP; while :; do sleep 0.05; done");
    try testing.expect(ms < 5000);
}

test "outputPath ersetzt die Endung" {
    const out = try outputPath(testing.allocator, "docs/deck.md");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("docs/deck.pdf", out);
}

test "argv: ohne Browserpfad nimmt marp den eigenen, mit Pfad chrome" {
    const plain = try argv(testing.allocator, "marp", "a.md", "a.pdf", null);
    defer testing.allocator.free(plain);
    try testing.expectEqual(@as(usize, 7), plain.len);
    try testing.expectEqualStrings("--no-stdin", plain[1]);
    try testing.expectEqualStrings("a.pdf", plain[6]);

    const with = try argv(testing.allocator, "marp", "a.md", "a.pdf", "/c/chrome");
    defer testing.allocator.free(with);
    try testing.expectEqualStrings("--browser-path", with[6]);
    try testing.expectEqualStrings("/c/chrome", with[7]);
}

test "browserMissing und errorLine lesen marp-clis Ausgabe" {
    const stderr =
        \\[  INFO ] Converting 1 markdown...
        \\[ ERROR ] Failed converting Markdown. (No suitable browser found. Please ensure
        \\          one of the following browsers is installed: chrome)
        \\CLIError: No suitable browser found.
    ;
    try testing.expect(browserMissing(stderr));
    try testing.expect(!browserMissing("[ ERROR ] Failed converting Markdown. (ENOENT)"));
    try testing.expectEqualStrings("Failed converting Markdown. (No suitable browser found. Please ensure", errorLine(stderr));
    try testing.expectEqualStrings("zweite", errorLine("erste\n\nzweite\n"));
}
