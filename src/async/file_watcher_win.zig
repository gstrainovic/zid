//! File Watcher für Windows via FindFirstChangeNotification.
//! Beobachtet Verzeichnisänderungen und pusht Results in den Scheduler.

const std = @import("std");
const scheduler_mod = @import("scheduler");

const log = std.log.scoped(.file_watcher);

// cImport Windows API
const c = @cImport(@cInclude("windows.h"));

const FILE_NOTIFY_CHANGE_LAST_WRITE = 0x00000010;
const FILE_NOTIFY_CHANGE_FILE_NAME = 0x00000001;
const FILE_NOTIFY_CHANGE_DIR_NAME = 0x00000002;

const WATCH_FLAGS = FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME;

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watch_handle: ?*c.HANDLE,
    watch_path: []const u8,
    should_stop: std.atomic.Value(bool),
    scheduler: *scheduler_mod.Scheduler,
    thread: std.Thread,

    const Self = @This();

    pub fn start(allocator: std.mem.Allocator, scheduler_ptr: *scheduler_mod.Scheduler, watch_path: []const u8) !*FileWatcher {
        const self = try allocator.create(FileWatcher);
        errdefer allocator.destroy(self);

        const watch_handle = c.FindFirstChangeNotificationA(
            watch_path.ptr,
            0, // don't watch subtrees
            WATCH_FLAGS,
        );

        if (watch_handle == null) {
            return error.WatchCreationFailed;
        }

        self.* = .{
            .allocator = allocator,
            .watch_handle = watch_handle,
            .watch_path = try allocator.dupe(u8, watch_path),
            .should_stop = std.atomic.Value(bool).init(false),
            .scheduler = scheduler_ptr,
            .thread = undefined,
        };

        self.thread = std.Thread.spawn(.{}, runLoop, .{self}) catch |err| {
            self.cleanup();
            return err;
        };

        return self;
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        self.thread.join();
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.cleanup();
    }

    fn cleanup(self: *Self) void {
        if (self.watch_handle) |h| {
            _ = c.FindCloseChangeNotification(h);
        }
        self.allocator.free(self.watch_path);
        self.allocator.destroy(self);
    }

    fn runLoop(self: *Self) void {
        while (!self.should_stop.load(.acquire)) {
            const result = c.WaitForSingleObject(self.watch_handle.?, 100);

            if (result == @intFromEnum(c.WAIT_TIMEOUT)) continue;
            if (result != @intFromEnum(c.WAIT_OBJECT_0)) continue;

            _ = c.FindNextChangeNotification(self.watch_handle.?);
        }
    }
};