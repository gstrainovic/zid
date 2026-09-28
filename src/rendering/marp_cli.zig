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
    /// Weckt den Frame-Loop, wenn sich der Zustand ändert (im Fenster `wio.cancelWait`).
    wake: ?*const fn () void = null,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.thread) |t| t.join();
        self.allocator.free(self.md_path);
        self.allocator.free(self.out_path);
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
