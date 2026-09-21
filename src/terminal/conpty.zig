//! ConPTY — Windows Pseudo Console wrapper
//!
//! Adapted from ghostty's pty.zig WindowsPty.
//! Creates a ConPTY, spawns a shell process, provides read/write pipes.
//! On Linux, uses POSIX PTY (forkpty).

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.conpty);

pub const Pty = if (builtin.os.tag == .windows) WindowsPty else PosixPty;

/// Result from open() — the handles/fds needed for I/O
pub const PtyFds = struct {
    /// Read end — we read shell output from here
    read: if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t,
    /// Write end — we write user input here
    write: if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t,
};

// ─── Windows ConPTY ───────────────────────────────────────────────

const WindowsPty = struct {
    const windows = std.os.windows;

    // Re-declare kernel32 externs not in std
    const k32 = struct {
        pub extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            hInput: windows.HANDLE,
            hOutput: windows.HANDLE,
            dwFlags: windows.DWORD,
            phPC: *windows.LPVOID,
        ) callconv(.winapi) windows.HRESULT;

        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: windows.LPVOID,
            size: windows.COORD,
        ) callconv(.winapi) windows.HRESULT;

        pub extern "kernel32" fn ClosePseudoConsole(hPC: windows.LPVOID) callconv(.winapi) void;

        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *windows.HANDLE,
            hWritePipe: *windows.HANDLE,
            lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            nSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;

        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: ?*anyopaque,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *usize,
        ) callconv(.winapi) windows.BOOL;

        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: ?*anyopaque,
            dwFlags: windows.DWORD,
            Attribute: usize,
            lpValue: windows.LPVOID,
            cbSize: usize,
            lpPreviousValue: ?windows.LPVOID,
            lpReturnSize: ?*usize,
        ) callconv(.winapi) windows.BOOL;

        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?windows.LPWSTR,
            lpCommandLine: ?windows.LPWSTR,
            lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
            bInheritHandles: windows.BOOL,
            dwCreationFlags: windows.DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?windows.LPWSTR,
            lpStartupInfo: *windows.STARTUPINFOW,
            lpProcessInformation: *windows.PROCESS_INFORMATION,
        ) callconv(.winapi) windows.BOOL;
    };

    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016; // (22 | 0x00020000)
    const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
    const CREATE_UNICODE_ENVIRONMENT: u32 = 0x00000400;
    const STARTF_USESTDHANDLES: u32 = 0x00000100;

    const STARTUPINFOEX = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };

    /// Pipe handles for I/O
    out_pipe: windows.HANDLE, // we read from this (shell stdout)
    in_pipe: windows.HANDLE, // we write to this (shell stdin)
    out_pipe_pty: windows.HANDLE, // pty side of output
    in_pipe_pty: windows.HANDLE, // pty side of input

    /// The pseudo console handle
    pseudo_console: windows.LPVOID,

    /// The shell process
    process_handle: ?windows.HANDLE = null,
    thread_handle: ?windows.HANDLE = null,

    /// Terminal size
    cols: u16,
    rows: u16,

    pub fn open(cols: u16, rows: u16) !Pty {
        var pty: Pty = undefined;
        pty.cols = cols;
        pty.rows = rows;

        // Create pipes for ConPTY
        if (k32.CreatePipe(&pty.in_pipe_pty, &pty.in_pipe, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            _ = windows.CloseHandle(pty.in_pipe_pty);
            _ = windows.CloseHandle(pty.in_pipe);
        }

        if (k32.CreatePipe(&pty.out_pipe, &pty.out_pipe_pty, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            _ = windows.CloseHandle(pty.out_pipe);
            _ = windows.CloseHandle(pty.out_pipe_pty);
        }

        // Create the pseudo console
        const result = k32.CreatePseudoConsole(
            .{ .X = @intCast(cols), .Y = @intCast(rows) },
            pty.in_pipe_pty,
            pty.out_pipe_pty,
            0,
            &pty.pseudo_console,
        );
        if (result != 0) { // S_OK = 0
            log.err("CreatePseudoConsole failed: HRESULT=0x{x}", .{@as(u32, @bitCast(result))});
            return error.CreatePseudoConsoleFailed;
        }

        return pty;
    }

    /// Spawn a shell process attached to this ConPTY
    pub fn spawn(self: *Pty, shell: []const u8, cwd: ?[]const u8) !void {
        const allocator = std.heap.page_allocator;

        // Convert shell path to UTF-16
        const shell_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell);
        defer allocator.free(shell_w);

        // Convert CWD if provided
        const cwd_w: ?[:0]u16 = if (cwd) |c|
            try std.unicode.utf8ToUtf16LeAllocZ(allocator, c)
        else
            null;
        defer if (cwd_w) |c| allocator.free(c);

        // Initialize process thread attribute list
        var attr_list_size: usize = 0;
        _ = k32.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);

        const attr_list_buf = try allocator.alloc(u8, attr_list_size);
        defer allocator.free(attr_list_buf);

        if (k32.InitializeProcThreadAttributeList(
            attr_list_buf.ptr,
            1,
            0,
            &attr_list_size,
        ) == 0) {
            return error.InitAttributeListFailed;
        }

        // Associate the pseudo console with the process
        if (k32.UpdateProcThreadAttribute(
            attr_list_buf.ptr,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            self.pseudo_console,
            @sizeOf(windows.LPVOID),
            null,
            null,
        ) == 0) {
            return error.UpdateAttributeFailed;
        }

        var startup_info_ex: STARTUPINFOEX = undefined;
        @memset(std.mem.asBytes(&startup_info_ex), 0);
        startup_info_ex.StartupInfo.cb = @sizeOf(STARTUPINFOEX);
        // Leere Std-Handles ausdrücklich setzen: ist zids stdout umgeleitet (Log-Datei, Pipe von
        // `zig build run`), erbt die Shell sonst diese Handles und schreibt Prompt und Ausgabe
        // dorthin statt in die ConPTY — der Terminal-Tab blieb leer (e2e_terminal unter Windows).
        startup_info_ex.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup_info_ex.lpAttributeList = attr_list_buf.ptr;

        var process_info: windows.PROCESS_INFORMATION = undefined;

        const flags: u32 = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;

        if (k32.CreateProcessW(
            null,
            @constCast(shell_w.ptr),
            null,
            null,
            windows.FALSE,
            flags,
            null,
            if (cwd_w) |c| @constCast(c.ptr) else null,
            @ptrCast(&startup_info_ex.StartupInfo),
            &process_info,
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            log.err("CreateProcessW failed: {}", .{err});
            return error.CreateProcessFailed;
        }

        self.process_handle = process_info.hProcess;
        self.thread_handle = process_info.hThread;

        log.info("Shell spawned: '{s}' (PID handle acquired)", .{shell});
    }

    /// Get the I/O handles for reading/writing
    pub fn getFds(self: *const Pty) PtyFds {
        return .{
            .read = self.out_pipe,
            .write = self.in_pipe,
        };
    }

    /// Read output from the PTY
    pub fn read(self: *const Pty, buf: []u8) !usize {
        var bytes_read: u32 = 0;
        const success = windows.kernel32.ReadFile(
            self.out_pipe,
            buf.ptr,
            @intCast(buf.len),
            &bytes_read,
            null,
        );
        if (success == 0) {
            const err = windows.kernel32.GetLastError();
            if (err == .BROKEN_PIPE) return error.BrokenPipe;
            return error.ReadFailed;
        }
        return @intCast(bytes_read);
    }

    /// Write input to the PTY
    pub fn write(self: *const Pty, data: []const u8) !usize {
        var bytes_written: u32 = 0;
        const success = windows.kernel32.WriteFile(
            self.in_pipe,
            data.ptr,
            @intCast(data.len),
            &bytes_written,
            null,
        );
        if (success == 0) {
            return error.WriteFailed;
        }
        return @intCast(bytes_written);
    }

    /// Resize the terminal
    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        const result = k32.ResizePseudoConsole(
            self.pseudo_console,
            .{ .X = @intCast(cols), .Y = @intCast(rows) },
        );
        if (result != 0) return error.ResizeFailed;
        self.cols = cols;
        self.rows = rows;
    }

    /// Check if the shell process has exited
    pub fn hasExited(self: *const Pty) bool {
        if (self.process_handle) |h| {
            const res = windows.kernel32.WaitForSingleObject(h, 0);
            return res == 0; // WAIT_OBJECT_0 = 0
        }
        return true;
    }

    pub fn deinit(self: *Pty) void {
        k32.ClosePseudoConsole(self.pseudo_console);
        if (self.process_handle) |h| _ = windows.CloseHandle(h);
        if (self.thread_handle) |h| _ = windows.CloseHandle(h);
        _ = windows.CloseHandle(self.in_pipe);
        _ = windows.CloseHandle(self.in_pipe_pty);
        _ = windows.CloseHandle(self.out_pipe);
        _ = windows.CloseHandle(self.out_pipe_pty);
        self.* = undefined;
    }
};

// ─── POSIX PTY ────────────────────────────────────────────────────

const PosixPty = struct {
    master: std.posix.fd_t = -1,
    child_pid: ?std.posix.pid_t = null,
    cols: u16 = 80,
    rows: u16 = 24,

    pub fn open(cols: u16, rows: u16) !Pty {
        const master = try std.posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer std.posix.close(master);

        // unlockpt(master)
        const unlock: i32 = 0;
        if (std.posix.system.ioctl(master, @bitCast(@as(u32, std.posix.system.T.IOCSPTLCK)), @intFromPtr(&unlock)) != 0) {
            return error.UnlockPtFailed;
        }

        return Pty{
            .master = master,
            .cols = cols,
            .rows = rows,
        };
    }

    pub fn spawn(self: *Pty, shell: []const u8, cwd: ?[]const u8) !void {
        // ptsname_r replacement using ioctl(TIOCGPTN)
        var pty_num: i32 = 0;
        if (std.posix.system.ioctl(self.master, @bitCast(@as(u32, std.posix.system.T.IOCGPTN)), @intFromPtr(&pty_num)) != 0) {
            return error.GetPtyNumberFailed;
        }

        var slave_name_buf: [64]u8 = undefined;
        const slave_name = try std.fmt.bufPrintZ(&slave_name_buf, "/dev/pts/{d}", .{pty_num});

        const pid = try std.posix.fork();

        if (pid == 0) {
            // Child process
            _ = std.os.linux.setsid();

            const slave = std.posix.open(slave_name, .{ .ACCMODE = .RDWR }, 0) catch std.os.linux.exit(1);
            defer std.posix.close(slave);

            // Set as controlling terminal
            if (std.posix.system.ioctl(slave, @bitCast(@as(u32, std.posix.system.T.IOCSCTTY)), @as(usize, 0)) != 0) {
                std.os.linux.exit(1);
            }

            // Set initial size
            var winsize = std.posix.winsize{
                .row = self.rows,
                .col = self.cols,
                .xpixel = 0,
                .ypixel = 0,
            };
            _ = std.posix.system.ioctl(slave, @bitCast(@as(u32, std.posix.system.T.IOCSWINSZ)), @intFromPtr(&winsize));

            // Dup slave to stdin, stdout, stderr
            std.posix.dup2(slave, std.posix.STDIN_FILENO) catch std.os.linux.exit(1);
            std.posix.dup2(slave, std.posix.STDOUT_FILENO) catch std.os.linux.exit(1);
            std.posix.dup2(slave, std.posix.STDERR_FILENO) catch std.os.linux.exit(1);

            // Close master in child
            std.posix.close(self.master);

            // Change directory if requested
            if (cwd) |c| {
                std.posix.chdir(c) catch {};
            }

            // Setup environment: Inherit from parent
            
            // Convert shell to [*:0]const u8
            const shell_z = try std.heap.page_allocator.dupeZ(u8, shell);

            const argv = [_:null]?[*:0]const u8{
                shell_z.ptr,
                null,
            };

            const err = std.posix.execveZ(shell_z, &argv, @ptrCast(std.os.environ.ptr));
            log.err("execveZ failed: {}", .{err});
            std.os.linux.exit(1);
        }

        // Parent
        self.child_pid = pid;
        log.info("Child spawned with PID: {}", .{pid});
    }

    pub fn getFds(self: *const Pty) PtyFds {
        return .{ .read = self.master, .write = self.master };
    }

    pub fn read(self: *const Pty, buf: []u8) !usize {
        return std.posix.read(self.master, buf);
    }

    pub fn write(self: *const Pty, data: []const u8) !usize {
        return std.posix.write(self.master, data);
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var winsize = std.posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        const res = std.posix.system.ioctl(self.master, @bitCast(@as(u32, std.posix.system.T.IOCSWINSZ)), @intFromPtr(&winsize));
        if (res != 0) return error.ResizeFailed;
        self.cols = cols;
        self.rows = rows;
    }

    pub fn hasExited(self: *const Pty) bool {
        if (self.child_pid) |pid| {
            const res = std.posix.waitpid(pid, std.posix.W.NOHANG);
            return res.pid != 0;
        }
        return true;
    }

    pub fn deinit(self: *Pty) void {
        if (self.master >= 0) std.posix.close(self.master);
        // Kill child if still alive? Usually PTY closure handles this via SIGHUP
        self.* = undefined;
    }
};
