//! File Watcher für Windows via ReadDirectoryChangesW.
//! Ein Verzeichnis-Handle auf die Wurzel (ganzer Baum), überlappende I/O mit Event,
//! damit der Thread alle 100 ms `should_stop` prüfen kann. Gleiche Schnittstelle und
//! gleiche Ergebnisse wie `file_watcher_linux.zig`.
//!
//! `bWatchSubtree` folgt keinen Reparse-Points: Änderungen hinter einem Symlink- oder
//! Junction-Ordner, dessen Ziel außerhalb der Wurzel liegt, meldet das Wurzel-Handle nie.
//! Der Thread sucht deshalb beim Start solche Ordner und öffnet für jedes Ziel ein
//! eigenes Handle; dessen Ereignisse kommen unter dem Link-Pfad heraus, also so, wie die
//! Datei im Editor geöffnet wurde. Ziele innerhalb der Wurzel braucht es nicht: deren
//! Ereignisse meldet das Wurzel-Handle unter dem echten Pfad, und `bufferKeyForPath`
//! findet den Buffer über realpath. Links, die erst nach dem Start entstehen, und Links
//! innerhalb eines Link-Ziels werden nicht beobachtet.

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

/// Ein beobachteter Baum: Handle, Event und Puffer der laufenden Abfrage.
/// Liegt auf dem Heap, weil die überlappende I/O Adressen von `overlapped` und `buf` hält.
const Watch = struct {
    handle: windows.HANDLE,
    event: windows.HANDLE,
    /// Pfad, unter dem Ereignisse gemeldet werden (Wurzel bzw. Link-Pfad).
    prefix: []u8,
    overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    pending: bool = false,
    buf: [64 * 1024]u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)) = undefined,

    fn open(allocator: std.mem.Allocator, dir_path: []const u8, prefix: []const u8) !*Watch {
        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, dir_path);
        defer allocator.free(path_w);

        const handle = kernel32.CreateFileW(
            path_w.ptr,
            windows.FILE_LIST_DIRECTORY,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.WatchCreationFailed;
        errdefer windows.CloseHandle(handle);

        const event = kernel32.CreateEventExW(null, null, CREATE_EVENT_MANUAL_RESET, EVENT_ALL_ACCESS) orelse
            return error.WatchCreationFailed;
        errdefer windows.CloseHandle(event);

        const w = try allocator.create(Watch);
        errdefer allocator.destroy(w);
        w.* = .{ .handle = handle, .event = event, .prefix = try allocator.dupe(u8, prefix) };
        return w;
    }

    /// Nächste Abfrage starten. false, wenn Windows sie ablehnt.
    fn arm(self: *Watch) bool {
        self.overlapped = std.mem.zeroes(windows.OVERLAPPED);
        self.overlapped.hEvent = self.event;
        _ = ResetEvent(self.event);
        if (kernel32.ReadDirectoryChangesW(self.handle, &self.buf, self.buf.len, windows.TRUE, notify_filter, null, &self.overlapped, null) == 0) {
            log.err("ReadDirectoryChangesW failed for {s}: {}", .{ self.prefix, windows.GetLastError() });
            return false;
        }
        self.pending = true;
        return true;
    }

    /// Laufende Abfrage abbrechen und ihr Ende abwarten, bevor der Puffer freigegeben wird.
    fn cancel(self: *Watch) void {
        if (!self.pending) return;
        _ = kernel32.CancelIoEx(self.handle, &self.overlapped);
        var ignored: windows.DWORD = 0;
        _ = kernel32.GetOverlappedResult(self.handle, &self.overlapped, &ignored, windows.TRUE);
        self.pending = false;
    }

    fn close(self: *Watch, allocator: std.mem.Allocator) void {
        windows.CloseHandle(self.event);
        windows.CloseHandle(self.handle);
        allocator.free(self.prefix);
        allocator.destroy(self);
    }
};

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    /// [0] ist die Wurzel, danach je ein Link-Ziel außerhalb. Nur der Watcher-Thread
    /// ändert die Liste; `cleanup` läuft erst nach dem join.
    watches: std.ArrayList(*Watch) = .empty,
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

        const root_watch = try Watch.open(allocator, watch_path, watch_path);
        errdefer root_watch.close(allocator);

        const root_path = try allocator.dupe(u8, watch_path);
        errdefer allocator.free(root_path);

        self.* = .{
            .allocator = allocator,
            .should_stop = std.atomic.Value(bool).init(false),
            .scheduler = scheduler_ptr,
            .thread = undefined,
            .root_path = root_path,
        };
        try self.watches.append(allocator, root_watch);

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
        for (self.watches.items) |w| w.close(self.allocator);
        self.watches.deinit(self.allocator);
        self.allocator.free(self.root_path);
        self.allocator.free(self.last_path);
        self.allocator.destroy(self);
    }

    fn runLoop(self: *Self) void {
        defer for (self.watches.items) |w| w.cancel();

        // Wurzel zuerst scharf schalten, dann in Ruhe nach Links suchen (grosse Bäume).
        if (!self.watches.items[0].arm()) return;
        self.addLinkWatches();

        var events: [windows.MAXIMUM_WAIT_OBJECTS]windows.HANDLE = undefined;
        while (!self.should_stop.load(.acquire)) {
            for (self.watches.items, 0..) |w, i| {
                if (!w.pending and !w.arm() and i == 0) return;
                events[i] = w.event;
            }

            _ = windows.WaitForMultipleObjectsEx(events[0..self.watches.items.len], false, 100, false) catch |err| switch (err) {
                error.WaitTimeOut => continue,
                else => {
                    log.err("WaitForMultipleObjects failed: {}", .{err});
                    return;
                },
            };

            // Alle fertigen Abfragen abholen, nicht nur die erste: sonst verhungern hintere.
            for (self.watches.items) |w| {
                if (!w.pending or kernel32.WaitForSingleObject(w.event, 0) != windows.WAIT_OBJECT_0) continue;
                w.pending = false;
                var bytes: windows.DWORD = 0;
                if (kernel32.GetOverlappedResult(w.handle, &w.overlapped, &bytes, windows.FALSE) == 0) continue;
                // 0 Bytes: Puffer übergelaufen, Einzelereignisse sind verloren
                if (bytes == 0) continue;
                self.processEvents(w, w.buf[0..bytes]);
            }
        }
    }

    /// Baum unter der Wurzel nach Symlink-/Junction-Ordnern mit Ziel außerhalb durchsuchen
    /// und je Ziel ein Handle öffnen. Versteckte und ignorierte Ordner werden übersprungen,
    /// Links selbst nicht betreten.
    fn addLinkWatches(self: *Self) void {
        const root_real = std.fs.realpathAlloc(self.allocator, self.root_path) catch return;
        defer self.allocator.free(root_real);

        var stack: std.ArrayList([]u8) = .empty;
        defer {
            for (stack.items) |p| self.allocator.free(p);
            stack.deinit(self.allocator);
        }
        stack.append(self.allocator, self.allocator.dupe(u8, self.root_path) catch return) catch return;

        while (stack.pop()) |dir_path| {
            defer self.allocator.free(dir_path);
            if (self.should_stop.load(.acquire)) return;

            var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .directory and entry.kind != .sym_link) continue;
                if (isIgnoredName(entry.name)) continue;
                const child = std.fs.path.join(self.allocator, &.{ dir_path, entry.name }) catch continue;

                if (!isReparsePoint(self.allocator, child)) {
                    if (entry.kind == .directory) {
                        stack.append(self.allocator, child) catch self.allocator.free(child);
                    } else self.allocator.free(child);
                    continue;
                }
                defer self.allocator.free(child);

                const target = std.fs.realpathAlloc(self.allocator, child) catch continue;
                defer self.allocator.free(target);
                if (!isOutside(root_real, target)) continue;
                if (self.watches.items.len >= windows.MAXIMUM_WAIT_OBJECTS) {
                    log.warn("too many linked folders, not watching {s}", .{child});
                    continue;
                }
                const w = Watch.open(self.allocator, target, child) catch |err| {
                    log.warn("cannot watch linked folder {s}: {}", .{ child, err });
                    continue;
                };
                self.watches.append(self.allocator, w) catch {
                    w.close(self.allocator);
                    continue;
                };
                log.debug("watching linked folder {s} -> {s}", .{ child, target });
            }
        }
    }

    fn isReparsePoint(allocator: std.mem.Allocator, path: []const u8) bool {
        const path_w = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch return false;
        defer allocator.free(path_w);
        const attrs = windows.GetFileAttributesW(path_w.ptr) catch return false;
        return attrs & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }

    /// Liegt `target` ausserhalb von `root`? Beide sind realpaths; Windows-Pfade ohne
    /// Rücksicht auf Gross-/Kleinschreibung, Grenze an einem Trenner.
    fn isOutside(root: []const u8, target: []const u8) bool {
        const r = std.mem.trimRight(u8, root, "\\/");
        if (target.len < r.len or !std.ascii.eqlIgnoreCase(target[0..r.len], r)) return true;
        return target.len > r.len and target[r.len] != '\\' and target[r.len] != '/';
    }

    fn processEvents(self: *Self, w: *const Watch, data: []align(@alignOf(windows.FILE_NOTIFY_INFORMATION)) u8) void {
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
                self.handleEvent(w.prefix, name_buf[0..len], info.Action);
            }

            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }

    fn isIgnoredName(part: []const u8) bool {
        if (part.len == 0) return false;
        if (part[0] == '.') return true;
        return std.mem.eql(u8, part, "zig-out") or std.mem.eql(u8, part, "node_modules");
    }

    /// Wie unter Linux: versteckte Einträge (auch in versteckten Ordnern), Build-Ausgaben
    /// und Modelldateien erzeugen Ereignis-Fluten ohne Relevanz für den Editor.
    fn isIgnored(rel: []const u8) bool {
        if (std.mem.endsWith(u8, rel, ".gguf")) return true;
        var it = std.mem.tokenizeAny(u8, rel, "\\/");
        while (it.next()) |part| {
            if (isIgnoredName(part)) return true;
        }
        return false;
    }

    fn handleEvent(self: *Self, prefix: []const u8, rel: []const u8, action: windows.DWORD) void {
        if (rel.len == 0 or isIgnored(rel)) return;

        const tag: scheduler_mod.ResultTag = switch (action) {
            windows.FILE_ACTION_ADDED, windows.FILE_ACTION_RENAMED_NEW_NAME => .file_created,
            windows.FILE_ACTION_REMOVED, windows.FILE_ACTION_RENAMED_OLD_NAME => .file_deleted,
            else => .file_changed,
        };

        const full_path = std.fs.path.join(self.allocator, &.{ prefix, rel }) catch return;

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

test "isOutside: Grenze am Trenner, Gross/Klein egal" {
    try std.testing.expect(!FileWatcher.isOutside("C:\\p\\zid", "C:\\p\\zid"));
    try std.testing.expect(!FileWatcher.isOutside("C:\\p\\zid", "c:\\P\\ZID\\tmp\\real"));
    try std.testing.expect(!FileWatcher.isOutside("C:\\p\\zid\\", "C:\\p\\zid\\a"));
    try std.testing.expect(FileWatcher.isOutside("C:\\p\\zid", "C:\\p\\zid2\\a"));
    try std.testing.expect(FileWatcher.isOutside("C:\\p\\zid", "C:\\Temp\\out"));
    try std.testing.expect(FileWatcher.isOutside("C:\\p\\zid", "C:\\p"));
}
