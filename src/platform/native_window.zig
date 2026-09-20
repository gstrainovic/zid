//! Fenster-Handles für die WGPU-Surface, unabhängig von Fenster- und Render-Schicht.
//! Welche Variante kommt, entscheidet das Backend, das wio beim Start gewählt hat.

/// Handles des Fensters, aus denen WGPU seine Surface baut.
pub const NativeWindow = union(enum) {
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    /// Xlib: `Display*` und die Fenster-ID (kein Zeiger).
    xlib: struct { display: *anyopaque, window: u64 },
    /// Windows: HWND.
    win32: *anyopaque,
};
