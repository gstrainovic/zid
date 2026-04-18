//! Thread-Pool Scheduler für async Tasks in vulkan-ed.
//!
//! Main Thread: submit(task) → non-blocking
//! Main Thread: pollResults(buf) → non-blocking drain
//! Worker Threads: dürfen NIEMALS wio/wgpu/Clay anfassen.

const std = @import("std");

const log = std.log.scoped(.scheduler);

pub const ResultTag = enum {
    git_status,
    git_diff,
    git_branch,
    git_log,
    git_blame,
    lsp_completion,
    lsp_diagnostics,
    lsp_hover,
    lsp_definition,
    file_changed,
    file_created,
    file_deleted,
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
    func: *const fn (allocator: std.mem.Allocator, data: ?*const anyopaque) anyerror!TaskResult,
    data: ?*const anyopaque = null,
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

    const Self = @This();

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
        self.should_stop.store(true, .release);
        self.work_queue.wakeAll();
        for (self.workers) |w| w.join();
    }

    fn workerFn(self: *Self) void {
        while (true) {
            const task = self.work_queue.popWait(&self.should_stop) orelse break;
            const result = task.func(self.allocator, task.data) catch |err| {
                log.err("task failed: {}", .{err});
                continue;
            };
            if (!self.result_queue.push(result)) {
                log.warn("result queue full — dropping result", .{});
                result.deinit();
            }
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

fn testTask(allocator: std.mem.Allocator, data: ?*const anyopaque) !TaskResult {
    const idx: usize = @intFromPtr(data);
    return .{
        .tag = .git_status,
        .payload = try std.fmt.allocPrint(allocator, "result-{d}", .{idx}),
        .allocator = allocator,
    };
}
