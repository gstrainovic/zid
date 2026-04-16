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
const clay = @import("clay");

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

    /// Shell path (owned)
    shell: []const u8,

    // --- Scrolling & UI State ---
    view_row: usize = 0,
    scrollbar_dragging: bool = false,
    scrollbar_drag_start_y: f32 = 0,
    scrollbar_scroll_offset_at_drag_start: f32 = 0,
    scrollbar_track_x: f32 = 0,
    scrollbar_track_y: f32 = 0,
    scrollbar_thumb_y: f32 = 0,
    scrollbar_thumb_height: f32 = 0,
    scrollbar_width: f32 = 10,
    height: f32 = 400,
    terminal_content_x: f32 = 0,
    terminal_content_y: f32 = 0,

    /// Mouse selection state
    selection_start_pin: ?ghostty_vt.PageList.Pin = null,

    /// Context Menu state
    show_context_menu: bool = false,
    context_menu_x: f32 = 0,
    context_menu_y: f32 = 0,

    const Self = @This();

    pub fn totalRowsUnlocked(self: *Self) usize {
        return self.terminal.screens.active.pages.total_rows;
    }

    pub fn visibleLineCount(self: *const Self) usize {
        const line_height: f32 = 24.0;
        const available = self.height;
        if (available <= 0) return 24;
        return @max(1, @as(usize, @intFromFloat(@floor(available / line_height))));
    }

    pub fn isAtBottom(self: *Self) bool {
        const total = self.totalRowsUnlocked();
        const visible = self.visibleLineCount();
        const max_offset = if (total > visible) total - visible else 0;
        return self.view_row >= max_offset;
    }

    pub fn scrollToBottom(self: *Self) void {
        const total = self.totalRowsUnlocked();
        const visible = self.visibleLineCount();
        self.view_row = if (total > visible) total - visible else 0;
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (delta > 0) {
            const amount = @as(usize, @intCast(delta));
            self.view_row = if (amount > self.view_row) 0 else self.view_row - amount;
        } else if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            const total = self.totalRowsUnlocked();
            const visible = self.visibleLineCount();
            const max_offset = if (total > visible) total - visible else 0;
            self.view_row = @min(self.view_row + amount, max_offset);
        }
    }

    pub fn handleScrollbarMouseDown(self: *Self, x: f32, y: f32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const total = self.totalRowsUnlocked();
        const visible = self.visibleLineCount();
        if (total <= visible) return false;

        if (x < self.scrollbar_track_x) return false;
        if (x > self.scrollbar_track_x + self.scrollbar_width) return false;
        if (y < self.scrollbar_track_y) return false;
        if (y > self.scrollbar_track_y + self.height) return false;

        if (y >= self.scrollbar_thumb_y and y <= self.scrollbar_thumb_y + self.scrollbar_thumb_height) {
            self.scrollbar_dragging = true;
            self.scrollbar_drag_start_y = y;
            self.scrollbar_scroll_offset_at_drag_start = @as(f32, @floatFromInt(self.view_row));
            return true;
        }

        if (y < self.scrollbar_thumb_y) {
            const amount = visible;
            self.view_row = if (amount > self.view_row) 0 else self.view_row - amount;
        } else {
            const amount = visible;
            const max_offset = if (total > visible) total - visible else 0;
            self.view_row = @min(self.view_row + amount, max_offset);
        }
        return true;
    }

    pub fn handleScrollbarMouseMove(self: *Self, x: f32, y: f32) void {
        _ = x;
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const total = self.totalRowsUnlocked();
        const visible = self.visibleLineCount();
        if (total <= visible) return;

        const track_height = self.height;
        const thumb_ratio: f32 = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
        const thumb_height = @max(20.0, track_height * thumb_ratio);
        const max_offset: usize = total - visible;
        const scrollable_height = track_height - thumb_height;

        if (scrollable_height <= 0) return;

        const delta_y = y - self.scrollbar_drag_start_y;
        const scroll_delta_frac = delta_y / scrollable_height;
        const scroll_delta_lines = scroll_delta_frac * @as(f32, @floatFromInt(max_offset));
        const scroll_delta_int: i32 = @intFromFloat(@round(scroll_delta_lines));

        var new_offset: isize = @as(isize, @intFromFloat(self.scrollbar_scroll_offset_at_drag_start)) + @as(isize, scroll_delta_int);
        new_offset = @max(0, @min(new_offset, @as(isize, @intCast(max_offset))));

        self.view_row = @as(usize, @intCast(new_offset));
    }

    pub fn handleMouseUp(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scrollbar_dragging = false;
        self.selection_start_pin = null;
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, char_w: f32, line_h: f32, term_x: f32, term_y: f32) bool {
        if (self.handleScrollbarMouseDown(x, y)) return true;

        self.mutex.lock();
        defer self.mutex.unlock();

        const local_x = x - term_x;
        const local_y = y - term_y;

        if (local_x < 0 or local_y < 0) return false;

        const col = @as(u16, @intFromFloat(@floor(local_x / char_w)));
        const row_in_view = @as(usize, @intFromFloat(@floor(local_y / line_h)));
        const abs_row = self.view_row + row_in_view;

        if (abs_row >= self.totalRowsUnlocked()) return false;

        const pt = ghostty_vt.point.Point{ .history = .{ .x = col, .y = @intCast(abs_row) } };
        const screen = self.terminal.screens.active;
        if (screen.pages.pin(pt)) |pin| {
            self.selection_start_pin = pin;
            // Clear current selection on click
            screen.clearSelection();
            return true;
        }

        return false;
    }

    pub fn showContextMenu(self: *Self, x: f32, y: f32) void {
        self.show_context_menu = true;
        self.context_menu_x = x;
        self.context_menu_y = y;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32, char_w: f32, line_h: f32, term_x: f32, term_y: f32) void {
        if (self.scrollbar_dragging) {
            self.handleScrollbarMouseMove(x, y);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const start_pin = self.selection_start_pin orelse return;

        const local_x = x - term_x;
        const local_y = y - term_y;

        const col = @as(u16, @intFromFloat(@floor(@max(0, local_x) / char_w)));
        const row_in_view = @as(usize, @intFromFloat(@floor(@max(0, local_y) / line_h)));
        const abs_row = self.view_row + row_in_view;

        const pt = ghostty_vt.point.Point{ .history = .{ .x = col, .y = @intCast(abs_row) } };
        const screen = self.terminal.screens.active;
        if (screen.pages.pin(pt)) |end_pin| {
            const sel = ghostty_vt.Selection{
                .bounds = .{ .untracked = .{ .start = start_pin, .end = end_pin } },
            };
            screen.select(sel) catch {};
        }
    }

    /// Total number of rows including scrollback history
    pub fn totalRows(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.terminal.screens.active.pages.total_rows;
    }

    pub fn isSelected(self: *Self, col: u16, abs_row: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const screen = self.terminal.screens.active;
        const sel = screen.selection orelse return false;

        const pt = ghostty_vt.point.Point{ .history = .{ .x = col, .y = @intCast(abs_row) } };
        const pin = screen.pages.pin(pt) orelse return false;

        return sel.contains(screen, pin);
    }

    pub fn renderContextMenu(self: *Self) void {
        if (!self.show_context_menu) return;

        const font_size: f32 = 16.0;
        const item_height = font_size + 12;
        const menu_width: f32 = 150;
        const item_count: f32 = 2; // Copy, Paste
        const menu_height = item_height * item_count + 8;

        clay.UI()(.{
            .id = clay.ElementId.ID("term_context_menu_anchor"),
            .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(0) } },
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = .{ .x = self.context_menu_x, .y = self.context_menu_y },
                .z_index = 1000,
            },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("term_context_menu_container"),
                .layout = .{
                    .sizing = .{ .w = .fixed(menu_width), .h = .fixed(menu_height) },
                    .direction = .top_to_bottom,
                    .padding = .all(4),
                },
                .background_color = .{ 45, 45, 60, 255 },
                .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
                .corner_radius = .all(4),
            })({
                self.renderContextMenuItem("Copy", font_size);
                self.renderContextMenuItem("Paste", font_size);
            });
        });
    }

    fn renderContextMenuItem(self: *Self, label: []const u8, font_size: f32) void {
        _ = self;
        const item_id = clay.getElementId(label);
        const is_hovered = clay.pointerOver(item_id);

        clay.UI()(.{
            .id = item_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(font_size + 12) },
                .padding = .{ .left = 8, .right = 8 },
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = if (is_hovered) .{ 80, 80, 100, 255 } else .{ 0, 0, 0, 0 },
            .corner_radius = .all(2),
        })({
            clay.text(label, .{ .font_size = @intFromFloat(font_size), .color = .{ 220, 220, 220, 255 } });
        });
    }


    /// Create a new terminal instance and spawn a shell
    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Detect shell
        const shell = try detectShell(allocator);
        errdefer allocator.free(shell);

        // Initialize ghostty-vt terminal
        var terminal = try ghostty_vt.Terminal.init(allocator, .{
            .cols = cols,
            .rows = rows,
        });
        errdefer terminal.deinit(allocator);

        // Open PTY
        var pty = try ConPty.Pty.open(cols, rows);
        errdefer pty.deinit();

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
            .shell = shell,
        };

        // Start background read thread
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{self});

        return self;
    }

    /// Detect the user's preferred shell
    fn detectShell(allocator: std.mem.Allocator) ![]const u8 {
        if (builtin.os.tag == .windows) {
            // Try COMSPEC (usually cmd.exe), but prefer PowerShell if it exists in PATH
            if (std.process.getEnvVarOwned(allocator, "COMSPEC")) |comspec| {
                return comspec;
            } else |_| {}
            return try allocator.dupe(u8, "powershell.exe");
        } else {
            // Unix: use SHELL env var or fall back to /bin/sh
            if (std.process.getEnvVarOwned(allocator, "SHELL")) |shell| {
                return shell;
            } else |_| {}
            return try allocator.dupe(u8, "/bin/sh");
        }
    }

    /// Background thread: reads PTY output and feeds it to ghostty-vt
    fn readLoop(self: *Self) void {
        var buf: [4096]u8 = undefined;

        // Create a VT stream for proper escape sequence parsing.
        // The stream persists parser state across reads.
        var stream = self.terminal.vtStream();

        const fds = self.pty.getFds();

        while (!self.should_stop.load(.acquire)) {
            // Use poll to avoid blocking indefinitely in read()
            // This allows us to check should_stop periodically.
            if (builtin.os.tag != .windows) {
                var poll_fds = [_]std.posix.pollfd{.{
                    .fd = fds.read,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ret = std.posix.poll(&poll_fds, 100) catch |err| {
                    if (err == error.Interrupted) continue;
                    log.err("poll failed: {}", .{err});
                    break;
                };
                if (ret == 0) continue; // Timeout
                if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) break;
            }

            const n = self.pty.read(&buf) catch |err| {
                if (err == error.BrokenPipe or err == error.FileDescriptorInvalid) {
                    log.info("Shell process connection closed (expected on exit)", .{});
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
                // EOF - Shell exited
                log.info("Shell process exited (EOF)", .{});
                self.mutex.lock();
                self.exited = true;
                self.mutex.unlock();
                return;
            }

            // Feed output through VT stream (handles ANSI escapes, colors, cursor, etc.)
            self.mutex.lock();
            const was_at_bottom = self.isAtBottom();
            stream.nextSlice(buf[0..n]);
            if (was_at_bottom) self.scrollToBottom();
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
    pub fn getScreenText(self: *Self, alloc: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try self.terminal.plainString(alloc);
    }

    /// Get the current cursor position (relative to the active screen area)
    pub fn getCursor(self: *Self) struct { x: u16, y: u16 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const cursor = self.terminal.screens.active.cursor;
        return .{ .x = cursor.x, .y = cursor.y };
    }

    /// Get a single line of text from the terminal (y is absolute row index)
    pub fn getLine(self: *Self, y: usize, alloc: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const screen = self.terminal.screens.active;
        const pt_tl = ghostty_vt.point.Point{ .history = .{ .x = 0, .y = @intCast(y) } };
        const pt_br = ghostty_vt.point.Point{ .history = .{ .x = @as(u16, @intCast(@max(1, self.cols))) - 1, .y = @intCast(y) } };
        
        const tl = screen.pages.pin(pt_tl) orelse return error.InvalidRow;
        const br = screen.pages.pin(pt_br) orelse tl;
        
        var builder: std.Io.Writer.Allocating = .init(alloc);
        errdefer builder.deinit();

        var fmt = ghostty_vt.formatter.ScreenFormatter.init(screen, .{
            .emit = .vt,
            .unwrap = false,
            .trim = false,
            .palette = &self.terminal.colors.palette.current,
        });
        
        fmt.content = .{ .selection = ghostty_vt.Selection.init(tl, br, false) };
        fmt.extra = ghostty_vt.formatter.ScreenFormatter.Extra.styles;
        
        try fmt.format(&builder.writer);
        
        const result = try builder.toOwnedSlice();
        // Remove trailing newline/CR
        return std.mem.trimRight(u8, result, "\n\r");
    }


    /// Resize the terminal
    pub fn resize(self: *Self, cols: u16, rows: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pty.resize(cols, rows);
        try self.terminal.resize(self.allocator, cols, rows);
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
        log.debug("TerminalInstance.deinit: starting", .{});
        // Signal read thread to stop
        self.should_stop.store(true, .release);
        log.debug("TerminalInstance.deinit: should_stop signal set", .{});

        // Cleanup PTY first – this will close the pipes and force the blocking
        // read in the background thread to return (error.BrokenPipe on Windows, 0 on Linux).
        self.pty.deinit();
        log.debug("TerminalInstance.deinit: PTY deinit done", .{});

        // Wait for read thread
        if (self.read_thread) |t| {
            log.debug("TerminalInstance.deinit: joining read thread...", .{});
            t.join();
            log.debug("TerminalInstance.deinit: read thread joined", .{});
        }

        // Cleanup rest
        log.debug("TerminalInstance.deinit: freeing shell path...", .{});
        self.allocator.free(self.shell);
        log.debug("TerminalInstance.deinit: shell path freed", .{});
        
        log.debug("TerminalInstance.deinit: deinitializing ghostty terminal...", .{});
        self.terminal.deinit(self.allocator);
        log.debug("TerminalInstance.deinit: ghostty terminal deinit done", .{});
        
        log.debug("TerminalInstance.deinit: destroying self...", .{});
        self.allocator.destroy(self);
        log.debug("TerminalInstance.deinit: finished", .{});
    }
};
