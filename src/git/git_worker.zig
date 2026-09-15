//! Git Task-Funktionen für den Scheduler.
//! Alle Funktionen laufen in Worker-Threads via std.process.Child.
//! Payload-Format ist plain-text (human readable + maschinell parsbar).

const std = @import("std");
const scheduler = @import("scheduler");
const git_history = @import("git_history");
const git_diff = @import("git_diff");

const log = std.log.scoped(.git_worker);

/// Parameter für alle Git-Tasks. Selbst-owned: deinit() in der Task-Funktion aufrufen.
pub const Params = struct {
    alloc: std.mem.Allocator,
    repo_path: []const u8,
    extra: []const u8 = "", // Datei-Pfad für diff/blame

    pub fn init(alloc: std.mem.Allocator, repo_path: []const u8, extra: []const u8) !*Params {
        const self = try alloc.create(Params);
        self.* = .{
            .alloc = alloc,
            .repo_path = try alloc.dupe(u8, repo_path),
            .extra = if (extra.len > 0) try alloc.dupe(u8, extra) else "",
        };
        return self;
    }

    pub fn deinit(self: *Params) void {
        self.alloc.free(self.repo_path);
        if (self.extra.len > 0) self.alloc.free(self.extra);
        self.alloc.destroy(self);
    }
};

// ─── Task-Funktionen ──────────────────────────────────────────────────────────

/// Payload: Branch-Name als plain text, z.B. "main"
pub fn taskGitBranch(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *Params = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const out = try runGit(alloc, params.repo_path, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer alloc.free(out);

    return .{
        .tag = .git_branch,
        .payload = try alloc.dupe(u8, std.mem.trimRight(u8, out, "\n\r")),
        .allocator = alloc,
    };
}

/// Payload: "branch:<name>\n<code>:<path>\n..."
///   Codes: A staged, M modified, ? untracked, C conflict, S submodule
pub fn taskGitStatus(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *Params = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const out = try runGit(alloc, params.repo_path, &.{
        "--no-optional-locks", "status", "--porcelain=v2",
        "--branch",            "--null", "--ignored",
    });
    defer alloc.free(out);

    // Pfade in porcelain v2 sind relativ zur Repo-Wurzel, nicht zum Projektordner
    const toplevel = runGit(alloc, params.repo_path, &.{ "rev-parse", "--show-toplevel" }) catch null;
    defer if (toplevel) |t| alloc.free(t);
    const root = if (toplevel) |t| std.mem.trimEnd(u8, t, "\n\r") else null;

    return .{
        .tag = .git_status,
        .payload = try parseStatusOutput(alloc, out, root),
        .allocator = alloc,
    };
}

/// porcelain-v2-Ausgabe (NUL-getrennt) in das Explorer-Format übersetzen:
/// `root:<abs>`, `branch:<name>`, dann je Eintrag `<code>:<pfad>` (A/M/C/S/?/I).
/// `I` sind ignorierte Einträge (`! pfad`, Ordner ohne abschließenden Schrägstrich).
pub fn parseStatusOutput(alloc: std.mem.Allocator, out: []const u8, root: ?[]const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    if (root) |r| {
        try buf.appendSlice(alloc, "root:");
        try buf.appendSlice(alloc, r);
        try buf.append(alloc, '\n');
    }

    var it = std.mem.splitScalar(u8, out, 0);
    outer: while (it.next()) |line| {
        if (line.len == 0) continue :outer;

        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            try buf.appendSlice(alloc, "branch:");
            try buf.appendSlice(alloc, line["# branch.head ".len..]);
            try buf.append(alloc, '\n');
            continue :outer;
        }

        if ((line[0] == '1' or line[0] == '2') and line.len > 4) {
            // "1 XY sub mH mI mW hH hI path" or "2 XY sub mH mI mW hH hI SMMM HMMM path"
            var parts = std.mem.splitScalar(u8, line, ' ');
            _ = parts.next() orelse continue; // "1" or "2"
            const xy = parts.next() orelse continue; // XY
            // Skip 6 metadata fields (sub,mH,mI,mW,hH,hI)
            var i: usize = 0;
            while (i < 6) : (i += 1) { _ = parts.next() orelse continue :outer; }
            const path = parts.next() orelse continue;
            if (path.len == 0) continue :outer;

            // Skip deleted in worktree (D in second col) — file gone from explorer
            if (xy[1] == 'D') continue :outer;

            // Submodule indicator
            const is_submodule = line[0] == '2';
            // Conflict: 'u' in either column
            const is_conflict = xy[0] == 'u' or xy[1] == 'u';

            const code: u8 = if (is_conflict) 'C'
            else if (is_submodule) 'S'
            else if (xy[0] == 'M' or xy[0] == 'A' or xy[0] == 'D' or xy[0] == 'R') 'A'
            else if (xy[1] == 'M') 'M'
            else continue :outer;
            const entry = try std.fmt.allocPrint(alloc, "{c}:{s}\n", .{ code, path });
            defer alloc.free(entry);
            try buf.appendSlice(alloc, entry);
            continue :outer;
        }

        if (line[0] == '?' or line[0] == '!') {
            // "? <path>" bzw. "! <path>" — Ordner kommen als "pfad/"
            var parts = std.mem.splitScalar(u8, line, ' ');
            _ = parts.next() orelse continue; // "?" / "!"
            const raw = parts.next() orelse continue;
            const path = std.mem.trimEnd(u8, raw, "/");
            if (path.len == 0) continue :outer;
            const code: u8 = if (line[0] == '!') 'I' else '?';
            const entry = try std.fmt.allocPrint(alloc, "{c}:{s}\n", .{ code, path });
            defer alloc.free(entry);
            try buf.appendSlice(alloc, entry);
            continue :outer;
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// Parameter der History-Tasks. `tab_path` ist der Schlüssel im Ergebnis und bestimmt
/// über `git_history.parseTarget` Repo oder Datei. Selbst-owned.
pub const HistoryParams = struct {
    alloc: std.mem.Allocator,
    /// Alle Strings liegen in diesem einen Puffer
    owned: []u8,
    tab_path: []const u8,
    show: Show,

    /// Nur `show`: Commit, Pfad der Datei darin und im nächstälteren Commit (leer = ganzer Commit)
    pub const Show = struct { hash: []const u8 = "", path: []const u8 = "", previous_path: []const u8 = "" };

    pub fn init(alloc: std.mem.Allocator, tab_path: []const u8, show: ?Show) !*HistoryParams {
        const sh = show orelse Show{};
        const self = try alloc.create(HistoryParams);
        errdefer alloc.destroy(self);
        const owned = try std.mem.concat(alloc, u8, &.{ tab_path, sh.hash, sh.path, sh.previous_path });
        var rest: []const u8 = owned;
        self.* = .{
            .alloc = alloc,
            .owned = owned,
            .tab_path = take(&rest, tab_path.len),
            .show = .{ .hash = take(&rest, sh.hash.len), .path = take(&rest, sh.path.len), .previous_path = take(&rest, sh.previous_path.len) },
        };
        return self;
    }

    fn take(rest: *[]const u8, n: usize) []const u8 {
        defer rest.* = rest.*[n..];
        return rest.*[0..n];
    }

    pub fn deinit(self: *HistoryParams) void {
        self.alloc.free(self.owned);
        self.alloc.destroy(self);
    }

    /// Arbeitsordner: der Repo-Ordner selbst, bei Dateien ihr Ordner.
    fn cwd(self: *const HistoryParams) []const u8 {
        const target = git_history.parseTarget(self.tab_path) orelse return ".";
        return switch (target) {
            .repo => |p| p,
            .file => |p| std.fs.path.dirname(p) orelse ".",
        };
    }
};

/// Payload: `<tab_path>\n<git log>` im Format von `git_history.logArgs`.
/// Fehler (kein Repo, Datei nie committet) → Tag `git_log_error` mit stderr als Text.
pub fn taskGitLog(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *HistoryParams = @ptrCast(@alignCast(data.?));
    defer params.deinit();
    const target = git_history.parseTarget(params.tab_path) orelse return error.InvalidHistoryPath;

    var args_buf: [16][]const u8 = undefined;
    return historyResult(alloc, params.tab_path, runGitCapture(alloc, params.cwd(), git_history.logArgs(&args_buf, target)), .git_log, .git_log_error);
}

/// Payload: `<tab_path>\x1f<hash>\n<git show>`; Fehler → Tag `git_show_error`.
pub fn taskGitShow(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *HistoryParams = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    var args_buf: [16][]const u8 = undefined;
    var spec_buf: [2 * std.fs.max_path_bytes + 16]u8 = undefined;
    const sh = params.show;
    const args = git_history.showArgs(&args_buf, &spec_buf, sh.hash, sh.path, sh.previous_path);
    const key = try std.mem.concat(alloc, u8, &.{ params.tab_path, "\x1f", sh.hash });
    defer alloc.free(key);
    return historyResult(alloc, key, runGitCapture(alloc, params.cwd(), args), .git_show, .git_show_error);
}

/// Ein selbst-owned String als Task-Parameter (Tab-Pfad eines Diff-Tabs).
pub const TextParam = struct {
    alloc: std.mem.Allocator,
    text: []u8,

    pub fn init(alloc: std.mem.Allocator, text: []const u8) !*TextParam {
        const self = try alloc.create(TextParam);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .text = try alloc.dupe(u8, text) };
        return self;
    }

    pub fn deinit(self: *TextParam) void {
        self.alloc.free(self.text);
        self.alloc.destroy(self);
    }
};

/// Diff-Editor: Payload `<tab_path>\n` + `git_diff.encodeContents(alt, neu, hunks)`.
/// Fehlt eine Seite (Datei neu angelegt, gelöscht, Wurzel-Commit), ist sie leer.
/// Scheitern die Hunks, kommt Tag `git_file_diff_error` mit stderr.
pub fn taskGitFileDiff(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const param: *TextParam = @ptrCast(@alignCast(data.?));
    defer param.deinit();
    const spec = git_diff.parseTabPath(param.text) orelse return error.InvalidDiffPath;

    var args_buf: [16][]const u8 = undefined;
    var spec_buf: [2 * std.fs.max_path_bytes + 64]u8 = undefined;

    const old = contentOrEmpty(alloc, spec.repo, git_diff.contentArgs(&args_buf, &spec_buf, spec.parent, spec.previous_path));
    defer alloc.free(old);
    const new = contentOrEmpty(alloc, spec.repo, git_diff.contentArgs(&args_buf, &spec_buf, spec.hash, spec.path));
    defer alloc.free(new);

    switch (runGitCapture(alloc, spec.repo, git_diff.hunkArgs(&args_buf, &spec_buf, spec))) {
        .ok => |hunks| {
            defer alloc.free(hunks);
            const body = try git_diff.encodeContents(alloc, old, new, hunks);
            defer alloc.free(body);
            return .{ .tag = .git_file_diff, .payload = try git_history.frame(alloc, param.text, body), .allocator = alloc };
        },
        .failed => |msg| return historyResult(alloc, param.text, .{ .failed = msg }, .git_file_diff, .git_file_diff_error),
    }
}

/// Dateiinhalt über `git show <ref>:<pfad>`; nicht vorhanden → leer (owned).
fn contentOrEmpty(alloc: std.mem.Allocator, cwd: []const u8, args: ?[]const []const u8) []u8 {
    const a = args orelse return no_message;
    return switch (runGitCapture(alloc, cwd, a)) {
        .ok => |out| out,
        .failed => |msg| blk: {
            alloc.free(msg);
            break :blk no_message;
        },
    };
}

fn historyResult(alloc: std.mem.Allocator, key: []const u8, run: GitRun, ok_tag: scheduler.ResultTag, err_tag: scheduler.ResultTag) !scheduler.TaskResult {
    const body, const tag = switch (run) {
        .ok => |out| .{ out, ok_tag },
        .failed => |msg| blk: {
            // Warnung, kein Fehler: eine nie committete Datei ist ein normaler Fall, die
            // Meldung zeigt die Ansicht selbst.
            log.warn("git history '{s}': {s}", .{ key, msg });
            break :blk .{ msg, err_tag };
        },
    };
    defer alloc.free(body);
    return .{ .tag = tag, .payload = try git_history.frame(alloc, key, body), .allocator = alloc };
}

/// Payload: Roher unified diff-Text
pub fn taskGitDiff(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *Params = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const args: []const []const u8 = if (params.extra.len > 0)
        &.{ "diff", "HEAD", "--", params.extra }
    else
        &.{ "diff", "HEAD" };

    const out = try runGit(alloc, params.repo_path, args);

    return .{
        .tag = .git_diff,
        .payload = out,
        .allocator = alloc,
    };
}

/// Payload: Roher git-blame --porcelain Output
pub fn taskGitBlame(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *Params = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    if (params.extra.len == 0) return error.MissingFilePath;

    const dir = std.fs.path.dirname(params.extra) orelse ".";
    const base = std.fs.path.basename(params.extra);

    const out = try runGitCwd(alloc, dir, &.{
        "blame", "--porcelain", "HEAD", "--", base,
    });

    return .{
        .tag = .git_blame,
        .payload = out,
        .allocator = alloc,
    };
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn runGit(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    return runGitCwd(alloc, cwd, args);
}

fn runGitCwd(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    return switch (runGitCapture(alloc, cwd, args)) {
        .ok => |out| out,
        .failed => |msg| {
            // stderr mitloggen: „git exited 128" allein sagt nicht, ob der Ordner
            // kein Repo ist, die Datei fehlt oder git etwas anderes bemängelt.
            log.err("git {s} in '{s}': {s}", .{ args[0], cwd, msg });
            alloc.free(msg);
            return error.GitFailed;
        },
    };
}

/// Ausgabe von git (owned) oder die Fehlermeldung (owned, stderr bzw. Fehlername).
const GitRun = union(enum) { ok: []u8, failed: []u8 };
/// Leere Meldung ohne Allokation (free auf Länge 0 ist erlaubt).
const no_message: []u8 = &.{};

fn runGitCapture(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) GitRun {
    var argv_buf: [32][]const u8 = undefined;
    // quotepath=off: Dateinamen mit Umlauten kommen roh statt als "\303\244" (log --name-only)
    const prefix = [_][]const u8{ "git", "-c", "core.quotepath=off" };
    @memcpy(argv_buf[0..prefix.len], &prefix);
    @memcpy(argv_buf[prefix.len..][0..args.len], args);
    const argv = argv_buf[0 .. args.len + prefix.len];

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 10 * 1024 * 1024,
    }) catch |err| return .{ .failed = alloc.dupe(u8, @errorName(err)) catch no_message };

    const ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (ok) {
        alloc.free(result.stderr);
        return .{ .ok = result.stdout };
    }
    alloc.free(result.stdout);
    const owned = alloc.dupe(u8, std.mem.trim(u8, result.stderr, " \t\r\n")) catch no_message;
    alloc.free(result.stderr);
    return .{ .failed = owned };
}

/// Liegt `path` in einem Git-Repository? Sucht `.git` aufwärts bis zur Wurzel.
/// `.git` kann Ordner (normales Repo) oder Datei (Worktree, Submodul) sein.
///
/// Ohne diese Prüfung reihte jeder Ordnerwechsel git-Tasks ein, die in Ordnern
/// wie `~/projects` nur mit Exit 128 zurückkamen.
pub fn isInsideRepo(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir: []const u8 = std.fs.cwd().realpath(path, &buf) catch return false;

    while (true) {
        var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrint(&candidate_buf, "{s}/.git", .{dir}) catch return false;
        // access statt statFile: `.git` ist ein Ordner (statFile scheitert daran
        // unter Windows) oder bei Worktrees/Submodulen eine Datei — beides zählt.
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return true;
        } else |_| {}

        const parent = std.fs.path.dirname(dir) orelse return false;
        if (parent.len == dir.len) return false;
        dir = parent;
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "isInsideRepo erkennt das eigene Repo und Unterordner" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    try std.testing.expect(isInsideRepo(cwd));

    const sub = try std.fs.path.join(alloc, &.{ cwd, "src", "git" });
    defer alloc.free(sub);
    try std.testing.expect(isInsideRepo(sub));
}

test "isInsideRepo lehnt Ordner ohne Repo ab" {
    // Nicht `std.testing.tmpDir` nehmen: der legt unter `.zig-cache/tmp` an und
    // liegt damit selbst im Repo.
    try std.testing.expect(!isInsideRepo("/tmp"));
    try std.testing.expect(!isInsideRepo("/"));
    try std.testing.expect(!isInsideRepo("/gibt/es/nicht"));
}

test "git branch returns non-empty string" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    const params = try Params.init(alloc, cwd, "");
    const result = try taskGitBranch(alloc, params);
    defer result.deinit();

    try std.testing.expect(result.payload.len > 0);
    try std.testing.expect(result.tag == .git_branch);
}

test "git status returns branch line" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    const params = try Params.init(alloc, cwd, "");
    const result = try taskGitStatus(alloc, params);
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.payload, "branch:") != null);
}

test "taskGitLog: Repo-Log mit Tab-Pfad als Schlüssel, Commits lesbar" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    const tab = try git_history.tabPath(alloc, .{ .repo = cwd });
    defer alloc.free(tab);

    const result = try taskGitLog(alloc, try HistoryParams.init(alloc, tab, null));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_log);
    const u = git_history.unframe(result.payload).?;
    try std.testing.expectEqualStrings(tab, u.key);
    var log_ = try git_history.parseLog(alloc, u.body);
    defer log_.deinit();
    try std.testing.expect(log_.commits.len > 1);
    try std.testing.expectEqual(@as(usize, 40), log_.commits[0].hash.len);
    try std.testing.expectEqualStrings("", log_.commits[0].path);
}

test "taskGitLog: Datei-Log liefert Pfad relativ zur Repo-Wurzel" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    const file = try std.fs.path.join(alloc, &.{ cwd, "src", "git", "git_worker.zig" });
    defer alloc.free(file);
    const tab = try git_history.tabPath(alloc, .{ .file = file });
    defer alloc.free(tab);

    const result = try taskGitLog(alloc, try HistoryParams.init(alloc, tab, null));
    defer result.deinit();
    var log_ = try git_history.parseLog(alloc, git_history.unframe(result.payload).?.body);
    defer log_.deinit();
    try std.testing.expect(log_.commits.len > 0);
    try std.testing.expectEqualStrings("src/git/git_worker.zig", log_.commits[0].path);
}

test "taskGitShow: Diff eines Commits, Schlüssel mit Hash, auf Datei begrenzt" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    const file = try std.fs.path.join(alloc, &.{ cwd, "src", "git", "git_worker.zig" });
    defer alloc.free(file);
    const tab = try git_history.tabPath(alloc, .{ .file = file });
    defer alloc.free(tab);

    const log_result = try taskGitLog(alloc, try HistoryParams.init(alloc, tab, null));
    defer log_result.deinit();
    var log_ = try git_history.parseLog(alloc, git_history.unframe(log_result.payload).?.body);
    defer log_.deinit();
    const c = log_.commits[0];

    const result = try taskGitShow(alloc, try HistoryParams.init(alloc, tab, .{ .hash = c.hash, .path = c.path, .previous_path = c.path }));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_show);
    const u = git_history.unframe(result.payload).?;
    const k = git_history.splitKey(u.key);
    try std.testing.expectEqualStrings(tab, k.tab_path);
    try std.testing.expectEqualStrings(c.hash, k.hash);
    try std.testing.expect(std.mem.startsWith(u8, u.body, "commit "));
    try std.testing.expect(std.mem.indexOf(u8, u.body, "diff --git a/src/git/git_worker.zig") != null);
    // auf die Datei begrenzt: kein Diff anderer Dateien. Zeilenanfänge zählen, nicht Teilstrings:
    // der Diff dieser Datei enthält den Text "diff --git" selbst (in genau diesem Test).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, u.body, "\ndiff --git "));
}

test "taskGitFileDiff: alter und neuer Inhalt plus Hunks einer Datei in einem Commit" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    const file = try std.fs.path.join(alloc, &.{ cwd, "src", "git", "git_history.zig" });
    defer alloc.free(file);
    const htab = try git_history.tabPath(alloc, .{ .file = file });
    defer alloc.free(htab);
    const log_result = try taskGitLog(alloc, try HistoryParams.init(alloc, htab, null));
    defer log_result.deinit();
    var log_ = try git_history.parseLog(alloc, git_history.unframe(log_result.payload).?.body);
    defer log_.deinit();

    // jüngster Commit: beide Seiten vorhanden
    const c = log_.commits[0];
    const tab = try git_diff.tabPath(alloc, .{ .hash = c.hash, .parent = c.firstParent(), .repo = cwd, .path = c.path, .previous_path = log_.commits[@min(1, log_.commits.len - 1)].path });
    defer alloc.free(tab);
    const result = try taskGitFileDiff(alloc, try TextParam.init(alloc, tab));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_file_diff);
    const u = git_history.unframe(result.payload).?;
    try std.testing.expectEqualStrings(tab, u.key);
    const contents = git_diff.decodeContents(u.body).?;
    try std.testing.expect(std.mem.indexOf(u8, contents.new, "pub const State") != null);
    const hunks = try git_diff.parseHunks(alloc, contents.hunks);
    defer alloc.free(hunks);
    try std.testing.expect(hunks.len > 0);

    // ältester Commit: Datei neu angelegt, alter Inhalt leer, ein Hunk ab Zeile 0
    const first = log_.commits[log_.commits.len - 1];
    const tab0 = try git_diff.tabPath(alloc, .{ .hash = first.hash, .parent = first.firstParent(), .repo = cwd, .path = first.path, .previous_path = first.path });
    defer alloc.free(tab0);
    const r0 = try taskGitFileDiff(alloc, try TextParam.init(alloc, tab0));
    defer r0.deinit();
    const c0 = git_diff.decodeContents(git_history.unframe(r0.payload).?.body).?;
    try std.testing.expectEqual(@as(usize, 0), c0.old.len);
    const h0 = try git_diff.parseHunks(alloc, c0.hunks);
    defer alloc.free(h0);
    try std.testing.expectEqual(@as(u32, 0), h0[0].old_start);
}

test "taskGitLog: Fehler von git kommt als Text im Ergebnis, nicht als Task-Fehler" {
    const alloc = std.testing.allocator;
    const tab = try git_history.tabPath(alloc, .{ .repo = "/" });
    defer alloc.free(tab);
    const result = try taskGitLog(alloc, try HistoryParams.init(alloc, tab, null));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_log_error);
    try std.testing.expectEqualStrings(tab, git_history.unframe(result.payload).?.key);
}

test "git diff HEAD runs without error" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    const params = try Params.init(alloc, cwd, "");
    const result = try taskGitDiff(alloc, params);
    defer result.deinit();

    try std.testing.expect(result.tag == .git_diff);
}

test "git blame on known file" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    const file = try std.fs.path.join(alloc, &.{ cwd, "README.md" });
    defer alloc.free(file);

    const params = try Params.init(alloc, cwd, file);
    const result = try taskGitBlame(alloc, params);
    defer result.deinit();

    try std.testing.expect(result.payload.len > 0);
    try std.testing.expect(result.tag == .git_blame);
}
// extra line Sa 18 Apr 2026 12:35:44 CEST

test "parseStatusOutput: root, branch, geändert, unbekannt, ignoriert (Ordner ohne Schrägstrich)" {
    const alloc = std.testing.allocator;
    const out = "# branch.head main\x00" ++
        "1 .M N... 100644 100644 100644 abc def src/a.zig\x00" ++
        "1 A. N... 000000 100644 100644 000 111 src/new.zig\x00" ++
        "? notes.txt\x00" ++
        "! zig-out/\x00" ++
        "! build.log\x00";
    const payload = try parseStatusOutput(alloc, out, "/repo");
    defer alloc.free(payload);
    try std.testing.expectEqualStrings("root:/repo\nbranch:main\nM:src/a.zig\nA:src/new.zig\n?:notes.txt\nI:zig-out\nI:build.log\n", payload);
    const no_root = try parseStatusOutput(alloc, "? x\x00", null);
    defer alloc.free(no_root);
    try std.testing.expectEqualStrings("?:x\n", no_root);
}
