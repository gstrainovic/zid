//! Git Task-Funktionen für den Scheduler.
//! Alle Funktionen laufen in Worker-Threads via std.process.Child.
//! Payload-Format ist plain-text (human readable + maschinell parsbar).

const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("scheduler");
const git_diff = @import("git_diff");
const git_timeline = @import("git_timeline");
const git_scm = @import("git_scm");

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

    // Fremdes Repo: die Rückfrage kommt vom Status-Task, der Branch bleibt leer
    const out = runGit(alloc, params.repo_path, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) catch |err| switch (err) {
        error.GitUnsafeRepo => return .{ .tag = .git_branch, .payload = try alloc.dupe(u8, ""), .allocator = alloc },
        else => return err,
    };
    defer alloc.free(out);

    return .{
        .tag = .git_branch,
        .payload = try alloc.dupe(u8, std.mem.trimRight(u8, out, "\n\r")),
        .allocator = alloc,
    };
}

/// Payload: "branch:<name>\n<code>:<path>\n..." (Explorer), dann 0x1c und die rohe
/// porcelain-v2-Ausgabe (NUL-getrennt) für Source Control (`git_changes.parseStatus`).
///   Codes: A staged, M modified, ? untracked, C conflict, S submodule
pub fn taskGitStatus(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const params: *Params = @ptrCast(@alignCast(data.?));
    defer params.deinit();

    const args = [_][]const u8{
        "--no-optional-locks", "status", "--porcelain=v2",
        "--branch",            "--null", "--ignored",
    };
    const out = switch (runGitCapture(alloc, params.repo_path, &args)) {
        .ok => |o| o,
        .failed => |msg| {
            defer alloc.free(msg);
            // Repo gehört einem anderen Benutzer: die UI fragt, ob sie ihm vertrauen soll
            // (Payload = der Wert, den git selbst für safe.directory vorschlägt)
            if (unsafeRepoDirectory(msg)) |dir| {
                log.warn("git status in '{s}': Repo gehört einem anderen Benutzer (safe.directory)", .{params.repo_path});
                return .{ .tag = .git_unsafe_repo, .payload = try alloc.dupe(u8, dir), .allocator = alloc };
            }
            log.err("git status in '{s}': {s}", .{ params.repo_path, msg });
            return error.GitFailed;
        },
    };
    defer alloc.free(out);

    // Pfade in porcelain v2 sind relativ zur Repo-Wurzel, nicht zum Projektordner
    const toplevel = runGit(alloc, params.repo_path, &.{ "rev-parse", "--show-toplevel" }) catch null;
    defer if (toplevel) |t| alloc.free(t);
    const root = if (toplevel) |t| std.mem.trimEnd(u8, t, "\n\r") else null;

    const explorer = try parseStatusOutput(alloc, out, root);
    defer alloc.free(explorer);
    return .{
        .tag = .git_status,
        .payload = try std.mem.concat(alloc, u8, &.{ explorer, "\x1c", out }),
        .allocator = alloc,
    };
}

/// Explorer-Teil und rohe v2-Ausgabe eines `git_status`-Payloads.
pub fn splitStatusPayload(payload: []const u8) struct { explorer: []const u8, raw: []const u8 } {
    const sep = std.mem.indexOfScalar(u8, payload, 0x1c) orelse return .{ .explorer = payload, .raw = "" };
    return .{ .explorer = payload[0..sep], .raw = payload[sep + 1 ..] };
}

/// Source-Control-Aktion (Felder: Aktion, Repo, dann Pfade bzw. die Commit-Nachricht):
/// `stage` = `add -A --`, `unstage` = `reset -q HEAD --`, `discard_tracked` = `checkout -q --`,
/// `discard_untracked` = `clean -f -q --`, `commit` = `commit --quiet --file - --allow-empty-message`
/// mit der Nachricht über stdin (VS Code git.ts), `push` = `push --quiet` plus Felder als
/// Argumente (Publish Branch), `sync` = `pull --quiet`, dann `push --quiet` (VS Code git.sync).
/// Payload `<aktion>\n<stderr>`; Fehler von git kommen als Tag `git_action_error`, nie als
/// Task-Fehler.
pub fn taskGitAction(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const param: *FieldsParam = @ptrCast(@alignCast(data.?));
    defer param.deinit();
    const action = param.field(0);
    const repo = param.field(1);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    var stdin: ?[]const u8 = null;
    if (std.mem.eql(u8, action, "commit_diff")) {
        // Diff für „Generate Commit Message“: gestagt, sonst Arbeitskopie plus untracked Dateien
        const staged = switch (runGitCapture(alloc, repo, &.{ "diff", "--cached", "--no-color", "--no-ext-diff" })) {
            .ok => |out| out,
            .failed => |msg| return framedResult(alloc, action, .{ .failed = msg }, .git_action, .git_action_error),
        };
        defer alloc.free(staged);
        if (std.mem.trim(u8, staged, " \r\n").len > 0) return .{ .tag = .git_action, .payload = try frame(alloc, action, staged), .allocator = alloc };
        const work = switch (runGitCapture(alloc, repo, &.{ "diff", "--no-color", "--no-ext-diff" })) {
            .ok => |out| out,
            .failed => |msg| return framedResult(alloc, action, .{ .failed = msg }, .git_action, .git_action_error),
        };
        defer alloc.free(work);
        const untracked = switch (runGitCapture(alloc, repo, &.{ "ls-files", "--others", "--exclude-standard" })) {
            .ok => |out| out,
            .failed => |msg| blk: {
                alloc.free(msg);
                break :blk try alloc.dupe(u8, "");
            },
        };
        defer alloc.free(untracked);
        const body = if (untracked.len > 0) try std.mem.concat(alloc, u8, &.{ work, "\nUntracked files:\n", untracked }) else try alloc.dupe(u8, work);
        defer alloc.free(body);
        return .{ .tag = .git_action, .payload = try frame(alloc, action, body), .allocator = alloc };
    }
    if (std.mem.eql(u8, action, "sync")) {
        // Sync wie VS Code `git.sync` (repository.ts `sync`): erst pull, dann push. Scheitert der
        // Pull (Konflikt, divergiert ohne pull.rebase), bleibt es beim Fehler, kein Push.
        switch (runGitCapture(alloc, repo, &.{ "pull", "--quiet" })) {
            .ok => |out| alloc.free(out),
            .failed => |msg| return framedResult(alloc, action, .{ .failed = msg }, .git_action, .git_action_error),
        }
        try argv.appendSlice(alloc, &.{ "push", "--quiet" });
    } else if (std.mem.eql(u8, action, "commit") or std.mem.eql(u8, action, "commit_all")) {
        // commit_all = VS Code smartCommit ohne Staged Changes: erst alles stagen
        if (std.mem.eql(u8, action, "commit_all")) switch (runGitCapture(alloc, repo, &.{ "add", "-A" })) {
            .ok => |out| alloc.free(out),
            .failed => |msg| return framedResult(alloc, action, .{ .failed = msg }, .git_action, .git_action_error),
        };
        try argv.appendSlice(alloc, &.{ "commit", "--quiet", "--file", "-", "--allow-empty-message" });
        stdin = param.field(2);
    } else {
        const head: []const []const u8 = if (std.mem.eql(u8, action, "stage"))
            &.{ "add", "-A", "--" }
        else if (std.mem.eql(u8, action, "unstage"))
            &.{ "reset", "-q", "HEAD", "--" }
        else if (std.mem.eql(u8, action, "discard_tracked"))
            &.{ "checkout", "-q", "--" }
        else if (std.mem.eql(u8, action, "discard_untracked"))
            &.{ "clean", "-f", "-q", "--" }
        else if (std.mem.eql(u8, action, "push"))
            // Push (Felder = weitere git-Argumente, `-u origin main` für Publish Branch)
            &.{ "push", "--quiet" }
        else if (std.mem.eql(u8, action, "trust_repo"))
            // Fremdes Repo freigeben wie VS Code „Manage Unsafe Repositories“ (Feld = Wert
            // aus gits Fehlermeldung, siehe unsafeRepoDirectory)
            &.{ "config", "--global", "--add", "safe.directory" }
        else
            return error.UnknownGitAction;
        try argv.appendSlice(alloc, head);
        var i: usize = 2;
        while (true) : (i += 1) {
            const p = param.field(i);
            if (p.len == 0) break;
            try argv.append(alloc, p);
        }
    }
    const run = runGitCaptureStdin(alloc, repo, argv.items, stdin);
    return switch (run) {
        .ok => |out| blk: {
            defer alloc.free(out);
            break :blk .{ .tag = .git_action, .payload = try frame(alloc, action, ""), .allocator = alloc };
        },
        .failed => |msg| framedResult(alloc, action, .{ .failed = msg }, .git_action, .git_action_error),
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

/// Ergebnis der Git-Ansichten (Timeline, Diff-Editor, Graph): `<schlüssel>\n<text>`. Der
/// Schlüssel ist der Tab-Pfad bzw. die Datei, bei Commit-Anfragen zusätzlich `\x1f<hash>`,
/// damit ein veraltetes Ergebnis erkannt wird (owned).
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
    // Arbeitskopie (Source Control „Changes“): Datei von der Platte, fehlt sie (gelöscht) leer
    const worktree = std.mem.eql(u8, spec.hash, git_diff.worktree_ref);
    const new = if (worktree) readWorktreeFile(alloc, spec.repo, spec.path) else contentOrEmpty(alloc, spec.repo, git_diff.contentArgs(&args_buf, &spec_buf, spec.hash, spec.path));
    defer alloc.free(new);

    // Untracked: git kennt die Datei nicht, der Hunk-Kopf kommt aus der Zeilenzahl
    if (worktree and spec.parent.len == 0) {
        const hunks = try git_diff.syntheticAddHunk(alloc, new);
        defer alloc.free(hunks);
        const body = try git_diff.encodeContents(alloc, old, new, hunks);
        defer alloc.free(body);
        return .{ .tag = .git_file_diff, .payload = try frame(alloc, param.text, body), .allocator = alloc };
    }

    switch (runGitCapture(alloc, spec.repo, git_diff.hunkArgs(&args_buf, &spec_buf, spec))) {
        .ok => |hunks| {
            defer alloc.free(hunks);
            const body = try git_diff.encodeContents(alloc, old, new, hunks);
            defer alloc.free(body);
            return .{ .tag = .git_file_diff, .payload = try frame(alloc, param.text, body), .allocator = alloc };
        },
        .failed => |msg| return framedResult(alloc, param.text, .{ .failed = msg }, .git_file_diff, .git_file_diff_error),
    }
}

/// Timeline einer Datei: Payload `<datei>\n<repo-wurzel>\n<git log>` (git_timeline.logArgs).
/// Fehler (kein Repo) → Tag `git_timeline_error` mit stderr.
pub fn taskGitTimeline(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const param: *TextParam = @ptrCast(@alignCast(data.?));
    defer param.deinit();
    const dir = std.fs.path.dirname(param.text) orelse ".";

    const toplevel = switch (runGitCapture(alloc, dir, &.{ "rev-parse", "--show-toplevel" })) {
        .ok => |out| out,
        .failed => |msg| return framedResult(alloc, param.text, .{ .failed = msg }, .git_timeline, .git_timeline_error),
    };
    defer alloc.free(toplevel);

    var args_buf: [16][]const u8 = undefined;
    // Index-Status für „Staged Changes“ (leer, wenn die Datei nicht gestagt ist)
    const staged = switch (runGitCapture(alloc, dir, git_timeline.stagedArgs(&args_buf, param.text))) {
        .ok => |out| out,
        .failed => |msg| msg,
    };
    defer alloc.free(staged);
    switch (runGitCapture(alloc, dir, git_timeline.logArgs(&args_buf, param.text))) {
        .ok => |log_out| {
            defer alloc.free(log_out);
            const body = try std.mem.concat(alloc, u8, &.{ repoRoot(toplevel), "\n", staged, "\x1c", log_out });
            defer alloc.free(body);
            return .{ .tag = .git_timeline, .payload = try frame(alloc, param.text, body), .allocator = alloc };
        },
        .failed => |msg| return framedResult(alloc, param.text, .{ .failed = msg }, .git_timeline, .git_timeline_error),
    }
}

/// Mehrere Strings als Task-Parameter, intern mit 0x1e getrennt (selbst-owned). Nicht 0x1f:
/// das trennt bereits Schlüssel wie `graph<gen>\x1f<hash>`.
pub const FieldsParam = struct {
    const sep: u8 = 0x1e;

    alloc: std.mem.Allocator,
    text: []u8,

    pub fn init(alloc: std.mem.Allocator, fields: []const []const u8) !*FieldsParam {
        const self = try alloc.create(FieldsParam);
        errdefer alloc.destroy(self);
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(alloc);
        for (fields, 0..) |f, i| {
            if (i > 0) try list.append(alloc, sep);
            try list.appendSlice(alloc, f);
        }
        self.* = .{ .alloc = alloc, .text = try list.toOwnedSlice(alloc) };
        return self;
    }

    pub fn deinit(self: *FieldsParam) void {
        self.alloc.free(self.text);
        self.alloc.destroy(self);
    }

    fn field(self: *const FieldsParam, index: usize) []const u8 {
        var it = std.mem.splitScalar(u8, self.text, sep);
        var i: usize = 0;
        while (it.next()) |f| : (i += 1) if (i == index) return f;
        return "";
    }
};

/// Repo-Wurzel aus `rev-parse --show-toplevel`: Zeilenende weg, und unter Windows
/// die "/" von git auf "\" — der Pfad wird mit Editor- und Explorer-Pfaden verglichen
/// und zu Tab-Schlüsseln zusammengesetzt.
fn repoRoot(toplevel: []u8) []const u8 {
    const root = std.mem.trimRight(u8, toplevel, "\r\n");
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, toplevel[0..root.len], '/', std.fs.path.sep);
    return root;
}

/// Erste Zeile einer git-Ausgabe oder leer (owned), Fehler zählen als leer.
fn firstLineOrEmpty(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) []u8 {
    return switch (runGitCapture(alloc, cwd, args)) {
        .ok => |out| blk: {
            const trimmed = std.mem.trim(u8, out, " \r\n");
            std.mem.copyForwards(u8, out, trimmed);
            break :blk alloc.realloc(out, trimmed.len) catch out[0..trimmed.len];
        },
        .failed => |msg| blk: {
            alloc.free(msg);
            break :blk no_message;
        },
    };
}

/// Source Control Graph, eine Seite. Felder: Schlüssel, Repo-Ordner, skip, Seitengröße.
/// Payload: `<schlüssel>\n<branch>\x1f<ref>\x1f<upstream>\x1f<basis>\x1f<repo>\n<git log>`.
/// Filter wie VS Code „Auto“: Branch, Upstream, Basis (Standard-Branch des Remotes).
pub fn taskGitGraphLog(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const param: *FieldsParam = @ptrCast(@alignCast(data.?));
    defer param.deinit();
    const key = param.field(0);
    const dir = param.field(1);
    const skip = std.fmt.parseInt(usize, param.field(2), 10) catch 0;
    const limit = std.fmt.parseInt(usize, param.field(3), 10) catch git_scm.page_size;

    const toplevel = switch (runGitCapture(alloc, dir, &.{ "rev-parse", "--show-toplevel" })) {
        .ok => |out| out,
        .failed => |msg| return framedResult(alloc, key, .{ .failed = msg }, .git_graph_log, .git_graph_log_error),
    };
    defer alloc.free(toplevel);
    const current = firstLineOrEmpty(alloc, dir, &.{ "symbolic-ref", "-q", "HEAD" });
    defer alloc.free(current);
    const upstream = firstLineOrEmpty(alloc, dir, &.{ "rev-parse", "--symbolic-full-name", "@{upstream}" });
    defer alloc.free(upstream);
    const base = firstLineOrEmpty(alloc, dir, &.{ "symbolic-ref", "-q", "refs/remotes/origin/HEAD" });
    defer alloc.free(base);

    const filter = git_scm.AutoFilter{ .current = current, .upstream = upstream, .base = base };
    var refs_buf: [4][]const u8 = undefined;
    var args_buf: [24][]const u8 = undefined;
    var num_buf: [48]u8 = undefined;
    const args = git_scm.logArgs(&args_buf, &num_buf, filter.refNames(&refs_buf), skip, limit);
    switch (runGitCapture(alloc, dir, args)) {
        .ok => |log_out| {
            defer alloc.free(log_out);
            const branch = if (std.mem.startsWith(u8, current, "refs/heads/")) current["refs/heads/".len..] else "HEAD";
            const body = try std.mem.concat(alloc, u8, &.{
                branch, "\x1f", current, "\x1f", upstream, "\x1f", base, "\x1f", repoRoot(toplevel), "\n", log_out,
            });
            defer alloc.free(body);
            return .{ .tag = .git_graph_log, .payload = try frame(alloc, key, body), .allocator = alloc };
        },
        .failed => |msg| return framedResult(alloc, key, .{ .failed = msg }, .git_graph_log, .git_graph_log_error),
    }
}

/// Geänderte Dateien eines Commits. Felder: Schlüssel, Repo, Commit, erster Elternteil.
/// Payload `<schlüssel>\n<git diff --name-status>`.
pub fn taskGitCommitChanges(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const param: *FieldsParam = @ptrCast(@alignCast(data.?));
    defer param.deinit();
    var args_buf: [16][]const u8 = undefined;
    const args = git_scm.changesArgs(&args_buf, param.field(2), param.field(3));
    return framedResult(alloc, param.field(0), runGitCapture(alloc, param.field(1), args), .git_commit_changes, .git_commit_changes_error);
}

/// Statistik eines Commits für den Graph-Hover (`git_scm.statArgs`). Felder wie
/// `taskGitCommitChanges`; Payload `<schlüssel>\n<git diff --shortstat>`.
pub fn taskGitCommitStat(alloc: std.mem.Allocator, data: ?*anyopaque) !scheduler.TaskResult {
    const param: *FieldsParam = @ptrCast(@alignCast(data.?));
    defer param.deinit();
    var args_buf: [16][]const u8 = undefined;
    const args = git_scm.statArgs(&args_buf, param.field(2), param.field(3));
    return framedResult(alloc, param.field(0), runGitCapture(alloc, param.field(1), args), .git_commit_stat, .git_commit_stat_error);
}

/// Dateiinhalt über `git show <ref>:<pfad>`; nicht vorhanden → leer (owned).
/// Datei der Arbeitskopie (relativ zur Repo-Wurzel), leer wenn sie fehlt oder zu groß ist.
fn readWorktreeFile(alloc: std.mem.Allocator, repo: []const u8, path: []const u8) []u8 {
    var dir = std.fs.cwd().openDir(repo, .{}) catch return no_message;
    defer dir.close();
    return dir.readFileAlloc(alloc, path, 64 * 1024 * 1024) catch no_message;
}

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

fn framedResult(alloc: std.mem.Allocator, key: []const u8, run: GitRun, ok_tag: scheduler.ResultTag, err_tag: scheduler.ResultTag) !scheduler.TaskResult {
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
    return .{ .tag = tag, .payload = try frame(alloc, key, body), .allocator = alloc };
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
            defer alloc.free(msg);
            // Fremdes Repo: eine Zeile statt gits zehnzeiliger Anleitung, die Rückfrage
            // übernimmt die UI (taskGitStatus → git_unsafe_repo)
            if (unsafeRepoDirectory(msg) != null) {
                log.warn("git {s} in '{s}': Repo gehört einem anderen Benutzer (safe.directory)", .{ args[0], cwd });
                return error.GitUnsafeRepo;
            }
            // stderr mitloggen: „git exited 128" allein sagt nicht, ob der Ordner
            // kein Repo ist, die Datei fehlt oder git etwas anderes bemängelt.
            log.err("git {s} in '{s}': {s}", .{ args[0], cwd, msg });
            return error.GitFailed;
        },
    };
}

/// Weist git das Repo ab, weil es einem anderen Benutzer gehört („detected dubious ownership“,
/// seit git 2.35.2)? Dann der Wert, den git in seiner Anleitung für
/// `git config --global --add safe.directory <wert>` vorschlägt, ohne Anführungszeichen.
/// Den Wert nimmt zid wörtlich: unter Windows auf Netzlaufwerken ist es `%(prefix)///host/…`,
/// eine Form, die sich aus dem Projektpfad nicht sicher ableiten lässt. null sonst.
pub fn unsafeRepoDirectory(msg: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, msg, "dubious ownership") == null) return null;
    const marker = "safe.directory ";
    const start = (std.mem.lastIndexOf(u8, msg, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, msg, start, '\n') orelse msg.len;
    var value = std.mem.trim(u8, msg[start..end], " \t\r");
    // git quotet nur bei Bedarf (sq_quote_buf_pretty): unter Windows mit '…', unter Linux meist roh
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') value = value[1 .. value.len - 1];
    return if (value.len > 0) value else null;
}

/// Ausgabe von git (owned) oder die Fehlermeldung (owned, stderr bzw. Fehlername).
const GitRun = union(enum) { ok: []u8, failed: []u8 };
/// Leere Meldung ohne Allokation (free auf Länge 0 ist erlaubt).
const no_message: []u8 = &.{};

/// Laufende git-Prozesse, damit `killRunning` sie beim Beenden abbrechen kann. Auf einem
/// Netzlaufwerk dauert `git log` länger als die 2 s, die der Scheduler beim Beenden wartet;
/// er ließ den Worker dann zurück, und der Allocator meldete dessen Speicher als Leck.
///
/// Unter Windows reicht es nicht, den gestarteten Prozess zu beenden: `git.exe` aus `bin\` ist
/// ein Launcher, der `mingw64\bin\git.exe` startet. Der echte git hielt die Pipes offen und
/// der Worker wartete weiter. Deshalb laufen alle git-Prozesse in einem Job-Objekt;
/// Kindprozesse erben es, `TerminateJobObject` beendet den ganzen Baum.
var running_mutex: std.Thread.Mutex = .{};
var running: [16]?std.process.Child.Id = @splat(null);
var stopping: bool = false;
var git_job: ?std.os.windows.HANDLE = null;

const job_api = struct {
    const windows = std.os.windows;
    extern "kernel32" fn CreateJobObjectW(attrs: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, exit_code: windows.UINT) callconv(.winapi) windows.BOOL;
};

/// Beendet sich zid schon, wird der Prozess sofort wieder beendet.
fn registerRunning(id: std.process.Child.Id) void {
    running_mutex.lock();
    defer running_mutex.unlock();
    if (builtin.os.tag == .windows) {
        if (git_job == null) git_job = job_api.CreateJobObjectW(null, null);
        if (git_job) |job| _ = job_api.AssignProcessToJobObject(job, id);
    }
    if (stopping) return terminateLocked(id);
    for (&running) |*slot| if (slot.* == null) {
        slot.* = id;
        break;
    };
}

/// Muss vor `child.wait` laufen: wait schließt den Handle, danach darf ihn niemand mehr beenden.
fn unregisterRunning(id: std.process.Child.Id) void {
    running_mutex.lock();
    defer running_mutex.unlock();
    for (&running) |*slot| if (slot.* == id) {
        slot.* = null;
    };
}

fn terminateLocked(id: std.process.Child.Id) void {
    if (builtin.os.tag == .windows) {
        if (git_job) |job| {
            _ = job_api.TerminateJobObject(job, 1);
        } else std.os.windows.TerminateProcess(id, 1) catch {};
    } else {
        // Ganze Prozessgruppe (pgid = 0 beim Start): Kinder wie ein Hook erben sonst die
        // stderr-Pipe und halten sie offen, nachdem git selbst schon beendet ist.
        std.posix.kill(-id, std.posix.SIG.TERM) catch {};
    }
}

/// Beim Beenden: laufende git-Prozesse abbrechen und keine neuen mehr starten.
pub fn killRunning() void {
    running_mutex.lock();
    defer running_mutex.unlock();
    stopping = true;
    for (&running) |*slot| if (slot.*) |id| {
        terminateLocked(id);
        slot.* = null;
    };
}

fn runGitCapture(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) GitRun {
    return runGitCaptureStdin(alloc, cwd, args, null);
}

/// Wie `runGitCapture`, optional mit Text auf stdin (Commit-Nachricht über `--file -`).
fn runGitCaptureStdin(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8, stdin: ?[]const u8) GitRun {
    var argv_buf: [64][]const u8 = undefined;
    // quotepath=off: Dateinamen mit Umlauten kommen roh statt als "\303\244" (log --name-only)
    const prefix = [_][]const u8{ "git", "-c", "core.quotepath=off" };
    if (args.len + prefix.len > argv_buf.len) return .{ .failed = alloc.dupe(u8, "too many arguments") catch no_message };
    @memcpy(argv_buf[0..prefix.len], &prefix);
    @memcpy(argv_buf[prefix.len..][0..args.len], args);
    const argv = argv_buf[0 .. args.len + prefix.len];

    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = if (stdin != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;
    // Eigene Prozessgruppe, damit killRunning git samt Kindern beenden kann
    if (builtin.os.tag != .windows) child.pgid = 0;
    child.spawn() catch |err| return .{ .failed = alloc.dupe(u8, @errorName(err)) catch no_message };
    registerRunning(child.id);
    if (stdin) |text| {
        if (child.stdin) |f| {
            f.writeAll(text) catch |err| log.warn("git stdin: {}", .{err});
            f.close();
            child.stdin = null;
        }
    }
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(alloc);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(alloc);
    const collected = child.collectOutput(alloc, &stdout, &stderr, 10 * 1024 * 1024);
    unregisterRunning(child.id);
    collected catch |err| {
        _ = child.kill() catch {};
        return .{ .failed = alloc.dupe(u8, @errorName(err)) catch no_message };
    };
    const term = child.wait() catch |err| return .{ .failed = alloc.dupe(u8, @errorName(err)) catch no_message };

    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (ok) return .{ .ok = stdout.toOwnedSlice(alloc) catch no_message };
    // Manche git-Fehler stehen auf stdout (z. B. „nothing to commit“): beides zusammen zeigen
    const msg = if (stderr.items.len > 0) stderr.items else stdout.items;
    return .{ .failed = alloc.dupe(u8, std.mem.trim(u8, msg, " \t\r\n")) catch no_message };
}

/// Liegt `path` in einem Git-Repository? Sucht `.git` aufwärts bis zur Wurzel.
/// `.git` kann Ordner (normales Repo) oder Datei (Worktree, Submodul) sein.
///
/// Ohne diese Prüfung reihte jeder Ordnerwechsel git-Tasks ein, die in Ordnern
/// wie `~/projects` nur mit Exit 128 zurückkamen.
pub fn isInsideRepo(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return repoTopLevel(path, &buf) != null;
}

/// Wurzel des Repos, in dem `path` liegt (Ordner mit `.git`), in `buf`; null ohne Repo.
pub fn repoTopLevel(path: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var dir: []const u8 = std.fs.cwd().realpath(path, buf) catch return null;

    while (true) {
        var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrint(&candidate_buf, "{s}/.git", .{dir}) catch return null;
        // access statt statFile: `.git` ist ein Ordner (statFile scheitert daran
        // unter Windows) oder bei Worktrees/Submodulen eine Datei — beides zählt.
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return dir;
        } else |_| {}

        // An der Laufwerks- bzw. Freigabewurzel aufhören: dirname steigt unter UNC von
        // `\\server\share` weiter zu `\\server` und `\`, access darauf endet in
        // `error.Unexpected` samt Stacktrace (NTSTATUS 0xc00000cc, 0xc0000039).
        const root = std.fs.path.diskDesignator(dir);
        if (std.mem.trimRight(u8, dir, "/\\").len <= root.len) return null;

        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
}

/// Gleicher Pfad trotz `/` gegen `\` und (unter Windows) Groß/Klein: die Repo-Wurzel kommt
/// von git, der Projektordner vom Dateisystem.
pub fn samePath(a: []const u8, b: []const u8) bool {
    const ta = std.mem.trimRight(u8, a, "/\\");
    const tb = std.mem.trimRight(u8, b, "/\\");
    if (ta.len != tb.len) return false;
    for (ta, tb) |x, y| {
        const nx: u8 = if (x == '\\') '/' else x;
        const ny: u8 = if (y == '\\') '/' else y;
        if (nx == ny) continue;
        if (builtin.os.tag == .windows and std.ascii.toLower(nx) == std.ascii.toLower(ny)) continue;
        return false;
    }
    return true;
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

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(samePath(repoTopLevel(sub, &buf).?, cwd));
}

test "samePath: Trenner und Endstrich egal, sonst genau" {
    try std.testing.expect(samePath("C:/x/repo", "C:\\x\\repo\\"));
    try std.testing.expect(!samePath("/x/repo", "/x/repo/sub"));
    try std.testing.expect(!samePath("/x/repo", "/x/rep"));
}

test "unsafeRepoDirectory: Vorschlag aus gits Meldung, wörtlich" {
    // Windows, Repo auf einem Netzlaufwerk (Format der Meldung von git for Windows)
    const win =
        \\fatal: detected dubious ownership in repository at '//10.0.0.1/share/repo'
        \\'//10.0.0.1/share/repo' is owned by:
        \\        (inconvertible) (S-1-5-21-1-2-3-1007)
        \\but the current user is:
        \\        DOMAIN/user (S-1-12-1-4-5-6-7)
        \\To add an exception for this directory, call:
        \\
        \\        git config --global --add safe.directory '%(prefix)///10.0.0.1/share/repo'
    ;
    try std.testing.expectEqualStrings("%(prefix)///10.0.0.1/share/repo", unsafeRepoDirectory(win).?);
    // Linux ohne Anführungszeichen, mit Tab davor und Zeilenende danach
    const linux = "fatal: detected dubious ownership in repository at '/srv/repo'\n" ++
        "To add an exception for this directory, call:\n\n" ++
        "\tgit config --global --add safe.directory /srv/repo\n";
    try std.testing.expectEqualStrings("/srv/repo", unsafeRepoDirectory(linux).?);
    try std.testing.expect(unsafeRepoDirectory("fatal: not a git repository") == null);
    try std.testing.expect(unsafeRepoDirectory("fatal: detected dubious ownership in repository at '/x'") == null);
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

test "frame, unframe, splitKey: Schlüssel vor dem ersten Zeilenumbruch, Hash hinter 0x1f" {
    const alloc = std.testing.allocator;
    const f = try frame(alloc, "git-diff://x\x1fabc", "body\nzwei");
    defer alloc.free(f);
    const u = unframe(f).?;
    try std.testing.expectEqualStrings("git-diff://x\x1fabc", u.key);
    try std.testing.expectEqualStrings("body\nzwei", u.body);
    const k = splitKey(u.key);
    try std.testing.expectEqualStrings("git-diff://x", k.tab_path);
    try std.testing.expectEqualStrings("abc", k.hash);
    try std.testing.expect(unframe("ohne umbruch") == null);
    try std.testing.expectEqualStrings("", splitKey("nur-pfad").hash);
}

test "taskGitFileDiff: alter und neuer Inhalt plus Hunks einer Datei in einem Commit" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    // Commits der Datei über die Timeline (git log --follow), wie die Ansicht selbst
    const file = try std.fs.path.join(alloc, &.{ cwd, "src", "git", "git_scm.zig" });
    defer alloc.free(file);
    const log_result = try taskGitTimeline(alloc, try TextParam.init(alloc, file));
    defer log_result.deinit();
    var t = git_timeline.Timeline.init(alloc);
    defer t.deinit();
    t.setExpanded(true);
    t.follow(file);
    try t.apply(file, true, unframe(log_result.payload).?.body);
    const items = t.items();
    try std.testing.expect(items.len > 1);

    // jüngster Commit: beide Seiten vorhanden
    const c = items[0];
    const tab = try git_diff.tabPath(alloc, .{ .hash = c.hash, .parent = c.previous_ref, .repo = cwd, .path = c.path, .previous_path = c.previous_path });
    defer alloc.free(tab);
    const result = try taskGitFileDiff(alloc, try TextParam.init(alloc, tab));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_file_diff);
    const u = unframe(result.payload).?;
    try std.testing.expectEqualStrings(tab, u.key);
    const contents = git_diff.decodeContents(u.body).?;
    try std.testing.expect(std.mem.indexOf(u8, contents.new, "pub const View") != null);
    const hunks = try git_diff.parseHunks(alloc, contents.hunks);
    defer alloc.free(hunks);
    try std.testing.expect(hunks.len > 0);

    // ältester Commit: Datei neu angelegt, alter Inhalt leer, ein Hunk ab Zeile 0
    const first = items[items.len - 1];
    const tab0 = try git_diff.tabPath(alloc, .{ .hash = first.hash, .parent = first.previous_ref, .repo = cwd, .path = first.path, .previous_path = first.previous_path });
    defer alloc.free(tab0);
    const r0 = try taskGitFileDiff(alloc, try TextParam.init(alloc, tab0));
    defer r0.deinit();
    const c0 = git_diff.decodeContents(unframe(r0.payload).?.body).?;
    try std.testing.expectEqual(@as(usize, 0), c0.old.len);
    const h0 = try git_diff.parseHunks(alloc, c0.hunks);
    defer alloc.free(h0);
    try std.testing.expectEqual(@as(u32, 0), h0[0].old_start);
}

test "taskGitTimeline: Repo-Wurzel und Log der Datei, Schlüssel ist der Dateipfad" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    const file = try std.fs.path.join(alloc, &.{ cwd, "src", "git", "git_worker.zig" });
    defer alloc.free(file);

    const result = try taskGitTimeline(alloc, try TextParam.init(alloc, file));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_timeline);
    const u = unframe(result.payload).?;
    try std.testing.expectEqualStrings(file, u.key);

    var t = git_timeline.Timeline.init(alloc);
    defer t.deinit();
    t.setExpanded(true);
    t.follow(file);
    try t.apply(file, true, u.body);
    try std.testing.expectEqualStrings(cwd, t.repo);
    try std.testing.expect(t.items().len > 1);
    // Ist die Datei gerade gestagt, steht „Staged Changes“ vorn: ersten Commit-Eintrag prüfen
    const first = for (t.items()) |it| {
        if (it.kind == .commit) break it;
    } else unreachable;
    try std.testing.expectEqualStrings("src/git/git_worker.zig", first.path);
    try std.testing.expect(first.timestamp > 1_700_000_000);
    try std.testing.expect(first.stat.files == 1);
}

test "taskGitGraphLog und taskGitCommitChanges: eigenes Repo, Filter Auto, Dateien des jüngsten Commits" {
    const alloc = std.testing.allocator;
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    // Felder: Schlüssel (darf 0x1f enthalten), Repo-Ordner, Seite (skip), Seitengröße
    const result = try taskGitGraphLog(alloc, try FieldsParam.init(alloc, &.{ "graph\x1f0", cwd, "0", "5" }));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_graph_log);
    const u = unframe(result.payload).?;
    try std.testing.expectEqualStrings("graph\x1f0", u.key);

    var view = git_scm.View.init(alloc);
    defer view.deinit();
    _ = view.takeLogRequest();
    try view.applyLog(true, u.body, 5);
    try std.testing.expectEqualStrings(cwd, view.repo);
    try std.testing.expect(view.filter.current.len > 0); // Tests laufen auf einem Branch
    try std.testing.expectEqual(@as(usize, 5), view.commits().len);
    try std.testing.expect(view.has_more);

    const c = view.commits()[0];
    const ch_param = try FieldsParam.init(alloc, &.{ c.hash, cwd, c.hash, c.firstParent() });
    const ch = try taskGitCommitChanges(alloc, ch_param);
    defer ch.deinit();
    try std.testing.expect(ch.tag == .git_commit_changes);
    const cu = unframe(ch.payload).?;
    try std.testing.expectEqualStrings(c.hash, cu.key);
    const changes = try git_scm.parseChanges(alloc, cu.body);
    defer alloc.free(changes);
    try std.testing.expect(changes.len > 0);

    // Graph-Log ohne Statistik; der Hover lädt sie je Commit nach
    try std.testing.expectEqual(git_scm.StatState.unknown, c.stat);
    const st = try taskGitCommitStat(alloc, try FieldsParam.init(alloc, &.{ c.hash, cwd, c.hash, c.firstParent() }));
    defer st.deinit();
    try std.testing.expect(st.tag == .git_commit_stat);
    const su = unframe(st.payload).?;
    view.applyStat(su.key, true, su.body);
    const stat = view.commits()[0].stat.loaded;
    try std.testing.expectEqual(@as(u32, @intCast(changes.len)), stat.files);
}

test "taskGitTimeline: Fehler von git kommt als Text im Ergebnis, nicht als Task-Fehler" {
    const alloc = std.testing.allocator;
    const result = try taskGitTimeline(alloc, try TextParam.init(alloc, "/kein-repo.txt"));
    defer result.deinit();
    try std.testing.expect(result.tag == .git_timeline_error);
    try std.testing.expectEqualStrings("/kein-repo.txt", unframe(result.payload).?.key);
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

/// Fixture-Repo unter tmp: ein Commit mit a.txt (zwei Zeilen). Rückgabe = absoluter Pfad (owned).
fn testRepo(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const path = try tmp.dir.realpathAlloc(alloc, ".");
    errdefer alloc.free(path);
    for ([_][]const []const u8{
        &.{ "init", "-q", "-b", "main" },
        &.{ "config", "user.email", "t@example.com" },
        &.{ "config", "user.name", "Test" },
        // Git for Windows setzt systemweit core.autocrlf=true: checkout und diff lieferten
        // dann "\r\n", und die Vergleiche gegen "\n" scheiterten nur unter Windows.
        &.{ "config", "core.autocrlf", "false" },
    }) |args| alloc.free(try runGit(alloc, path, args));
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "eins\nzwei\n" });
    alloc.free(try runGit(alloc, path, &.{ "add", "a.txt" }));
    alloc.free(try runGit(alloc, path, &.{ "commit", "-q", "-m", "erster" }));
    return path;
}

fn statusRaw(alloc: std.mem.Allocator, repo: []const u8) ![]u8 {
    const r = try taskGitStatus(alloc, try Params.init(alloc, repo, ""));
    defer r.deinit();
    const sep = std.mem.indexOfScalar(u8, r.payload, 0x1c) orelse return error.NoRawStatus;
    return alloc.dupe(u8, r.payload[sep + 1 ..]);
}

test "taskGitStatus: hinter 0x1c die rohe porcelain-v2-Ausgabe für Source Control" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(alloc, &tmp);
    defer alloc.free(repo);
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "eins\nzwei\ndrei\n" });
    const raw = try statusRaw(alloc, repo);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "# branch.head main") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "1 .M ") != null);
    try std.testing.expect(std.mem.endsWith(u8, raw, "a.txt\x00"));
}

test "taskGitAction: stage, unstage, discard, commit im Fixture-Repo; Fehler als Text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(alloc, &tmp);
    defer alloc.free(repo);
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "eins\nzwei\ndrei\n" });
    try tmp.dir.writeFile(.{ .sub_path = "neu.txt", .data = "frei\n" });

    // stage: auch untracked (add -A)
    var r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "stage", repo, "a.txt", "neu.txt" }));
    try std.testing.expect(r.tag == .git_action);
    try std.testing.expectEqualStrings("stage", unframe(r.payload).?.key);
    r.deinit();
    var raw = try statusRaw(alloc, repo);
    try std.testing.expect(std.mem.indexOf(u8, raw, "1 M. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "1 A. ") != null);
    alloc.free(raw);

    // unstage neu.txt: wieder untracked
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "unstage", repo, "neu.txt" }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    raw = try statusRaw(alloc, repo);
    try std.testing.expect(std.mem.indexOf(u8, raw, "? neu.txt") != null);
    alloc.free(raw);

    // discard untracked löscht die Datei, discard tracked stellt den Index-Stand her
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "discard_untracked", repo, "neu.txt" }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("neu.txt", .{}));
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "ganz anders\n" });
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "discard_tracked", repo, "a.txt" }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    const back = try tmp.dir.readFileAlloc(alloc, "a.txt", 1024);
    defer alloc.free(back);
    try std.testing.expectEqualStrings("eins\nzwei\ndrei\n", back);

    // commit: Nachricht über stdin, mehrzeilig
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "commit", repo, "feat: drei\n\nBody mit Umlaut ä" }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    const log_out = try runGit(alloc, repo, &.{ "log", "-1", "--format=%B" });
    defer alloc.free(log_out);
    try std.testing.expectEqualStrings("feat: drei\n\nBody mit Umlaut ä", std.mem.trimRight(u8, log_out, "\n"));
    raw = try statusRaw(alloc, repo);
    try std.testing.expect(std.mem.indexOf(u8, raw, "1 ") == null); // sauber
    alloc.free(raw);

    // commit ohne Änderungen: Fehler als Text, kein Task-Fehler
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "commit", repo, "leer" }));
    try std.testing.expect(r.tag == .git_action_error);
    try std.testing.expectEqualStrings("commit", unframe(r.payload).?.key);
    try std.testing.expect(unframe(r.payload).?.body.len > 0);
    r.deinit();
}

test "taskGitFileDiff: Arbeitskopie gegen Index, Untracked gegen leeren Baum" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(alloc, &tmp);
    defer alloc.free(repo);
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "eins\nzwei\ndrei\n" });
    try tmp.dir.writeFile(.{ .sub_path = "neu.txt", .data = "x\ny\n" });

    const tab = try git_diff.tabPath(alloc, .{ .hash = git_diff.worktree_ref, .parent = git_diff.index_ref, .repo = repo, .path = "a.txt", .previous_path = "a.txt" });
    defer alloc.free(tab);
    const r = try taskGitFileDiff(alloc, try TextParam.init(alloc, tab));
    defer r.deinit();
    try std.testing.expect(r.tag == .git_file_diff);
    const c = git_diff.decodeContents(unframe(r.payload).?.body).?;
    try std.testing.expectEqualStrings("eins\nzwei\n", c.old);
    try std.testing.expectEqualStrings("eins\nzwei\ndrei\n", c.new);
    const hunks = try git_diff.parseHunks(alloc, c.hunks);
    defer alloc.free(hunks);
    try std.testing.expectEqual(@as(usize, 1), hunks.len);
    try std.testing.expectEqual(@as(u32, 1), hunks[0].new_count);

    const tab2 = try git_diff.tabPath(alloc, .{ .hash = git_diff.worktree_ref, .parent = "", .repo = repo, .path = "neu.txt", .previous_path = "neu.txt" });
    defer alloc.free(tab2);
    const r2 = try taskGitFileDiff(alloc, try TextParam.init(alloc, tab2));
    defer r2.deinit();
    try std.testing.expect(r2.tag == .git_file_diff);
    const c2 = git_diff.decodeContents(unframe(r2.payload).?.body).?;
    try std.testing.expectEqualStrings("", c2.old);
    try std.testing.expectEqualStrings("x\ny\n", c2.new);
    const h2 = try git_diff.parseHunks(alloc, c2.hunks);
    defer alloc.free(h2);
    try std.testing.expectEqual(@as(u32, 0), h2[0].old_start);
    try std.testing.expectEqual(@as(u32, 2), h2[0].new_count);
}

test "taskGitAction commit_all: stagt alles und committet (VS Code smartCommit)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(alloc, &tmp);
    defer alloc.free(repo);
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "anders\n" });
    try tmp.dir.writeFile(.{ .sub_path = "neu.txt", .data = "frei\n" });
    const r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "commit_all", repo, "alles" }));
    defer r.deinit();
    try std.testing.expect(r.tag == .git_action);
    try std.testing.expectEqualStrings("commit_all", unframe(r.payload).?.key);
    const raw = try statusRaw(alloc, repo);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "1 ") == null and std.mem.indexOf(u8, raw, "? ") == null);
    const log_out = try runGit(alloc, repo, &.{ "log", "-1", "--format=%s" });
    defer alloc.free(log_out);
    try std.testing.expectEqualStrings("alles", std.mem.trimRight(u8, log_out, "\n"));
}

test "taskGitAction push: Publish mit -u origin, danach Push; ohne Remote Fehler als Text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(alloc, &tmp);
    defer alloc.free(repo);
    // ohne Remote: Fehler von git, kein Task-Fehler
    var r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "push", repo }));
    try std.testing.expect(r.tag == .git_action_error);
    r.deinit();
    // bares Remote daneben, Publish Branch = push -u origin main
    try tmp.dir.makeDir("remote.git");
    const remote = try std.fs.path.join(alloc, &.{ repo, "remote.git" });
    defer alloc.free(remote);
    alloc.free(try runGit(alloc, remote, &.{ "init", "-q", "--bare" }));
    alloc.free(try runGit(alloc, repo, &.{ "remote", "add", "origin", remote }));
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "push", repo, "-u", "origin", "main" }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    const raw = try statusRaw(alloc, repo);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "# branch.upstream origin/main") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "# branch.ab +0 -0") != null);
    // neuer Commit, Push ohne Argumente
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "neu\n" });
    alloc.free(try runGit(alloc, repo, &.{ "commit", "-q", "-am", "zweiter" }));
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "push", repo }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    const remote_log = try runGit(alloc, remote, &.{ "log", "-1", "--format=%s", "main" });
    defer alloc.free(remote_log);
    try std.testing.expectEqualStrings("zweiter", std.mem.trimRight(u8, remote_log, "\n"));
}

test "taskGitAction sync: pull holt fremden Commit, push bringt eigenen hoch; Konflikt bleibt Fehler ohne Push" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(alloc, &tmp);
    defer alloc.free(repo);
    // bares Remote, Publish, dann ein zweiter Klon, der dort voranschreitet
    try tmp.dir.makeDir("remote.git");
    const remote = try std.fs.path.join(alloc, &.{ repo, "remote.git" });
    defer alloc.free(remote);
    // -b main: sonst zeigt HEAD des bare Repos auf master und der Klon hat keinen Branch
    alloc.free(try runGit(alloc, remote, &.{ "init", "-q", "--bare", "-b", "main" }));
    alloc.free(try runGit(alloc, repo, &.{ "remote", "add", "origin", remote }));
    alloc.free(try runGit(alloc, repo, &.{ "config", "pull.rebase", "false" }));
    var r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "push", repo, "-u", "origin", "main" }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    const other = try std.fs.path.join(alloc, &.{ repo, "other" });
    defer alloc.free(other);
    alloc.free(try runGit(alloc, repo, &.{ "clone", "-q", remote, other }));
    for ([_][]const []const u8{
        &.{ "config", "user.email", "o@example.com" },
        &.{ "config", "user.name", "Other" },
    }) |args| alloc.free(try runGit(alloc, other, args));
    try tmp.dir.writeFile(.{ .sub_path = "other/b.txt", .data = "fremd\n" });
    alloc.free(try runGit(alloc, other, &.{ "add", "b.txt" }));
    alloc.free(try runGit(alloc, other, &.{ "commit", "-q", "-m", "fremd" }));
    alloc.free(try runGit(alloc, other, &.{ "push", "-q", "origin", "main" }));
    // eigener Commit daneben: 1 voraus, nach fetch 1 zurück
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = "eigen\n" });
    alloc.free(try runGit(alloc, repo, &.{ "add", "c.txt" }));
    alloc.free(try runGit(alloc, repo, &.{ "commit", "-q", "-m", "eigen" }));
    alloc.free(try runGit(alloc, repo, &.{ "fetch", "-q" }));
    const before = try statusRaw(alloc, repo);
    defer alloc.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "# branch.ab +1 -1") != null);
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "sync", repo }));
    try std.testing.expect(r.tag == .git_action);
    r.deinit();
    const after = try statusRaw(alloc, repo);
    defer alloc.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "# branch.ab +0 -0") != null);
    try std.testing.expect(tmp.dir.access("b.txt", .{}) != error.FileNotFound); // fremder Commit da
    const remote_log = try runGit(alloc, remote, &.{ "log", "--format=%s", "main" });
    defer alloc.free(remote_log);
    try std.testing.expect(std.mem.indexOf(u8, remote_log, "eigen") != null); // eigener oben
    // Konflikt: beide ändern a.txt → pull scheitert, Remote bleibt ohne den eigenen Commit
    alloc.free(try runGit(alloc, other, &.{ "pull", "-q" })); // fast-forward auf „eigen“
    try tmp.dir.writeFile(.{ .sub_path = "other/a.txt", .data = "andere\n" });
    alloc.free(try runGit(alloc, other, &.{ "commit", "-q", "-am", "konflikt fremd" }));
    alloc.free(try runGit(alloc, other, &.{ "push", "-q", "origin", "main" }));
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "meine\n" });
    alloc.free(try runGit(alloc, repo, &.{ "commit", "-q", "-am", "konflikt eigen" }));
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "sync", repo }));
    try std.testing.expect(r.tag == .git_action_error);
    try std.testing.expect(std.mem.startsWith(u8, r.payload, "sync\n"));
    r.deinit();
    const remote_log2 = try runGit(alloc, remote, &.{ "log", "--format=%s", "main" });
    defer alloc.free(remote_log2);
    try std.testing.expect(std.mem.indexOf(u8, remote_log2, "konflikt eigen") == null);
    alloc.free(try runGit(alloc, repo, &.{ "merge", "--abort" }));
}

test "taskGitAction commit_diff: gestagter Diff, sonst Arbeitskopie mit untracked Dateien" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(alloc, &tmp);
    defer alloc.free(repo);
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "eins\nzwei\ndrei\n" });
    try tmp.dir.writeFile(.{ .sub_path = "neu.txt", .data = "frei\n" });
    // nichts gestagt: Diff der Arbeitskopie plus Liste der untracked Dateien
    var r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "commit_diff", repo }));
    var body = unframe(r.payload).?.body;
    try std.testing.expect(std.mem.indexOf(u8, body, "+drei") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Untracked files:\nneu.txt") != null);
    r.deinit();
    // a.txt gestagt: nur der gestagte Diff
    alloc.free(try runGit(alloc, repo, &.{ "add", "a.txt" }));
    r = try taskGitAction(alloc, try FieldsParam.init(alloc, &.{ "commit_diff", repo }));
    body = unframe(r.payload).?.body;
    try std.testing.expect(std.mem.indexOf(u8, body, "+drei") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "neu.txt") == null);
    r.deinit();
}
