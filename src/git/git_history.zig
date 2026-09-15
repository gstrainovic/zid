//! Git-History ohne Clay und ohne Prozesse: Tab-Pfade, git-Argumente, Log- und
//! Diff-Parsing, Auswahl und Virtualisierung. Die Ansicht steht in
//! `src/ui/git_history_view.zig`, die git-Aufrufe in `git_worker.zig`.

const std = @import("std");

pub const scheme = "git-history://";

/// Was der Tab zeigt: den Verlauf eines Repos (Ordner im Repo) oder einer Datei.
pub const Target = union(enum) {
    repo: []const u8,
    file: []const u8,

    pub fn path(self: Target) []const u8 {
        return switch (self) {
            inline else => |p| p,
        };
    }
};

/// Tab-Pfad `git-history://repo:<ordner>` bzw. `git-history://file:<datei>` (owned).
pub fn tabPath(alloc: std.mem.Allocator, target: Target) ![]u8 {
    return std.fmt.allocPrint(alloc, scheme ++ "{s}:{s}", .{ @tagName(target), target.path() });
}

pub fn isHistoryPath(tab_path: []const u8) bool {
    return std.mem.startsWith(u8, tab_path, scheme);
}

/// Gegenstück zu `tabPath`; der Pfad im Ergebnis zeigt in `tab_path`.
pub fn parseTarget(tab_path: []const u8) ?Target {
    if (!isHistoryPath(tab_path)) return null;
    const rest = tab_path[scheme.len..];
    if (std.mem.startsWith(u8, rest, "repo:")) return .{ .repo = rest["repo:".len..] };
    if (std.mem.startsWith(u8, rest, "file:")) return .{ .file = rest["file:".len..] };
    return null;
}

/// Tab-Beschriftung (owned).
pub fn displayName(alloc: std.mem.Allocator, target: Target) ![]u8 {
    const base = std.fs.path.basename(target.path());
    return switch (target) {
        .repo => std.fmt.allocPrint(alloc, "Git History: {s}", .{base}),
        .file => std.fmt.allocPrint(alloc, "History: {s}", .{base}),
    };
}

/// Obergrenze der geladenen Commits; die Liste ist virtualisiert, git selbst braucht bei
/// großen Repos für mehr spürbar länger.
pub const max_commits = "2000";

/// Feldtrenner im Log: 0x1e vor jedem Commit, 0x1f zwischen den Feldern. Betreffzeilen
/// dürfen damit jedes druckbare Zeichen enthalten.
const log_format = "--format=%x1e%H%x1f%h%x1f%an%x1f%ad%x1f%s";
const date_format = "--date=format:%Y-%m-%d %H:%M";

/// Argumente für `git log` (ohne "git"). Läuft im Repo-Ordner bzw. im Ordner der Datei.
/// Bei Dateien liefert `--name-only` den Pfad je Commit, damit `show` nach einer
/// Umbenennung den alten Namen bekommt.
pub fn logArgs(buf: *[16][]const u8, target: Target) []const []const u8 {
    var n: usize = 0;
    for ([_][]const u8{ "log", "--no-color", log_format, date_format, "-n", max_commits }) |a| {
        buf[n] = a;
        n += 1;
    }
    switch (target) {
        .repo => {},
        .file => |p| {
            for ([_][]const u8{ "--follow", "--name-only", "--", std.fs.path.basename(p) }) |a| {
                buf[n] = a;
                n += 1;
            }
        },
    }
    return buf[0..n];
}

/// Argumente für `git show` eines Commits; `repo_rel_path` (aus `Commit.path`) begrenzt
/// den Diff auf eine Datei. `:(top)` macht den Pfad unabhängig vom Arbeitsordner.
/// `previous_path` ist der Pfad im nächstälteren Commit: weicht er ab, kommt er mit in die
/// Pfadangabe, sonst sähe git bei einer Umbenennung nur eine neue Datei.
pub fn showArgs(buf: *[16][]const u8, spec_buf: []u8, hash: []const u8, repo_rel_path: []const u8, previous_path: []const u8) []const []const u8 {
    var n: usize = 0;
    for ([_][]const u8{ "show", "--no-color", "--stat", "--patch", date_format, hash }) |a| {
        buf[n] = a;
        n += 1;
    }
    if (repo_rel_path.len == 0) return buf[0..n];
    const renamed = previous_path.len > 0 and !std.mem.eql(u8, previous_path, repo_rel_path);
    const spec = std.fmt.bufPrint(spec_buf, ":(top){s}", .{repo_rel_path}) catch return buf[0..n];
    buf[n] = "--";
    buf[n + 1] = spec;
    n += 2;
    if (renamed) {
        if (std.fmt.bufPrint(spec_buf[spec.len..], ":(top){s}", .{previous_path})) |old| {
            buf[n] = old;
            n += 1;
        } else |_| {}
    }
    return buf[0..n];
}

pub const Commit = struct {
    hash: []const u8,
    short: []const u8,
    author: []const u8,
    date: []const u8,
    subject: []const u8,
    /// Pfad der Datei in diesem Commit (relativ zur Repo-Wurzel), leer beim Repo-Log.
    path: []const u8 = "",
};

pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    commits: []Commit,

    pub fn deinit(self: *Log) void {
        self.arena.deinit();
    }
};

/// Ausgabe von `git log` mit `log_format` zerlegen. Datensätze mit zu wenigen Feldern
/// werden übersprungen. Alle Strings liegen in der Arena des Ergebnisses.
pub fn parseLog(alloc: std.mem.Allocator, out: []const u8) !Log {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const text = try a.dupe(u8, out);

    var commits: std.ArrayListUnmanaged(Commit) = .empty;
    var records = std.mem.splitScalar(u8, text, 0x1e);
    _ = records.next(); // alles vor dem ersten Trenner
    while (records.next()) |record| {
        var lines = std.mem.splitScalar(u8, record, '\n');
        const head = trimCr(lines.next() orelse continue);
        var fields = std.mem.splitScalar(u8, head, 0x1f);
        var f: [5][]const u8 = undefined;
        var count: usize = 0;
        while (fields.next()) |field| : (count += 1) {
            if (count < f.len) f[count] = field;
        }
        if (count < f.len) continue;
        var path: []const u8 = "";
        while (lines.next()) |line| {
            const l = std.mem.trim(u8, line, " \t\r");
            if (l.len > 0) {
                path = l;
                break;
            }
        }
        try commits.append(a, .{ .hash = f[0], .short = f[1], .author = f[2], .date = f[3], .subject = f[4], .path = path });
    }
    return .{ .arena = arena, .commits = try commits.toOwnedSlice(a) };
}

pub const LineKind = enum { meta, file_header, hunk, added, removed, context };

/// Zeile im Diff-Text: Byte-Bereich (ohne Zeilenende) und Art.
pub const Line = struct {
    start: u32,
    len: u32,
    kind: LineKind,
};

pub fn lineText(text: []const u8, line: Line) []const u8 {
    return text[line.start..][0..line.len];
}

/// `git show`-Ausgabe in Zeilen mit Art zerlegen. Braucht Zustand: `--- x` ist im
/// Datei-Kopf ein Header, im Hunk eine entfernte Zeile, die mit „--“ beginnt.
pub fn parseDiff(alloc: std.mem.Allocator, text: []const u8) ![]Line {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    errdefer lines.deinit(alloc);
    var in_file = false;
    var in_hunk = false;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = nl orelse text.len;
        const line = trimCr(text[start..end]);
        const kind: LineKind = if (std.mem.startsWith(u8, line, "diff ")) blk: {
            in_file = true;
            in_hunk = false;
            break :blk .file_header;
        } else if (in_file and std.mem.startsWith(u8, line, "@@")) blk: {
            in_hunk = true;
            break :blk .hunk;
        } else if (in_hunk) switch (if (line.len > 0) line[0] else ' ') {
            '+' => .added,
            '-' => .removed,
            else => .context,
        } else if (in_file) .file_header else .meta;
        try lines.append(alloc, .{ .start = @intCast(start), .len = @intCast(line.len), .kind = kind });
        start = if (nl) |i| i + 1 else text.len;
    }
    return lines.toOwnedSlice(alloc);
}

fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// Worker-Ergebnis: `<schlüssel>\n<text>`. Der Schlüssel ist der Tab-Pfad, bei `show`
/// zusätzlich `\x1f<hash>`, damit ein veraltetes Ergebnis erkannt wird (owned).
pub fn frame(alloc: std.mem.Allocator, key: []const u8, body: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ key, "\n", body });
}

pub fn unframe(payload: []const u8) ?struct { key: []const u8, body: []const u8 } {
    const nl = std.mem.indexOfScalar(u8, payload, '\n') orelse return null;
    return .{ .key = payload[0..nl], .body = payload[nl + 1 ..] };
}

pub fn splitKey(key: []const u8) struct { tab_path: []const u8, hash: []const u8 } {
    const sep = std.mem.indexOfScalar(u8, key, 0x1f) orelse return .{ .tab_path = key, .hash = "" };
    return .{ .tab_path = key[0..sep], .hash = key[sep + 1 ..] };
}

/// Auswahl um `delta` verschieben, an die Liste geklemmt; ohne Auswahl beginnt sie oben.
pub fn moveSelection(current: ?usize, delta: isize, count: usize) ?usize {
    if (count == 0) return null;
    const cur = current orelse return 0;
    const moved = @as(isize, @intCast(@min(cur, count - 1))) + delta;
    return @intCast(std.math.clamp(moved, 0, @as(isize, @intCast(count - 1))));
}

/// Zu zeichnende Zeilen [first, end) einer Liste mit fester Zeilenhöhe, mit `overscan`
/// Zeilen Vorlauf je Richtung.
pub fn visibleRange(scroll: f32, viewport: f32, row_h: f32, count: usize, overscan: usize) struct { first: usize, end: usize } {
    const first_vis: usize = @intFromFloat(@max(0, @floor(scroll / row_h)));
    const last_vis: usize = @intFromFloat(@max(0, @ceil((scroll + viewport) / row_h)));
    const end = @min(count, last_vis + overscan);
    return .{ .first = @min(first_vis -| overscan, end), .end = end };
}

/// Scroll-Versatz, bei dem Zeile `index` ganz im Fenster steht (möglichst wenig bewegt).
pub fn scrollToShow(scroll: f32, viewport: f32, row_h: f32, index: usize) f32 {
    const top = @as(f32, @floatFromInt(index)) * row_h;
    if (top < scroll) return top;
    if (top + row_h > scroll + viewport) return top + row_h - viewport;
    return scroll;
}

pub fn clampScroll(scroll: f32, viewport: f32, row_h: f32, count: usize) f32 {
    const max = @max(0, @as(f32, @floatFromInt(count)) * row_h - viewport);
    return std.math.clamp(scroll, 0, max);
}

/// Was die Ansicht vom Worker braucht; `State.takeRequest` liefert es genau einmal.
pub const Request = enum { log, show };

/// Zustand eines History-Tabs ohne Clay: Log, Auswahl, Diff des gewählten Commits und
/// offene Anfragen. Antworten kommen asynchron; ein Diff, der nicht mehr zur Auswahl
/// passt, wird verworfen.
pub const State = struct {
    alloc: std.mem.Allocator,
    tab_path: []u8,
    log: ?Log = null,
    /// stderr von git, wenn der Log scheiterte (owned)
    log_error: ?[]u8 = null,
    loading_log: bool = false,
    selected: ?usize = null,
    /// Diff des Commits `diff_hash` (owned); bei `diff_failed` die Fehlermeldung
    diff_text: []u8 = &.{},
    diff_lines: []Line = &.{},
    diff_hash: []u8 = &.{},
    diff_failed: bool = false,
    loading_diff: bool = false,
    want_log: bool = true,
    want_show: bool = false,
    list_scroll: f32 = 0,
    diff_scroll: f32 = 0,

    pub fn init(alloc: std.mem.Allocator, tab_path: []const u8) !State {
        return .{ .alloc = alloc, .tab_path = try alloc.dupe(u8, tab_path) };
    }

    pub fn deinit(self: *State) void {
        if (self.log) |*l| l.deinit();
        if (self.log_error) |e| self.alloc.free(e);
        self.freeDiff();
        self.alloc.free(self.tab_path);
    }

    fn freeDiff(self: *State) void {
        self.alloc.free(self.diff_text);
        self.alloc.free(self.diff_lines);
        self.alloc.free(self.diff_hash);
        self.diff_text = &.{};
        self.diff_lines = &.{};
        self.diff_hash = &.{};
    }

    pub fn target(self: *const State) Target {
        return parseTarget(self.tab_path) orelse .{ .repo = "." };
    }

    pub fn commits(self: *const State) []const Commit {
        return if (self.log) |l| l.commits else &.{};
    }

    pub fn selectedCommit(self: *const State) ?Commit {
        const i = self.selected orelse return null;
        const all = self.commits();
        return if (i < all.len) all[i] else null;
    }

    /// Pfad der Datei im nächstälteren Commit (leer beim ältesten oder beim Repo-Log).
    pub fn previousPath(self: *const State, index: usize) []const u8 {
        const all = self.commits();
        return if (index + 1 < all.len) all[index + 1].path else "";
    }

    pub fn diffShowsSelected(self: *const State) bool {
        const c = self.selectedCommit() orelse return false;
        return std.mem.eql(u8, c.hash, self.diff_hash);
    }

    pub fn takeRequest(self: *State) ?Request {
        if (self.want_log) {
            self.want_log = false;
            self.loading_log = true;
            return .log;
        }
        if (self.want_show and self.selectedCommit() != null) {
            self.want_show = false;
            self.loading_diff = true;
            return .show;
        }
        return null;
    }

    pub fn reload(self: *State) void {
        self.want_log = true;
    }

    /// Antwort auf `git log`. Die Auswahl bleibt über den Hash erhalten (neue Commits
    /// schieben sie nach unten), sonst steht sie auf dem jüngsten Commit.
    pub fn applyLog(self: *State, ok: bool, body: []const u8) !void {
        self.loading_log = false;
        var prev_buf: [64]u8 = undefined;
        const prev: []const u8 = if (self.selectedCommit()) |c| blk: {
            const n = @min(c.hash.len, prev_buf.len);
            @memcpy(prev_buf[0..n], c.hash[0..n]);
            break :blk prev_buf[0..n];
        } else "";

        if (self.log_error) |e| self.alloc.free(e);
        self.log_error = null;
        if (!ok) {
            if (self.log) |*l| l.deinit();
            self.log = null;
            self.selected = null;
            self.log_error = try self.alloc.dupe(u8, body);
            return;
        }
        const new_log = try parseLog(self.alloc, body);
        if (self.log) |*l| l.deinit();
        self.log = new_log;

        self.selected = if (self.commits().len > 0) 0 else null;
        for (self.commits(), 0..) |c, i| {
            if (prev.len > 0 and std.mem.eql(u8, c.hash, prev)) self.selected = i;
        }
        if (self.selected != null and !self.diffShowsSelected()) self.want_show = true;
    }

    /// Antwort auf `git show <hash>`; passt der Hash nicht mehr zur Auswahl, wird sie verworfen.
    pub fn applyShow(self: *State, hash: []const u8, ok: bool, body: []const u8) !void {
        const c = self.selectedCommit() orelse return;
        if (!std.mem.eql(u8, c.hash, hash)) return;
        self.loading_diff = false;
        const same = std.mem.eql(u8, self.diff_hash, hash);
        const text = try self.alloc.dupe(u8, body);
        errdefer self.alloc.free(text);
        const lines = try parseDiff(self.alloc, text);
        errdefer self.alloc.free(lines);
        const owned_hash = try self.alloc.dupe(u8, hash);
        self.freeDiff();
        self.diff_text = text;
        self.diff_lines = lines;
        self.diff_hash = owned_hash;
        self.diff_failed = !ok;
        if (!same) self.diff_scroll = 0;
    }

    pub fn select(self: *State, index: usize) void {
        const n = self.commits().len;
        if (n == 0) return;
        const i = @min(index, n - 1);
        if (self.selected == i) return;
        self.selected = i;
        if (!self.diffShowsSelected()) self.want_show = true;
    }

    pub fn move(self: *State, delta: isize) void {
        if (moveSelection(self.selected, delta, self.commits().len)) |i| self.select(i);
    }
};

/// Zeile auf höchstens `max_bytes` kürzen, ohne ein UTF-8-Zeichen zu teilen. Der Shaper
/// liefert Runs über 2048 Bytes leer (siehe AGENTS.md, große Dateien).
pub fn displaySlice(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var cut = max_bytes;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return text[0..cut];
}

test "tabPath und parseTarget: Repo und Datei" {
    const alloc = std.testing.allocator;
    const repo = try tabPath(alloc, .{ .repo = "/home/u/proj" });
    defer alloc.free(repo);
    try std.testing.expectEqualStrings("git-history://repo:/home/u/proj", repo);
    try std.testing.expectEqualStrings("/home/u/proj", parseTarget(repo).?.repo);

    const file = try tabPath(alloc, .{ .file = "/home/u/proj/src/a.zig" });
    defer alloc.free(file);
    try std.testing.expectEqualStrings("/home/u/proj/src/a.zig", parseTarget(file).?.file);

    try std.testing.expect(parseTarget("/home/u/proj/a.zig") == null);
    try std.testing.expect(parseTarget("git-history://other:x") == null);
    const win = try tabPath(alloc, .{ .file = "C:\\proj\\a.zig" });
    defer alloc.free(win);
    try std.testing.expectEqualStrings("C:\\proj\\a.zig", parseTarget(win).?.file);
    try std.testing.expect(isHistoryPath(repo));
    try std.testing.expect(!isHistoryPath("preview://x.md"));
}

test "displayName: Repo heißt Git History, Datei History: name" {
    const alloc = std.testing.allocator;
    const a = try displayName(alloc, .{ .repo = "/home/u/proj" });
    defer alloc.free(a);
    try std.testing.expectEqualStrings("Git History: proj", a);
    const b = try displayName(alloc, .{ .file = "/home/u/proj/src/a.zig" });
    defer alloc.free(b);
    try std.testing.expectEqualStrings("History: a.zig", b);
}

test "logArgs: Repo ohne Pfad, Datei mit --follow und --name-only" {
    var buf: [16][]const u8 = undefined;
    const repo = logArgs(&buf, .{ .repo = "/r" });
    try std.testing.expectEqualStrings("log", repo[0]);
    try std.testing.expect(!containsArg(repo, "--follow"));
    try std.testing.expect(!containsArg(repo, "--"));

    const file = logArgs(&buf, .{ .file = "/r/src/a.zig" });
    try std.testing.expect(containsArg(file, "--follow"));
    try std.testing.expect(containsArg(file, "--name-only"));
    try std.testing.expectEqualStrings("--", file[file.len - 2]);
    try std.testing.expectEqualStrings("a.zig", file[file.len - 1]);
}

test "showArgs: Datei-Pfad relativ zur Repo-Wurzel über :(top)" {
    var buf: [16][]const u8 = undefined;
    var spec_buf: [256]u8 = undefined;
    const all = showArgs(&buf, &spec_buf, "abc123", "", "");
    try std.testing.expectEqualStrings("show", all[0]);
    try std.testing.expectEqualStrings("abc123", all[all.len - 1]);

    const one = showArgs(&buf, &spec_buf, "abc123", "src/name.zig", "src/name.zig");
    try std.testing.expectEqualStrings("abc123", one[one.len - 3]);
    try std.testing.expectEqualStrings("--", one[one.len - 2]);
    try std.testing.expectEqualStrings(":(top)src/name.zig", one[one.len - 1]);
}

test "showArgs: bei Umbenennung beide Pfade, damit git die Umbenennung erkennt" {
    var buf: [16][]const u8 = undefined;
    var spec_buf: [256]u8 = undefined;
    const args = showArgs(&buf, &spec_buf, "abc", "src/new.zig", "src/old.zig");
    try std.testing.expectEqualStrings("--", args[args.len - 3]);
    try std.testing.expectEqualStrings(":(top)src/new.zig", args[args.len - 2]);
    try std.testing.expectEqualStrings(":(top)src/old.zig", args[args.len - 1]);
    // ohne Vorgänger (ältester Commit): nur der eigene Pfad
    const first = showArgs(&buf, &spec_buf, "abc", "src/new.zig", "");
    try std.testing.expectEqualStrings(":(top)src/new.zig", first[first.len - 1]);
    try std.testing.expectEqualStrings("--", first[first.len - 2]);
}

test "State.previousPath: Pfad des nächstälteren Commits" {
    var s = try State.init(std.testing.allocator, "git-history://file:/r/b.txt");
    defer s.deinit();
    try s.applyLog(true, "\x1ea1\x1fa\x1fAda\x1f2026-09-14 10:00\x1frename\n\nb.txt\n" ++
        "\x1eb2\x1fb\x1fBob\x1f2026-09-13 10:00\x1fanlegen\n\na.txt\n");
    try std.testing.expectEqualStrings("a.txt", s.previousPath(0));
    try std.testing.expectEqualStrings("", s.previousPath(1));
}

test "parseLog: Repo-Log mit Feldtrennern" {
    const alloc = std.testing.allocator;
    const out = "\x1eaaaa1111\x1faaaa111\x1fAda\x1f2026-09-14 23:13\x1fperf: schneller\n" ++
        "\x1ebbbb2222\x1fbbbb222\x1fBob\x1f2026-09-13 20:12\x1ffix: Umlaut ä | Pipe\n";
    var log = try parseLog(alloc, out);
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 2), log.commits.len);
    try std.testing.expectEqualStrings("aaaa1111", log.commits[0].hash);
    try std.testing.expectEqualStrings("aaaa111", log.commits[0].short);
    try std.testing.expectEqualStrings("Ada", log.commits[0].author);
    try std.testing.expectEqualStrings("2026-09-14 23:13", log.commits[0].date);
    try std.testing.expectEqualStrings("perf: schneller", log.commits[0].subject);
    try std.testing.expectEqualStrings("", log.commits[0].path);
    try std.testing.expectEqualStrings("fix: Umlaut ä | Pipe", log.commits[1].subject);
}

test "parseLog: Datei-Log mit --name-only liefert den Pfad je Commit (Umbenennung)" {
    const alloc = std.testing.allocator;
    const out = "\x1ea1\x1fa\x1fAda\x1f2026-09-14 10:00\x1frename\n\nsrc/new.zig\n" ++
        "\x1eb2\x1fb\x1fBob\x1f2026-09-13 10:00\x1fanlegen\n\nsrc/old.zig\n";
    var log = try parseLog(alloc, out);
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 2), log.commits.len);
    try std.testing.expectEqualStrings("src/new.zig", log.commits[0].path);
    try std.testing.expectEqualStrings("src/old.zig", log.commits[1].path);
    try std.testing.expectEqualStrings("rename", log.commits[0].subject);
}

test "parseLog: leer und kaputte Datensätze" {
    const alloc = std.testing.allocator;
    var empty = try parseLog(alloc, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.commits.len);

    var broken = try parseLog(alloc, "\x1enur-hash\n\x1ec3\x1fc\x1fCy\x1f2026-01-01 00:00\x1fok\n");
    defer broken.deinit();
    try std.testing.expectEqual(@as(usize, 1), broken.commits.len);
    try std.testing.expectEqualStrings("ok", broken.commits[0].subject);
}

test "parseDiff: Kopf, Datei-Header, Hunk, plus/minus, Zeilen mit --- im Hunk" {
    const alloc = std.testing.allocator;
    const text =
        \\commit abc
        \\Author: Ada
        \\
        \\    msg
        \\
        \\diff --git a/x.zig b/x.zig
        \\index 1..2 100644
        \\--- a/x.zig
        \\+++ b/x.zig
        \\@@ -1,3 +1,3 @@ fn main
        \\ keep
        \\--- removed line starting with dashes
        \\+++ added line starting with plus
        \\-old
        \\+new
    ;
    const lines = try parseDiff(alloc, text);
    defer alloc.free(lines);
    const expected = [_]LineKind{
        .meta,        .meta,        .meta,  .meta,    .meta,
        .file_header, .file_header, .file_header, .file_header,
        .hunk,        .context,     .removed, .added, .removed, .added,
    };
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |kind, line| try std.testing.expectEqual(kind, line.kind);
    try std.testing.expectEqualStrings("-old", lineText(text, lines[13]));
    try std.testing.expectEqualStrings("commit abc", lineText(text, lines[0]));
}

test "parseDiff: zweite Datei beendet den Hunk, CRLF wird abgeschnitten, leerer Text" {
    const alloc = std.testing.allocator;
    const text = "diff --git a/a b/a\r\n--- a/a\r\n+++ b/a\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n" ++
        "diff --git a/b b/b\r\n--- a/b\r\n+++ b/b\r\n";
    const lines = try parseDiff(alloc, text);
    defer alloc.free(lines);
    try std.testing.expectEqual(@as(usize, 9), lines.len);
    try std.testing.expectEqual(LineKind.file_header, lines[7].kind);
    try std.testing.expectEqual(LineKind.file_header, lines[8].kind);
    try std.testing.expectEqualStrings("+b", lineText(text, lines[5]));

    const none = try parseDiff(alloc, "");
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "frame und unframe: Schlüssel vor dem ersten Zeilenumbruch" {
    const alloc = std.testing.allocator;
    const f = try frame(alloc, "git-history://repo:/r\x1fabc", "body\nzwei");
    defer alloc.free(f);
    const u = unframe(f).?;
    try std.testing.expectEqualStrings("git-history://repo:/r\x1fabc", u.key);
    try std.testing.expectEqualStrings("body\nzwei", u.body);
    const k = splitKey(u.key);
    try std.testing.expectEqualStrings("git-history://repo:/r", k.tab_path);
    try std.testing.expectEqualStrings("abc", k.hash);
    try std.testing.expect(unframe("ohne umbruch") == null);
    try std.testing.expectEqualStrings("", splitKey("nur-pfad").hash);
}

test "moveSelection: Start, Klemmen an den Rändern, leere Liste" {
    try std.testing.expectEqual(@as(?usize, 0), moveSelection(null, 1, 5));
    try std.testing.expectEqual(@as(?usize, 0), moveSelection(null, -1, 5));
    try std.testing.expectEqual(@as(?usize, 3), moveSelection(2, 1, 5));
    try std.testing.expectEqual(@as(?usize, 4), moveSelection(3, 10, 5));
    try std.testing.expectEqual(@as(?usize, 0), moveSelection(1, -10, 5));
    try std.testing.expectEqual(@as(?usize, null), moveSelection(null, 1, 0));
    try std.testing.expectEqual(@as(?usize, 2), moveSelection(9, 0, 3));
}

test "visibleRange: Vorlauf, Ende, leerer Viewport" {
    // 10 px Zeilen, 50 px sichtbar, 100 px gescrollt → Zeilen 10..15, plus 5 Vorlauf je Seite
    const r = visibleRange(100, 50, 10, 1000, 5);
    try std.testing.expectEqual(@as(usize, 5), r.first);
    try std.testing.expectEqual(@as(usize, 20), r.end);
    const tail = visibleRange(9990, 50, 10, 1000, 5);
    try std.testing.expectEqual(@as(usize, 1000), tail.end);
    const none = visibleRange(0, 50, 10, 0, 5);
    try std.testing.expectEqual(@as(usize, 0), none.first);
    try std.testing.expectEqual(@as(usize, 0), none.end);
}

test "scrollToShow und clampScroll" {
    // Zeile 20 (200..210) liegt unter einem 50-px-Fenster ab 0 → Fenster endet bei 210
    try std.testing.expectEqual(@as(f32, 160), scrollToShow(0, 50, 10, 20));
    // schon sichtbar → unverändert
    try std.testing.expectEqual(@as(f32, 180), scrollToShow(180, 50, 10, 20));
    // über dem Fenster → Zeile oben
    try std.testing.expectEqual(@as(f32, 200), scrollToShow(300, 50, 10, 20));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(-5, 50, 10, 100));
    try std.testing.expectEqual(@as(f32, 950), clampScroll(5000, 50, 10, 100));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(30, 50, 10, 3));
}

test "displaySlice: kürzt lange Zeilen an einer UTF-8-Grenze und ersetzt Tabs nicht" {
    try std.testing.expectEqualStrings("abc", displaySlice("abc", 10));
    try std.testing.expectEqualStrings("ab", displaySlice("abcdef", 2));
    // "ä" ist 2 Bytes: Schnitt nach 2 Bytes würde es teilen
    try std.testing.expectEqualStrings("a", displaySlice("aä", 2));
}

const two_commits = "\x1eaaaa\x1fa\x1fAda\x1f2026-09-14 10:00\x1ferster\n" ++
    "\x1ebbbb\x1fb\x1fBob\x1f2026-09-13 10:00\x1fzweiter\n";

test "State: fordert zuerst den Log an, genau einmal" {
    var s = try State.init(std.testing.allocator, "git-history://repo:/r");
    defer s.deinit();
    try std.testing.expectEqualStrings("/r", s.target().repo);
    try std.testing.expectEqual(@as(?Request, .log), s.takeRequest());
    try std.testing.expect(s.loading_log);
    try std.testing.expectEqual(@as(?Request, null), s.takeRequest());
}

test "State: Log da → erster Commit gewählt, Diff angefordert, veralteter Diff ignoriert" {
    var s = try State.init(std.testing.allocator, "git-history://repo:/r");
    defer s.deinit();
    _ = s.takeRequest();
    try s.applyLog(true, two_commits);
    try std.testing.expect(!s.loading_log);
    try std.testing.expectEqual(@as(?usize, 0), s.selected);
    try std.testing.expectEqual(@as(?Request, .show), s.takeRequest());
    try std.testing.expect(s.loading_diff);

    try s.applyShow("bbbb", true, "fremder diff");
    try std.testing.expect(!s.diffShowsSelected());
    try std.testing.expect(s.loading_diff);

    try s.applyShow("aaaa", true, "commit aaaa\n\ndiff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n");
    try std.testing.expect(s.diffShowsSelected());
    try std.testing.expect(!s.loading_diff);
    try std.testing.expectEqual(@as(usize, 6), s.diff_lines.len);
    try std.testing.expectEqual(LineKind.added, s.diff_lines[5].kind);
}

test "State: Auswahl bewegen fordert neuen Diff an, alter bleibt bis zur Antwort" {
    var s = try State.init(std.testing.allocator, "git-history://repo:/r");
    defer s.deinit();
    _ = s.takeRequest();
    try s.applyLog(true, two_commits);
    _ = s.takeRequest();
    try s.applyShow("aaaa", true, "alt");
    s.diff_scroll = 120;

    s.move(1);
    try std.testing.expectEqual(@as(?usize, 1), s.selected);
    try std.testing.expectEqualStrings("bbbb", s.selectedCommit().?.hash);
    try std.testing.expect(!s.diffShowsSelected());
    try std.testing.expectEqualStrings("alt", s.diff_text);
    try std.testing.expectEqual(@as(?Request, .show), s.takeRequest());

    s.move(1); // am Ende: nichts Neues
    try std.testing.expectEqual(@as(?Request, null), s.takeRequest());

    try s.applyShow("bbbb", true, "neu");
    try std.testing.expectEqualStrings("neu", s.diff_text);
    try std.testing.expectEqual(@as(f32, 0), s.diff_scroll);
}

test "State: Neu laden behält die Auswahl über den Hash, ohne den Diff neu zu holen" {
    var s = try State.init(std.testing.allocator, "git-history://repo:/r");
    defer s.deinit();
    _ = s.takeRequest();
    try s.applyLog(true, two_commits);
    s.move(1);
    _ = s.takeRequest();
    try s.applyShow("bbbb", true, "diff b");

    s.reload();
    try std.testing.expectEqual(@as(?Request, .log), s.takeRequest());
    try s.applyLog(true, "\x1ecccc\x1fc\x1fCy\x1f2026-09-15 10:00\x1fneu\n" ++ two_commits);
    try std.testing.expectEqual(@as(?usize, 2), s.selected);
    try std.testing.expect(s.diffShowsSelected());
    try std.testing.expectEqual(@as(?Request, null), s.takeRequest());
}

test "State: Fehler von git und leerer Log" {
    var s = try State.init(std.testing.allocator, "git-history://file:/r/neu.txt");
    defer s.deinit();
    _ = s.takeRequest();
    try s.applyLog(false, "fatal: kein Repo");
    try std.testing.expectEqualStrings("fatal: kein Repo", s.log_error.?);
    try std.testing.expectEqual(@as(usize, 0), s.commits().len);

    s.reload();
    _ = s.takeRequest();
    try s.applyLog(true, "");
    try std.testing.expect(s.log_error == null);
    try std.testing.expectEqual(@as(?usize, null), s.selected);
    try std.testing.expectEqual(@as(?Request, null), s.takeRequest());
}

test "State: fehlgeschlagener Diff wird als Fehler gemerkt" {
    var s = try State.init(std.testing.allocator, "git-history://repo:/r");
    defer s.deinit();
    _ = s.takeRequest();
    try s.applyLog(true, two_commits);
    _ = s.takeRequest();
    try s.applyShow("aaaa", false, "StdoutStreamTooLong");
    try std.testing.expect(s.diff_failed);
    try std.testing.expect(s.diffShowsSelected());
    try std.testing.expectEqualStrings("StdoutStreamTooLong", s.diff_text);
}

fn containsArg(args: []const []const u8, arg: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, arg)) return true;
    return false;
}
