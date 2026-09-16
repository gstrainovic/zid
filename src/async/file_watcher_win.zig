//! File Watcher für Windows via ReadDirectoryChangesW.
//! Ein Verzeichnis-Handle auf die Wurzel (ganzer Baum), überlappende I/O mit Event,
//! damit der Thread alle 100 ms `should_stop` prüfen kann. Gleiche Schnittstelle und
//! gleiche Ergebnisse wie `file_watcher_linux.zig`.

const std = @import("std");
const scheduler_mod = @import("scheduler");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

const log = std.log.scoped(.file_watcher);

extern "kernel32" fn ResetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

const CREATE_EVENT_MANUAL_RESET = 0x00000001;
const EVENT_ALL_ACCESS = 0x1F0003;

const notify_filter = windows.FileNotifyChangeFilter{
    .file_name = true,
    .dir_name = true,
    .size = true,
    .last_write = true,
};

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    dir_handle: windows.HANDLE,
    event: windows.HANDLE,
    should_stop: std.atomic.Value(bool),
    scheduler: *scheduler_mod.Scheduler,
    thread: std.Thread,
    root_path: []const u8,
    last_path: []const u8 = "",
    last_tag: ?scheduler_mod.ResultTag = null,
    last_ms: i64 = 0,

    const Self = @This();

    pub fn start(allocator: std.mem.Allocator, scheduler_ptr: *scheduler_mod.Scheduler, watch_path: []const u8) !*FileWatcher {
        const self = try allocator.create(FileWatcher);
        errdefer allocator.destroy(self);

        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, watch_path);
        defer allocator.free(path_w);

        const dir_handle = kernel32.CreateFileW(
            path_w.ptr,
            windows.FILE_LIST_DIRECTORY,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (dir_handle == windows.INVALID_HANDLE_VALUE) return error.WatchCreationFailed;
        errdefer windows.CloseHandle(dir_handle);

        const event = kernel32.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) orelse
            return error.WatchCreationFailed;
        errdefer windows.CloseHandle(event);

        const root_path = try allocator.dupe(u8, watch_path);
        errdefer allocator.free(root_path);

        self.* = .{
            .allocator = allocator,
            .dir_handle = dir_handle,
            .event = event,
            .should_stop = std.atomic.Value(bool).init(false),
            .scheduler = scheduler_ptr,
            .thread = undefined,
            .root_path = root_path,
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
        windows.CloseHandle(self.event);
        windows.CloseHandle(self.dir_handle);
        self.allocator.free(self.root_path);
        self.allocator.free(self.last_path);
        self.allocator.destroy(self);
    }

    fn runLoop(self: *Self) void {
        var buf: [64 * 1024]u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)) = undefined;

        while (!self.should_stop.load(.acquire)) {
            var overlapped = std.mem.zeroes(windows.OVERLAPPED);
            overlapped.hEvent = self.event;
            _ = ResetEvent(self.event);

            if (kernel32.ReadDirectoryChangesW(self.dir_handle, &buf, buf.len, windows.TRUE, notify_filter, null, &overlapped, null) == 0) {
                log.err("ReadDirectoryChangesW failed: {}", .{windows.GetLastError()});
                return;
            }

            // Auf Ereignisse warten, dabei regelmäßig das Stop-Flag prüfen
            while (true) {
                const rc = kernel32.WaitForSingleObject(self.event, 100);
                if (rc == windows.WAIT_OBJECT_0) break;
                if (rc != windows.WAIT_TIMEOUT or self.should_stop.load(.acquire)) {
                    // Laufende Abfrage abbrechen und ihr Ende abwarten, bevor der Puffer vom Stack geht
                    _ = kernel32.CancelIoEx(self.dir_handle, &overlapped);
                    var ignored: windows.DWORD = 0;
                    _ = kernel32.GetOverlappedResult(self.dir_handle, &overlapped, &ignored, windows.TRUE);
                    return;
                }
            }

            var bytes: windows.DWORD = 0;
            if (kernel32.GetOverlappedResult(self.dir_handle, &overlapped, &bytes, windows.FALSE) == 0) continue;
            // 0 Bytes: Puffer übergelaufen, Einzelereignisse sind verloren
            if (bytes == 0) continue;
            self.processEvents(buf[0..bytes]);
        }
    }

    fn processEvents(self: *Self, data: []align(@alignOf(windows.FILE_NOTIFY_INFORMATION)) u8) void {
        var offset: usize = 0;
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (offset + @sizeOf(windows.FILE_NOTIFY_INFORMATION) <= data.len) {
            const info: *const windows.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(data[offset..].ptr));
            const name_start = offset + @sizeOf(windows.FILE_NOTIFY_INFORMATION);
            const name_bytes = info.FileNameLength;
            if (name_start + name_bytes > data.len) break;

            const name_w = std.mem.bytesAsSlice(u16, data[name_start .. name_start + name_bytes]);
            var w_copy: [std.fs.max_path_bytes / 3]u16 = undefined;
            // Ein UTF-16-Zeichen wird höchstens 3 Bytes WTF-8: passt immer in name_buf
            if (name_w.len <= w_copy.len) {
                // bytesAsSlice ist nicht u16-ausgerichtet: kopieren
                for (name_w, 0..) |c, i| w_copy[i] = c;
                const len = std.unicode.wtf16LeToWtf8(&name_buf, w_copy[0..name_w.len]);
                self.handleEvent(name_buf[0..len], info.Action);
            }

            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }

    /// Wie unter Linux: versteckte Einträge (auch in versteckten Ordnern), Build-Ausgaben
    /// und Modelldateien erzeugen Ereignis-Fluten ohne Relevanz für den Editor.
    fn isIgnored(rel: []const u8) bool {
        if (std.mem.endsWith(u8, rel, ".gguf")) return true;
        var it = std.mem.tokenizeAny(u8, rel, "\\/");
        while (it.next()) |part| {
            if (part[0] == '.') return true;
            if (std.mem.eql(u8, part, "zig-out") or std.mem.eql(u8, part, "node_modules")) return true;
        }
        return false;
    }

    fn handleEvent(self: *Self, rel: []const u8, action: windows.DWORD) void {
        if (rel.len == 0 or isIgnored(rel)) return;

        const tag: scheduler_mod.ResultTag = switch (action) {
            windows.FILE_ACTION_ADDED, windows.FILE_ACTION_RENAMED_NEW_NAME => .file_created,
            windows.FILE_ACTION_REMOVED, windows.FILE_ACTION_RENAMED_OLD_NAME => .file_deleted,
            else => .file_changed,
        };

        const full_path = std.fs.path.join(self.allocator, &.{ self.root_path, rel }) catch return;

        // Ein Schreibvorgang liefert mehrere MODIFIED für dieselbe Datei: identische
        // Ereignisse innerhalb von 100 ms nur einmal melden (wie file_watcher_linux.zig).
        const now = std.time.milliTimestamp();
        if (self.last_tag == tag and std.mem.eql(u8, self.last_path, full_path) and now - self.last_ms < 100) {
            self.allocator.free(full_path);
            return;
        }
        self.allocator.free(self.last_path);
        self.last_path = full_path;
        self.last_tag = tag;
        self.last_ms = now;

        const owned_path = self.allocator.dupe(u8, full_path) catch return;
        const result = scheduler_mod.TaskResult{
            .tag = tag,
            .payload = owned_path,
            .allocator = self.allocator,
        };
        // pushResult loggt selbst, wenn die Queue voll ist
        if (!self.scheduler.pushResult(result)) self.allocator.free(owned_path);
    }
};

test "isIgnored: versteckte Pfadteile, Build-Ausgaben, Modelle" {
    try std.testing.expect(FileWatcher.isIgnored(".git\\index"));
    try std.testing.expect(FileWatcher.isIgnored("src\\.hidden\\a.zig"));
    try std.testing.expect(FileWatcher.isIgnored("zig-out\\bin\\zid.exe"));
    try std.testing.expect(FileWatcher.isIgnored("models\\x.gguf"));
    try std.testing.expect(!FileWatcher.isIgnored("src\\main.zig"));
}
