//! Windows-Papierkorb (Recycle Bin) über `SHFileOperationW` mit `FOF_ALLOWUNDO`.
//!
//! Nur feste Laufwerke haben einen Papierkorb. Auf Netz- und Wechsellaufwerken würde
//! Windows mit `FOF_NOCONFIRMATION` still endgültig löschen (der Explorer fragt dort
//! „Endgültig löschen?“); deshalb prüft `hasRecycleBin` vorher `GetDriveTypeW` und der
//! Aufrufer weicht auf die zid-Ablage aus (`explorer_ops.defaultTrashRoot`).
//! Auf anderen Plattformen liefert alles `error.NoRecycleBin`.
const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.recycle_bin);

pub const Error = error{ NoRecycleBin, ShellFailed, Aborted, InvalidWtf8, OutOfMemory };

const win = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    const SHFILEOPSTRUCTW = extern struct {
        hwnd: ?windows.HWND = null,
        wFunc: windows.UINT,
        /// Doppelt nullterminierte Liste von Pfaden.
        pFrom: [*]const u16,
        pTo: ?[*]const u16 = null,
        fFlags: u16,
        fAnyOperationsAborted: windows.BOOL = 0,
        hNameMappings: ?*anyopaque = null,
        lpszProgressTitle: ?[*:0]const u16 = null,
    };

    const FO_DELETE: windows.UINT = 3;
    const FOF_SILENT: u16 = 0x0004;
    const FOF_NOCONFIRMATION: u16 = 0x0010;
    const FOF_ALLOWUNDO: u16 = 0x0040;
    const FOF_NOCONFIRMMKDIR: u16 = 0x0200;
    const FOF_NOERRORUI: u16 = 0x0400;
    const DRIVE_FIXED: windows.UINT = 3;

    extern "shell32" fn SHFileOperationW(op: *SHFILEOPSTRUCTW) callconv(.winapi) c_int;
    extern "kernel32" fn GetDriveTypeW(root: ?[*:0]const u16) callconv(.winapi) windows.UINT;
} else struct {};

/// Laufwerkswurzel von `path` (`C:\` oder `\\server\share\`) als WTF-16 mit Nullende.
fn rootZ(alloc: std.mem.Allocator, path: []const u8) Error![:0]u16 {
    const dd = std.fs.path.diskDesignatorWindows(path);
    if (dd.len == 0) return error.NoRecycleBin; // relativer Pfad
    const root = std.fmt.allocPrint(alloc, "{s}\\", .{dd}) catch return error.OutOfMemory;
    defer alloc.free(root);
    return std.unicode.wtf8ToWtf16LeAllocZ(alloc, root);
}

/// Hat das Laufwerk von `path` einen Papierkorb? Nur feste Laufwerke (`DRIVE_FIXED`).
pub fn hasRecycleBin(alloc: std.mem.Allocator, path: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    const root = rootZ(alloc, path) catch return false;
    defer alloc.free(root);
    return win.GetDriveTypeW(root.ptr) == win.DRIVE_FIXED;
}

/// `path` (Datei oder Ordner, absolut) in den Papierkorb verschieben.
pub fn recycle(alloc: std.mem.Allocator, path: []const u8) Error!void {
    if (comptime builtin.os.tag != .windows) return error.NoRecycleBin;
    if (!hasRecycleBin(alloc, path)) return error.NoRecycleBin;

    // pFrom: doppelt nullterminiert, nur Backslashes (die Shell kennt kein '/').
    const w = try std.unicode.wtf8ToWtf16LeAlloc(alloc, path);
    defer alloc.free(w);
    const buf = try alloc.alloc(u16, w.len + 2);
    defer alloc.free(buf);
    for (w, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    buf[w.len] = 0;
    buf[w.len + 1] = 0;

    var op = win.SHFILEOPSTRUCTW{
        .wFunc = win.FO_DELETE,
        .pFrom = buf.ptr,
        .fFlags = win.FOF_ALLOWUNDO | win.FOF_NOCONFIRMATION | win.FOF_SILENT | win.FOF_NOERRORUI | win.FOF_NOCONFIRMMKDIR,
    };
    const rc = win.SHFileOperationW(&op);
    if (rc != 0) {
        log.warn("SHFileOperationW('{s}') returned 0x{X}", .{ path, @as(u32, @bitCast(rc)) });
        return error.ShellFailed;
    }
    if (op.fAnyOperationsAborted != 0) return error.Aborted;
}

const testing = std.testing;

test "hasRecycleBin: relativer Pfad nie, Temp-Verzeichnis unter Windows ja" {
    try testing.expect(!hasRecycleBin(testing.allocator, "nur/relativ.txt"));
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(abs);
    try testing.expect(hasRecycleBin(testing.allocator, abs));
}

test "recycle: ohne Papierkorb NoRecycleBin, nichts wird gelöscht" {
    try testing.expectError(error.NoRecycleBin, recycle(testing.allocator, "nur/relativ.txt"));
}
