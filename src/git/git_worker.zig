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
///   Codes: + staged, ~ modified, - deleted, ? untracked
pub fn taskGitStatus(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *Params = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const out = try runGit(alloc, params.repo_path, &.{
        "--no-optional-locks", "status", "--porcelain=v2",
        "--branch",            "--null",
    });
    defer alloc.free(out);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    var it = std.mem.splitScalar(u8, out, 0);
    outer: while (it.next()) |line| {
        if (line.len == 0) continue :outer;

        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            try buf.appendSlice(alloc, "branch:");
            try buf.appendSlice(alloc, line["# branch.head ".len..]);
            try buf.append(alloc, '\n');
            continue :outer;
        }

        if (line[0] == '1' and line.len > 4) {
            // "1 XY sub mH mI mW hH hI path"
            const xy = line[2..4];
            var fields = std.mem.splitScalar(u8, line, ' ');
            var idx: usize = 0;
            var path: []const u8 = "";
            while (fields.next()) |f| : (idx += 1) {
                if (idx == 8) { path = f; break; }
            }
            if (path.len == 0) continue :outer;

            const staged = xy[0] != '.' and xy[0] != ' ';
            const code: u8 = if (staged) '+' else if (xy[1] == 'M') '~' else if (xy[1] == 'D') '-' else {
                continue :outer;
            };
            const entry = try std.fmt.allocPrint(alloc, "{c}:{s}\n", .{ code, path });
            defer alloc.free(entry);
            try buf.appendSlice(alloc, entry);
            continue :outer;
        }

        if (line[0] == '?' and line.len > 2) {
            const entry = try std.fmt.allocPrint(alloc, "?:{s}\n", .{line[2..]});
            defer alloc.free(entry);
            try buf.appendSlice(alloc, entry);
            continue :outer;
        }
    }

    return .{
        .tag = .git_status,
        .payload = try buf.toOwnedSlice(alloc),
        .allocator = alloc,
    };
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
            log.err("git exited {d}", .{code});
            return error.GitFailed;
        },
        else => {
            alloc.free(result.stdout);
            return error.GitFailed;
        },
    }

    return result.stdout;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

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
