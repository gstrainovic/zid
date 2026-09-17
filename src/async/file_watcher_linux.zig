//! File Watcher via inotify für Linux.
//! Beobachtet Verzeichnisänderungen und pusht Results in den Scheduler.

const std = @import("std");
const scheduler_mod = @import("scheduler");

const log = std.log.scoped(.file_watcher);

// inotify event mask constants
const IN_MODIFY = 0x00000002;
const IN_CREATE = 0x00000100;
const IN_DELETE = 0x00000200;
const IN_MOVED_FROM = 0x00000040;
const IN_MOVED_TO = 0x00000080;
const IN_CLOSE_WRITE = 0x00000008;
const IN_ISDIR = 0x40000000;

const WATCH_MASK = IN_MODIFY | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_CLOSE_WRITE;

/// Event-Struktur von inotify_read
const InotifyEvent = extern struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    len: u32,
};

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    inotify_fd: i32,
    wd_to_path: std.AutoHashMap(i32, []const u8),
    should_stop: std.atomic.Value(bool),
    scheduler: *scheduler_mod.Scheduler,
    thread: std.Thread,
    /// Wurzel, deren Baum der Watcher-Thread beim Start registriert
    root_path: []const u8,
    last_path: []const u8 = "",
    last_tag: ?scheduler_mod.ResultTag = null,
    last_ms: i64 = 0,

    const Self = @This();

    pub fn start(allocator: std.mem.Allocator, scheduler_ptr: *scheduler_mod.Scheduler, watch_path: []const u8) !*FileWatcher {
        const self = try allocator.create(FileWatcher);
        errdefer allocator.destroy(self);

        const inotify_fd = try std.posix.inotify_init1(0);
        errdefer std.posix.close(inotify_fd);

        const root_path = try allocator.dupe(u8, watch_path);
        errdefer allocator.free(root_path);

        self.* = .{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .wd_to_path = std.AutoHashMap(i32, []const u8).init(allocator),
            .should_stop = std.atomic.Value(bool).init(false),
            .scheduler = scheduler_ptr,
            .thread = undefined,
            .root_path = root_path,
        };

        // Den Baum registriert der Watcher-Thread selbst: bei großen Ordnern
        // (z.B. ~/projects mit tausenden Verzeichnissen) dauert das Sekunden
        // und darf den Main-Thread nicht blockieren.
        self.thread = std.Thread.spawn(.{}, runLoop, .{self}) catch |err| {
            self.cleanup();
            return err;
        };

        return self;
    }

    fn addTree(self: *Self, dir_path: []const u8) !void {
        if (self.should_stop.load(.acquire)) return;
        // inotify folgt Symlinks: ein Link-Ordner liefert den Watch-Deskriptor seines Ziels.
        // Ist der schon registriert (Ziel im Baum, oder Link auf einen Vorfahren), bleibt
        // die erste Schreibweise und der Abstieg entfällt — sonst Endlosschleife.
        const wd = try std.posix.inotify_add_watch(self.inotify_fd, dir_path, WATCH_MASK);
        if (self.wd_to_path.contains(wd)) return;
        const owned = try self.allocator.dupe(u8, dir_path);
        try self.wd_to_path.put(wd, owned);

        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".") or isIgnoredDir(entry.name)) continue;
            // Symlink-Ordner mitnehmen (statFile folgt dem Link); Ziel außerhalb des
            // Projekts wäre sonst unbeobachtet, eine offene Datei dort bliebe veraltet.
            const is_dir = entry.kind == .directory or
                (entry.kind == .sym_link and if (dir.statFile(entry.name)) |st| st.kind == .directory else |_| false);
            if (is_dir) {
                const child_path = std.fs.path.join(self.allocator, &.{ dir_path, entry.name }) catch continue;
                defer self.allocator.free(child_path);
                self.addTree(child_path) catch |err| {
                    log.warn("failed to watch {s}: {}", .{ child_path, err });
                };
            }
        }
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
        std.posix.close(self.inotify_fd);
        var it = self.wd_to_path.valueIterator();
        while (it.next()) |path| self.allocator.free(path.*);
        self.wd_to_path.deinit();
        self.allocator.free(self.root_path);
        self.allocator.free(self.last_path);
        self.allocator.destroy(self);
    }

    fn runLoop(self: *Self) void {
        self.addTree(self.root_path) catch |err| {
            log.warn("failed to watch {s}: {}", .{ self.root_path, err });
        };
        var buf: [8192]u8 = undefined;

        while (!self.should_stop.load(.acquire)) {
            var pfd_arr = [_]std.posix.pollfd{.{
                .fd = self.inotify_fd,
                .events = 0x0001,
                .revents = undefined,
            }};

            const n = std.posix.poll(&pfd_arr, 100) catch |err| {
                log.err("poll error: {}", .{err});
                break;
            };

            if (n == 0) continue;

            const bytes_read = std.posix.read(self.inotify_fd, &buf) catch |err| {
                log.err("inotify read error: {}", .{err});
                break;
            };

            if (bytes_read == 0) continue;
            self.processEvents(buf[0..bytes_read]);
        }
    }

    fn processEvents(self: *Self, data: []u8) void {
        var offset: usize = 0;
        while (offset + @sizeOf(InotifyEvent) <= data.len) {
            const event: *const InotifyEvent = @ptrCast(@alignCast(data[offset..].ptr));

            if (event.len == 0) {
                offset += @sizeOf(InotifyEvent);
                continue;
            }

            const total_len = @sizeOf(InotifyEvent) + event.len;
            if (offset + total_len > data.len) break;

            const name = data[offset + @sizeOf(InotifyEvent) .. offset + total_len];
            const null_idx = std.mem.indexOfScalar(u8, name, 0) orelse event.len;
            const filename = name[0..null_idx];

            if (filename.len > 0 and filename[0] != '.') {
                if (self.wd_to_path.get(event.wd)) |parent| {
                    self.handleEvent(parent, filename, event.mask);
                }
            }

            offset += total_len;
        }
    }

    /// Build-Ausgaben erzeugen Ereignis-Fluten ohne Relevanz für den Editor.
    fn isIgnoredDir(name: []const u8) bool {
        return std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "node_modules");
    }

    fn handleEvent(self: *Self, parent_path: []const u8, filename: []const u8, mask: u32) void {
        if (std.mem.endsWith(u8, filename, ".gguf")) return;

        const tag: scheduler_mod.ResultTag = if ((mask & (IN_MOVED_TO | IN_CREATE)) != 0)
            .file_created
        else if ((mask & (IN_MOVED_FROM | IN_DELETE)) != 0)
            .file_deleted
        else
            .file_changed;

        const full_path = std.fs.path.join(self.allocator, &.{ parent_path, filename }) catch return;

        // Ein Schreibvorgang liefert hunderte IN_MODIFY für dieselbe Datei:
        // identische Ereignisse innerhalb von 100 ms nur einmal melden. Ohne Zeitfenster
        // ging eine spätere zweite Änderung derselben Datei verloren („changed on disk“).
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
