//! Timeline der aktiven Datei wie VS Codes Explorer-Abschnitt „Timeline“, ohne Clay:
//! git-Log der Datei, relative Zeiten (`fromNow` aus VS Code base/common/date.ts),
//! Hover-Text, Nachfolge der aktiven Datei, Anpinnen und der Diff zum vorigen Datei-Commit.
//! Quellen: vscode extensions/git/src/timelineProvider.ts, hover.ts,
//! src/vs/workbench/contrib/timeline/browser/timelinePane.ts.

const std = @import("std");
const git_diff = @import("git_diff");

const testing = std.testing;

const minute: i64 = 60;
const hour: i64 = minute * 60;
const day: i64 = hour * 24;
const week: i64 = day * 7;
const month: i64 = day * 30;
const year: i64 = day * 365;

/// VS Code `fromNow(date)` ohne „ago“ und mit Kurzwörtern (Zeitspalte der Timeline).
pub fn fromNow(buf: []u8, now: i64, timestamp: i64) []const u8 {
    return formatAge(buf, now - timestamp, false);
}

/// VS Code `fromNow(date, true, true)`: volle Wörter mit „ago“ (Hover).
pub fn fromNowLong(buf: []u8, now: i64, timestamp: i64) []const u8 {
    return formatAge(buf, now - timestamp, true);
}

fn formatAge(buf: []u8, seconds: i64, long: bool) []const u8 {
    if (seconds < -30) {
        var inner: [32]u8 = undefined;
        const text = formatAge(&inner, -seconds, long);
        return std.fmt.bufPrint(buf, "in {s}", .{text}) catch "";
    }
    if (seconds < 30) return "now";
    const Unit = struct { limit: ?i64, size: i64, short: [2][]const u8, long: [2][]const u8 };
    const units = [_]Unit{
        .{ .limit = minute, .size = 1, .short = .{ "sec", "secs" }, .long = .{ "second", "seconds" } },
        .{ .limit = hour, .size = minute, .short = .{ "min", "mins" }, .long = .{ "minute", "minutes" } },
        .{ .limit = day, .size = hour, .short = .{ "hr", "hrs" }, .long = .{ "hour", "hours" } },
        .{ .limit = week, .size = day, .short = .{ "day", "days" }, .long = .{ "day", "days" } },
        .{ .limit = month, .size = week, .short = .{ "wk", "wks" }, .long = .{ "week", "weeks" } },
        .{ .limit = year, .size = month, .short = .{ "mo", "mos" }, .long = .{ "month", "months" } },
        .{ .limit = null, .size = year, .short = .{ "yr", "yrs" }, .long = .{ "year", "years" } },
    };
    for (units) |u| {
        if (u.limit) |l| if (seconds >= l) continue;
        // Math.round aus JavaScript: .5 rundet auf
        const value: i64 = @divFloor(seconds * 2 + u.size, u.size * 2);
        const words = if (long) u.long else u.short;
        const word = if (value == 1) words[0] else words[1];
        return std.fmt.bufPrint(buf, "{d} {s}{s}", .{ value, word, if (long) " ago" else "" }) catch "";
    }
    unreachable;
}

/// `git log --shortstat` einer Datei: Dateien, Einfügungen, Löschungen.
pub const Stat = struct { files: u32 = 0, insertions: u32 = 0, deletions: u32 = 0 };

/// `staged`: VS Code „Staged Changes“ (Index gegen HEAD), erscheint, sobald die Datei gestagt ist.
pub const ItemKind = enum { commit, staged };

pub const Item = struct {
    kind: ItemKind = .commit,
    /// Name im Hover, falls anders als die Beschreibung (VS Code: „You“ beim Index)
    hover_author: []const u8 = "",
    hash: []const u8 = "",
    /// Commit-Datum in Sekunden (VS Code `git.timeline.date`: committed)
    timestamp: i64 = 0,
    author: []const u8 = "",
    email: []const u8 = "",
    /// Datum für den Hover, von git formatiert
    date_text: []const u8 = "",
    message: []const u8 = "",
    /// Erste Zeile der Nachricht
    label: []const u8 = "",
    stat: Stat = .{},
    /// Pfad der Datei in diesem Commit (relativ zur Repo-Wurzel)
    path: []const u8 = "",
    /// VS Code `previousRef`: nächstälterer Commit der Datei, leer = leerer Baum
    previous_ref: []const u8 = "",
    previous_path: []const u8 = "",
};

pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item,

    pub fn deinit(self: *Log) void {
        self.arena.deinit();
    }
};

/// Obergrenze der geladenen Einträge (VS Code lädt seitenweise mit „Load more“).
pub const max_items = "500";

const log_format = "--format=%x1e%H%x1f%ct%x1f%an%x1f%ae%x1f%cd%x1f%B%x1d";
/// Wie `toLocaleString(month: long, day, year, hour, minute)`: Monatsname in der Locale wie in
/// VS Code, 24 Stunden (`%p` ist in manchen Locales leer), %d statt %-d (Windows-strftime).
const date_format = "--date=format:%B %d, %Y at %H:%M";

/// Argumente für `git log` einer Datei (Arbeitsordner: Ordner der Datei). `--numstat` liefert
/// Zahlen und Pfad je Commit; `--shortstat` mit `--name-only` ergab keine Zahlen.
pub fn logArgs(buf: *[16][]const u8, abs_file: []const u8) []const []const u8 {
    const args = [_][]const u8{ "log", "--no-color", "--follow", "--numstat", log_format, date_format, "-n", max_items, "--", std.fs.path.basename(abs_file) };
    @memcpy(buf[0..args.len], &args);
    return buf[0..args.len];
}

/// `git diff --cached --name-status` für die Datei: steht sie im Index?
pub fn stagedArgs(buf: *[16][]const u8, abs_file: []const u8) []const []const u8 {
    const args = [_][]const u8{ "diff", "--no-color", "--cached", "--name-status", "--", std.fs.path.basename(abs_file) };
    @memcpy(buf[0..args.len], &args);
    return buf[0..args.len];
}

/// Statuszeile → Text wie VS Code `Resource.getStatusText` (INDEX_*), null ohne Eintrag.
pub fn parseStagedStatus(out: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, out, " \r\n");
    if (line.len == 0) return null;
    return switch (line[0]) {
        'M' => "Index Modified",
        'A' => "Index Added",
        'D' => "Index Deleted",
        'R' => "Index Renamed",
        'C' => "Index Copied",
        'T' => "Index Modified",
        else => null,
    };
}

pub fn parseLog(alloc: std.mem.Allocator, out: []const u8) !Log {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const text = try a.dupe(u8, out);
    var items: std.ArrayListUnmanaged(Item) = .empty;

    var records = std.mem.splitScalar(u8, text, 0x1e);
    _ = records.next();
    while (records.next()) |record| {
        const end = std.mem.indexOfScalar(u8, record, 0x1d) orelse continue;
        var fields = std.mem.splitScalar(u8, record[0..end], 0x1f);
        var f: [6][]const u8 = undefined;
        var n: usize = 0;
        while (n < 5) : (n += 1) f[n] = fields.next() orelse break;
        if (n < 5) continue;
        f[5] = fields.rest();
        const message = std.mem.trimRight(u8, f[5], " \t\r\n");
        var item = Item{
            .hash = f[0],
            .timestamp = std.fmt.parseInt(i64, f[1], 10) catch 0,
            .author = f[2],
            .email = f[3],
            .date_text = f[4],
            .message = message,
            .label = message[0 .. std.mem.indexOfScalar(u8, message, '\n') orelse message.len],
        };
        // numstat: "<plus>\t<minus>\t<pfad>", binär "-\t-\t<pfad>"
        var lines = std.mem.splitScalar(u8, record[end + 1 ..], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimRight(u8, raw, "\r");
            var cols = std.mem.splitScalar(u8, line, '\t');
            const plus = cols.next() orelse continue;
            const minus = cols.next() orelse continue;
            const path = cols.next() orelse continue;
            item.stat.files += 1;
            item.stat.insertions += std.fmt.parseInt(u32, plus, 10) catch 0;
            item.stat.deletions += std.fmt.parseInt(u32, minus, 10) catch 0;
            if (item.path.len == 0) item.path = try a.dupe(u8, numstatPath(path));
        }
        try items.append(a, item);
    }
    const all = try items.toOwnedSlice(a);
    for (all, 0..) |*it, i| {
        if (i + 1 < all.len) {
            it.previous_ref = all[i + 1].hash;
            it.previous_path = all[i + 1].path;
        }
    }
    return .{ .arena = arena, .items = all };
}

var numstat_buf: [std.fs.max_path_bytes]u8 = undefined;

/// Neuer Pfad aus einer numstat-Pfadangabe: `alt => neu` oder `pre/{alt => neu}/post`.
/// Das Ergebnis liegt bei der Klammer-Form in einem internen Puffer; Aufrufer kopieren es.
pub fn numstatPath(path: []const u8) []const u8 {
    const arrow = std.mem.indexOf(u8, path, " => ") orelse return path;
    const open = std.mem.indexOfScalar(u8, path, '{');
    const close = std.mem.indexOfScalar(u8, path, '}');
    if (open == null or close == null or open.? > arrow or close.? < arrow) return path[arrow + 4 ..];
    const prefix = path[0..open.?];
    const new_part = path[arrow + 4 .. close.?];
    var suffix = path[close.? + 1 ..];
    // leerer Teil „{ => }“: doppelten Schrägstrich vermeiden
    if (new_part.len == 0 and suffix.len > 0 and suffix[0] == '/' and std.mem.endsWith(u8, prefix, "/")) suffix = suffix[1..];
    return std.fmt.bufPrint(&numstat_buf, "{s}{s}{s}", .{ prefix, new_part, suffix }) catch path;
}

pub const Label = struct { text: []u8, hidden: bool };

/// Zeitspalte: gleiche relative Zeit direkt untereinander wird ausgeblendet
/// (VS Code `updateRelativeTime` / `hideRelativeTime`).
pub fn relativeLabels(alloc: std.mem.Allocator, items: []const Item, now: i64) ![]Label {
    const labels = try alloc.alloc(Label, items.len);
    var done: usize = 0;
    errdefer {
        for (labels[0..done]) |l| alloc.free(l.text);
        alloc.free(labels);
    }
    var buf: [32]u8 = undefined;
    for (items, 0..) |it, i| {
        const text = try alloc.dupe(u8, fromNow(&buf, now, it.timestamp));
        labels[i] = .{ .text = text, .hidden = i > 0 and std.mem.eql(u8, text, labels[i - 1].text) };
        done += 1;
    }
    return labels;
}

pub fn freeLabels(alloc: std.mem.Allocator, labels: []Label) void {
    for (labels) |l| alloc.free(l.text);
    alloc.free(labels);
}

pub const Hover = struct { header: []u8, message: []const u8, stats: []u8 };

/// Hover wie VS Code `getCommitHover`: „Autor, 2 hours ago (Datum)“, Nachricht, Statistik.
pub fn hoverText(alloc: std.mem.Allocator, item: Item, now: i64) !Hover {
    var age_buf: [32]u8 = undefined;
    const who = if (item.hover_author.len > 0) item.hover_author else item.author;
    const age = fromNowLong(&age_buf, now, item.timestamp);
    const header = if (item.date_text.len > 0)
        try std.fmt.allocPrint(alloc, "{s}, {s} ({s})", .{ who, age, item.date_text })
    else
        try std.fmt.allocPrint(alloc, "{s}, {s}", .{ who, age });
    errdefer alloc.free(header);
    var stats: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stats.deinit(alloc);
    // VS Code gibt dem Index-Eintrag keine Statistik mit
    if (item.kind == .staged) return .{ .header = header, .message = item.message, .stats = try stats.toOwnedSlice(alloc) };
    const w = stats.writer(alloc);
    try w.print("{d} {s} changed", .{ item.stat.files, if (item.stat.files == 1) "file" else "files" });
    if (item.stat.insertions > 0) try w.print(", {d} {s}(+)", .{ item.stat.insertions, if (item.stat.insertions == 1) "insertion" else "insertions" });
    if (item.stat.deletions > 0) try w.print(", {d} {s}(-)", .{ item.stat.deletions, if (item.stat.deletions == 1) "deletion" else "deletions" });
    return .{ .header = header, .message = item.message, .stats = try stats.toOwnedSlice(alloc) };
}

/// Zustand des Timeline-Abschnitts: aktive Datei, Log, Anpinnen, Auf-/Zuklappen, Auswahl.
pub const Timeline = struct {
    alloc: std.mem.Allocator,
    file: ?[]u8 = null,
    repo: []u8 = &.{},
    log: ?Log = null,
    error_text: ?[]u8 = null,
    /// VS Code: der Abschnitt ist im Explorer anfangs eingeklappt
    expanded: bool = false,
    /// „Pin the Current Timeline“: folgt nicht mehr dem aktiven Editor
    pinned: bool = false,
    want_load: bool = false,
    loading: bool = false,
    loaded: bool = false,
    selected: ?usize = null,
    scroll: f32 = 0,

    pub fn init(alloc: std.mem.Allocator) Timeline {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Timeline) void {
        self.clear();
        if (self.file) |f| self.alloc.free(f);
    }

    fn clear(self: *Timeline) void {
        if (self.log) |*l| l.deinit();
        self.log = null;
        if (self.error_text) |e| self.alloc.free(e);
        self.error_text = null;
        self.alloc.free(self.repo);
        self.repo = &.{};
        self.loaded = false;
        self.loading = false;
        self.selected = null;
        self.scroll = 0;
    }

    pub fn items(self: *const Timeline) []const Item {
        return if (self.log) |l| l.items else &.{};
    }

    /// Aktive Datei des Editors (null: kein Datei-Editor aktiv).
    pub fn follow(self: *Timeline, path: ?[]const u8) void {
        if (self.pinned) return;
        if (path) |p| {
            if (self.file) |f| if (std.mem.eql(u8, f, p)) return;
            const owned = self.alloc.dupe(u8, p) catch return;
            self.clear();
            if (self.file) |f| self.alloc.free(f);
            self.file = owned;
            self.want_load = self.expanded;
        } else {
            self.clear();
            if (self.file) |f| self.alloc.free(f);
            self.file = null;
            self.want_load = false;
        }
    }

    pub fn setExpanded(self: *Timeline, expanded: bool) void {
        self.expanded = expanded;
        if (expanded and self.file != null and !self.loaded and !self.loading) self.want_load = true;
    }

    pub fn togglePin(self: *Timeline) void {
        self.pinned = !self.pinned;
    }

    pub fn refresh(self: *Timeline) void {
        if (self.file != null and self.expanded) self.want_load = true;
    }

    pub fn takeRequest(self: *Timeline) bool {
        if (!self.want_load or self.file == null) return false;
        self.want_load = false;
        self.loading = true;
        return true;
    }

    /// Ergebnis für `key_file`: `<repo-wurzel>\n<git log>`; veraltete Dateien werden verworfen.
    pub fn apply(self: *Timeline, key_file: []const u8, ok: bool, body: []const u8) !void {
        const f = self.file orelse return;
        if (!std.mem.eql(u8, f, key_file)) return;
        const selected_hash: ?[]const u8 = if (self.selected) |i| (if (i < self.items().len) try self.alloc.dupe(u8, self.items()[i].hash) else null) else null;
        defer if (selected_hash) |h| self.alloc.free(h);
        self.clear();
        self.loaded = true;
        if (!ok) {
            self.error_text = try self.alloc.dupe(u8, body);
            return;
        }
        // `<repo>\n<git diff --cached --name-status>\x1c<git log>`; ohne 0x1c nur Log
        const nl = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
        self.repo = try self.alloc.dupe(u8, body[0..nl]);
        const rest = body[@min(body.len, nl + 1)..];
        const sep = std.mem.indexOfScalar(u8, rest, 0x1c);
        const staged = if (sep) |s| parseStagedStatus(rest[0..s]) else null;
        self.log = try parseLog(self.alloc, if (sep) |s| rest[s + 1 ..] else rest);
        if (staged) |status| try self.prependStaged(f, status);
        if (selected_hash) |h| for (self.items(), 0..) |it, i| {
            if (std.mem.eql(u8, it.hash, h)) self.selected = i;
        };
    }

    /// VS Code stellt „Staged Changes“ an den Anfang (`items.splice(0, 0, item)`).
    fn prependStaged(self: *Timeline, file: []const u8, status: []const u8) !void {
        const log = &self.log.?;
        const a = log.arena.allocator();
        const rel = try a.dupe(u8, if (std.mem.startsWith(u8, file, self.repo) and file.len > self.repo.len + 1) file[self.repo.len + 1 ..] else std.fs.path.basename(file));
        std.mem.replaceScalar(u8, rel, '\\', '/');
        const all = try a.alloc(Item, log.items.len + 1);
        all[0] = .{
            .kind = .staged,
            .hash = git_diff.index_ref,
            .label = "Staged Changes",
            .hover_author = "You",
            .message = status,
            .timestamp = std.time.timestamp(),
            .path = rel,
            .previous_ref = "HEAD",
            .previous_path = rel,
        };
        @memcpy(all[1..], log.items);
        log.items = all;
    }

    /// Diff wie VS Code `resolveTimelineOpenDiffCommand`: Commit gegen den vorigen Commit der Datei.
    pub fn diffSpec(self: *const Timeline, index: usize) ?git_diff.Spec {
        const all = self.items();
        if (index >= all.len) return null;
        const it = all[index];
        return .{ .hash = it.hash, .parent = it.previous_ref, .repo = self.repo, .path = it.path, .previous_path = it.previous_path };
    }

    /// Hinweistext statt der Liste (Texte aus VS Code timelinePane.ts), null = Liste zeigen.
    pub fn message(self: *const Timeline, buf: []u8) ?[]const u8 {
        const f = self.file orelse return "The active editor cannot provide timeline information.";
        if (self.loading and self.items().len == 0) {
            return std.fmt.bufPrint(buf, "Loading timeline for {s}...", .{std.fs.path.basename(f)}) catch "Loading...";
        }
        if (self.error_text != null) return "No timeline information was provided. Source Control has not been configured.";
        if (self.loaded and self.items().len == 0) return "No timeline information was provided.";
        if (!self.loaded) return "";
        return null;
    }
};

test "fromNow: Kurzformen wie VS Code ohne „ago“" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1_000_000_000;
    try testing.expectEqualStrings("now", fromNow(&buf, now, now - 29));
    try testing.expectEqualStrings("30 secs", fromNow(&buf, now, now - 30));
    try testing.expectEqualStrings("1 min", fromNow(&buf, now, now - 60));
    try testing.expectEqualStrings("5 mins", fromNow(&buf, now, now - 300));
    try testing.expectEqualStrings("1 hr", fromNow(&buf, now, now - 3600));
    try testing.expectEqualStrings("2 hrs", fromNow(&buf, now, now - 7200));
    try testing.expectEqualStrings("1 day", fromNow(&buf, now, now - 86400));
    try testing.expectEqualStrings("3 days", fromNow(&buf, now, now - 3 * 86400));
    try testing.expectEqualStrings("2 wks", fromNow(&buf, now, now - 14 * 86400));
    try testing.expectEqualStrings("4 mos", fromNow(&buf, now, now - 120 * 86400));
    try testing.expectEqualStrings("1 yr", fromNow(&buf, now, now - 365 * 86400));
    try testing.expectEqualStrings("2 yrs", fromNow(&buf, now, now - 800 * 86400));
    // Zukunft (Uhrzeit verstellt) wie VS Code: „in …“
    try testing.expectEqualStrings("in 2 hrs", fromNow(&buf, now, now + 7200));
}

test "fromNowLong: volle Wörter mit ago für den Hover" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1_000_000_000;
    try testing.expectEqualStrings("2 hours ago", fromNowLong(&buf, now, now - 7200));
    try testing.expectEqualStrings("1 day ago", fromNowLong(&buf, now, now - 86400));
    try testing.expectEqualStrings("now", fromNowLong(&buf, now, now - 5));
}

// Format wie `git log --follow --numstat`: Umbenennung als „alt => neu“
const sample_log = "\x1eaaaa\x1f2000\x1fAda\x1fada@x.org\x1fSeptember 15, 2026 at 22:47\x1fa nach b\n\nLänger erklärt.\n\x1d\n\n" ++
    "2\t1\ta.txt => b.txt\n" ++
    "\x1ebbbb\x1f1000\x1fBob\x1fbob@x.org\x1fSeptember 14, 2026 at 09:00\x1fanlegen\n\x1d\n\n" ++
    "3\t0\ta.txt\n";

test "numstatPath: einfache, umbenannte und in Klammern umbenannte Pfade" {
    try testing.expectEqualStrings("src/a.zig", numstatPath("src/a.zig"));
    try testing.expectEqualStrings("b.txt", numstatPath("a.txt => b.txt"));
    try testing.expectEqualStrings("src/neu/x.zig", numstatPath("src/{alt => neu}/x.zig"));
    try testing.expectEqualStrings("src/x.zig", numstatPath("src/{ => }/x.zig"));
}

test "parseLog: Felder, Nachricht mit Leerzeilen, Statistik, Pfad, Vorgänger wie VS Code" {
    var log = try parseLog(testing.allocator, sample_log);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 2), log.items.len);
    const a = log.items[0];
    try testing.expectEqualStrings("aaaa", a.hash);
    try testing.expectEqual(@as(i64, 2000), a.timestamp);
    try testing.expectEqualStrings("Ada", a.author);
    try testing.expectEqualStrings("ada@x.org", a.email);
    try testing.expectEqualStrings("September 15, 2026 at 22:47", a.date_text);
    try testing.expectEqualStrings("a nach b\n\nLänger erklärt.", a.message);
    try testing.expectEqualStrings("a nach b", a.label);
    try testing.expectEqual(Stat{ .files = 1, .insertions = 2, .deletions = 1 }, a.stat);
    try testing.expectEqualStrings("b.txt", a.path);
    // previousRef = nächstälterer Commit der Datei, beim ältesten der leere Baum
    try testing.expectEqualStrings("bbbb", a.previous_ref);
    try testing.expectEqualStrings("a.txt", a.previous_path);
    const b = log.items[1];
    try testing.expectEqualStrings("", b.previous_ref);
    try testing.expectEqual(Stat{ .files = 1, .insertions = 3, .deletions = 0 }, b.stat);
    try testing.expectEqualStrings("anlegen", b.label);
}

test "relativeLabels: gleiche Zeit direkt darunter wird ausgeblendet" {
    const items = [_]Item{
        .{ .timestamp = 1000 }, .{ .timestamp = 990 }, .{ .timestamp = 1000 - 2 * 3600 }, // 3, 3, 5 hrs
    };
    const labels = try relativeLabels(testing.allocator, &items, 1000 + 3 * 3600);
    defer freeLabels(testing.allocator, labels);
    try testing.expectEqualStrings("3 hrs", labels[0].text);
    try testing.expect(!labels[0].hidden);
    try testing.expectEqualStrings("3 hrs", labels[1].text);
    try testing.expect(labels[1].hidden);
    try testing.expect(!labels[2].hidden);
}

test "hoverText: Autor, relative Zeit mit Datum, Nachricht, Statistik" {
    var log = try parseLog(testing.allocator, sample_log);
    defer log.deinit();
    const h = try hoverText(testing.allocator, log.items[0], 2000 + 7200);
    defer testing.allocator.free(h.header);
    defer testing.allocator.free(h.stats);
    try testing.expectEqualStrings("Ada, 2 hours ago (September 15, 2026 at 22:47)", h.header);
    try testing.expectEqualStrings("a nach b\n\nLänger erklärt.", h.message);
    try testing.expectEqualStrings("1 file changed, 2 insertions(+), 1 deletion(-)", h.stats);
}

test "logArgs: --follow, Statistik, Pfade, Commit-Datum, Datei als Pfadangabe" {
    var buf: [16][]const u8 = undefined;
    const args = logArgs(&buf, "/r/src/b.txt");
    try testing.expectEqualStrings("log", args[0]);
    for ([_][]const u8{ "--follow", "--numstat", "--" }) |a| try testing.expect(contains(args, a));
    try testing.expect(!contains(args, "--name-only")); // zusammen mit Statistik liefert git sonst keine Zahlen
    try testing.expectEqualStrings("b.txt", args[args.len - 1]);
}

test "Timeline: folgt der aktiven Datei nur aufgeklappt, angepinnt bleibt sie stehen" {
    var t = Timeline.init(testing.allocator);
    defer t.deinit();
    t.follow("/r/a.zig");
    try testing.expect(!t.takeRequest()); // eingeklappt: nichts laden (VS Code isExpanded)
    t.setExpanded(true);
    try testing.expect(t.takeRequest());
    try testing.expect(!t.takeRequest());
    try testing.expectEqualStrings("/r/a.zig", t.file.?);

    t.follow("/r/a.zig"); // gleiche Datei: kein neuer Request
    try testing.expect(!t.takeRequest());

    t.togglePin();
    t.follow("/r/b.zig");
    try testing.expectEqualStrings("/r/a.zig", t.file.?);
    try testing.expect(!t.takeRequest());
    t.togglePin(); // lösen: sofort der aktiven Datei folgen (VS Code)
    t.follow("/r/b.zig");
    try testing.expect(t.takeRequest());
}

test "Timeline: Ergebnis nur für die aktuelle Datei, Diff-Spec zum vorigen Datei-Commit" {
    var t = Timeline.init(testing.allocator);
    defer t.deinit();
    t.setExpanded(true);
    t.follow("/r/b.txt");
    _ = t.takeRequest();
    try t.apply("/r/andere.txt", true, "/r\n" ++ sample_log); // veraltet
    try testing.expectEqual(@as(usize, 0), t.items().len);
    try t.apply("/r/b.txt", true, "/r\n" ++ sample_log);
    try testing.expectEqual(@as(usize, 2), t.items().len);
    try testing.expect(!t.loading);

    const spec = t.diffSpec(0).?;
    try testing.expectEqualStrings("aaaa", spec.hash);
    try testing.expectEqualStrings("bbbb", spec.parent);
    try testing.expectEqualStrings("/r", spec.repo);
    try testing.expectEqualStrings("b.txt", spec.path);
    try testing.expectEqualStrings("a.txt", spec.previous_path);
    try testing.expectEqualStrings("", t.diffSpec(1).?.parent); // ältester: leerer Baum
    try testing.expect(t.diffSpec(5) == null);
}

test "Timeline: Meldungen wie VS Code" {
    var t = Timeline.init(testing.allocator);
    defer t.deinit();
    var buf: [256]u8 = undefined;
    t.setExpanded(true);
    try testing.expectEqualStrings("The active editor cannot provide timeline information.", t.message(&buf).?);
    t.follow("/r/b.txt");
    _ = t.takeRequest();
    try testing.expectEqualStrings("Loading timeline for b.txt...", t.message(&buf).?);
    try t.apply("/r/b.txt", true, "/r\n");
    try testing.expectEqualStrings("No timeline information was provided.", t.message(&buf).?);
    t.refresh();
    _ = t.takeRequest();
    try t.apply("/r/b.txt", true, "/r\n" ++ sample_log);
    try testing.expect(t.message(&buf) == null);
    t.follow(null); // kein Datei-Editor aktiv
    try testing.expectEqualStrings("The active editor cannot provide timeline information.", t.message(&buf).?);
}

test "stagedArgs und parseStagedStatus: Status der Datei im Index wie VS Code getStatusText" {
    var buf: [16][]const u8 = undefined;
    const args = stagedArgs(&buf, "/r/src/a.zig");
    try testing.expect(contains(args, "--cached") and contains(args, "--name-status"));
    try testing.expectEqualStrings("a.zig", args[args.len - 1]);
    try testing.expectEqualStrings("Index Modified", parseStagedStatus("M\tsrc/a.zig\n").?);
    try testing.expectEqualStrings("Index Added", parseStagedStatus("A\tsrc/a.zig\n").?);
    try testing.expectEqualStrings("Index Deleted", parseStagedStatus("D\tsrc/a.zig\n").?);
    try testing.expectEqualStrings("Index Renamed", parseStagedStatus("R100\told.zig\tsrc/a.zig\n").?);
    try testing.expect(parseStagedStatus("") == null);
}

test "Timeline: gestagte Datei bekommt „Staged Changes“ oben, Diff Index gegen HEAD" {
    var t = Timeline.init(testing.allocator);
    defer t.deinit();
    t.setExpanded(true);
    t.follow("/r/b.txt");
    _ = t.takeRequest();
    try t.apply("/r/b.txt", true, "/r\nM\tb.txt\n\x1c" ++ sample_log);
    try testing.expectEqual(@as(usize, 3), t.items().len);
    const staged = t.items()[0];
    try testing.expectEqual(ItemKind.staged, staged.kind);
    try testing.expectEqualStrings("Staged Changes", staged.label);
    try testing.expectEqualStrings("", staged.author); // Beschreibung leer
    try testing.expectEqualStrings("You", staged.hover_author);
    try testing.expectEqualStrings("Index Modified", staged.message);
    try testing.expectEqualStrings("b.txt", staged.path);
    // Der erste Commit behält seinen Vorgänger, der gestagte Eintrag vergleicht mit HEAD
    try testing.expectEqualStrings("bbbb", t.items()[1].previous_ref);
    const spec = t.diffSpec(0).?;
    try testing.expectEqualStrings(git_diff.index_ref, spec.hash);
    try testing.expectEqualStrings("HEAD", spec.parent);
    try testing.expectEqualStrings("b.txt", spec.path);

    // ohne Index-Änderung kein Eintrag
    t.refresh();
    _ = t.takeRequest();
    try t.apply("/r/b.txt", true, "/r\n\x1c" ++ sample_log);
    try testing.expectEqual(@as(usize, 2), t.items().len);
    try testing.expectEqual(ItemKind.commit, t.items()[0].kind);
}

fn contains(args: []const []const u8, arg: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, arg)) return true;
    return false;
}
