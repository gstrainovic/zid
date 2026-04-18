// Force wio backend symbol emission.
// backend.init() body touches `exports.wio_wl_proxy_*` — referencing a pointer
// to the function forces the whole chain to be codegen'd into the test binary.
const wio = @import("wio");

comptime {
    _ = &wio.backend.init;
    _ = &wio.backend.deinit;
    if (@hasDecl(wio.backend, "wayland")) {
        _ = &wio.backend.wayland.init;
    }
}

// Re-export all tests from code_editor
test {
    _ = @import("code_editor");
}
