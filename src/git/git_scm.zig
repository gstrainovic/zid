//! Source Control Graph (Daten, ohne Clay): Log mit Referenzen, Filter „Auto“ mit Farben,
//! geänderte Dateien eines Commits, Zeilen der Ansicht (Commits, aufgeklappte Dateien,
//! „Load More“) und der Multi-File-Diff eines Commits.
//! Quellen: vscode extensions/git/src/historyProvider.ts (`_resolveHistoryItemRefs`),
//! git.ts (`log`), src/vs/workbench/contrib/scm/browser/scmHistoryViewPane.ts.

const std = @import("std");
const git_graph = @import("git_graph");
const git_diff = @import("git_diff");

const testing = std.testing;

pub const RefKind = enum { head, branch, remote, tag };

pub const Ref = struct {
    id: []const u8,
    name: []const u8,
    kind: RefKind,
};

/// `%D` mit `--decorate=full` zerlegen (VS Code `_resolveHistoryItemRefs`).
pub fn parseRefs(buf: []Ref, decoration: []const u8) []Ref {
    var n: usize = 0;
    var parts = std.mem.splitSequence(u8, decoration, ", ");
    while (parts.next()) |raw| {
        const ref = std.mem.trim(u8, raw, " \r\n");
        if (ref.len == 0 or std.mem.eql(u8, ref, "refs/remotes/origin/HEAD")) continue;
        if (n == buf.len) break;
        const r: ?Ref = if (std.mem.startsWith(u8, ref, "HEAD -> refs/heads/"))
            .{ .id = ref["HEAD -> ".len..], .name = ref["HEAD -> refs/heads/".len..], .kind = .head }
        else if (std.mem.startsWith(u8, ref, "refs/heads/"))
            .{ .id = ref, .name = ref["refs/heads/".len..], .kind = .branch }
        else if (std.mem.startsWith(u8, ref, "refs/remotes/"))
            .{ .id = ref, .name = ref["refs/remotes/".len..], .kind = .remote }
        else if (std.mem.startsWith(u8, ref, "tag: refs/tags/"))
            .{ .id = ref["tag: ".len..], .name = ref["tag: refs/tags/".len..], .kind = .tag }
        else
            null;
        if (r) |x| {
            buf[n] = x;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Graph-Filter „Auto“: aktueller Branch, sein Upstream und die Basis, jeweils mit Farbe
/// (scmGraph.historyItemRefColor / historyItemRemoteRefColor / historyItemBaseRefColor).
pub const AutoFilter = struct {
    current: []const u8 = "",
    upstream: []const u8 = "",
    base: []const u8 = "",

    pub fn colorOf(self: AutoFilter, id: []const u8) ?git_graph.Color {
        if (self.current.len > 0 and std.mem.eql(u8, id, self.current)) return .ref_current;
        if (self.upstream.len > 0 and std.mem.eql(u8, id, self.upstream)) return .ref_remote;
        if (self.base.len > 0 and std.mem.eql(u8, id, self.base)) return .ref_base;
        return null;
    }

    /// Refs für `git log` ohne Doppelte; ohne Branch (losgelöster HEAD) „HEAD“.
    pub fn refNames(self: AutoFilter, buf: *[4][]const u8) []const []const u8 {
        var n: usize = 0;
        buf[n] = if (self.current.len > 0) self.current else "HEAD";
        n += 1;
        if (self.upstream.len > 0 and !std.mem.eql(u8, self.upstream, self.current)) {
            buf[n] = self.upstream;
            n += 1;
        }
        if (self.base.len > 0 and !std.mem.eql(u8, self.base, self.upstream) and !std.mem.eql(u8, self.base, self.current)) {
            buf[n] = self.base;
            n += 1;
        }
        return buf[0..n];
    }
};

/// VS Code `scm.graph.pageSize`
pub const page_size: usize = 50;

const log_format = "--format=%x1e%H%x1f%aN%x1f%aE%x1f%at%x1f%P%x1f%D%x1f%B%x1d";

/// Wie VS Code `Repository.log` mit `refNames` und `shortStats`.
pub fn logArgs(buf: *[24][]const u8, num_buf: []u8, refs: []const []const u8, skip: usize, limit: usize) []const []const u8 {
    const n_arg = std.fmt.bufPrint(num_buf, "-n{d}", .{limit}) catch "-n50";
    const skip_arg = std.fmt.bufPrint(num_buf[n_arg.len..], "--skip={d}", .{skip}) catch "--skip=0";
    var n: usize = 0;
    for ([_][]const u8{ "log", "--no-color", log_format, "--topo-order", "--decorate=full", "--shortstat", "--diff-merges=first-parent", n_arg, skip_arg }) |a| {
        buf[n] = a;
        n += 1;
    }
    for (refs) |r| {
        buf[n] = r;
        n += 1;
    }
    buf[n] = "--";
    return buf[0 .. n + 1];
}

pub const Stat = struct { files: u32 = 0, insertions: u32 = 0, deletions: u32 = 0 };

pub const Commit = struct {
    hash: []const u8,
    author: []const u8,
    email: []const u8,
    /// Autorendatum in Sekunden (VS Code `timestamp: commit.authorDate`)
    timestamp: i64,
    parents: []const []const u8,
    refs: []const Ref,
    subject: []const u8,
    message: []const u8,
    stat: Stat,
    label_color: ?git_graph.Color = null,

    pub fn firstParent(self: Commit) []const u8 {
        return if (self.parents.len > 0) self.parents[0] else "";
    }
};

pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    commits: []Commit,

    pub fn deinit(self: *Log) void {
        self.arena.deinit();
    }
};

pub fn parseLog(alloc: std.mem.Allocator, out: []const u8) !Log {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const commits = try parseLogInto(arena.allocator(), out);
    return .{ .arena = arena, .commits = commits };
}

fn parseLogInto(a: std.mem.Allocator, out: []const u8) ![]Commit {
    const text = try a.dupe(u8, out);
    var list: std.ArrayListUnmanaged(Commit) = .empty;
    var records = std.mem.splitScalar(u8, text, 0x1e);
    _ = records.next();
    while (records.next()) |record| {
        const end = std.mem.indexOfScalar(u8, record, 0x1d) orelse continue;
        var fields = std.mem.splitScalar(u8, record[0..end], 0x1f);
        var f: [7][]const u8 = undefined;
        var n: usize = 0;
        while (n < 6) : (n += 1) f[n] = fields.next() orelse break;
        if (n < 6) continue;
        f[6] = fields.rest();

        var parents: std.ArrayListUnmanaged([]const u8) = .empty;
        var pit = std.mem.tokenizeScalar(u8, f[4], ' ');
        while (pit.next()) |ph| try parents.append(a, ph);
        var ref_buf: [64]Ref = undefined;
        const refs = try a.dupe(Ref, parseRefs(&ref_buf, f[5]));
        const message = std.mem.trimRight(u8, f[6], " \t\r\n");

        var stat = Stat{};
        var lines = std.mem.splitScalar(u8, record[end + 1 ..], '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, " changed") == null) continue;
            var parts = std.mem.splitSequence(u8, std.mem.trim(u8, line, " \r"), ", ");
            while (parts.next()) |part| {
                const space = std.mem.indexOfScalar(u8, part, ' ') orelse continue;
                const value = std.fmt.parseInt(u32, part[0..space], 10) catch continue;
                const word = part[space + 1 ..];
                if (std.mem.startsWith(u8, word, "file")) stat.files = value;
                if (std.mem.startsWith(u8, word, "insertion")) stat.insertions = value;
                if (std.mem.startsWith(u8, word, "deletion")) stat.deletions = value;
            }
        }
        try list.append(a, .{
            .hash = f[0],
            .author = f[1],
            .email = f[2],
            .timestamp = std.fmt.parseInt(i64, f[3], 10) catch 0,
            .parents = try parents.toOwnedSlice(a),
            .refs = refs,
            .subject = message[0 .. std.mem.indexOfScalar(u8, message, '\n') orelse message.len],
            .message = message,
            .stat = stat,
        });
    }
    return list.toOwnedSlice(a);
}

pub const ChangeStatus = enum {
    modified,
    added,
    deleted,
    renamed,
    copied,

    /// Buchstabe der Dateidekoration (VS Code Git: M, A, D, R, C)
    pub fn letter(self: ChangeStatus) u8 {
        return switch (self) {
            .modified => 'M',
            .added => 'A',
            .deleted => 'D',
            .renamed => 'R',
            .copied => 'C',
        };
    }
};

pub const Change = struct {
    status: ChangeStatus,
    path: []const u8,
    old_path: []const u8,
};

/// `git diff --name-status -M` bzw. `git show --name-status`; Slices zeigen in `out`.
pub fn parseChanges(alloc: std.mem.Allocator, out: []const u8) ![]Change {
    var list: std.ArrayListUnmanaged(Change) = .empty;
    errdefer list.deinit(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        var cols = std.mem.splitScalar(u8, line, '\t');
        const code = cols.next() orelse continue;
        if (code.len == 0) continue;
        const first = cols.next() orelse continue;
        const status: ChangeStatus = switch (code[0]) {
            'A' => .added,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            else => .modified,
        };
        if (status == .renamed or status == .copied) {
            const second = cols.next() orelse continue;
            try list.append(alloc, .{ .status = status, .path = second, .old_path = first });
        } else {
            try list.append(alloc, .{ .status = status, .path = first, .old_path = first });
        }
    }
    return list.toOwnedSlice(alloc);
}

/// Geänderte Dateien gegen den ersten Elternteil; beim Wurzel-Commit über `git show`.
pub fn changesArgs(buf: *[16][]const u8, hash: []const u8, parent: []const u8) []const []const u8 {
    const args: []const []const u8 = if (parent.len > 0)
        &.{ "diff", "--no-color", "--name-status", "-M", parent, hash }
    else
        &.{ "show", "--no-color", "--name-status", "-M", "--format=", hash };
    @memcpy(buf[0..args.len], args);
    return buf[0..args.len];
}

/// Tab-Titel des Multi-File-Diffs wie VS Code `git.viewCommit`: `kurz - betreff` (owned).
pub fn commitTitle(alloc: std.mem.Allocator, hash: []const u8, subject: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s} - {s}", .{ hash[0..@min(hash.len, 7)], subject });
}

pub const commit_scheme = "git-commit://";

pub const CommitSpec = struct {
    hash: []const u8,
    parent: []const u8,
    repo: []const u8,
    subject: []const u8,
};

pub fn commitTabPath(alloc: std.mem.Allocator, s: CommitSpec) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ commit_scheme, s.hash, "\x1f", s.parent, "\x1f", s.repo, "\x1f", s.subject });
}

pub fn parseCommitTabPath(path: []const u8) ?CommitSpec {
    if (!std.mem.startsWith(u8, path, commit_scheme)) return null;
    var it = std.mem.splitScalar(u8, path[commit_scheme.len..], 0x1f);
    const hash = it.next() orelse return null;
    const parent = it.next() orelse return null;
    const repo = it.next() orelse return null;
    const subject = it.rest();
    return .{ .hash = hash, .parent = parent, .repo = repo, .subject = subject };
}

pub const RowKind = enum { commit, change, load_more };

pub const ViewRow = struct {
    kind: RowKind,
    commit: usize = 0,
    change: usize = 0,
};

const Expansion = struct {
    expanded: bool = true,
    loading: bool = false,
    changes: ?[]Change = null,
    /// Ausgabe von git, in die `changes` zeigt (owned)
    text: []u8 = &.{},
};

/// Zustand des Graphen: geladene Seiten, Graph-Bahnen, aufgeklappte Commits, Zeilen.
pub const View = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    repo: []const u8 = "",
    branch: []const u8 = "",
    filter: AutoFilter = .{},
    list: std.ArrayListUnmanaged(Commit) = .empty,
    graph: ?git_graph.Graph = null,
    expansions: std.StringHashMapUnmanaged(Expansion) = .empty,
    rows: std.ArrayListUnmanaged(ViewRow) = .empty,
    /// nächste anzufordernde Seite (Anzahl zu überspringender Commits)
    want_log: ?usize = 0,
    loading: bool = false,
    has_more: bool = false,
    error_text: ?[]u8 = null,
    want_changes: std.ArrayListUnmanaged([]const u8) = .empty,
    selected: ?usize = null,
    scroll: f32 = 0,

    pub fn init(alloc: std.mem.Allocator) View {
        return .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *View) void {
        self.reset();
        self.arena.deinit();
    }

    fn reset(self: *View) void {
        var it = self.expansions.valueIterator();
        while (it.next()) |e| {
            if (e.changes) |c| self.alloc.free(c);
            self.alloc.free(e.text);
        }
        self.expansions.deinit(self.alloc);
        self.expansions = .empty;
        if (self.graph) |*g| g.deinit();
        self.graph = null;
        self.list.deinit(self.alloc);
        self.list = .empty;
        self.rows.deinit(self.alloc);
        self.rows = .empty;
        self.want_changes.deinit(self.alloc);
        self.want_changes = .empty;
        if (self.error_text) |e| self.alloc.free(e);
        self.error_text = null;
        _ = self.arena.reset(.retain_capacity);
        self.repo = "";
        self.branch = "";
        self.filter = .{};
        self.has_more = false;
        self.selected = null;
    }

    pub fn commits(self: *const View) []const Commit {
        return self.list.items;
    }

    /// Alles neu laden (Refresh).
    pub fn refresh(self: *View) void {
        self.reset();
        self.scroll = 0;
        self.want_log = 0;
    }

    /// Nächste Log-Seite: Anzahl zu überspringender Commits, genau einmal.
    pub fn takeLogRequest(self: *View) ?usize {
        const skip = self.want_log orelse return null;
        self.want_log = null;
        self.loading = true;
        return skip;
    }

    /// Kopfzeile `<branch>\x1f<ref>\x1f<upstream>\x1f<basis>\x1f<repo>` und das Log einer Seite.
    pub fn applyLog(self: *View, ok: bool, body: []const u8, requested: usize) !void {
        self.loading = false;
        if (!ok) {
            if (self.error_text) |e| self.alloc.free(e);
            self.error_text = try self.alloc.dupe(u8, body);
            return;
        }
        const a = self.arena.allocator();
        const nl = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
        if (self.list.items.len == 0) {
            var head = std.mem.splitScalar(u8, try a.dupe(u8, body[0..nl]), 0x1f);
            self.branch = head.next() orelse "";
            self.filter = .{ .current = head.next() orelse "", .upstream = head.next() orelse "", .base = head.next() orelse "" };
            self.repo = head.next() orelse "";
        }
        const page = try parseLogInto(a, body[@min(body.len, nl + 1)..]);
        for (page) |*c| {
            for (c.refs) |r| if (self.filter.colorOf(r.id)) |col| {
                c.label_color = col;
                break;
            };
        }
        try self.list.appendSlice(self.alloc, page);
        self.has_more = page.len >= requested;
        try self.rebuildGraph();
        try self.rebuildRows();
    }

    fn rebuildGraph(self: *View) !void {
        if (self.graph) |*g| g.deinit();
        self.graph = null;
        const nodes = try self.alloc.alloc(git_graph.Commit, self.list.items.len);
        defer self.alloc.free(nodes);
        var head: ?[]const u8 = null;
        for (self.list.items, nodes) |c, *n| {
            n.* = .{ .id = c.hash, .parents = c.parents, .label_color = c.label_color };
            for (c.refs) |r| if (self.filter.current.len > 0 and std.mem.eql(u8, r.id, self.filter.current)) {
                head = c.hash;
            };
        }
        self.graph = try git_graph.build(self.alloc, nodes, head);
    }

    fn rebuildRows(self: *View) !void {
        self.rows.clearRetainingCapacity();
        for (self.list.items, 0..) |c, i| {
            try self.rows.append(self.alloc, .{ .kind = .commit, .commit = i });
            const e = self.expansions.get(c.hash) orelse continue;
            if (!e.expanded) continue;
            if (e.changes) |changes| for (0..changes.len) |k| {
                try self.rows.append(self.alloc, .{ .kind = .change, .commit = i, .change = k });
            };
        }
        if (self.has_more) try self.rows.append(self.alloc, .{ .kind = .load_more });
    }

    pub fn toggleExpanded(self: *View, commit_index: usize) void {
        if (commit_index >= self.list.items.len) return;
        const hash = self.list.items[commit_index].hash;
        const gop = self.expansions.getOrPut(self.alloc, hash) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .loading = true };
            self.want_changes.append(self.alloc, hash) catch {};
        } else {
            gop.value_ptr.expanded = !gop.value_ptr.expanded;
        }
        self.rebuildRows() catch {};
    }

    pub fn isExpanded(self: *const View, commit_index: usize) bool {
        const e = self.expansions.get(self.list.items[commit_index].hash) orelse return false;
        return e.expanded;
    }

    pub fn takeChangesRequest(self: *View) ?[]const u8 {
        return self.want_changes.pop();
    }

    pub fn applyChanges(self: *View, hash: []const u8, ok: bool, out: []const u8) !void {
        const e = self.expansions.getPtr(hash) orelse return;
        e.loading = false;
        if (!ok) return;
        if (e.changes) |c| self.alloc.free(c);
        self.alloc.free(e.text);
        e.text = try self.alloc.dupe(u8, out);
        e.changes = try parseChanges(self.alloc, e.text);
        try self.rebuildRows();
    }

    pub fn changeOf(self: *const View, row: ViewRow) ?Change {
        if (row.kind != .change) return null;
        const e = self.expansions.get(self.list.items[row.commit].hash) orelse return null;
        const changes = e.changes orelse return null;
        return if (row.change < changes.len) changes[row.change] else null;
    }

    pub fn changesOf(self: *const View, hash: []const u8) ?[]const Change {
        const e = self.expansions.get(hash) orelse return null;
        return e.changes;
    }

    /// Datei-Zeile → Diff-Editor gegen den ersten Elternteil.
    pub fn diffSpec(self: *const View, row: ViewRow) ?git_diff.Spec {
        const change = self.changeOf(row) orelse return null;
        const c = self.list.items[row.commit];
        return .{ .hash = c.hash, .parent = c.firstParent(), .repo = self.repo, .path = change.path, .previous_path = change.old_path };
    }

    pub fn commitSpec(self: *const View, commit_index: usize) ?CommitSpec {
        if (commit_index >= self.list.items.len) return null;
        const c = self.list.items[commit_index];
        return .{ .hash = c.hash, .parent = c.firstParent(), .repo = self.repo, .subject = c.subject };
    }

    /// „Load More“: nächste Seite anfordern; Rückgabe = zu überspringende Commits.
    pub fn loadMore(self: *View) ?usize {
        if (!self.has_more or self.loading or self.want_log != null) return null;
        self.want_log = self.list.items.len;
        return self.want_log;
    }
};

test "parseRefs: HEAD, Branch, Remote, Tag wie _resolveHistoryItemRefs, origin/HEAD fällt weg" {
    var buf: [8]Ref = undefined;
    const refs = parseRefs(&buf, "HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1.0, refs/heads/dev");
    try testing.expectEqual(@as(usize, 4), refs.len);
    try testing.expectEqualStrings("refs/heads/main", refs[0].id);
    try testing.expectEqualStrings("main", refs[0].name);
    try testing.expectEqual(RefKind.head, refs[0].kind);
    try testing.expectEqualStrings("origin/main", refs[1].name);
    try testing.expectEqual(RefKind.remote, refs[1].kind);
    try testing.expectEqualStrings("refs/tags/v1.0", refs[2].id);
    try testing.expectEqual(RefKind.tag, refs[2].kind);
    try testing.expectEqual(RefKind.branch, refs[3].kind);
    try testing.expectEqual(@as(usize, 0), parseRefs(&buf, "").len);
}

test "Filter Auto: Branch blau, Upstream lila, Basis orange; Basis gleich Upstream zählt einmal" {
    const f = AutoFilter{ .current = "refs/heads/feature", .upstream = "refs/remotes/origin/feature", .base = "refs/remotes/origin/main" };
    try testing.expectEqual(@as(?git_graph.Color, .ref_current), f.colorOf("refs/heads/feature"));
    try testing.expectEqual(@as(?git_graph.Color, .ref_remote), f.colorOf("refs/remotes/origin/feature"));
    try testing.expectEqual(@as(?git_graph.Color, .ref_base), f.colorOf("refs/remotes/origin/main"));
    try testing.expectEqual(@as(?git_graph.Color, null), f.colorOf("refs/heads/dev"));
    var buf: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), f.refNames(&buf).len);
    const same = AutoFilter{ .current = "refs/heads/main", .upstream = "refs/remotes/origin/main", .base = "refs/remotes/origin/main" };
    try testing.expectEqual(@as(usize, 2), same.refNames(&buf).len);
    try testing.expectEqual(@as(?git_graph.Color, .ref_remote), same.colorOf("refs/remotes/origin/main"));
}

test "logArgs: Format, --topo-order, --decorate=full, Statistik, Seite, Refs am Ende" {
    var buf: [24][]const u8 = undefined;
    var num: [32]u8 = undefined;
    const refs = [_][]const u8{ "refs/heads/main", "refs/remotes/origin/main" };
    const args = logArgs(&buf, &num, &refs, 50, 50);
    try testing.expectEqualStrings("log", args[0]);
    for ([_][]const u8{ "--topo-order", "--decorate=full", "--shortstat", "--diff-merges=first-parent", "-n50", "--" }) |a| try testing.expect(contains(args, a));
    try testing.expect(contains(args, "--skip=50"));
    try testing.expectEqualStrings("refs/remotes/origin/main", args[args.len - 2]);
    try testing.expectEqualStrings("--", args[args.len - 1]);
}

const sample =
    "\x1eaaaa\x1fAda\x1fada@x.org\x1f2000\x1fbbbb\x1fHEAD -> refs/heads/main, refs/remotes/origin/main\x1fzweiter\n\nText\n\x1d\n" ++
    " 2 files changed, 3 insertions(+), 1 deletion(-)\n" ++
    "\x1ebbbb\x1fBob\x1fbob@x.org\x1f1000\x1f\x1f\x1ferster\n\x1d\n" ++
    " 1 file changed, 5 insertions(+)\n";

test "parseLog: Commit-Felder, Eltern, Referenzen, Betreff, Statistik" {
    var log = try parseLog(testing.allocator, sample);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 2), log.commits.len);
    const a = log.commits[0];
    try testing.expectEqualStrings("aaaa", a.hash);
    try testing.expectEqualStrings("Ada", a.author);
    try testing.expectEqual(@as(i64, 2000), a.timestamp);
    try testing.expectEqual(@as(usize, 1), a.parents.len);
    try testing.expectEqualStrings("bbbb", a.parents[0]);
    try testing.expectEqual(@as(usize, 2), a.refs.len);
    try testing.expectEqualStrings("zweiter", a.subject);
    try testing.expectEqualStrings("zweiter\n\nText", a.message);
    try testing.expectEqual(@as(u32, 2), a.stat.files);
    try testing.expectEqual(@as(u32, 1), a.stat.deletions);
    try testing.expectEqual(@as(usize, 0), log.commits[1].parents.len);
    try testing.expectEqual(@as(u32, 5), log.commits[1].stat.insertions);
}

test "parseChanges: name-status mit Umbenennung, Status wie VS Code Dekoration" {
    const out = "M\tsrc/a.zig\nA\tneu.txt\nD\talt.txt\nR087\tlib.zig\tapp.zig\n";
    const changes = try parseChanges(testing.allocator, out);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 4), changes.len);
    try testing.expectEqual(ChangeStatus.modified, changes[0].status);
    try testing.expectEqualStrings("src/a.zig", changes[0].path);
    try testing.expectEqualStrings("src/a.zig", changes[0].old_path);
    try testing.expectEqual(ChangeStatus.renamed, changes[3].status);
    try testing.expectEqualStrings("app.zig", changes[3].path);
    try testing.expectEqualStrings("lib.zig", changes[3].old_path);
    try testing.expectEqual(@as(u8, 'R'), changes[3].status.letter());
    try testing.expectEqual(@as(u8, 'M'), changes[0].status.letter());
}

test "changesArgs: gegen den ersten Elternteil, Wurzel über git show" {
    var buf: [16][]const u8 = undefined;
    const d = changesArgs(&buf, "aaaa", "bbbb");
    try testing.expectEqualStrings("diff", d[0]);
    try testing.expect(contains(d, "--name-status") and contains(d, "-M"));
    try testing.expectEqualStrings("aaaa", d[d.len - 1]);
    const root = changesArgs(&buf, "aaaa", "");
    try testing.expectEqualStrings("show", root[0]);
    try testing.expect(contains(root, "--format="));
}

test "View: Zeilen aus Commits, aufgeklappte Dateien, Load More am Ende" {
    var v = View.init(testing.allocator);
    defer v.deinit();
    try testing.expect(v.takeLogRequest() != null);
    try v.applyLog(true, "main\x1frefs/heads/main\x1frefs/remotes/origin/main\x1f\x1f/r\n" ++ sample, 2);
    try testing.expectEqualStrings("/r", v.repo);
    try testing.expectEqual(@as(usize, 3), v.rows.items.len); // 2 Commits + Load More (Seite voll)
    try testing.expectEqual(RowKind.load_more, v.rows.items[2].kind);
    try testing.expectEqual(git_graph.Kind.head, v.graph.?.rows[0].kind);
    try testing.expectEqual(@as(?git_graph.Color, .ref_current), v.commits()[0].label_color);

    // Aufklappen fordert die Dateien an, Antwort fügt Zeilen ein
    v.toggleExpanded(0);
    try testing.expectEqualStrings("aaaa", v.takeChangesRequest().?);
    try v.applyChanges("aaaa", true, "M\tsrc/a.zig\nA\tb.txt\n");
    try testing.expectEqual(@as(usize, 5), v.rows.items.len);
    try testing.expectEqual(RowKind.change, v.rows.items[1].kind);
    try testing.expectEqualStrings("src/a.zig", v.changeOf(v.rows.items[1]).?.path);
    try testing.expectEqual(RowKind.commit, v.rows.items[3].kind);

    // Datei → Diff-Spec gegen den ersten Elternteil
    const spec = v.diffSpec(v.rows.items[2]).?;
    try testing.expectEqualStrings("aaaa", spec.hash);
    try testing.expectEqualStrings("bbbb", spec.parent);
    try testing.expectEqualStrings("b.txt", spec.path);

    v.toggleExpanded(0);
    try testing.expectEqual(@as(usize, 3), v.rows.items.len);
    try testing.expect(v.takeChangesRequest() == null); // schon geladen

    // Load More hängt die nächste Seite an
    try testing.expectEqual(@as(?usize, 2), v.loadMore());
    try testing.expectEqual(@as(usize, 2), v.takeLogRequest().?);
}

test "commitTitle wie VS Code viewCommit: Kurz-Hash - Betreff" {
    const t = try commitTitle(testing.allocator, "3bd7496b18f7", "a nach b");
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("3bd7496 - a nach b", t);
}

test "Commit-Tab-Pfad: Commit, Eltern, Repo, Betreff hin und zurück" {
    const spec = CommitSpec{ .hash = "aaaa", .parent = "bbbb", .repo = "/r", .subject = "zweiter" };
    const path = try commitTabPath(testing.allocator, spec);
    defer testing.allocator.free(path);
    const back = parseCommitTabPath(path).?;
    try testing.expectEqualStrings("aaaa", back.hash);
    try testing.expectEqualStrings("bbbb", back.parent);
    try testing.expectEqualStrings("/r", back.repo);
    try testing.expectEqualStrings("zweiter", back.subject);
    try testing.expect(parseCommitTabPath("git-diff://x") == null);
}

fn contains(args: []const []const u8, arg: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, arg)) return true;
    return false;
}
