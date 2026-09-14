//! Git Task-Funktionen für den Scheduler.
//! Alle Funktionen laufen in Worker-Threads via std.process.Child.
//! Payload-Format ist plain-text (human readable + maschinell parsbar).

const std = @import("std");
const scheduler = @import("scheduler");

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

/// Payload: "<short-hash> <subject>\n" pro Zeile
pub fn taskGitLog(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *Params = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const out = try runGit(alloc, params.repo_path, &.{
        "log", "--oneline", "-n", "50",
    });

    return .{
        .tag = .git_log,
        .payload = out,
        .allocator = alloc,
    };
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
    var argv_buf: [32][]const u8 = undefined;
    argv_buf[0] = "git";
    @memcpy(argv_buf[1..][0..args.len], args);
    const argv = argv_buf[0 .. args.len + 1];

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 10 * 1024 * 1024,
    });
    defer alloc.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            alloc.free(result.stdout);
            // stderr mitloggen: „git exited 128" allein sagt nicht, ob der Ordner
            // kein Repo ist, die Datei fehlt oder git etwas anderes bemängelt.
            log.err("git {s} in '{s}': exit {d}: {s}", .{
                args[0],
                cwd,
                code,
                std.mem.trim(u8, result.stderr, " \t\r\n"),
            });
            return error.GitFailed;
        },
        else => {
            alloc.free(result.stdout);
            log.err("git {s} in '{s}' abgebrochen: {s}", .{
                args[0],
                cwd,
                std.mem.trim(u8, result.stderr, " \t\r\n"),
            });
            return error.GitFailed;
        },
    }

    return result.stdout;
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

test "git log returns oneline entries" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    const params = try Params.init(alloc, cwd, "");
    const result = try taskGitLog(alloc, params);
    defer result.deinit();

    try std.testing.expect(result.payload.len > 0);
    try std.testing.expect(result.tag == .git_log);
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
