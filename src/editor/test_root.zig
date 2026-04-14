// Force wio backend symbol emission by referencing init
comptime {
    _ = @import("wio").backend.init;
}

// Re-export all tests from code_editor
test {
    _ = @import("code_editor.zig");
}
