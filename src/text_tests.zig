//! Test-Wurzel für das Textsystem. Liegt in src/, weil text/types.zig
//! ../platform importiert und ein Modul-Root unter src/text/ das nicht erreicht.

test {
    _ = @import("text/cache.zig");
}
