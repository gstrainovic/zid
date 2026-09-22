//! Thread-Pool Scheduler für async Tasks in zid.
//!
//! Main Thread: submit(task) → non-blocking
//! Main Thread: pollResults(buf) → non-blocking drain
//! Worker Threads: dürfen NIEMALS wio/wgpu/Clay anfassen.

const std = @import("std");

const log = std.log.scoped(.scheduler);

pub const ResultTag = enum {
    git_status,
    /// Repo gehört einem anderen Benutzer; Payload = Wert für `safe.directory`
    /// (git_worker.unsafeRepoDirectory), die UI fragt nach
    git_unsafe_repo,
    git_diff,
    git_branch,
    /// Payload `<tab_path>\n` + git_diff.encodeContents (git_worker.taskGitFileDiff)
    git_file_diff,
    git_file_diff_error,
    /// Payload `<datei>\n<repo-wurzel>\n<git log>` (git_worker.taskGitTimeline)
    git_timeline,
    git_timeline_error,
    /// Payload `<schlüssel>\n<kopf>\n<git log>` (git_worker.taskGitGraphLog)
    git_graph_log,
    git_graph_log_error,
    /// Payload `<schlüssel>\n<git diff --name-status>` (git_worker.taskGitCommitChanges)
    git_commit_changes,
    git_commit_changes_error,
    /// Payload `<schlüssel>\n<git diff --shortstat>` (git_worker.taskGitCommitStat, Graph-Hover)
    git_commit_stat,
    git_commit_stat_error,
    /// Payload `<aktion>\n<stderr>` (git_worker.taskGitAction: stage/unstage/discard/commit)
    git_action,
    git_action_error,
    git_blame,
    lsp_completion,
    lsp_diagnostics,
    lsp_hover,
    lsp_definition,
    file_changed,
    file_created,
    file_deleted,
    ai_chat_reply,
    ai_chat_error,
    /// „Generate Commit Message“: Antwort des Modells bzw. Fehlername (ChatParams.reply_tag/error_tag)
    ai_commit_message,
    ai_commit_message_error,
    /// Teilstück einer gestreamten Antwort (Worker pusht per pushResult)
    ai_chat_delta,
    /// Antwort per Escape abgebrochen; Payload = bisheriger Text
    ai_chat_cancelled,
    /// Modell will Werkzeuge: Payload = {"content": "...", "tool_calls": [OpenAI-Array]}
    ai_chat_tool_calls,
    ai_warmup_done,
    ai_warmup_error,
};

pub const TaskResult = struct {
    tag: ResultTag,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: TaskResult) void {
        self.allocator.free(self.payload);
    }
};

pub const Task = struct {
    func: *const fn (allocator: std.mem.Allocator, data: ?*anyopaque) anyerror!TaskResult,
    data: ?*anyopaque = null,
};

fn BoundedQueue(comptime T: type, comptime cap: usize) type {
    return struct {
        buf: [cap]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        const Self = @This();

        fn push(self: *Self, item: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == cap) return false;
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % cap;
            self.len += 1;
            self.cond.signal();
            return true;
        }

        fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % cap;
            self.len -= 1;
            return item;
        }

        // Blockiert bis Item verfügbar oder should_stop gesetzt.
        fn popWait(self: *Self, should_stop: *const std.atomic.Value(bool)) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == 0) {
                if (should_stop.load(.acquire)) return null;
                self.cond.wait(&self.mutex);
            }
            const item = self.buf[self.head];
            self.head = (self.head + 1) % cap;
            self.len -= 1;
            return item;
        }

        fn wakeAll(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.broadcast();
        }
    };
}

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    workers: []std.Thread,
    work_queue: BoundedQueue(Task, 64),
    result_queue: BoundedQueue(TaskResult, 256),
    should_stop: std.atomic.Value(bool),
    workers_done: std.atomic.Value(usize),
    // Wenn shutdown workers nicht in der Zeit einsammelt, werden sie detached
    // statt joined. Dann dürfen workers und self NICHT freigegeben werden
    // (noch-laufender Worker hält Referenzen).
    detached: bool = false,
    /// shutdown lief schon (main ruft es vor deinit, um `detached` zu lesen)
    stopped: bool = false,
    /// Wird nach jedem erfolgreich eingereihten Result gerufen, auch aus Worker- und
    /// Watcher-Threads. main.zig hängt hier wio.cancelWait ein: der Frame-Loop schläft
    /// sonst in wio.wait(.{}) und holt Results erst beim nächsten Fenster-Event ab.
    on_result: ?*const fn () void = null,

    const Self = @This();

    /// Max. Zeit die shutdown() auf hängende Worker wartet, bevor detached wird.
    const shutdown_timeout_ns: u64 = 2 * std.time.ns_per_s;

    pub fn init(allocator: std.mem.Allocator, n_workers: usize) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const workers = try allocator.alloc(std.Thread, n_workers);
        errdefer allocator.free(workers);

        self.* = .{
            .allocator = allocator,
            .workers = workers,
            .work_queue = .{},
            .result_queue = .{},
            .should_stop = std.atomic.Value(bool).init(false),
            .workers_done = std.atomic.Value(usize).init(0),
        };

        var spawned: usize = 0;
        for (workers) |*w| {
            w.* = std.Thread.spawn(.{}, workerFn, .{self}) catch |err| {
                self.should_stop.store(true, .release);
                self.work_queue.wakeAll();
                for (workers[0..spawned]) |prev| prev.join();
                return err;
            };
            spawned += 1;
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        if (self.detached) {
            // Ein oder mehrere Worker blockieren in unabbrechbaren Calls
            // (HTTP fetch, long sleep) — wurden detached. Memory kontrolliert
            // leaken, OS räumt beim Prozessende auf.
            return;
        }
        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }

    /// Non-blocking. Gibt false zurück wenn Work Queue voll.
    pub fn submit(self: *Self, task: Task) bool {
        if (!self.work_queue.push(task)) {
            log.warn("work queue full — task dropped", .{});
            return false;
        }
        return true;
    }

    /// Non-blocking Result von externem Producer (z.B. FileWatcher) einreihen.
    pub fn pushResult(self: *Self, result: TaskResult) bool {
        if (!self.result_queue.push(result)) {
            log.warn("result queue full — result dropped", .{});
            return false;
        }
        if (self.on_result) |wake| wake();
        return true;
    }

    /// Non-blocking drain der Result Queue in buf. Gibt gefüllte Slice zurück.
    pub fn pollResults(self: *Self, buf: []TaskResult) []TaskResult {
        var count: usize = 0;
        while (count < buf.len) {
            buf[count] = self.result_queue.pop() orelse break;
            count += 1;
        }
        return buf[0..count];
    }

    pub fn shutdown(self: *Self) void {
        if (self.stopped) return;
        self.stopped = true;
        self.should_stop.store(true, .release);
        self.work_queue.wakeAll();

        // Poll-basiert auf alle Worker warten. Wenn eine Task in einem
        // unabbrechbaren Call hängt (HTTP fetch ohne Timeout, langer sleep),
        // würde join() ewig blockieren und der Wayland-Compositor zeigt
        // "App antwortet nicht". Deshalb: best-effort join mit Timeout,
        // dann detach.
        const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(shutdown_timeout_ns));
        while (std.time.nanoTimestamp() < deadline) {
            if (self.workers_done.load(.acquire) == self.workers.len) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        const done = self.workers_done.load(.acquire);
        if (done == self.workers.len) {
            for (self.workers) |w| w.join();
        } else {
            log.warn("shutdown timeout: {d}/{d} workers stuck — detaching", .{
                self.workers.len - done,
                self.workers.len,
            });
            for (self.workers) |w| w.detach();
            self.detached = true;
        }

        // Nicht abgeholte Results freigeben (safe: kein Worker pushed mehr
        // relevante Ergebnisse nach should_stop — Warmup/Chat returns vor push)
        while (self.result_queue.pop()) |r| r.deinit();
    }

    fn workerFn(self: *Self) void {
        defer _ = self.workers_done.fetchAdd(1, .release);
        while (true) {
            const task = self.work_queue.popWait(&self.should_stop) orelse break;
            const result = task.func(self.allocator, task.data) catch |err| {
                log.err("task failed: {}", .{err});
                continue;
            };
            if (!self.result_queue.push(result)) {
                log.warn("result queue full — dropping result", .{});
                result.deinit();
                continue;
            }
            if (self.on_result) |wake| wake();
        }
    }
};

test "submit 10 tasks, poll all results" {
    var scheduler = try Scheduler.init(std.testing.allocator, 2);
    defer scheduler.deinit();

    for (0..10) |i| {
        try std.testing.expect(scheduler.submit(.{
            .func = testTask,
            .data = @ptrFromInt(i),
        }));
    }

    var total: usize = 0;
    var buf: [32]TaskResult = undefined;
    var attempts: usize = 0;
    while (total < 10 and attempts < 2000) : (attempts += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
        for (scheduler.pollResults(&buf)) |r| {
            r.deinit();
            total += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 10), total);
}

var wake_count = std.atomic.Value(usize).init(0);
fn countWake() void {
    _ = wake_count.fetchAdd(1, .monotonic);
}

test "on_result weckt bei jedem eingereihten Result: pushResult und Worker" {
    var scheduler = try Scheduler.init(std.testing.allocator, 1);
    defer scheduler.deinit();
    wake_count.store(0, .monotonic);
    scheduler.on_result = &countWake;

    try std.testing.expect(scheduler.pushResult(.{
        .tag = .file_changed,
        .payload = try std.testing.allocator.dupe(u8, "x"),
        .allocator = std.testing.allocator,
    }));
    try std.testing.expectEqual(@as(usize, 1), wake_count.load(.monotonic));

    try std.testing.expect(scheduler.submit(.{ .func = testTask, .data = @ptrFromInt(7) }));
    var buf: [4]TaskResult = undefined;
    var got: usize = 0;
    var attempts: usize = 0;
    while (got < 2 and attempts < 2000) : (attempts += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
        for (scheduler.pollResults(&buf)) |r| {
            r.deinit();
            got += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), got);
    try std.testing.expectEqual(@as(usize, 2), wake_count.load(.monotonic));
}

fn testTask(allocator: std.mem.Allocator, data: ?*anyopaque) !TaskResult {
    const idx: usize = @intFromPtr(data);
    return .{
        .tag = .git_status,
        .payload = try std.fmt.allocPrint(allocator, "result-{d}", .{idx}),
        .allocator = allocator,
    };
}

/// Fasst Ereignis-Bursts zu höchstens einer Aktion pro Zeitfenster zusammen.
/// mark() beim Ereignis, take() im Loop: liefert einmal true, sobald das Fenster
/// nach dem ersten Ereignis abgelaufen ist. Weitere Ereignisse im Fenster
/// verlängern es nicht, sie sind in der einen Aktion enthalten.
pub const Debounce = struct {
    delay_ms: i64,
    due_at: ?i64 = null,

    pub fn mark(self: *Debounce, now_ms: i64) void {
        if (self.due_at == null) self.due_at = now_ms + self.delay_ms;
    }

    pub fn take(self: *Debounce, now_ms: i64) bool {
        const due = self.due_at orelse return false;
        if (now_ms < due) return false;
        self.due_at = null;
        return true;
    }
};

test "Debounce: ohne mark liefert take nie true" {
    var d = Debounce{ .delay_ms = 300 };
    try std.testing.expect(!d.take(0));
    try std.testing.expect(!d.take(10_000));
}

test "Debounce: mark wird erst nach Ablauf des Fensters fällig, dann genau einmal" {
    var d = Debounce{ .delay_ms = 300 };
    d.mark(1000);
    try std.testing.expect(!d.take(1000));
    try std.testing.expect(!d.take(1299));
    try std.testing.expect(d.take(1300));
    try std.testing.expect(!d.take(1300));
    try std.testing.expect(!d.take(5000));
}

test "Debounce: viele marks im Fenster ergeben eine Aktion, Fenster wird nicht verlängert" {
    var d = Debounce{ .delay_ms = 300 };
    d.mark(1000);
    var t: i64 = 1000;
    while (t < 1300) : (t += 10) d.mark(t);
    try std.testing.expect(d.take(1300));
    try std.testing.expect(!d.take(1301));
}

test "Debounce: nach take startet ein neues mark ein neues Fenster" {
    var d = Debounce{ .delay_ms = 300 };
    d.mark(1000);
    try std.testing.expect(d.take(1300));
    d.mark(1400);
    try std.testing.expect(!d.take(1600));
    try std.testing.expect(d.take(1700));
}
