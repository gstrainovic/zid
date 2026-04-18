const std = @import("std"); pub fn main() !void { var list = std.ArrayListUnmanaged(u32).empty; if (list.popOrNull()) |x| { _ = x; } }
