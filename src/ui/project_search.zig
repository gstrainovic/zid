//! Suche im ganzen Projekt (Ctrl+Shift+F) wie VS Code: ripgrep (`rg --json`) sucht, zid
//! gruppiert die Treffer je Datei und ersetzt selbst. Hier nur Logik ohne Clay: Argumente,
//! JSON-Zeilen, Ergebnisbaum, Byte-Ersetzungen und der Hintergrund-Lauf von rg.
//! Gezeichnet wird in `search_view.zig`.

const std = @import("std");

pub const Options = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
    regex: bool = false,
};

/// Höchstzahl Treffer je Suche (VS Code `DEFAULT_MAX_SEARCH_RESULTS`).
pub const MAX_RESULTS: usize = 20_000;
/// Vorschau einer Trefferzeile: längere Zeilen (minifizierte Dateien) werden gekürzt.
pub const MAX_PREVIEW_BYTES: usize = 4096;

pub const MAX_ARGS = 24;

/// rg-Argumente. `replace` setzt `-r`, dann liefert rg je Treffer den fertigen Ersatztext
/// (mit Gruppen `$1` bei Regex). Ohne Regex ist der Ersatztext wörtlich gemeint, `$` wird
/// deshalb verdoppelt; dafür braucht `escape_buf` Platz (doppelte Länge reicht).
/// `path` ist der Suchort, `.` für den Ordner (cwd) oder `-` für stdin.
pub fn buildArgs(
    out: *[MAX_ARGS][]const u8,
    rg: []const u8,
    query: []const u8,
    replace: ?[]const u8,
    opts: Options,
    path: []const u8,
    escape_buf: []u8,
) []const []const u8 {
    var n: usize = 0;
    const fixed = [_][]const u8{
        rg,
        "--json",
        "--no-config",
        // Versteckte Dateien (.github/…) durchsuchen, .git selbst nicht; .gitignore gilt auch
        // ohne Repo — dieselben Schalter wie VS Code (ripgrepTextSearchEngine.getRgArgs)
        "--hidden",
        "--glob=!.git",
        "--no-require-git",
        // Fehler beim Öffnen einzelner Dateien (Rechte) nicht auf stderr, Regex-Fehler schon
        "--no-messages",
        // `$` passt auch vor \r\n
        "--crlf",
    };
    for (fixed) |a| {
        out[n] = a;
        n += 1;
    }
    out[n] = if (opts.case_sensitive) "--case-sensitive" else "--ignore-case";
    n += 1;
    if (!opts.regex) {
        out[n] = "--fixed-strings";
        n += 1;
    }
    if (opts.whole_word) {
        out[n] = "--word-regexp";
        n += 1;
    }
    if (replace) |r| {
        const text = if (opts.regex) r else (escapeReplacement(escape_buf, r) orelse r);
        out[n] = "-r";
        out[n + 1] = text;
        n += 2;
    }
    out[n] = "--";
    out[n + 1] = query;
    out[n + 2] = path;
    n += 3;
    return out[0..n];
}

/// `$` → `$$` (rg-Ersatztext wörtlich). Liefert null, wenn `buf` zu klein ist.
pub fn escapeReplacement(buf: []u8, text: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (text) |c| {
        const need: usize = if (c == '$') 2 else 1;
        if (n + need > buf.len) return null;
        buf[n] = c;
        if (c == '$') buf[n + 1] = '$';
        n += need;
    }
    return buf[0..n];
}

pub const Sub = struct {
    /// Bytes innerhalb der Zeile
    start: u32,
    end: u32,
    /// Ersatztext von rg (nur mit `-r`)
    replacement: ?[]const u8 = null,
};

/// Eine Treffer-Zeile aus `rg --json` (Typ "match"). Speicher gehört dem Allocator von
/// `parseMatch` (Arena empfohlen).
pub const LineMatch = struct {
    path: []const u8,
    /// 0-basiert
    row: u32,
    /// Byte-Offset des Zeilenanfangs in der Datei
    offset: u64,
    /// Zeile ohne `\r\n`, auf `MAX_PREVIEW_BYTES` gekürzt
    line: []const u8,
    subs: []Sub,
};

/// Eine Ausgabezeile von `rg --json`; null für andere Typen (begin, end, summary, context).
pub fn parseMatch(alloc: std.mem.Allocator, json_line: []const u8) !?LineMatch {
    // Schneller Ausschluss ohne JSON-Parser: begin/end/summary sind die Mehrheit der Zeilen
    if (std.mem.indexOf(u8, json_line, "\"type\":\"match\"") == null) return null;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_line, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const ty = root.object.get("type") orelse return null;
    if (ty != .string or !std.mem.eql(u8, ty.string, "match")) return null;
    const data = root.object.get("data") orelse return null;
    if (data != .object) return null;

    const path = try textOrBytes(alloc, data.object.get("path")) orelse return null;
    const full = try textOrBytes(alloc, data.object.get("lines")) orelse return null;
    var line = std.mem.trimRight(u8, full, "\r\n");
    if (line.len > MAX_PREVIEW_BYTES) line = line[0..MAX_PREVIEW_BYTES];
    const line_number = intField(data, "line_number") orelse return null;
    const offset = intField(data, "absolute_offset") orelse return null;

    var subs: std.ArrayList(Sub) = .empty;
    if (data.object.get("submatches")) |sm| if (sm == .array) for (sm.array.items) |s| {
        if (s != .object) continue;
        const start = intField(s, "start") orelse continue;
        const end = intField(s, "end") orelse continue;
        if (end > line.len) continue; // hinter der gekürzten Vorschau
        try subs.append(alloc, .{
            .start = @intCast(start),
            .end = @intCast(end),
            .replacement = try textOrBytes(alloc, s.object.get("replacement")),
        });
    };
    return .{
        .path = path,
        .row = @intCast(line_number -| 1),
        .offset = offset,
        .line = line,
        .subs = try subs.toOwnedSlice(alloc),
    };
}

fn intField(v: std.json.Value, name: []const u8) ?u64 {
    const f = v.object.get(name) orelse return null;
    return switch (f) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

/// rg kodiert Pfade und Zeilen als `{"text": …}` oder, wenn kein gültiges UTF-8, als
/// `{"bytes": base64}`. Kopie im Allocator.
fn textOrBytes(alloc: std.mem.Allocator, v: ?std.json.Value) !?[]const u8 {
    const obj = v orelse return null;
    if (obj != .object) return null;
    if (obj.object.get("text")) |t| if (t == .string) return try alloc.dupe(u8, t.string);
    if (obj.object.get("bytes")) |b| if (b == .string) {
        const dec = std.base64.standard.Decoder;
        const len = dec.calcSizeForSlice(b.string) catch return null;
        const out = try alloc.alloc(u8, len);
        dec.decode(out, b.string) catch return null;
        return out;
    };
    return null;
}

/// Ersetzung auf Byte-Ebene. `expect` ist der Text, der dort stehen muss.
pub const Edit = struct {
    start: u64,
    end: u64,
    expect: []const u8,
    replacement: []const u8,
};

/// Wendet aufsteigend sortierte, nicht überlappende Ersetzungen an. `error.Stale`, wenn der
/// Inhalt an einer Stelle nicht mehr dem Treffer entspricht (Datei inzwischen geändert).
pub fn applyEdits(alloc: std.mem.Allocator, content: []const u8, edits: []const Edit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    for (edits) |e| {
        if (e.end < e.start or e.end > content.len or e.start < pos) return error.Stale;
        const s: usize = @intCast(e.start);
        const t: usize = @intCast(e.end);
        if (!std.mem.eql(u8, content[s..t], e.expect)) return error.Stale;
        try out.appendSlice(alloc, content[pos..s]);
        try out.appendSlice(alloc, e.replacement);
        pos = t;
    }
    try out.appendSlice(alloc, content[pos..]);
    return out.toOwnedSlice(alloc);
}

pub const FileResult = struct {
    /// relativ zum Suchordner, wie rg ihn meldet
    path: []const u8,
    lines: std.ArrayList(LineMatch) = .empty,
    collapsed: bool = false,
    /// Treffer (Teiltreffer aller Zeilen)
    count: usize = 0,
};

/// Eine sichtbare Zeile im Ergebnisbaum: Dateikopf oder ein einzelner Treffer. Wie VS Code
/// steht jeder Treffer in einer eigenen Zeile, auch mehrere in derselben Textzeile.
pub const Row = union(enum) {
    file: u32,
    match: MatchRef,
};

pub const MatchRef = struct { file: u32, line: u32, sub: u32 };

/// Ergebnisbaum einer Suche. Alle Texte liegen in der eigenen Arena.
pub const Results = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    files: std.ArrayList(FileResult) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    rows: std.ArrayList(Row) = .empty,
    match_count: usize = 0,
    /// neue Dateien seit dem letzten `rebuildRows`
    unsorted: bool = false,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Self) void {
        self.files.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn clear(self: *Self) void {
        self.files.clearRetainingCapacity(); // Zeilenlisten liegen in der Arena
        self.index.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.match_count = 0;
        self.unsorted = false;
        _ = self.arena.reset(.retain_capacity);
    }

    /// Treffer-Zeile übernehmen (Kopie). Zeilen ohne Teiltreffer zählen nicht.
    pub fn add(self: *Self, m: LineMatch) !void {
        if (m.subs.len == 0) return;
        const a = self.arena.allocator();
        const fi = self.index.get(m.path) orelse blk: {
            const path = try a.dupe(u8, m.path);
            const i: u32 = @intCast(self.files.items.len);
            try self.files.append(self.gpa, .{ .path = path });
            try self.index.put(self.gpa, path, i);
            self.unsorted = true;
            break :blk i;
        };
        var copy = m;
        copy.path = self.files.items[fi].path;
        copy.line = try a.dupe(u8, m.line);
        copy.subs = try a.dupe(Sub, m.subs);
        for (copy.subs) |*s| {
            if (s.replacement) |rep| s.replacement = try a.dupe(u8, rep);
        }
        const f = &self.files.items[fi];
        try f.lines.append(a, copy);
        f.count += copy.subs.len;
        self.match_count += copy.subs.len;
    }

    /// Flache Zeilenliste neu aufbauen (nach add, Auf-/Zuklappen, Verwerfen). Sortiert vorher
    /// die Dateien nach Pfad wie VS Code (search.sortOrder default); rg liefert sie parallel
    /// in wechselnder Reihenfolge. Datei-Indizes gelten erst danach.
    pub fn rebuildRows(self: *Self) !void {
        if (self.unsorted) {
            std.sort.pdq(FileResult, self.files.items, {}, lessPath);
            try self.reindex();
            self.unsorted = false;
        }
        self.rows.clearRetainingCapacity();
        for (self.files.items, 0..) |f, fi| {
            try self.rows.append(self.gpa, .{ .file = @intCast(fi) });
            if (f.collapsed) continue;
            for (f.lines.items, 0..) |l, li| {
                for (0..l.subs.len) |si| {
                    try self.rows.append(self.gpa, .{ .match = .{ .file = @intCast(fi), .line = @intCast(li), .sub = @intCast(si) } });
                }
            }
        }
    }

    pub fn toggleCollapsed(self: *Self, file: u32) !void {
        if (file >= self.files.items.len) return;
        self.files.items[file].collapsed = !self.files.items[file].collapsed;
        try self.rebuildRows();
    }

    pub fn setAllCollapsed(self: *Self, collapsed: bool) !void {
        for (self.files.items) |*f| f.collapsed = collapsed;
        try self.rebuildRows();
    }

    pub fn dismissMatch(self: *Self, ref: MatchRef) !void {
        if (ref.file >= self.files.items.len) return;
        const f = &self.files.items[ref.file];
        if (ref.line >= f.lines.items.len) return;
        const l = &f.lines.items[ref.line];
        if (ref.sub >= l.subs.len) return;
        std.mem.copyForwards(Sub, l.subs[ref.sub..], l.subs[ref.sub + 1 ..]);
        l.subs = l.subs[0 .. l.subs.len - 1];
        f.count -= 1;
        self.match_count -= 1;
        if (l.subs.len == 0) _ = f.lines.orderedRemove(ref.line);
        if (f.lines.items.len == 0) return self.dismissFile(ref.file);
        try self.rebuildRows();
    }

    pub fn dismissFile(self: *Self, file: u32) !void {
        if (file >= self.files.items.len) return;
        const removed = self.files.orderedRemove(file);
        self.match_count -= removed.count;
        try self.reindex();
        try self.rebuildRows();
    }

    fn lessPath(_: void, a: FileResult, b: FileResult) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }

    fn reindex(self: *Self) !void {
        self.index.clearRetainingCapacity();
        for (self.files.items, 0..) |f, i| try self.index.put(self.gpa, f.path, @intCast(i));
    }

    /// Ersetzungen eines Treffers bzw. aller Treffer einer Datei (aufsteigend). `fallback`
    /// gilt, wenn rg keinen Ersatztext geliefert hat (Suche lief ohne `-r`).
    pub fn matchEdit(self: *const Self, ref: MatchRef, fallback: []const u8) Edit {
        const l = self.files.items[ref.file].lines.items[ref.line];
        return subEdit(l, l.subs[ref.sub], fallback);
    }

    pub fn fileEdits(self: *const Self, alloc: std.mem.Allocator, file: u32, fallback: []const u8) ![]Edit {
        var out: std.ArrayList(Edit) = .empty;
        errdefer out.deinit(alloc);
        for (self.files.items[file].lines.items) |l| {
            for (l.subs) |s| try out.append(alloc, subEdit(l, s, fallback));
        }
        return out.toOwnedSlice(alloc);
    }

    fn subEdit(l: LineMatch, s: Sub, fallback: []const u8) Edit {
        return .{
            .start = l.offset + s.start,
            .end = l.offset + s.end,
            .expect = l.line[s.start..s.end],
            .replacement = s.replacement orelse fallback,
        };
    }
};

/// Ausschnitt einer Trefferzeile für die Liste: Text vor dem Treffer, Treffer, Text danach.
/// Wie VS Code: führender Leerraum fällt weg, und vor dem Treffer bleiben höchstens
/// `max_before` Zeichen stehen, das „…“ mitgezählt (`elided` = davor wurde gekürzt).
pub const Preview = struct {
    before: []const u8,
    match: []const u8,
    after: []const u8,
    elided: bool,
};

pub fn preview(line: []const u8, sub: Sub, max_before: usize) Preview {
    const s = @min(sub.start, line.len);
    const e = @min(@max(sub.end, s), line.len);
    var begin: usize = 0;
    while (begin < s and (line[begin] == ' ' or line[begin] == '\t')) begin += 1;
    var chars: usize = 0;
    var i = begin;
    while (i < s) : (i += std.unicode.utf8ByteSequenceLength(line[i]) catch 1) chars += 1;
    var elided = false;
    if (chars > max_before) {
        // So viele Zeichen überspringen, dass mit dem „…“ `max_before` bleiben
        var skip = chars - (max_before -| 1);
        while (skip > 0 and begin < s) : (skip -= 1) {
            begin += std.unicode.utf8ByteSequenceLength(line[begin]) catch 1;
        }
        elided = true;
    }
    return .{ .before = line[begin..s], .match = line[s..e], .after = line[e..], .elided = elided };
}

/// Offener Buffer mit ungespeicherten Änderungen: wird statt der Datei durchsucht (wie VS
/// Code und Zed). `path` relativ zum Suchordner, `/` als Trenner.
pub const DirtyBuffer = struct { path: []const u8, text: []const u8 };

pub const Query = struct {
    rg: []const u8,
    root: []const u8,
    text: []const u8,
    replace: ?[]const u8 = null,
    opts: Options = .{},
    dirty: []const DirtyBuffer = &.{},
};

pub const Poll = struct {
    /// neue Treffer übernommen
    changed: bool = false,
    /// Lauf dieser Generation ist fertig (auch nach Fehler oder Limit)
    finished: bool = false,
};

fn cloneMatch(a: std.mem.Allocator, m: LineMatch, path: []const u8) !LineMatch {
    var copy = m;
    copy.path = try a.dupe(u8, path);
    copy.line = try a.dupe(u8, m.line);
    copy.subs = try a.dupe(Sub, m.subs);
    for (copy.subs) |*s| {
        if (s.replacement) |rep| s.replacement = try a.dupe(u8, rep);
    }
    return copy;
}

/// rg meldet Pfade unter `.` als `./a/b` (Windows `.\a\b`): Präfix weg, `/` als Trenner.
fn normalizePath(buf: []u8, path: []const u8) []const u8 {
    var p = path;
    if (p.len >= 2 and p[0] == '.' and (p[1] == '/' or p[1] == '\\')) p = p[2..];
    const n = @min(p.len, buf.len);
    for (p[0..n], 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    return buf[0..n];
}

/// rg im Hintergrund-Thread. `start` bricht einen laufenden Lauf ab (Prozess beenden),
/// `poll` übergibt neue Treffer im Main-Thread an `Results`.
pub const Runner = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    /// Jeder Start erhöht die Generation; ein Worker mit älterer Generation liefert nichts mehr.
    generation: std.atomic.Value(u32) = .init(0),
    mutex: std.Thread.Mutex = .{},
    // ── unter `mutex` ──
    batch_arena: ?std.heap.ArenaAllocator = null,
    batch: std.ArrayList(LineMatch) = .empty,
    done_generation: u32 = 0,
    err: ?[]u8 = null,
    limit: bool = false,
    child_id: ?std.process.Child.Id = null,
    total: usize = 0,

    const Job = struct {
        arena: std.heap.ArenaAllocator,
        q: Query,
        generation: u32,
    };

    pub fn init(gpa: std.mem.Allocator) Runner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Runner) void {
        self.cancel();
        if (self.thread) |t| t.join();
        self.thread = null;
        self.batch.deinit(self.gpa);
        if (self.batch_arena) |*a| a.deinit();
        if (self.err) |e| self.gpa.free(e);
    }

    /// Neue Suche. Der Aufrufer leert seine `Results` selbst.
    pub fn start(self: *Runner, q: Query) !void {
        self.cancel();
        if (self.thread) |t| t.join();
        self.thread = null;

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var copy = q;
        copy.rg = try a.dupe(u8, q.rg);
        copy.root = try a.dupe(u8, q.root);
        copy.text = try a.dupe(u8, q.text);
        if (q.replace) |r| copy.replace = try a.dupe(u8, r);
        const dirty = try a.alloc(DirtyBuffer, q.dirty.len);
        for (q.dirty, dirty) |d, *o| o.* = .{ .path = try a.dupe(u8, d.path), .text = try a.dupe(u8, d.text) };
        copy.dirty = dirty;

        const gen = self.generation.load(.acquire);
        self.mutex.lock();
        self.batch.clearRetainingCapacity();
        if (self.batch_arena) |*ba| _ = ba.reset(.retain_capacity) else self.batch_arena = std.heap.ArenaAllocator.init(self.gpa);
        if (self.err) |e| self.gpa.free(e);
        self.err = null;
        self.limit = false;
        self.total = 0;
        self.mutex.unlock();

        const job = try self.gpa.create(Job);
        errdefer self.gpa.destroy(job);
        job.* = .{ .arena = arena, .q = copy, .generation = gen };
        self.thread = try std.Thread.spawn(.{}, work, .{ self, job });
    }

    /// Laufenden Lauf abbrechen: Generation weiter, rg beenden.
    pub fn cancel(self: *Runner) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.child_id) |id| killChild(id);
    }

    fn killChild(id: std.process.Child.Id) void {
        if (@import("builtin").os.tag == .windows) {
            std.os.windows.TerminateProcess(id, 1) catch {};
        } else {
            std.posix.kill(id, std.posix.SIG.TERM) catch {};
        }
    }

    fn current(self: *const Runner, gen: u32) bool {
        return self.generation.load(.acquire) == gen;
    }

    pub fn poll(self: *Runner, results: *Results) Poll {
        var out: Poll = .{};
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.batch.items.len > 0) {
            for (self.batch.items) |m| results.add(m) catch break;
            self.batch.clearRetainingCapacity();
            if (self.batch_arena) |*ba| _ = ba.reset(.retain_capacity);
            out.changed = true;
        }
        out.finished = self.done_generation == self.generation.load(.acquire);
        return out;
    }

    /// Neue Treffer oder das Ende des aktuellen Laufs liegen bereit.
    pub fn hasOutput(self: *Runner) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.batch.items.len > 0 or self.done_generation == self.generation.load(.acquire);
    }

    pub fn running(self: *Runner) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.thread != null and self.done_generation != self.generation.load(.acquire);
    }

    /// Fehlermeldung des letzten Laufs (rg fehlt, Regex ungültig), sonst null. Gültig bis
    /// zum nächsten `start`.
    pub fn errorText(self: *Runner) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.err;
    }

    pub fn limitHit(self: *Runner) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.limit;
    }

    fn setError(self: *Runner, gen: u32, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.current(gen) or self.err != null) return;
        self.err = self.gpa.dupe(u8, msg) catch null;
    }

    fn work(self: *Runner, job: *Job) void {
        defer {
            job.arena.deinit();
            self.gpa.destroy(job);
        }
        const gen = job.generation;
        self.runOne(job, null);
        for (job.q.dirty) |*d| {
            if (!self.current(gen)) break;
            self.runOne(job, d);
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.current(gen)) self.done_generation = gen;
    }

    fn isDirty(job: *const Job, path: []const u8) bool {
        for (job.q.dirty) |d| if (std.mem.eql(u8, d.path, path)) return true;
        return false;
    }

    /// Ein rg-Aufruf: über den Ordner (`dirty` null) oder über einen Buffer per stdin.
    fn runOne(self: *Runner, job: *Job, dirty: ?*const DirtyBuffer) void {
        const gen = job.generation;
        const q = job.q;
        var argv_buf: [MAX_ARGS][]const u8 = undefined;
        const esc = job.arena.allocator().alloc(u8, if (q.replace) |r| r.len * 2 else 0) catch return;
        const argv = buildArgs(&argv_buf, q.rg, q.text, q.replace, q.opts, if (dirty != null) "-" else ".", esc);

        var child = std.process.Child.init(argv, self.gpa);
        child.cwd = q.root;
        child.stdin_behavior = if (dirty != null) .Pipe else .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        spawnChecked(&child) catch |err| {
            if (err == error.FileNotFound)
                self.setError(gen, "ripgrep (rg) not found. Install ripgrep to search in files.")
            else
                self.setError(gen, "ripgrep could not be started.");
            return;
        };
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.current(gen)) self.child_id = child.id else killChild(child.id);
        }
        // Vor `wait` austragen: nach dem Einsammeln kann die PID neu vergeben sein, und ein
        // `cancel` träfe dann einen fremden Prozess
        var registered = true;
        defer if (registered) self.forgetChild();

        // Buffer in eigenem Thread schreiben: rg schreibt Treffer, während es noch liest,
        // und eine volle stdout-Pipe hielte sonst beide Seiten an.
        var writer_thread: ?std.Thread = null;
        if (dirty) |d| {
            const stdin = child.stdin.?;
            child.stdin = null;
            writer_thread = std.Thread.spawn(.{}, writeAndClose, .{ stdin, d.text }) catch blk: {
                writeAndClose(stdin, d.text);
                break :blk null;
            };
        }
        defer if (writer_thread) |t| t.join();

        self.readMatches(job, &child, dirty);

        var err_text: []const u8 = "";
        var err_buf: [2048]u8 = undefined;
        if (child.stderr) |f| {
            const n = f.readAll(&err_buf) catch 0;
            err_text = std.mem.trim(u8, err_buf[0..n], " \r\n");
        }
        self.forgetChild();
        registered = false;
        const term = child.wait() catch return;
        // Exit 1 = keine Treffer; 2 = Fehler (Regex, Argumente). Nach Abbruch zählt nichts.
        if (term == .Exited and term.Exited == 2 and err_text.len > 0) {
            var msg_buf: [512]u8 = undefined;
            self.setError(gen, oneLine(&msg_buf, err_text));
        }
    }

    /// Unter POSIX gelingt `spawn` schon nach dem fork; dass exec scheiterte (rg fehlt),
    /// meldet erst `waitForSpawn`. `wait` räumt danach nicht auf (kehrt mit dem Fehler vorher
    /// zurück), deshalb Kind einsammeln und Pipes hier schließen.
    fn spawnChecked(child: *std.process.Child) !void {
        try child.spawn();
        child.waitForSpawn() catch |err| {
            if (@import("builtin").os.tag != .windows) _ = std.posix.waitpid(child.id, 0);
            inline for (.{ "stdin", "stdout", "stderr" }) |name| {
                if (@field(child, name)) |f| f.close();
                @field(child, name) = null;
            }
            return err;
        };
    }

    fn forgetChild(self: *Runner) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child_id = null;
    }

    fn writeAndClose(file: std.fs.File, text: []const u8) void {
        file.writeAll(text) catch {};
        file.close();
    }

    fn readMatches(self: *Runner, job: *Job, child: *std.process.Child, dirty: ?*const DirtyBuffer) void {
        const gen = job.generation;
        const stdout = child.stdout orelse return;
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = stdout.readerStreaming(&read_buf);
        const r = &reader.interface;
        var line_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer line_arena.deinit();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (true) {
            const line = r.takeDelimiter('\n') catch |err| switch (err) {
                // Zeile länger als der Puffer (riesige minifizierte Zeile): überspringen
                error.StreamTooLong => {
                    _ = r.discardDelimiterInclusive('\n') catch break;
                    continue;
                },
                else => break,
            } orelse break;
            if (!self.current(gen)) break;
            _ = line_arena.reset(.retain_capacity);
            const m = (parseMatch(line_arena.allocator(), line) catch continue) orelse continue;
            const path = if (dirty) |d| d.path else normalizePath(&path_buf, m.path);
            if (dirty == null and isDirty(job, path)) continue;

            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.current(gen)) break;
            const ba = if (self.batch_arena) |*x| x else break;
            const copy = cloneMatch(ba.allocator(), m, path) catch break;
            self.batch.append(self.gpa, copy) catch break;
            self.total += m.subs.len;
            if (self.total >= MAX_RESULTS) {
                self.limit = true;
                killChild(child.id);
                break;
            }
        }
    }

    /// Mehrzeilige rg-Meldung („regex parse error:\n    (\n    ^\nerror: unclosed group“)
    /// als eine Zeile, Leerraum zusammengefasst.
    fn oneLine(buf: []u8, text: []const u8) []const u8 {
        var n: usize = 0;
        var space = false;
        var rest = text;
        if (std.mem.startsWith(u8, rest, "rg: ")) rest = rest[4..];
        for (rest) |c| {
            if (n >= buf.len) break;
            if (c == '\n' or c == '\r' or c == ' ' or c == '\t') {
                space = n > 0;
                continue;
            }
            if (space and n < buf.len) {
                buf[n] = ' ';
                n += 1;
                space = false;
                if (n >= buf.len) break;
            }
            buf[n] = c;
            n += 1;
        }
        return buf[0..n];
    }
};

// ───────────────────────────── Tests ─────────────────────────────

test "preview: Einrückung weg, langer Vorlauf gekürzt, UTF-8 bleibt ganz" {
    const p = preview("        const x = foo();", .{ .start = 18, .end = 21 }, 30);
    try testing.expectEqualStrings("const x = ", p.before);
    try testing.expectEqualStrings("foo", p.match);
    try testing.expectEqualStrings("();", p.after);
    try testing.expect(!p.elided);

    // „ä“ ist zwei Bytes; gekürzt wird nach Zeichen, nie mitten im Zeichen
    const line = "ääääääääää foo";
    const q = preview(line, .{ .start = 21, .end = 24 }, 4);
    try testing.expectEqualStrings("ää ", q.before);
    try testing.expect(q.elided);
    try testing.expectEqualStrings("foo", q.match);

    // Treffer ganz am Anfang, Treffer auf Leerraum
    const r = preview("foo", .{ .start = 0, .end = 3 }, 10);
    try testing.expectEqualStrings("", r.before);
    try testing.expectEqualStrings("", r.after);
    const s = preview("   x", .{ .start = 1, .end = 2 }, 10);
    try testing.expectEqualStrings(" ", s.match);
}

fn rgAvailable() bool {
    var child = std.process.Child.init(&.{ "rg", "--version" }, testing.allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return term == .Exited and term.Exited == 0;
}

fn runToEnd(runner: *Runner, results: *Results) !void {
    var waited: usize = 0;
    while (waited < 500) : (waited += 1) {
        if (runner.poll(results).finished) {
            try results.rebuildRows();
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn fileIndex(r: *const Results, path: []const u8) ?usize {
    for (r.files.items, 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return i;
    return null;
}

test "Runner: sucht im Ordner, beachtet .gitignore, Pfade ohne ./" {
    if (!rgAvailable()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "foo\nbar foo\n" });
    try tmp.dir.makePath("sub");
    try tmp.dir.writeFile(.{ .sub_path = "sub/b.txt", .data = "Foo" });
    try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try tmp.dir.writeFile(.{ .sub_path = "ignored.txt", .data = "foo" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var results = Results.init(testing.allocator);
    defer results.deinit();
    var runner = Runner.init(testing.allocator);
    defer runner.deinit();
    try runner.start(.{ .rg = "rg", .root = root, .text = "foo" });
    try runToEnd(&runner, &results);
    try testing.expect(runner.errorText() == null);
    try testing.expectEqual(@as(usize, 2), results.files.items.len);
    try testing.expectEqual(@as(usize, 3), results.match_count);
    const a = fileIndex(&results, "a.txt") orelse return error.MissingFile;
    try testing.expectEqual(@as(u32, 1), results.files.items[a].lines.items[1].row);
    try testing.expect(fileIndex(&results, "sub/b.txt") != null);
    try testing.expect(fileIndex(&results, "ignored.txt") == null);
}

test "Runner: ungespeicherter Buffer ersetzt die Datei auf der Platte" {
    if (!rgAvailable()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "foo\nfoo\nfoo\n" });
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = "foo" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var results = Results.init(testing.allocator);
    defer results.deinit();
    var runner = Runner.init(testing.allocator);
    defer runner.deinit();
    const dirty = [_]DirtyBuffer{.{ .path = "a.txt", .text = "xx\nyy foo" }};
    try runner.start(.{ .rg = "rg", .root = root, .text = "foo", .replace = "bar", .dirty = &dirty });
    try runToEnd(&runner, &results);
    const a = fileIndex(&results, "a.txt") orelse return error.MissingFile;
    const lines = results.files.items[a].lines.items;
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(@as(u32, 1), lines[0].row);
    try testing.expectEqual(@as(u64, 3), lines[0].offset);
    try testing.expectEqualStrings("bar", lines[0].subs[0].replacement.?);
    try testing.expect(fileIndex(&results, "c.txt") != null);
}

test "Runner: ungültige Regex und fehlendes rg melden einen Fehler" {
    if (!rgAvailable()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "foo" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var results = Results.init(testing.allocator);
    defer results.deinit();
    var runner = Runner.init(testing.allocator);
    defer runner.deinit();
    try runner.start(.{ .rg = "rg", .root = root, .text = "(", .opts = .{ .regex = true } });
    try runToEnd(&runner, &results);
    try testing.expect(std.mem.indexOf(u8, runner.errorText().?, "regex") != null);

    try runner.start(.{ .rg = "/nonexistent/rg", .root = root, .text = "foo" });
    try runToEnd(&runner, &results);
    try testing.expect(std.mem.indexOf(u8, runner.errorText().?, "not found") != null);
}

test "Runner: neuer Start bricht den laufenden ab, alte Treffer kommen nicht an" {
    if (!rgAvailable()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "alpha\nbeta\n" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var results = Results.init(testing.allocator);
    defer results.deinit();
    var runner = Runner.init(testing.allocator);
    defer runner.deinit();
    try runner.start(.{ .rg = "rg", .root = root, .text = "alpha" });
    try runner.start(.{ .rg = "rg", .root = root, .text = "beta" });
    // hasOutput: neue Treffer oder Ende liegen bereit (die Liste tauscht erst dann aus)
    var waited: usize = 0;
    while (!runner.hasOutput() and waited < 500) : (waited += 1) std.Thread.sleep(10 * std.time.ns_per_ms);
    try testing.expect(runner.hasOutput());
    try runToEnd(&runner, &results);
    try testing.expectEqual(@as(usize, 1), results.match_count);
    try testing.expectEqualStrings("beta", results.files.items[0].lines.items[0].line);
}

fn testLine(path: []const u8, row: u32, offset: u64, line: []const u8, subs: []Sub) LineMatch {
    return .{ .path = path, .row = row, .offset = offset, .line = line, .subs = subs };
}

test "Results: gruppiert je Datei, ein Eintrag je Treffer, Zuklappen" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    var s1 = [_]Sub{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } };
    var s2 = [_]Sub{.{ .start = 2, .end = 5 }};
    var s3 = [_]Sub{.{ .start = 0, .end = 3 }};
    try r.add(testLine("a.zig", 0, 0, "foo foo", &s1));
    try r.add(testLine("b.zig", 4, 40, "x foo", &s2));
    try r.add(testLine("a.zig", 2, 20, "foo", &s3));
    try r.rebuildRows();
    try testing.expectEqual(@as(usize, 2), r.files.items.len);
    try testing.expectEqual(@as(usize, 4), r.match_count);
    try testing.expectEqual(@as(usize, 3), r.files.items[0].count);
    // a.zig, 3 Treffer, b.zig, 1 Treffer
    try testing.expectEqual(@as(usize, 6), r.rows.items.len);
    try testing.expectEqual(Row{ .file = 0 }, r.rows.items[0]);
    try testing.expectEqual(Row{ .match = .{ .file = 0, .line = 0, .sub = 1 } }, r.rows.items[2]);
    try testing.expectEqual(Row{ .match = .{ .file = 0, .line = 1, .sub = 0 } }, r.rows.items[3]);
    try testing.expectEqual(Row{ .file = 1 }, r.rows.items[4]);

    try r.toggleCollapsed(0);
    try testing.expectEqual(@as(usize, 3), r.rows.items.len);
    try r.setAllCollapsed(true);
    try testing.expectEqual(@as(usize, 2), r.rows.items.len);
    try r.setAllCollapsed(false);
    try testing.expectEqual(@as(usize, 6), r.rows.items.len);

    r.clear();
    try testing.expectEqual(@as(usize, 0), r.rows.items.len);
    try testing.expectEqual(@as(usize, 0), r.match_count);
}

test "Results: Dateien alphabetisch, egal in welcher Reihenfolge rg sie liefert" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    var s = [_]Sub{.{ .start = 0, .end = 1 }};
    try r.add(testLine("src/b.zig", 0, 0, "x", &s));
    try r.add(testLine("c.txt", 0, 0, "x", &s));
    try r.add(testLine("a.txt", 0, 0, "x", &s));
    try r.add(testLine("c.txt", 3, 9, "x", &s));
    try r.rebuildRows();
    try testing.expectEqualStrings("a.txt", r.files.items[0].path);
    try testing.expectEqualStrings("c.txt", r.files.items[1].path);
    try testing.expectEqualStrings("src/b.zig", r.files.items[2].path);
    try testing.expectEqual(@as(usize, 2), r.files.items[1].lines.items.len);
}

test "Results: Verwerfen von Treffer und Datei" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    var s1 = [_]Sub{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } };
    var s2 = [_]Sub{.{ .start = 2, .end = 5 }};
    try r.add(testLine("a.zig", 0, 0, "foo foo", &s1));
    try r.add(testLine("b.zig", 4, 40, "x foo", &s2));
    try r.rebuildRows();
    try r.dismissMatch(.{ .file = 0, .line = 0, .sub = 0 });
    try testing.expectEqual(@as(usize, 2), r.match_count);
    try testing.expectEqual(@as(usize, 1), r.files.items[0].count);
    // letzter Treffer der Datei weg: Datei verschwindet
    try r.dismissMatch(.{ .file = 0, .line = 0, .sub = 0 });
    try testing.expectEqual(@as(usize, 1), r.files.items.len);
    try testing.expectEqualStrings("b.zig", r.files.items[0].path);
    try testing.expectEqual(@as(usize, 2), r.rows.items.len);
    try r.dismissFile(0);
    try testing.expectEqual(@as(usize, 0), r.files.items.len);
    try testing.expectEqual(@as(usize, 0), r.match_count);
    // nach dem Verwerfen findet add eine neue Datei desselben Namens korrekt
    try r.add(testLine("a.zig", 0, 0, "foo foo", &s1));
    try testing.expectEqual(@as(usize, 1), r.files.items.len);
}

test "Results: Ersetzungen mit Ersatztext von rg oder Rückfall" {
    var r = Results.init(testing.allocator);
    defer r.deinit();
    var s1 = [_]Sub{ .{ .start = 0, .end = 3, .replacement = "X1" }, .{ .start = 4, .end = 7 } };
    try r.add(testLine("a.zig", 1, 10, "foo foo", &s1));
    const e = r.matchEdit(.{ .file = 0, .line = 0, .sub = 0 }, "fb");
    try testing.expectEqual(@as(u64, 10), e.start);
    try testing.expectEqual(@as(u64, 13), e.end);
    try testing.expectEqualStrings("foo", e.expect);
    try testing.expectEqualStrings("X1", e.replacement);
    const all = try r.fileEdits(testing.allocator, 0, "fb");
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(@as(u64, 14), all[1].start);
    try testing.expectEqualStrings("fb", all[1].replacement);
}

const testing = std.testing;

fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

test "buildArgs: wörtlich, Groß/Klein egal, Suchbegriff nach --" {
    var out: [MAX_ARGS][]const u8 = undefined;
    var esc: [64]u8 = undefined;
    const args = buildArgs(&out, "rg", "-foo", null, .{}, ".", &esc);
    try testing.expectEqualStrings("rg", args[0]);
    try testing.expect(argsContain(args, "--json"));
    try testing.expect(argsContain(args, "--fixed-strings"));
    try testing.expect(argsContain(args, "--ignore-case"));
    try testing.expect(argsContain(args, "--no-require-git"));
    try testing.expect(!argsContain(args, "--word-regexp"));
    try testing.expect(!argsContain(args, "-r"));
    // Suchbegriff darf mit '-' beginnen: steht hinter "--", danach der Ort
    try testing.expectEqualStrings("--", args[args.len - 3]);
    try testing.expectEqualStrings("-foo", args[args.len - 2]);
    try testing.expectEqualStrings(".", args[args.len - 1]);
}

test "buildArgs: Regex, Ganzwort, Groß/Klein, Ersatz mit Gruppen bleibt roh" {
    var out: [MAX_ARGS][]const u8 = undefined;
    var esc: [64]u8 = undefined;
    const args = buildArgs(&out, "/x/rg", "a(\\d)", "b$1", .{ .regex = true, .whole_word = true, .case_sensitive = true }, "-", &esc);
    try testing.expect(!argsContain(args, "--fixed-strings"));
    try testing.expect(argsContain(args, "--case-sensitive"));
    try testing.expect(argsContain(args, "--word-regexp"));
    try testing.expect(argsContain(args, "-r"));
    try testing.expect(argsContain(args, "b$1"));
    try testing.expectEqualStrings("-", args[args.len - 1]);
}

test "buildArgs: wörtlicher Ersatz verdoppelt $" {
    var out: [MAX_ARGS][]const u8 = undefined;
    var esc: [64]u8 = undefined;
    const args = buildArgs(&out, "rg", "x", "a$1$", .{}, ".", &esc);
    try testing.expect(argsContain(args, "a$$1$$"));
}

test "escapeReplacement" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("x$$y", escapeReplacement(&buf, "x$y").?);
    try testing.expectEqualStrings("", escapeReplacement(&buf, "").?);
    try testing.expect(escapeReplacement(&buf, "$$$$$") == null);
}

test "parseMatch: Treffer mit Ersatz, CRLF abgeschnitten" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line =
        \\{"type":"match","data":{"path":{"text":"src/a.zig"},"lines":{"text":"foo1 foo2\r\n"},"line_number":2,"absolute_offset":9,"submatches":[{"match":{"text":"foo1"},"replacement":{"text":"<foo1>"},"start":0,"end":4},{"match":{"text":"foo2"},"replacement":{"text":"<foo2>"},"start":5,"end":9}]}}
    ;
    const m = (try parseMatch(arena.allocator(), line)).?;
    try testing.expectEqualStrings("src/a.zig", m.path);
    try testing.expectEqual(@as(u32, 1), m.row);
    try testing.expectEqual(@as(u64, 9), m.offset);
    try testing.expectEqualStrings("foo1 foo2", m.line);
    try testing.expectEqual(@as(usize, 2), m.subs.len);
    try testing.expectEqual(@as(u32, 5), m.subs[1].start);
    try testing.expectEqual(@as(u32, 9), m.subs[1].end);
    try testing.expectEqualStrings("<foo2>", m.subs[1].replacement.?);
}

test "parseMatch: andere Typen null, Pfad als base64-Bytes, ohne Ersatz" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try parseMatch(a, "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"x\"}}}")) == null);
    try testing.expect((try parseMatch(a, "{\"type\":\"summary\",\"data\":{}}")) == null);
    // "b\xffc.txt" base64 = "Yv9jLnR4dA=="
    const line =
        \\{"type":"match","data":{"path":{"bytes":"Yv9jLnR4dA=="},"lines":{"text":"hit"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"hit"},"start":0,"end":3}]}}
    ;
    const m = (try parseMatch(a, line)).?;
    try testing.expectEqualStrings("b\xffc.txt", m.path);
    try testing.expectEqualStrings("hit", m.line);
    try testing.expect(m.subs[0].replacement == null);
}

test "parseMatch: lange Zeile wird gekürzt, Treffer dahinter fallen weg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = try a.alloc(u8, MAX_PREVIEW_BYTES + 100);
    @memset(long, 'x');
    const json = try std.fmt.allocPrint(a,
        \\{{"type":"match","data":{{"path":{{"text":"m.js"}},"lines":{{"text":"{s}"}},"line_number":1,"absolute_offset":0,"submatches":[{{"match":{{"text":"x"}},"start":0,"end":1}},{{"match":{{"text":"x"}},"start":{d},"end":{d}}}]}}}}
    , .{ long, MAX_PREVIEW_BYTES + 10, MAX_PREVIEW_BYTES + 11 });
    const m = (try parseMatch(a, json)).?;
    try testing.expectEqual(MAX_PREVIEW_BYTES, m.line.len);
    try testing.expectEqual(@as(usize, 1), m.subs.len);
}

test "applyEdits: mehrere Stellen, Länge ändert sich" {
    const out = try applyEdits(testing.allocator, "foo bar foo", &.{
        .{ .start = 0, .end = 3, .expect = "foo", .replacement = "x" },
        .{ .start = 8, .end = 11, .expect = "foo", .replacement = "yyyy" },
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x bar yyyy", out);
}

test "applyEdits: veralteter Inhalt oder Bereich außerhalb gibt Stale" {
    try testing.expectError(error.Stale, applyEdits(testing.allocator, "fox bar", &.{
        .{ .start = 0, .end = 3, .expect = "foo", .replacement = "x" },
    }));
    try testing.expectError(error.Stale, applyEdits(testing.allocator, "fo", &.{
        .{ .start = 0, .end = 3, .expect = "foo", .replacement = "x" },
    }));
}
