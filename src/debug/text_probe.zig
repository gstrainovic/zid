//! Headless-Ersatz für den GPU-Text-Renderer: fasst jeden Text-String der Render-Commands
//! genauso an wie `renderText`, aber über `pwrite(2)` in ein memfd (Offset 0, die Datei
//! bleibt so groß wie der längste Text). /dev/null taugt nicht: dessen write liest den
//! Puffer gar nicht. Zeigt ein Command auf unmapped Speicher, liefert der Kernel EFAULT
//! statt SIGSEGV, und der Aufrufer kann melden, welches Command betroffen ist.
const std = @import("std");
const builtin = @import("builtin");
const clay = @import("clay");

pub const Fault = struct {
    index: usize,
    ptr: usize,
    len: usize,
    bbox: clay.BoundingBox,
    /// Letzter gültiger Text vor dem fehlerhaften Command (Orientierung im Layout)
    prev_text: []const u8,
};

var sink: ?std.posix.fd_t = null;

fn fd() std.posix.fd_t {
    if (sink) |f| return f;
    const rc = std.os.linux.memfd_create("text_probe", 0);
    if (std.os.linux.E.init(rc) != .SUCCESS) @panic("memfd_create for text probe failed");
    const f: std.posix.fd_t = @intCast(rc);
    sink = f;
    return f;
}

pub fn probe(commands: []const clay.RenderCommand) ?Fault {
    // memfd und EFAULT-Erkennung gibt es nur auf Linux; anderswo bleibt die Probe stumm.
    if (comptime builtin.os.tag != .linux) return null;
    const out = fd();
    var prev: []const u8 = "";
    for (commands, 0..) |cmd, i| {
        if (cmd.command_type != .text) continue;
        const s = cmd.render_data.text.string_contents;
        const len: usize = @intCast(@max(s.length, 0));
        if (len == 0) continue;
        const rc = std.os.linux.pwrite(out, s.chars, len, 0);
        switch (std.os.linux.E.init(rc)) {
            .SUCCESS => {},
            .FAULT => return .{ .index = i, .ptr = @intFromPtr(s.chars), .len = len, .bbox = cmd.bounding_box, .prev_text = prev },
            else => |e| std.debug.panic("text_probe: write failed: {s}", .{@tagName(e)}),
        }
        prev = s.chars[0..len];
    }
    return null;
}
