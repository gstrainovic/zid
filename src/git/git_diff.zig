//! Diff-Editor wie in VS Code, ohne Clay: Hunks aus `git show -U0`, Ausrichtung alter und
//! neuer Zeilen (nebeneinander / untereinander), eingeklappte unveränderte Bereiche,
//! Sprünge zwischen Änderungen und Zeichen-Markierung innerhalb geänderter Zeilen.
//! Standardwerte aus VS Code `src/vs/editor/common/config/diffEditor.ts`.

const std = @import("std");

const testing = std.testing;

/// VS Code `renderSideBySideInlineBreakpoint`: schmaler als das → untereinander.
pub const side_by_side_breakpoint: f32 = 900;

pub fn useSideBySide(width: f32) bool {
    return width >= side_by_side_breakpoint;
}

/// Ein Hunk aus `@@ -old_start,old_count +new_start,new_count @@` (1-basiert wie git).
pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

/// Hunk-Köpfe aus `git show -U0` bzw. `git diff -U0`; alles andere wird übersprungen.
pub fn parseHunks(alloc: std.mem.Allocator, out: []const u8) ![]Hunk {
    var hunks: std.ArrayListUnmanaged(Hunk) = .empty;
    errdefer hunks.deinit(alloc);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "@@ -")) continue;
        const rest = line["@@ -".len..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const old = parseRange(rest[0..space]) orelse continue;
        const after = rest[space + 1 ..];
        if (after.len == 0 or after[0] != '+') continue;
        const end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
        const new = parseRange(after[1..end]) orelse continue;
        try hunks.append(alloc, .{ .old_start = old[0], .old_count = old[1], .new_start = new[0], .new_count = new[1] });
    }
    return hunks.toOwnedSlice(alloc);
}

fn parseRange(text: []const u8) ?[2]u32 {
    const comma = std.mem.indexOfScalar(u8, text, ',');
    const start = std.fmt.parseInt(u32, text[0 .. comma orelse text.len], 10) catch return null;
    const count = if (comma) |c| std.fmt.parseInt(u32, text[c + 1 ..], 10) catch return null else 1;
    return .{ start, count };
}

pub const RowKind = enum { equal, modified, removed, added };

/// Eine Anzeigezeile: Index der alten und/oder neuen Zeile (0-basiert), null = Lücke.
pub const Row = struct {
    kind: RowKind,
    old: ?u32,
    new: ?u32,
};

pub const Layout = enum { side_by_side, inline_ };

/// Nebeneinander: entfernte und hinzugefügte Zeilen eines Hunks stehen paarweise in einer Zeile.
pub fn sideBySide(alloc: std.mem.Allocator, old_count: usize, new_count: usize, hunks: []const Hunk) ![]Row {
    return buildRows(alloc, old_count, new_count, hunks, .side_by_side);
}

/// Untereinander: je Hunk zuerst alle entfernten, dann alle hinzugefügten Zeilen.
pub fn inlineRows(alloc: std.mem.Allocator, old_count: usize, new_count: usize, hunks: []const Hunk) ![]Row {
    return buildRows(alloc, old_count, new_count, hunks, .inline_);
}

fn buildRows(alloc: std.mem.Allocator, old_count: usize, new_count: usize, hunks: []const Hunk, layout: Layout) ![]Row {
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    errdefer rows.deinit(alloc);
    var old_i: u32 = 0;
    var new_i: u32 = 0;
    for (hunks) |h| {
        // Zählung 0: der Start nennt die Zeile *vor* der Stelle, 0-basiert also genau den Start
        const old_begin = if (h.old_count > 0) h.old_start -| 1 else h.old_start;
        const new_begin = if (h.new_count > 0) h.new_start -| 1 else h.new_start;
        while (old_i < old_begin and new_i < new_begin) : ({
            old_i += 1;
            new_i += 1;
        }) try rows.append(alloc, .{ .kind = .equal, .old = old_i, .new = new_i });
        old_i = @max(old_i, old_begin);
        new_i = @max(new_i, new_begin);
        switch (layout) {
            .side_by_side => {
                for (0..@max(h.old_count, h.new_count)) |k| {
                    const o: ?u32 = if (k < h.old_count) old_i + @as(u32, @intCast(k)) else null;
                    const n: ?u32 = if (k < h.new_count) new_i + @as(u32, @intCast(k)) else null;
                    const kind: RowKind = if (o != null and n != null) .modified else if (o != null) .removed else .added;
                    try rows.append(alloc, .{ .kind = kind, .old = o, .new = n });
                }
            },
            .inline_ => {
                for (0..h.old_count) |k| try rows.append(alloc, .{ .kind = .removed, .old = old_i + @as(u32, @intCast(k)), .new = null });
                for (0..h.new_count) |k| try rows.append(alloc, .{ .kind = .added, .old = null, .new = new_i + @as(u32, @intCast(k)) });
            },
        }
        old_i += h.old_count;
        new_i += h.new_count;
    }
    while (old_i < old_count and new_i < new_count) : ({
        old_i += 1;
        new_i += 1;
    }) try rows.append(alloc, .{ .kind = .equal, .old = old_i, .new = new_i });
    return rows.toOwnedSlice(alloc);
}

/// Erste Zeile jedes zusammenhängenden Änderungsblocks (Ziele für Next/Previous Change).
pub fn changeStarts(alloc: std.mem.Allocator, rows: []const Row) ![]usize {
    var starts: std.ArrayListUnmanaged(usize) = .empty;
    errdefer starts.deinit(alloc);
    for (rows, 0..) |r, i| {
        if (r.kind != .equal and (i == 0 or rows[i - 1].kind == .equal)) try starts.append(alloc, i);
    }
    return starts.toOwnedSlice(alloc);
}

/// Nächster Block nach Zeile `current`; nach dem letzten wieder der erste (wie VS Code).
pub fn nextChange(starts: []const usize, current: usize) ?usize {
    if (starts.len == 0) return null;
    for (starts) |s| if (s > current) return s;
    return starts[0];
}

pub fn prevChange(starts: []const usize, current: usize) ?usize {
    if (starts.len == 0) return null;
    var i = starts.len;
    while (i > 0) {
        i -= 1;
        if (starts[i] < current) return starts[i];
    }
    return starts[starts.len - 1];
}

/// Aufgedeckter Teil eines eingeklappten Bereichs (Klick auf den Faltbalken).
pub const Reveal = struct { first: usize, count: usize };

/// VS Code `hideUnchangedRegions`: contextLineCount 3, minimumLineCount 3, revealLineCount 20.
pub const CollapseOptions = struct {
    context: usize = 3,
    minimum: usize = 3,
    revealed: []const Reveal = &.{},
};
pub const reveal_line_count: usize = 20;

pub const Item = union(enum) {
    row: usize,
    fold: struct { first: usize, count: usize },
};

/// Unveränderte Bereiche einklappen: sichtbar bleiben `context` Zeilen um jede Änderung und
/// aufgedeckte Bereiche; verborgen wird nur ein Stück ab `minimum` Zeilen.
pub fn collapse(alloc: std.mem.Allocator, rows: []const Row, opts: CollapseOptions) ![]Item {
    const visible = try alloc.alloc(bool, rows.len);
    defer alloc.free(visible);
    @memset(visible, false);
    for (rows, 0..) |r, i| {
        if (r.kind == .equal) continue;
        const from = i -| opts.context;
        const to = @min(rows.len, i + opts.context + 1);
        @memset(visible[from..to], true);
    }
    for (opts.revealed) |rv| {
        if (rv.first >= rows.len) continue;
        @memset(visible[rv.first..@min(rows.len, rv.first + rv.count)], true);
    }

    var items: std.ArrayListUnmanaged(Item) = .empty;
    errdefer items.deinit(alloc);
    var i: usize = 0;
    while (i < rows.len) {
        if (visible[i]) {
            try items.append(alloc, .{ .row = i });
            i += 1;
            continue;
        }
        var end = i;
        while (end < rows.len and !visible[end]) end += 1;
        if (end - i >= opts.minimum) {
            try items.append(alloc, .{ .fold = .{ .first = i, .count = end - i } });
        } else {
            for (i..end) |k| try items.append(alloc, .{ .row = k });
        }
        i = end;
    }
    return items.toOwnedSlice(alloc);
}

/// Geänderter Teil zweier Zeilen (Byte-Bereiche), über gemeinsamen Anfang und gemeinsames Ende.
/// Schnitte liegen immer auf UTF-8-Zeichengrenzen.
pub const InnerChange = struct { old_start: usize, old_end: usize, new_start: usize, new_end: usize };

pub fn innerChange(old: []const u8, new: []const u8) InnerChange {
    const limit = @min(old.len, new.len);
    var prefix: usize = 0;
    while (prefix < limit and old[prefix] == new[prefix]) prefix += 1;
    while (prefix > 0 and prefix < old.len and isContinuation(old[prefix])) prefix -= 1;
    var suffix: usize = 0;
    while (suffix < limit - prefix and old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    while (suffix > 0 and isContinuation(old[old.len - suffix])) suffix -= 1;
    return .{ .old_start = prefix, .old_end = old.len - suffix, .new_start = prefix, .new_end = new.len - suffix };
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

pub const scheme = "git-diff://";

/// Ref für den Index (gestagter Stand) wie VS Code `GitTimelineItem('~', 'HEAD', …)`.
pub const index_ref = "~";

/// Hash des leeren Baums: VS Code vergleicht einen Wurzel-Commit damit.
pub const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// Was ein Diff-Tab zeigt: Datei `path` in Commit `hash` gegen `previous_path` im Eltern-Commit
/// (leer = Wurzel-Commit). Pfade relativ zur Repo-Wurzel `repo`.
pub const Spec = struct {
    hash: []const u8,
    parent: []const u8,
    repo: []const u8,
    path: []const u8,
    previous_path: []const u8,
};

/// `git-diff://hash␟parent␟repo␟path␟previous_path` (owned); 0x1f kommt in Pfaden nicht vor.
pub fn tabPath(alloc: std.mem.Allocator, s: Spec) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ scheme, s.hash, "\x1f", s.parent, "\x1f", s.repo, "\x1f", s.path, "\x1f", s.previous_path });
}

pub fn isDiffPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, scheme);
}

pub fn parseTabPath(path: []const u8) ?Spec {
    if (!isDiffPath(path)) return null;
    var it = std.mem.splitScalar(u8, path[scheme.len..], 0x1f);
    var f: [5][]const u8 = undefined;
    for (&f) |*field| field.* = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{ .hash = f[0], .parent = f[1], .repo = f[2], .path = f[3], .previous_path = f[4] };
}

fn short(hash: []const u8) []const u8 {
    return hash[0..@min(hash.len, 7)];
}

pub fn specTitle(alloc: std.mem.Allocator, s: Spec) ![]u8 {
    // VS Code: '{0} (Index)' für den gestagten Stand
    if (std.mem.eql(u8, s.hash, index_ref)) return std.fmt.allocPrint(alloc, "{s} (Index)", .{std.fs.path.basename(s.path)});
    return title(alloc, s.path, short(if (s.parent.len > 0) s.parent else empty_tree), short(s.hash));
}

/// `git show <ref>:<pfad>` für den Dateiinhalt; null ohne Ref (Wurzel-Commit hat keinen Vorgänger).
pub fn contentArgs(buf: *[16][]const u8, spec_buf: []u8, ref: []const u8, path: []const u8) ?[]const []const u8 {
    if (ref.len == 0 or path.len == 0) return null;
    // Index: `git show :pfad`
    const object = std.fmt.bufPrint(spec_buf, "{s}:{s}", .{ if (std.mem.eql(u8, ref, index_ref)) "" else ref, path }) catch return null;
    buf[0] = "show";
    buf[1] = "--no-color";
    buf[2] = object;
    return buf[0..3];
}

/// Nur die Hunk-Köpfe: `-U0`, Umbenennung über beide Pfade erkennbar. Mit Vorgänger
/// `git diff <vorher> <commit>` (exakt die beiden gezeigten Stände), sonst `git show`.
pub fn hunkArgs(buf: *[16][]const u8, spec_buf: []u8, s: Spec) []const []const u8 {
    var n: usize = 0;
    const head: []const []const u8 = if (std.mem.eql(u8, s.hash, index_ref))
        &.{ "diff", "--no-color", "--no-ext-diff", "--cached", "-U0", "-M", s.parent, "--" }
    else if (s.parent.len > 0)
        &.{ "diff", "--no-color", "--no-ext-diff", "-U0", "-M", s.parent, s.hash, "--" }
    else
        &.{ "show", "--no-color", "--no-ext-diff", "--format=", "-U0", "-M", s.hash, "--" };
    for (head) |a| {
        buf[n] = a;
        n += 1;
    }
    var used: usize = 0;
    for ([_][]const u8{ s.path, s.previous_path }, 0..) |p, i| {
        if (p.len == 0 or (i == 1 and std.mem.eql(u8, p, s.path))) continue;
        const spec = std.fmt.bufPrint(spec_buf[used..], ":(top){s}", .{p}) catch continue;
        used += spec.len;
        buf[n] = spec;
        n += 1;
    }
    return buf[0..n];
}

/// Tab-Titel wie VS Code `resolveTimelineOpenDiffCommand`: `name (alt) ↔ name (neu)` (owned).
pub fn title(alloc: std.mem.Allocator, path: []const u8, short_old: []const u8, short_new: []const u8) ![]u8 {
    const name = std.fs.path.basename(path);
    return std.fmt.allocPrint(alloc, "{s} ({s}) \u{2194} {s} ({s})", .{ name, short_old, name, short_new });
}

/// Worker-Ergebnis mit drei Teilen: `<len alt> <len neu> <len hunks>\n` und die Teile hintereinander (owned).
pub fn encodeContents(alloc: std.mem.Allocator, old: []const u8, new: []const u8, hunks: []const u8) ![]u8 {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "{d} {d} {d}\n", .{ old.len, new.len, hunks.len });
    return std.mem.concat(alloc, u8, &.{ header, old, new, hunks });
}

pub const Contents = struct { old: []const u8, new: []const u8, hunks: []const u8 };

pub fn decodeContents(payload: []const u8) ?Contents {
    const nl = std.mem.indexOfScalar(u8, payload, '\n') orelse return null;
    var it = std.mem.splitScalar(u8, payload[0..nl], ' ');
    var lens: [3]usize = undefined;
    for (&lens) |*l| l.* = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const body = payload[nl + 1 ..];
    if (lens[0] + lens[1] + lens[2] != body.len) return null;
    return .{
        .old = body[0..lens[0]],
        .new = body[lens[0]..][0..lens[1]],
        .hunks = body[lens[0] + lens[1] ..],
    };
}

pub const ByteRange = struct { start: usize, end: usize };

/// Bytes einer Zeile, die ab Anzeigespalte `first_col` in `cols` Spalten passen (horizontales
/// Scrollen ohne Clipping). Codepoint = 1 Spalte, Tab = 4, wie im Editor.
pub fn columnSlice(line: []const u8, first_col: usize, cols: usize) ByteRange {
    var col: usize = 0;
    var i: usize = 0;
    var start: ?usize = null;
    while (i < line.len) {
        if (start == null and col >= first_col) start = i;
        if (start != null and col >= first_col + cols) return .{ .start = start.?, .end = i };
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        col += if (line[i] == '\t') 4 else 1;
        i = @min(line.len, i + len);
    }
    const s = start orelse line.len;
    return .{ .start = s, .end = line.len };
}

/// VS Code „Diff View“: Automatic (nach Breite), Side by Side, Inline.
pub const Mode = enum { auto, side_by_side, inline_ };

pub const Stats = struct { changes: usize, added: usize, removed: usize };

/// Zustand eines Diff-Tabs ohne Clay: Laden, Zeilen je Layout, Einklappen, Sprünge.
pub const DiffState = struct {
    alloc: std.mem.Allocator,
    tab_path: []u8,
    spec: Spec,
    title_text: []u8,
    want_load: bool = true,
    loading: bool = false,
    loaded: bool = false,
    /// stderr von git, wenn die Hunks nicht zu bekommen waren (owned)
    error_text: ?[]u8 = null,
    body: []u8 = &.{},
    old_lines: [][]const u8 = &.{},
    new_lines: [][]const u8 = &.{},
    side_rows: []Row = &.{},
    inline_rows: []Row = &.{},
    side_starts: []usize = &.{},
    inline_starts: []usize = &.{},
    mode: Mode = .auto,
    /// VS Code „Collapse Unchanged Regions“ (Standard aus)
    collapse_unchanged: bool = false,
    side_reveals: std.ArrayListUnmanaged(Reveal) = .empty,
    inline_reveals: std.ArrayListUnmanaged(Reveal) = .empty,
    side_items: ?[]Item = null,
    inline_items: ?[]Item = null,
    /// Zeile der zuletzt angesprungenen Änderung (Next/Previous Change)
    current_row: ?usize = null,
    scroll_y: f32 = 0,
    scroll_x: f32 = 0,

    pub fn init(alloc: std.mem.Allocator, tab_path: []const u8) !DiffState {
        const owned = try alloc.dupe(u8, tab_path);
        errdefer alloc.free(owned);
        const spec = parseTabPath(owned) orelse return error.InvalidDiffPath;
        return .{ .alloc = alloc, .tab_path = owned, .spec = spec, .title_text = try specTitle(alloc, spec) };
    }

    pub fn deinit(self: *DiffState) void {
        self.freeContent();
        if (self.error_text) |e| self.alloc.free(e);
        self.side_reveals.deinit(self.alloc);
        self.inline_reveals.deinit(self.alloc);
        self.alloc.free(self.title_text);
        self.alloc.free(self.tab_path);
    }

    fn freeContent(self: *DiffState) void {
        self.invalidateItems();
        for ([_][]Row{ self.side_rows, self.inline_rows }) |r| self.alloc.free(r);
        for ([_][]usize{ self.side_starts, self.inline_starts }) |s| self.alloc.free(s);
        self.alloc.free(self.old_lines);
        self.alloc.free(self.new_lines);
        self.alloc.free(self.body);
        self.side_rows = &.{};
        self.inline_rows = &.{};
        self.side_starts = &.{};
        self.inline_starts = &.{};
        self.old_lines = &.{};
        self.new_lines = &.{};
        self.body = &.{};
    }

    fn invalidateItems(self: *DiffState) void {
        if (self.side_items) |i| self.alloc.free(i);
        if (self.inline_items) |i| self.alloc.free(i);
        self.side_items = null;
        self.inline_items = null;
    }

    pub fn takeRequest(self: *DiffState) bool {
        if (!self.want_load) return false;
        self.want_load = false;
        self.loading = true;
        return true;
    }

    /// Ergebnis von `taskGitFileDiff` (ohne Schlüssel).
    pub fn apply(self: *DiffState, ok: bool, payload: []const u8) !void {
        self.loading = false;
        if (self.error_text) |e| self.alloc.free(e);
        self.error_text = null;
        if (!ok) {
            self.error_text = try self.alloc.dupe(u8, payload);
            return;
        }
        if (decodeContents(payload) == null) {
            self.error_text = try self.alloc.dupe(u8, "invalid diff result");
            return;
        }
        self.freeContent();
        self.body = try self.alloc.dupe(u8, payload);
        // Zeilen-Slices zeigen in die eigene Kopie
        const c = decodeContents(self.body).?;
        self.old_lines = try splitLines(self.alloc, c.old);
        self.new_lines = try splitLines(self.alloc, c.new);
        const hunks = try parseHunks(self.alloc, c.hunks);
        defer self.alloc.free(hunks);
        self.side_rows = try sideBySide(self.alloc, self.old_lines.len, self.new_lines.len, hunks);
        self.inline_rows = try inlineRows(self.alloc, self.old_lines.len, self.new_lines.len, hunks);
        self.side_starts = try changeStarts(self.alloc, self.side_rows);
        self.inline_starts = try changeStarts(self.alloc, self.inline_rows);
        self.loaded = true;
    }

    pub fn layoutFor(self: *const DiffState, width: f32) Layout {
        return switch (self.mode) {
            .auto => if (useSideBySide(width)) .side_by_side else .inline_,
            .side_by_side => .side_by_side,
            .inline_ => .inline_,
        };
    }

    pub fn rows(self: *const DiffState, layout: Layout) []const Row {
        return switch (layout) {
            .side_by_side => self.side_rows,
            .inline_ => self.inline_rows,
        };
    }

    fn starts(self: *const DiffState, layout: Layout) []const usize {
        return switch (layout) {
            .side_by_side => self.side_starts,
            .inline_ => self.inline_starts,
        };
    }

    /// Anzeigeeinträge (Zeilen und Faltbalken), zwischengespeichert bis zur nächsten Änderung.
    pub fn items(self: *DiffState, layout: Layout) ![]const Item {
        const cache = switch (layout) {
            .side_by_side => &self.side_items,
            .inline_ => &self.inline_items,
        };
        if (cache.*) |c| return c;
        const r = self.rows(layout);
        const built = if (self.collapse_unchanged)
            try collapse(self.alloc, r, .{ .revealed = self.reveals(layout).items })
        else blk: {
            const all = try self.alloc.alloc(Item, r.len);
            for (all, 0..) |*it, i| it.* = .{ .row = i };
            break :blk all;
        };
        cache.* = built;
        return built;
    }

    fn reveals(self: *DiffState, layout: Layout) *std.ArrayListUnmanaged(Reveal) {
        return switch (layout) {
            .side_by_side => &self.side_reveals,
            .inline_ => &self.inline_reveals,
        };
    }

    pub fn toggleCollapse(self: *DiffState) void {
        self.collapse_unchanged = !self.collapse_unchanged;
        self.invalidateItems();
    }

    /// Klick auf einen Faltbalken: `count` Zeilen ab `first` sichtbar machen.
    pub fn revealFold(self: *DiffState, layout: Layout, first: usize, count: usize) !void {
        try self.reveals(layout).append(self.alloc, .{ .first = first, .count = count });
        self.invalidateItems();
    }

    pub fn stats(self: *const DiffState) Stats {
        var s = Stats{ .changes = self.side_starts.len, .added = 0, .removed = 0 };
        for (self.side_rows) |r| switch (r.kind) {
            .modified => {
                s.added += 1;
                s.removed += 1;
            },
            .added => s.added += 1,
            .removed => s.removed += 1,
            .equal => {},
        };
        return s;
    }

    /// Nächste Änderung; Rückgabe ist der Eintragsindex zum Hinscrollen.
    pub fn goNext(self: *DiffState, layout: Layout) !?usize {
        const st = self.starts(layout);
        const row = if (self.current_row) |cur| nextChange(st, cur) else if (st.len > 0) st[0] else null;
        return self.jumpTo(layout, row orelse return null);
    }

    pub fn goPrev(self: *DiffState, layout: Layout) !?usize {
        const st = self.starts(layout);
        const row = if (self.current_row) |cur| prevChange(st, cur) else if (st.len > 0) st[st.len - 1] else null;
        return self.jumpTo(layout, row orelse return null);
    }

    fn jumpTo(self: *DiffState, layout: Layout, row: usize) !?usize {
        self.current_row = row;
        for (try self.items(layout), 0..) |it, i| switch (it) {
            .row => |r| if (r == row) return i,
            .fold => |f| if (row >= f.first and row < f.first + f.count) return i,
        };
        return null;
    }
};

/// Text in Zeilen ohne Umbruch zerlegen (Slices in `text`); ein abschließendes `\n` erzeugt
/// keine leere Zeile, `\r` am Zeilenende fällt weg.
pub fn splitLines(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(alloc);
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        var line = text[start .. nl orelse text.len];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try lines.append(alloc, line);
        start = if (nl) |i| i + 1 else text.len;
    }
    return lines.toOwnedSlice(alloc);
}

test "parseHunks: Zählung fehlt = 1, 0 bei reinem Einfügen/Löschen, andere Zeilen ignoriert" {
    const out =
        \\diff --git a/x b/x
        \\index 1..2 100644
        \\--- a/x
        \\+++ b/x
        \\@@ -2 +2 @@ fn a
        \\-b
        \\+B
        \\@@ -4,0 +5,1 @@
        \\+x
        \\@@ -7,2 +8,0 @@
        \\-g
        \\-h
    ;
    const hunks = try parseHunks(testing.allocator, out);
    defer testing.allocator.free(hunks);
    try testing.expectEqual(@as(usize, 3), hunks.len);
    try testing.expectEqual(Hunk{ .old_start = 2, .old_count = 1, .new_start = 2, .new_count = 1 }, hunks[0]);
    try testing.expectEqual(Hunk{ .old_start = 4, .old_count = 0, .new_start = 5, .new_count = 1 }, hunks[1]);
    try testing.expectEqual(Hunk{ .old_start = 7, .old_count = 2, .new_start = 8, .new_count = 0 }, hunks[2]);
}

fn expectRows(expected: []const Row, actual: []const Row) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |e, a, i| {
        testing.expectEqual(e, a) catch |err| {
            std.debug.print("Zeile {d}: erwartet {any}, bekommen {any}\n", .{ i, e, a });
            return err;
        };
    }
}

test "sideBySide: Änderung paarweise, Einfügen mit Lücke links, Rest gleich" {
    // alt: a b c d e    neu: a B c d x e
    const hunks = [_]Hunk{
        .{ .old_start = 2, .old_count = 1, .new_start = 2, .new_count = 1 },
        .{ .old_start = 4, .old_count = 0, .new_start = 5, .new_count = 1 },
    };
    const rows = try sideBySide(testing.allocator, 5, 6, &hunks);
    defer testing.allocator.free(rows);
    try expectRows(&.{
        .{ .kind = .equal, .old = 0, .new = 0 },
        .{ .kind = .modified, .old = 1, .new = 1 },
        .{ .kind = .equal, .old = 2, .new = 2 },
        .{ .kind = .equal, .old = 3, .new = 3 },
        .{ .kind = .added, .old = null, .new = 4 },
        .{ .kind = .equal, .old = 4, .new = 5 },
    }, rows);
}

test "sideBySide: mehr entfernt als hinzugefügt, reines Löschen, neue Datei" {
    // alt: a b c d   neu: a X d   (b c → X)
    const h1 = [_]Hunk{.{ .old_start = 2, .old_count = 2, .new_start = 2, .new_count = 1 }};
    const r1 = try sideBySide(testing.allocator, 4, 3, &h1);
    defer testing.allocator.free(r1);
    try expectRows(&.{
        .{ .kind = .equal, .old = 0, .new = 0 },
        .{ .kind = .modified, .old = 1, .new = 1 },
        .{ .kind = .removed, .old = 2, .new = null },
        .{ .kind = .equal, .old = 3, .new = 2 },
    }, r1);

    // alt: a b c   neu: a   (b c gelöscht; neu-Zählung 0 zeigt auf die Zeile davor)
    const h2 = [_]Hunk{.{ .old_start = 2, .old_count = 2, .new_start = 1, .new_count = 0 }};
    const r2 = try sideBySide(testing.allocator, 3, 1, &h2);
    defer testing.allocator.free(r2);
    try expectRows(&.{
        .{ .kind = .equal, .old = 0, .new = 0 },
        .{ .kind = .removed, .old = 1, .new = null },
        .{ .kind = .removed, .old = 2, .new = null },
    }, r2);

    const h3 = [_]Hunk{.{ .old_start = 0, .old_count = 0, .new_start = 1, .new_count = 2 }};
    const r3 = try sideBySide(testing.allocator, 0, 2, &h3);
    defer testing.allocator.free(r3);
    try expectRows(&.{
        .{ .kind = .added, .old = null, .new = 0 },
        .{ .kind = .added, .old = null, .new = 1 },
    }, r3);
}

test "inline: erst alle entfernten, dann alle hinzugefügten Zeilen eines Hunks" {
    const h = [_]Hunk{.{ .old_start = 2, .old_count = 2, .new_start = 2, .new_count = 1 }};
    const rows = try inlineRows(testing.allocator, 4, 3, &h);
    defer testing.allocator.free(rows);
    try expectRows(&.{
        .{ .kind = .equal, .old = 0, .new = 0 },
        .{ .kind = .removed, .old = 1, .new = null },
        .{ .kind = .removed, .old = 2, .new = null },
        .{ .kind = .added, .old = null, .new = 1 },
        .{ .kind = .equal, .old = 3, .new = 2 },
    }, rows);
}

test "changeStarts: erste Zeile jedes zusammenhängenden Änderungsblocks" {
    const rows = [_]Row{
        .{ .kind = .equal, .old = 0, .new = 0 },
        .{ .kind = .removed, .old = 1, .new = null },
        .{ .kind = .added, .old = null, .new = 1 },
        .{ .kind = .equal, .old = 2, .new = 2 },
        .{ .kind = .modified, .old = 3, .new = 3 },
    };
    const starts = try changeStarts(testing.allocator, &rows);
    defer testing.allocator.free(starts);
    try testing.expectEqualSlices(usize, &.{ 1, 4 }, starts);
    try testing.expectEqual(@as(?usize, 1), nextChange(starts, 0));
    try testing.expectEqual(@as(?usize, 4), nextChange(starts, 1));
    try testing.expectEqual(@as(?usize, 1), nextChange(starts, 4)); // am Ende von vorn wie VS Code
    try testing.expectEqual(@as(?usize, 1), prevChange(starts, 4));
    try testing.expectEqual(@as(?usize, 4), prevChange(starts, 1)); // am Anfang von hinten
    try testing.expectEqual(@as(?usize, null), nextChange(&.{}, 0));
}

fn eqRows(n: usize) ![]Row {
    const rows = try testing.allocator.alloc(Row, n);
    for (rows, 0..) |*r, i| r.* = .{ .kind = .equal, .old = @intCast(i), .new = @intCast(i) };
    return rows;
}

test "collapse: Kontext 3 um Änderungen, nur ab 3 verborgenen Zeilen, Dateianfang und -ende" {
    // 30 Zeilen, Änderung in Zeile 15
    const rows = try eqRows(30);
    defer testing.allocator.free(rows);
    rows[15].kind = .modified;
    const items = try collapse(testing.allocator, rows, .{});
    defer testing.allocator.free(items);
    // 0..11 verborgen (12), 12..18 sichtbar (3 + Änderung + 3), 19..29 verborgen (11)
    try testing.expectEqual(@as(usize, 9), items.len);
    try testing.expectEqual(Item{ .fold = .{ .first = 0, .count = 12 } }, items[0]);
    try testing.expectEqual(Item{ .row = 12 }, items[1]);
    try testing.expectEqual(Item{ .row = 18 }, items[7]);
    try testing.expectEqual(Item{ .fold = .{ .first = 19, .count = 11 } }, items[8]);

    // zwei Änderungen mit nur 8 gleichen Zeilen dazwischen: 3 + 2 verborgen + 3 → 2 < 3, nichts verborgen
    const close = try eqRows(20);
    defer testing.allocator.free(close);
    close[0].kind = .added;
    close[9].kind = .added;
    const items2 = try collapse(testing.allocator, close, .{});
    defer testing.allocator.free(items2);
    for (items2[0..10], 0..) |it, i| try testing.expectEqual(Item{ .row = i }, it);
    try testing.expectEqual(Item{ .fold = .{ .first = 13, .count = 7 } }, items2[13]);
}

test "collapse: ohne Änderungen alles in einem Block, aufgeklappte Bereiche bleiben sichtbar" {
    const rows = try eqRows(10);
    defer testing.allocator.free(rows);
    const items = try collapse(testing.allocator, rows, .{});
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(Item{ .fold = .{ .first = 0, .count = 10 } }, items[0]);

    // Bereich ab Zeile 0 um 20 aufgedeckt (revealLineCount): 0..9 sichtbar
    const revealed = [_]Reveal{.{ .first = 0, .count = 20 }};
    const items2 = try collapse(testing.allocator, rows, .{ .revealed = &revealed });
    defer testing.allocator.free(items2);
    try testing.expectEqual(@as(usize, 10), items2.len);
}

test "innerChange: gemeinsamer Anfang und Ende, geänderte Mitte in Bytes" {
    const c = innerChange("const x = 1;", "const y = 12;");
    try testing.expectEqual(InnerChange{ .old_start = 6, .old_end = 11, .new_start = 6, .new_end = 12 }, c);
    const same = innerChange("abc", "abc");
    try testing.expectEqual(same.old_start, same.old_end);
    // UTF-8: Schnitt nie mitten im Zeichen
    const u = innerChange("aä", "aö");
    try testing.expectEqual(InnerChange{ .old_start = 1, .old_end = 3, .new_start = 1, .new_end = 3 }, u);
}

test "useSideBySide: ab 900 px nebeneinander" {
    try testing.expect(useSideBySide(900));
    try testing.expect(!useSideBySide(899));
}

test "title wie VS Code: name (alt) ↔ name (neu)" {
    const t = try title(testing.allocator, "/r/src/b.txt", "5940e42", "3bd7496");
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("b.txt (5940e42) \u{2194} b.txt (3bd7496)", t);
}

test "Payload: alter Inhalt, neuer Inhalt und Hunks in einem Ergebnis" {
    const p = try encodeContents(testing.allocator, "alt\n", "neu\nx\n", "@@ -1 +1,2 @@\n");
    defer testing.allocator.free(p);
    const d = decodeContents(p).?;
    try testing.expectEqualStrings("alt\n", d.old);
    try testing.expectEqualStrings("neu\nx\n", d.new);
    try testing.expectEqualStrings("@@ -1 +1,2 @@\n", d.hunks);
    try testing.expect(decodeContents("kaputt") == null);
    try testing.expect(decodeContents("99 1 1\nab") == null);
}

test "Tab-Pfad: Commit, Eltern, Repo, Pfad, alter Pfad; Titel mit Kurz-Hashes" {
    const spec = Spec{
        .hash = "3bd7496b18f7f972ef54a617af2e6aa3ec4466ab",
        .parent = "5940e42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .repo = "C:\\proj",
        .path = "b.txt",
        .previous_path = "a.txt",
    };
    const p = try tabPath(testing.allocator, spec);
    defer testing.allocator.free(p);
    try testing.expect(isDiffPath(p));
    const back = parseTabPath(p).?;
    try testing.expectEqualStrings(spec.hash, back.hash);
    try testing.expectEqualStrings(spec.parent, back.parent);
    try testing.expectEqualStrings(spec.repo, back.repo);
    try testing.expectEqualStrings("b.txt", back.path);
    try testing.expectEqualStrings("a.txt", back.previous_path);
    try testing.expect(parseTabPath("git-diff://nur\x1fzwei") == null);
    try testing.expect(parseTabPath("/home/x") == null);

    const t = try specTitle(testing.allocator, spec);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("b.txt (5940e42) \u{2194} b.txt (3bd7496)", t);
    // Wurzel-Commit: VS Code vergleicht mit dem leeren Baum
    var root = spec;
    root.parent = "";
    const rt = try specTitle(testing.allocator, root);
    defer testing.allocator.free(rt);
    try testing.expectEqualStrings("b.txt (4b825dc) \u{2194} b.txt (3bd7496)", rt);
}

test "showArgs: alter und neuer Inhalt über <ref>:<pfad>, Hunks mit -U0 und beiden Pfaden" {
    var buf: [16][]const u8 = undefined;
    var spec_buf: [512]u8 = undefined;
    const spec = Spec{ .hash = "abc", .parent = "def", .repo = "/r", .path = "b.txt", .previous_path = "a.txt" };
    const old = contentArgs(&buf, &spec_buf, spec.parent, spec.previous_path).?;
    try testing.expectEqualStrings("show", old[0]);
    try testing.expectEqualStrings("def:a.txt", old[old.len - 1]);
    const new = contentArgs(&buf, &spec_buf, spec.hash, spec.path).?;
    try testing.expectEqualStrings("abc:b.txt", new[new.len - 1]);
    try testing.expect(contentArgs(&buf, &spec_buf, "", "a.txt") == null);

    // Mit Vorgänger: git diff <vorher> <commit> — die Timeline vergleicht mit dem vorigen
    // Commit der Datei, der nicht der Eltern-Commit sein muss
    const h = hunkArgs(&buf, &spec_buf, spec);
    try testing.expectEqualStrings("diff", h[0]);
    try testing.expect(containsArg(h, "-U0"));
    try testing.expect(containsArg(h, "-M"));
    try testing.expectEqualStrings("def", h[h.len - 5]);
    try testing.expectEqualStrings("abc", h[h.len - 4]);
    try testing.expectEqualStrings(":(top)b.txt", h[h.len - 2]);
    try testing.expectEqualStrings(":(top)a.txt", h[h.len - 1]);

    // Ohne Vorgänger (Wurzel / erster Commit der Datei): git show gegen den leeren Stand
    var root = spec;
    root.parent = "";
    const r = hunkArgs(&buf, &spec_buf, root);
    try testing.expectEqualStrings("show", r[0]);
    try testing.expect(containsArg(r, "abc"));
}

fn containsArg(args: []const []const u8, arg: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, arg)) return true;
    return false;
}

const test_tab = "git-diff://abc1234\x1fdef5678\x1f/r\x1fx.txt\x1fx.txt";

fn loadedState() !DiffState {
    var s = try DiffState.init(testing.allocator, test_tab);
    errdefer s.deinit();
    try testing.expect(s.takeRequest());
    // alt: 30 Zeilen z0..z29, neu: Zeile 15 geändert, nach Zeile 20 eine eingefügt
    var old: std.ArrayListUnmanaged(u8) = .empty;
    defer old.deinit(testing.allocator);
    var new: std.ArrayListUnmanaged(u8) = .empty;
    defer new.deinit(testing.allocator);
    for (0..30) |i| {
        try old.writer(testing.allocator).print("z{d}\n", .{i});
        if (i == 15) try new.appendSlice(testing.allocator, "geändert\n") else try new.writer(testing.allocator).print("z{d}\n", .{i});
        if (i == 20) try new.appendSlice(testing.allocator, "neu\n");
    }
    const body = try encodeContents(testing.allocator, old.items, new.items, "@@ -16 +16 @@\n@@ -21,0 +22 @@\n");
    defer testing.allocator.free(body);
    try s.apply(true, body);
    return s;
}

test "DiffState: lädt einmal, baut Zeilen für beide Layouts, zeigt ohne Einklappen alles" {
    var s = try loadedState();
    defer s.deinit();
    try testing.expect(!s.takeRequest());
    try testing.expect(s.loaded and !s.loading);
    try testing.expectEqual(@as(usize, 30), s.old_lines.len);
    try testing.expectEqual(@as(usize, 31), s.new_lines.len);
    try testing.expectEqualStrings("x.txt (def5678) \u{2194} x.txt (abc1234)", s.title_text);
    try testing.expectEqual(@as(usize, 31), s.rows(.side_by_side).len);
    try testing.expectEqual(@as(usize, 32), s.rows(.inline_).len); // geänderte Zeile doppelt
    try testing.expectEqual(@as(usize, 31), (try s.items(.side_by_side)).len);
    try testing.expectEqual(@as(usize, 2), s.stats().changes);
    try testing.expectEqual(@as(usize, 2), s.stats().added);
    try testing.expectEqual(@as(usize, 1), s.stats().removed);
}

test "DiffState: Layout automatisch nach Breite oder fest gewählt" {
    var s = try DiffState.init(testing.allocator, test_tab);
    defer s.deinit();
    try testing.expectEqual(Layout.side_by_side, s.layoutFor(1000));
    try testing.expectEqual(Layout.inline_, s.layoutFor(800));
    s.mode = .inline_;
    try testing.expectEqual(Layout.inline_, s.layoutFor(1000));
    s.mode = .side_by_side;
    try testing.expectEqual(Layout.side_by_side, s.layoutFor(800));
}

test "DiffState: Einklappen umschalten, Faltbereich aufdecken" {
    var s = try loadedState();
    defer s.deinit();
    s.toggleCollapse();
    const folded = try s.items(.side_by_side);
    // 0..11 verborgen, 12..24 sichtbar (Änderungen bei 15 und 21), 25..30 verborgen
    try testing.expectEqual(Item{ .fold = .{ .first = 0, .count = 12 } }, folded[0]);
    try testing.expectEqual(Item{ .row = 12 }, folded[1]);
    try testing.expectEqual(Item{ .fold = .{ .first = 25, .count = 6 } }, folded[folded.len - 1]);

    try s.revealFold(.side_by_side, 0, 12);
    const after = try s.items(.side_by_side);
    try testing.expectEqual(Item{ .row = 0 }, after[0]);

    s.toggleCollapse();
    try testing.expectEqual(@as(usize, 31), (try s.items(.side_by_side)).len);
}

test "DiffState: nächste/vorige Änderung liefert den Eintrag, zyklisch" {
    var s = try loadedState();
    defer s.deinit();
    try testing.expectEqual(@as(?usize, 15), try s.goNext(.side_by_side));
    try testing.expectEqual(@as(?usize, 21), try s.goNext(.side_by_side));
    try testing.expectEqual(@as(?usize, 15), try s.goNext(.side_by_side));
    try testing.expectEqual(@as(?usize, 21), try s.goPrev(.side_by_side));
    // eingeklappt: Eintragsindex statt Zeilenindex (Faltbalken 0 + Zeilen 12..)
    s.toggleCollapse();
    s.current_row = null;
    try testing.expectEqual(@as(?usize, 4), try s.goNext(.side_by_side));
}

test "DiffState: Fehler von git wird gemerkt" {
    var s = try DiffState.init(testing.allocator, test_tab);
    defer s.deinit();
    _ = s.takeRequest();
    try s.apply(false, "fatal: bad object");
    try testing.expectEqualStrings("fatal: bad object", s.error_text.?);
    try testing.expect(!s.loaded);
}

test "columnSlice: Byte-Bereich ab Spalte für n Spalten, Tabs zählen 4, UTF-8 ganz" {
    try testing.expectEqual(ByteRange{ .start = 2, .end = 5 }, columnSlice("abcdefg", 2, 3));
    try testing.expectEqual(ByteRange{ .start = 7, .end = 7 }, columnSlice("abcdefg", 20, 3));
    // "ä" = 2 Bytes, eine Spalte
    try testing.expectEqual(ByteRange{ .start = 1, .end = 4 }, columnSlice("aäbc", 1, 2));
    // Tab = 4 Spalten: ab Spalte 4 beginnt "x"
    try testing.expectEqual(ByteRange{ .start = 1, .end = 2 }, columnSlice("\tx", 4, 10));
}

test "Index (Staged Changes) wie VS Code: Titel „name (Index)“, Inhalt :pfad, Hunks --cached" {
    const spec = Spec{ .hash = index_ref, .parent = "HEAD", .repo = "/r", .path = "a.zig", .previous_path = "a.zig" };
    const t = try specTitle(testing.allocator, spec);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("a.zig (Index)", t);

    var buf: [16][]const u8 = undefined;
    var spec_buf: [512]u8 = undefined;
    const new = contentArgs(&buf, &spec_buf, spec.hash, spec.path).?;
    try testing.expectEqualStrings(":a.zig", new[new.len - 1]);
    const old = contentArgs(&buf, &spec_buf, spec.parent, spec.previous_path).?;
    try testing.expectEqualStrings("HEAD:a.zig", old[old.len - 1]);
    const h = hunkArgs(&buf, &spec_buf, spec);
    try testing.expectEqualStrings("diff", h[0]);
    try testing.expect(containsArg(h, "--cached"));
    try testing.expect(containsArg(h, "HEAD"));
    try testing.expect(!containsArg(h, index_ref));
}

test "splitLines: Zeilen ohne Umbruch, letzte leere Zeile nach \\n zählt nicht, CR weg" {
    const lines = try splitLines(testing.allocator, "a\r\nb\n\nc\n");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("", lines[2]);
    try testing.expectEqualStrings("c", lines[3]);
    const empty = try splitLines(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
