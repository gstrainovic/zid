//! Debug-Allocator: jede Allokation kommt direkt vom page_allocator (eigene Seiten,
//! Freigabe = munmap, ein Use-after-free liest damit sofort unmapped Speicher).
//! Jede Freigabe wird mit Stack-Trace in einem Ring protokolliert, damit nach einem
//! Fehlzugriff die Freigabestelle zu einer Adresse gefunden werden kann.
//! Nur für Fehlersuche (`--page-alloc`), nie im Normalbetrieb.
const std = @import("std");

pub const FreeLog = struct {
    const Self = @This();
    pub const trace_depth = 24;
    pub const ring_len = 8192;

    pub const Entry = struct {
        ptr: usize = 0,
        len: usize = 0,
        addrs: [trace_depth]usize = [_]usize{0} ** trace_depth,
        count: usize = 0,
    };

    backing: std.mem.Allocator = std.heap.page_allocator,
    mutex: std.Thread.Mutex = .{},
    ring: [ring_len]Entry = [_]Entry{.{}} ** ring_len,
    next: usize = 0,

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // Kein In-Place-Remap: alte Seiten werden frei (und protokolliert), damit ein
        // Zugriff über einen alten Pointer nach dem Wachsen sofort auffällt.
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.record(memory, ret_addr);
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    fn record(self: *Self, memory: []u8, ret_addr: usize) void {
        var trace = std.builtin.StackTrace{ .instruction_addresses = undefined, .index = 0 };
        var addrs: [trace_depth]usize = [_]usize{0} ** trace_depth;
        trace.instruction_addresses = &addrs;
        std.debug.captureStackTrace(ret_addr, &trace);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ring[self.next] = .{ .ptr = @intFromPtr(memory.ptr), .len = memory.len, .addrs = addrs, .count = trace.index };
        self.next = (self.next + 1) % ring_len;
    }

    /// Jüngste Freigabe, deren Bereich `addr` enthält.
    pub fn findFree(self: *Self, addr: usize) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < ring_len) : (i += 1) {
            const idx = (self.next + ring_len - 1 - i) % ring_len;
            const e = self.ring[idx];
            if (e.ptr == 0) continue;
            if (addr >= e.ptr and addr < e.ptr + e.len) return e;
        }
        return null;
    }

    pub fn dumpEntry(e: Entry) void {
        var addrs = e.addrs;
        const trace = std.builtin.StackTrace{ .instruction_addresses = addrs[0..], .index = e.count };
        std.debug.print("freed block ptr=0x{x} len={d}, freed at:\n", .{ e.ptr, e.len });
        std.debug.dumpStackTrace(trace);
    }
};
