//! Source Control „Changes“ ohne Clay: `git status --porcelain=v2 -z` in die Gruppen Merge
//! Changes / Staged Changes / Changes wie VS Codes Git-Erweiterung (`repository.ts`), Buchstabe,
//! Farbe, Hover-Text und Durchstreichen je Status, Diff-Spec je Zeile, Auswahl und Tastatur.

const std = @import("std");
const git_diff = @import("git_diff");
const testing = std.testing;

/// Status einer Datei wie VS Code `Status` in `extensions/git/src/api/git.d.ts`.
pub const Kind = enum {
    index_modified,
    index_added,
    index_deleted,
    index_renamed,
    index_copied,
    index_type_changed,
    modified,
    deleted,
    type_changed,
    untracked,
    ignored,
    intent_to_add,
    added_by_us,
    added_by_them,
    deleted_by_us,
    deleted_by_them,
    both_added,
    both_deleted,
    both_modified,
};

pub const Group = enum { merge, staged, changes };

pub const Entry = struct {
    kind: Kind,
    /// relativ zur Repo-Wurzel
    path: []const u8,
    /// bei Umbenennung/Kopie der alte Pfad, sonst leer
    old_path: []const u8 = "",
};

/// `git status --porcelain=v2 --branch -z` in Gruppen; alle Strings liegen in der Arena.
pub const Status = struct {
    arena: std.heap.ArenaAllocator,
    branch: []const u8 = "",
    /// `# branch.upstream`, leer ohne Upstream (Publish Branch)
    upstream: []const u8 = "",
    /// `# branch.ab +ahead -behind`
    ahead: u32 = 0,
    behind: u32 = 0,
    merge: []Entry = &.{},
    staged: []Entry = &.{},
    changes: []Entry = &.{},

    pub fn deinit(self: *Status) void {
        self.arena.deinit();
    }

    pub fn entries(self: *const Status, g: Group) []Entry {
        return switch (g) {
            .merge => self.merge,
            .staged => self.staged,
            .changes => self.changes,
        };
    }
};

/// Zeilen der v2-Ausgabe: `1 XY …`, `2 XY … path\0orig`, `u XY …`, `? path`, `! path`,
/// `# branch.head name`. Zuordnung XY → Gruppe wie `repository.ts`/`git.ts` (untracked in
/// Changes = Einstellung `git.untrackedChanges: mixed`).
pub fn parseStatus(alloc: std.mem.Allocator, raw: []const u8) !Status {
    var s = Status{ .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    var merge: std.ArrayListUnmanaged(Entry) = .empty;
    var staged: std.ArrayListUnmanaged(Entry) = .empty;
    var changes: std.ArrayListUnmanaged(Entry) = .empty;

    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            s.branch = try a.dupe(u8, line["# branch.head ".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "# branch.upstream ")) {
            s.upstream = try a.dupe(u8, line["# branch.upstream ".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            // "+2 -1"
            var ab = std.mem.splitScalar(u8, line["# branch.ab ".len..], ' ');
            const plus = ab.next() orelse "";
            const minus = ab.next() orelse "";
            s.ahead = std.fmt.parseInt(u32, std.mem.trimLeft(u8, plus, "+"), 10) catch 0;
            s.behind = std.fmt.parseInt(u32, std.mem.trimLeft(u8, minus, "-"), 10) catch 0;
            continue;
        }
        switch (line[0]) {
            '1', '2', 'u' => {
                var parts = std.mem.splitScalar(u8, line, ' ');
                _ = parts.next();
                const xy = parts.next() orelse continue;
                if (xy.len < 2) continue;
                // 1: sub mH mI mW hH hI (6), 2: + Xscore (7), u: sub m1 m2 m3 mW h1 h2 h3 (8)
                const skip: usize = switch (line[0]) {
                    '1' => 6,
                    '2' => 7,
                    else => 8,
                };
                var i: usize = 0;
                while (i < skip) : (i += 1) _ = parts.next() orelse break;
                if (i < skip) continue;
                const path = try a.dupe(u8, parts.rest());
                if (path.len == 0) continue;
                var old_path: []const u8 = "";
                if (line[0] == '2') old_path = try a.dupe(u8, it.next() orelse "");

                if (line[0] == 'u') {
                    const kind: Kind = if (std.mem.eql(u8, xy, "DD")) .both_deleted else if (std.mem.eql(u8, xy, "AU")) .added_by_us else if (std.mem.eql(u8, xy, "UD")) .deleted_by_them else if (std.mem.eql(u8, xy, "UA")) .added_by_them else if (std.mem.eql(u8, xy, "DU")) .deleted_by_us else if (std.mem.eql(u8, xy, "AA")) .both_added else .both_modified;
                    try merge.append(a, .{ .kind = kind, .path = path });
                    continue;
                }
                const x = xy[0];
                const y = xy[1];
                const index_kind: ?Kind = switch (x) {
                    'M' => .index_modified,
                    'A' => .index_added,
                    'D' => .index_deleted,
                    'R' => .index_renamed,
                    'C' => .index_copied,
                    'T' => .index_type_changed,
                    else => null,
                };
                if (index_kind) |k| try staged.append(a, .{ .kind = k, .path = path, .old_path = old_path });
                const work_kind: ?Kind = switch (y) {
                    'M' => .modified,
                    'D' => .deleted,
                    'T' => .type_changed,
                    'A' => .intent_to_add,
                    else => null,
                };
                if (work_kind) |k| try changes.append(a, .{ .kind = k, .path = path });
            },
            '?' => if (line.len > 2) try changes.append(a, .{ .kind = .untracked, .path = try a.dupe(u8, line[2..]) }),
            // '!' ignoriert: nicht in Source Control (nur Explorer-Dekoration)
            else => {},
        }
    }
    s.merge = try merge.toOwnedSlice(a);
    s.staged = try staged.toOwnedSlice(a);
    s.changes = try changes.toOwnedSlice(a);
    return s;
}

/// Buchstabe der Dekoration wie VS Code `Resource.letter`.
pub fn letter(kind: Kind) u8 {
    return switch (kind) {
        .index_modified, .modified => 'M',
        .index_added, .intent_to_add => 'A',
        .index_deleted, .deleted => 'D',
        .index_renamed => 'R',
        .index_copied => 'C',
        .index_type_changed, .type_changed => 'T',
        .untracked => 'U',
        .ignored => 'I',
        .added_by_us, .added_by_them, .deleted_by_us, .deleted_by_them, .both_added, .both_deleted, .both_modified => '!',
    };
}

/// Farbschlüssel (`gitDecoration.*`), Theme-Felder `git_<name>`.
pub const Color = enum { added, modified, deleted, untracked, renamed, ignored, conflict };

pub fn color(kind: Kind) Color {
    return switch (kind) {
        .index_modified, .modified, .index_type_changed, .type_changed => .modified,
        .index_added, .intent_to_add => .added,
        .index_deleted, .deleted => .deleted,
        .index_renamed, .index_copied => .renamed,
        .untracked => .untracked,
        .ignored => .ignored,
        .added_by_us, .added_by_them, .deleted_by_us, .deleted_by_them, .both_added, .both_deleted, .both_modified => .conflict,
    };
}

/// Gelöschte Dateien durchgestrichen wie VS Code `Resource.strikeThrough`.
pub fn strikeThrough(kind: Kind) bool {
    return switch (kind) {
        .deleted, .index_deleted, .deleted_by_them, .deleted_by_us, .both_deleted => true,
        else => false,
    };
}

/// Hover-Text wie VS Code `Resource.getStatusText`.
pub fn statusText(kind: Kind) []const u8 {
    return switch (kind) {
        .index_modified => "Index Modified",
        .modified => "Modified",
        .index_added => "Index Added",
        .index_deleted => "Index Deleted",
        .deleted => "Deleted",
        .index_renamed => "Index Renamed",
        .index_copied => "Index Copied",
        .untracked => "Untracked",
        .ignored => "Ignored",
        .intent_to_add => "Intent to Add",
        .type_changed => "Type Changed",
        .index_type_changed => "Index Type Changed",
        .both_deleted => "Conflict: Both Deleted",
        .added_by_us => "Conflict: Added By Us",
        .deleted_by_them => "Conflict: Deleted By Them",
        .added_by_them => "Conflict: Added By Them",
        .deleted_by_us => "Conflict: Deleted By Us",
        .both_added => "Conflict: Both Added",
        .both_modified => "Conflict: Both Modified",
    };
}

/// Gruppentitel wie VS Code.
pub fn groupTitle(g: Group) []const u8 {
    return switch (g) {
        .merge => "Merge Changes",
        .staged => "Staged Changes",
        .changes => "Changes",
    };
}

pub const RowKind = enum { group, entry };

pub const Row = struct {
    kind: RowKind,
    group: Group,
    /// Index in der Gruppe (nur `entry`)
    index: usize = 0,
};

/// Zustand des Changes-Bereichs: Status, Zeilen (Gruppenköpfe und Einträge), Auf-/Zuklappen,
/// Auswahl. Merge und Staged erscheinen nur, wenn nicht leer; Changes immer (VS Code).
pub const View = struct {
    alloc: std.mem.Allocator,
    status: ?Status = null,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    collapsed: [3]bool = .{ false, false, false },
    selected: ?usize = null,
    scroll: f32 = 0,

    pub fn init(alloc: std.mem.Allocator) View {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *View) void {
        if (self.status) |*s| s.deinit();
        self.rows.deinit(self.alloc);
    }

    /// Neuer Status aus der rohen v2-Ausgabe; die Auswahl bleibt über den Pfad erhalten.
    pub fn apply(self: *View, raw: []const u8) !void {
        var keep_buf: [std.fs.max_path_bytes]u8 = undefined;
        var keep: ?struct { group: Group, path: []const u8 } = null;
        if (self.selected) |i| if (i < self.rows.items.len) {
            const r = self.rows.items[i];
            if (r.kind == .entry) if (self.entry(r)) |e| {
                const n = @min(e.path.len, keep_buf.len);
                @memcpy(keep_buf[0..n], e.path[0..n]);
                keep = .{ .group = r.group, .path = keep_buf[0..n] };
            };
        };
        var s = try parseStatus(self.alloc, raw);
        errdefer s.deinit();
        if (self.status) |*old| old.deinit();
        self.status = s;
        try self.rebuildRows();
        self.selected = null;
        if (keep) |k| for (self.rows.items, 0..) |r, i| {
            if (r.kind == .entry and r.group == k.group) if (self.entry(r)) |e| if (std.mem.eql(u8, e.path, k.path)) {
                self.selected = i;
            };
        };
    }

    fn rebuildRows(self: *View) !void {
        self.rows.clearRetainingCapacity();
        const s = &(self.status orelse return);
        inline for ([_]Group{ .merge, .staged, .changes }) |g| {
            const list = s.entries(g);
            if (list.len > 0 or g == .changes) {
                try self.rows.append(self.alloc, .{ .kind = .group, .group = g });
                if (!self.collapsed[@intFromEnum(g)]) {
                    for (0..list.len) |i| try self.rows.append(self.alloc, .{ .kind = .entry, .group = g, .index = i });
                }
            }
        }
    }

    pub fn entry(self: *const View, row: Row) ?Entry {
        if (row.kind != .entry) return null;
        const s = &(self.status orelse return null);
        const list = s.entries(row.group);
        return if (row.index < list.len) list[row.index] else null;
    }

    pub fn count(self: *const View, g: Group) usize {
        const s = &(self.status orelse return 0);
        return s.entries(g).len;
    }

    pub fn isClean(self: *const View) bool {
        return self.count(.merge) == 0 and self.count(.staged) == 0 and self.count(.changes) == 0;
    }

    pub fn branch(self: *const View) []const u8 {
        const s = &(self.status orelse return "");
        return s.branch;
    }

    pub fn upstream(self: *const View) []const u8 {
        const s = &(self.status orelse return "");
        return s.upstream;
    }

    pub fn ahead(self: *const View) u32 {
        const s = &(self.status orelse return 0);
        return s.ahead;
    }

    /// Großer Knopf unter dem Feld wie VS Code `scm.showActionButton`: Commit, solange etwas zu
    /// committen ist; sauber und ohne Upstream „Publish Branch“; sauber und voraus „Push“.
    pub const Button = enum { commit, publish, push };

    pub fn actionButton(self: *const View) Button {
        const s = &(self.status orelse return .commit);
        if (!self.isClean() or s.branch.len == 0) return .commit;
        if (s.upstream.len == 0) return .publish;
        if (s.ahead > 0) return .push;
        return .commit;
    }

    pub fn buttonLabel(self: *const View, buf: []u8) []const u8 {
        return switch (self.actionButton()) {
            .commit => "Commit",
            .publish => "Publish Branch",
            .push => std.fmt.bufPrint(buf, "Push {d}\u{2191}", .{self.ahead()}) catch "Push",
        };
    }

    /// Platzhalter des Eingabefelds wie VS Code `repository.ts`.
    pub fn placeholder(self: *const View, buf: []u8) []const u8 {
        const b = self.branch();
        if (b.len == 0) return "Message (Ctrl+Enter to commit)";
        return std.fmt.bufPrint(buf, "Message (Ctrl+Enter to commit on \"{s}\")", .{b}) catch "Message (Ctrl+Enter to commit)";
    }

    pub fn toggleGroup(self: *View, g: Group) void {
        self.collapsed[@intFromEnum(g)] = !self.collapsed[@intFromEnum(g)];
        self.rebuildRows() catch {};
        if (self.selected) |i| if (i >= self.rows.items.len) {
            self.selected = if (self.rows.items.len > 0) self.rows.items.len - 1 else null;
        };
    }

    /// Tastatur: Auswahl um `delta` Zeilen verschieben, geklemmt; ohne Auswahl beginnt sie oben.
    pub fn moveSelection(self: *View, delta: isize) ?usize {
        const n = self.rows.items.len;
        if (n == 0) {
            self.selected = null;
            return null;
        }
        const cur: isize = if (self.selected) |s| @intCast(@min(s, n - 1)) else if (delta > 0) -1 else 0;
        const moved = std.math.clamp(cur + delta, 0, @as(isize, @intCast(n - 1)));
        self.selected = @intCast(moved);
        return self.selected;
    }

    pub const Activate = union(enum) { none, toggled, open_diff: Row };

    /// Enter/Leertaste: Gruppenkopf klappt zu/auf, Eintrag öffnet den Diff.
    pub fn activateSelected(self: *View) Activate {
        const i = self.selected orelse return .none;
        if (i >= self.rows.items.len) return .none;
        const row = self.rows.items[i];
        switch (row.kind) {
            .group => {
                self.toggleGroup(row.group);
                return .toggled;
            },
            .entry => return .{ .open_diff = row },
        }
    }

    /// Diff wie VS Code `git.openDiffOnClick`: Staged = HEAD ↔ Index, Changes = Index ↔
    /// Arbeitskopie, Untracked = leerer Baum ↔ Arbeitskopie, Konflikte wie Changes.
    pub fn diffSpec(self: *const View, row: Row, repo: []const u8) ?git_diff.Spec {
        const e = self.entry(row) orelse return null;
        const old = if (e.old_path.len > 0) e.old_path else e.path;
        return switch (row.group) {
            .staged => .{ .hash = git_diff.index_ref, .parent = "HEAD", .repo = repo, .path = e.path, .previous_path = old },
            .changes, .merge => switch (e.kind) {
                .untracked, .intent_to_add => .{ .hash = git_diff.worktree_ref, .parent = "", .repo = repo, .path = e.path, .previous_path = e.path },
                else => .{ .hash = git_diff.worktree_ref, .parent = git_diff.index_ref, .repo = repo, .path = e.path, .previous_path = e.path },
            },
        };
    }

    /// Pfade einer Gruppe für Stage All / Unstage All / Discard All (owned Slice, Strings in der Arena).
    pub fn groupPaths(self: *const View, alloc: std.mem.Allocator, g: Group) ![]const []const u8 {
        const s = &(self.status orelse return alloc.alloc([]const u8, 0));
        const list = s.entries(g);
        const out = try alloc.alloc([]const u8, list.len);
        for (list, out) |e, *p| p.* = e.path;
        return out;
    }

    /// Rückfrage vor Discard wie VS Code `commands.ts` (`_cleanTrackedChanges`/`_cleanUntrackedChange`).
    pub fn discardQuestion(self: *const View, buf: []u8, row: Row) ![]const u8 {
        const e = self.entry(row) orelse return error.NoEntry;
        const name = std.fs.path.basename(e.path);
        return switch (e.kind) {
            .untracked, .intent_to_add => std.fmt.bufPrint(buf, "Are you sure you want to DELETE the following untracked file: '{s}'?", .{name}),
            .deleted, .deleted_by_them, .deleted_by_us, .both_deleted => std.fmt.bufPrint(buf, "Are you sure you want to restore '{s}'?", .{name}),
            else => std.fmt.bufPrint(buf, "Are you sure you want to discard changes in '{s}'?", .{name}),
        };
    }

    /// Knopftext der Rückfrage wie VS Code.
    pub fn discardButton(self: *const View, row: Row) []const u8 {
        const e = self.entry(row) orelse return "Discard File";
        return switch (e.kind) {
            .untracked, .intent_to_add => "Delete File",
            .deleted, .deleted_by_them, .deleted_by_us, .both_deleted => "Restore File",
            else => "Discard File",
        };
    }
};

test "parseStatus: Gruppen wie VS Code, Umbenennung mit altem Pfad, Konflikte, Untracked in Changes" {
    const raw = "# branch.oid abc\x00# branch.head main\x00" ++
        "1 M. N... 100644 100644 100644 h h src/a.zig\x00" ++
        "1 .M N... 100644 100644 100644 h h src/b.zig\x00" ++
        "1 MM N... 100644 100644 100644 h h src/c.zig\x00" ++
        "1 A. N... 000000 100644 100644 h h neu.txt\x00" ++
        "1 .D N... 100644 100644 000000 h h weg.txt\x00" ++
        "1 D. N... 100644 000000 000000 h h index_weg.txt\x00" ++
        "2 R. N... 100644 100644 100644 h h R100 nach.txt\x00vorher.txt\x00" ++
        "u UU N... 100644 100644 100644 100644 h h h konflikt.txt\x00" ++
        "? frei.txt\x00" ++
        "! ignoriert.txt\x00";
    var s = try parseStatus(testing.allocator, raw);
    defer s.deinit();
    try testing.expectEqualStrings("main", s.branch);

    try testing.expectEqual(@as(usize, 1), s.merge.len);
    try testing.expectEqual(Kind.both_modified, s.merge[0].kind);
    try testing.expectEqualStrings("konflikt.txt", s.merge[0].path);

    try testing.expectEqual(@as(usize, 5), s.staged.len);
    try testing.expectEqual(Kind.index_modified, s.staged[0].kind);
    try testing.expectEqualStrings("src/a.zig", s.staged[0].path);
    try testing.expectEqual(Kind.index_modified, s.staged[1].kind); // MM: in beiden Gruppen
    try testing.expectEqualStrings("src/c.zig", s.staged[1].path);
    try testing.expectEqual(Kind.index_added, s.staged[2].kind);
    try testing.expectEqual(Kind.index_deleted, s.staged[3].kind);
    try testing.expectEqual(Kind.index_renamed, s.staged[4].kind);
    try testing.expectEqualStrings("nach.txt", s.staged[4].path);
    try testing.expectEqualStrings("vorher.txt", s.staged[4].old_path);

    try testing.expectEqual(@as(usize, 4), s.changes.len);
    try testing.expectEqual(Kind.modified, s.changes[0].kind);
    try testing.expectEqualStrings("src/b.zig", s.changes[0].path);
    try testing.expectEqual(Kind.modified, s.changes[1].kind);
    try testing.expectEqualStrings("src/c.zig", s.changes[1].path);
    try testing.expectEqual(Kind.deleted, s.changes[2].kind);
    try testing.expectEqual(Kind.untracked, s.changes[3].kind); // mixed: untracked unter Changes
    try testing.expectEqualStrings("frei.txt", s.changes[3].path);
}

test "letter, color, strikeThrough, statusText wie VS Code Resource" {
    try testing.expectEqual(@as(u8, 'M'), letter(.index_modified));
    try testing.expectEqual(@as(u8, 'A'), letter(.index_added));
    try testing.expectEqual(@as(u8, 'A'), letter(.intent_to_add));
    try testing.expectEqual(@as(u8, 'D'), letter(.deleted));
    try testing.expectEqual(@as(u8, 'R'), letter(.index_renamed));
    try testing.expectEqual(@as(u8, 'C'), letter(.index_copied));
    try testing.expectEqual(@as(u8, 'T'), letter(.type_changed));
    try testing.expectEqual(@as(u8, 'U'), letter(.untracked));
    try testing.expectEqual(@as(u8, 'I'), letter(.ignored));
    try testing.expectEqual(@as(u8, '!'), letter(.both_modified));

    try testing.expectEqual(Color.modified, color(.index_modified));
    try testing.expectEqual(Color.added, color(.index_added));
    try testing.expectEqual(Color.deleted, color(.index_deleted));
    try testing.expectEqual(Color.renamed, color(.index_renamed));
    try testing.expectEqual(Color.untracked, color(.untracked));
    try testing.expectEqual(Color.ignored, color(.ignored));
    try testing.expectEqual(Color.conflict, color(.deleted_by_them));

    try testing.expect(strikeThrough(.deleted));
    try testing.expect(strikeThrough(.index_deleted));
    try testing.expect(strikeThrough(.deleted_by_them));
    try testing.expect(!strikeThrough(.modified));

    try testing.expectEqualStrings("Index Modified", statusText(.index_modified));
    try testing.expectEqualStrings("Index Renamed", statusText(.index_renamed));
    try testing.expectEqualStrings("Untracked", statusText(.untracked));
    try testing.expectEqualStrings("Intent to Add", statusText(.intent_to_add));
    try testing.expectEqualStrings("Conflict: Both Modified", statusText(.both_modified));
    try testing.expectEqualStrings("Conflict: Deleted By Them", statusText(.deleted_by_them));
}

test "View: Zeilen aus Gruppenköpfen und Einträgen, Zuklappen, Auswahl über Gruppen hinweg" {
    var v = View.init(testing.allocator);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 0), v.rows.items.len);
    try v.apply("# branch.head main\x00" ++
        "1 M. N... 100644 100644 100644 h h a.zig\x00" ++
        "1 .M N... 100644 100644 100644 h h b.zig\x00" ++
        "? c.txt\x00");
    // Kopf Staged, a.zig, Kopf Changes, b.zig, c.txt (Merge-Kopf nur bei Konflikten)
    try testing.expectEqual(@as(usize, 5), v.rows.items.len);
    try testing.expectEqual(RowKind.group, v.rows.items[0].kind);
    try testing.expectEqual(Group.staged, v.rows.items[0].group);
    try testing.expectEqual(RowKind.entry, v.rows.items[1].kind);
    try testing.expectEqual(RowKind.group, v.rows.items[2].kind);
    try testing.expectEqual(Group.changes, v.rows.items[2].group);
    try testing.expectEqual(@as(usize, 2), v.count(.changes));
    try testing.expectEqual(@as(usize, 1), v.count(.staged));

    // Tastatur: ↓ beginnt oben, Enter auf dem Kopf klappt zu, Zeilen verschwinden
    try testing.expectEqual(@as(?usize, 0), v.moveSelection(1));
    try testing.expectEqual(View.Activate.toggled, v.activateSelected());
    try testing.expectEqual(@as(usize, 4), v.rows.items.len);
    try testing.expectEqual(View.Activate.toggled, v.activateSelected());
    try testing.expectEqual(@as(usize, 5), v.rows.items.len);
    // End springt zu c.txt, Enter öffnet den Diff (Untracked: leerer Baum gegen Arbeitskopie)
    try testing.expectEqual(@as(?usize, 4), v.moveSelection(100));
    const act = v.activateSelected();
    try testing.expectEqual(Group.changes, act.open_diff.group);
    try testing.expectEqualStrings("c.txt", v.entry(act.open_diff).?.path);
    const spec = v.diffSpec(act.open_diff, "/r").?;
    try testing.expectEqualStrings(git_diff.worktree_ref, spec.hash);
    try testing.expectEqualStrings("", spec.parent);
    try testing.expectEqualStrings("/r", spec.repo);
    // Staged: Index gegen HEAD; Changes: Arbeitskopie gegen Index
    const staged = v.diffSpec(v.rows.items[1], "/r").?;
    try testing.expectEqualStrings(git_diff.index_ref, staged.hash);
    try testing.expectEqualStrings("HEAD", staged.parent);
    try testing.expectEqualStrings("a.zig", staged.path);
    const changed = v.diffSpec(v.rows.items[3], "/r").?;
    try testing.expectEqualStrings(git_diff.worktree_ref, changed.hash);
    try testing.expectEqualStrings(git_diff.index_ref, changed.parent);

    // Neuer Status: Auswahl bleibt über den Pfad erhalten, leere Gruppe Staged fällt weg
    try v.apply("# branch.head main\x00" ++
        "1 .M N... 100644 100644 100644 h h b.zig\x00" ++
        "? c.txt\x00");
    try testing.expectEqual(@as(usize, 3), v.rows.items.len);
    try testing.expectEqual(@as(?usize, 2), v.selected);
    try testing.expectEqual(@as(usize, 2), v.count(.changes));
    try testing.expectEqual(@as(usize, 0), v.count(.staged));
    try testing.expect(v.isClean() == false);
    try v.apply("# branch.head main\x00");
    try testing.expect(v.isClean());
    try testing.expectEqual(@as(usize, 1), v.rows.items.len); // Changes-Kopf bleibt immer
}

test "Kopf-Aktionen: Pfade einer Gruppe, Platzhalter mit Branch" {
    var v = View.init(testing.allocator);
    defer v.deinit();
    try v.apply("# branch.head feature\x00" ++
        "1 M. N... 100644 100644 100644 h h a.zig\x00" ++
        "1 .M N... 100644 100644 100644 h h b.zig\x00" ++
        "1 .D N... 100644 100644 000000 h h weg.txt\x00" ++
        "? c.txt\x00");
    const paths = try v.groupPaths(testing.allocator, .changes);
    defer testing.allocator.free(paths);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("b.zig", paths[0]);
    try testing.expectEqualStrings("c.txt", paths[2]);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Message (Ctrl+Enter to commit on \"feature\")", v.placeholder(&buf));
    // Discard-Rückfragen wie VS Code commands.ts
    try testing.expectEqualStrings("Are you sure you want to discard changes in 'b.zig'?", try v.discardQuestion(&buf, v.rows.items[3]));
    try testing.expectEqualStrings("Are you sure you want to restore 'weg.txt'?", try v.discardQuestion(&buf, v.rows.items[4]));
    try testing.expectEqualStrings("Are you sure you want to DELETE the following untracked file: 'c.txt'?", try v.discardQuestion(&buf, v.rows.items[5]));
}

test "parseStatus: Upstream und Vorsprung aus den branch-Zeilen; Knopf Commit / Publish / Push" {
    var s = try parseStatus(testing.allocator, "# branch.oid abc\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -1\x00");
    defer s.deinit();
    try testing.expectEqualStrings("origin/main", s.upstream);
    try testing.expectEqual(@as(u32, 2), s.ahead);
    try testing.expectEqual(@as(u32, 1), s.behind);

    var v = View.init(testing.allocator);
    defer v.deinit();
    try testing.expectEqual(View.Button.commit, v.actionButton()); // ohne Status
    try v.apply("# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -1\x00");
    try testing.expectEqual(View.Button.push, v.actionButton()); // sauber, 2 voraus
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Push 2\u{2191}", v.buttonLabel(&buf));
    try v.apply("# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -1\x001 .M N... 100644 100644 100644 h h a.zig\x00");
    try testing.expectEqual(View.Button.commit, v.actionButton()); // Änderungen: Commit zuerst
    try testing.expectEqualStrings("Commit", v.buttonLabel(&buf));
    try v.apply("# branch.head neu\x00");
    try testing.expectEqual(View.Button.publish, v.actionButton()); // kein Upstream
    try testing.expectEqualStrings("Publish Branch", v.buttonLabel(&buf));
    try v.apply("# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +0 -0\x00");
    try testing.expectEqual(View.Button.commit, v.actionButton()); // nichts zu tun
}
