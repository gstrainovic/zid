//! TerminalInstance — High-level terminal combining ConPTY + ghostty-vt
//!
//! This is the main API for embedded terminal tabs in vulkan-ed.
//! It manages:
//! - PTY lifecycle (spawn shell, read/write)
//! - VT emulation via ghostty-vt (Terminal state machine)
//! - Background read thread
//! - Thread-safe screen state for rendering

const std = @import("std");
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const ConPty = @import("conpty.zig");

const log = std.log.scoped(.terminal_instance);

pub const TerminalInstance = struct {
    allocator: std.mem.Allocator,

    /// ghostty-vt terminal state machine
    terminal: ghostty_vt.Terminal,

    /// Platform PTY
    pty: ConPty.Pty,

    /// Background reader thread
    read_thread: ?std.Thread = null,

    /// Flag to stop the read thread
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Mutex for terminal state access
    mutex: std.Thread.Mutex = .{},

    /// Whether the shell process has exited
    exited: bool = false,

    /// Terminal dimensions
    cols: u16,
    rows: u16,

    const Self = @This();

    /// Create a new terminal instance and spawn a shell
    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Initialize ghostty-vt terminal
        var terminal = try ghostty_vt.Terminal.init(allocator, .{
            .cols = cols,
            .rows = rows,
        });
        errdefer terminal.deinit(allocator);

        // Open PTY
        var pty = try ConPty.Pty.open(cols, rows);
        errdefer pty.deinit();

        // Detect shell
        const shell = detectShell();
        log.info("Using shell: {s}", .{shell});

        // Get CWD
        var cwd_buf: [1024]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch null;

        // Spawn shell process
        try pty.spawn(shell, cwd);

        self.* = .{
            .allocator = allocator,
            .terminal = terminal,
            .pty = pty,
            .cols = cols,
            .rows = rows,
        };

        // Start background read thread
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{self});

        return self;
    }

    /// Detect the user's preferred shell
    fn detectShell() []const u8 {
        if (builtin.os.tag == .windows) {
            // Try PowerShell first, fall back to cmd.exe
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "COMSPEC")) |comspec| {
                defer std.heap.page_allocator.free(comspec);
                // COMSPEC is usually cmd.exe, but we prefer PowerShell
            } else |_| {}
            return "powershell.exe";
        } else {
            // Unix: use SHELL env var or fall back to /bin/sh
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "SHELL")) |shell| {
                // Note: this leaks but it's called once
                return shell;
            } else |_| {}
            return "/bin/sh";
        }
    }

    /// Background thread: reads PTY output and feeds it to ghostty-vt
    fn readLoop(self: *Self) void {
        var buf: [4096]u8 = undefined;

        // Create a VT stream for proper escape sequence parsing.
        // The stream persists parser state across reads (handles
        // escape sequences split across read boundaries).
        var stream = self.terminal.vtStream();

        while (!self.should_stop.load(.acquire)) {
            const n = self.pty.read(&buf) catch |err| {
                if (err == error.BrokenPipe) {
                    log.info("Shell process exited (broken pipe)", .{});
                    self.mutex.lock();
                    self.exited = true;
                    self.mutex.unlock();
                    return;
                }
                log.err("PTY read error: {}", .{err});
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            if (n == 0) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }

            // Feed output through VT stream (handles ANSI escapes, colors, cursor, etc.)
            self.mutex.lock();
            stream.nextSlice(buf[0..n]);
            self.mutex.unlock();
        }
    }

    /// Send keyboard input to the shell
    pub fn sendInput(self: *Self, data: []const u8) !void {
        _ = try self.pty.write(data);
    }

    /// Send a single character
    pub fn sendChar(self: *Self, char: u8) !void {
        try self.sendInput(&[_]u8{char});
    }

    /// Get the plain text content of the terminal screen (for rendering)
    pub fn getScreenText(self: *Self) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try self.terminal.plainString(self.allocator);
    }

    /// Resize the terminal
    pub fn resize(self: *Self, cols: u16, rows: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pty.resize(cols, rows);
        try self.terminal.resize(.{ .cols = cols, .rows = rows });
        self.cols = cols;
        self.rows = rows;
    }

    /// Check if the terminal process is still alive
    pub fn isAlive(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.exited and !self.pty.hasExited();
    }

    pub fn deinit(self: *Self) void {
        // Signal read thread to stop
        self.should_stop.store(true, .release);

        // Wait for read thread
        if (self.read_thread) |t| {
            t.join();
        }

        // Cleanup
        self.pty.deinit();
        self.terminal.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};
