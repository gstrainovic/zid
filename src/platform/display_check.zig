//! Erklärt einen fehlgeschlagenen Fensterstart. zid wird mit beiden Unix-Backends
//! von wio gebaut (Wayland und X11), eine X11-Sitzung ist also kein Fehler mehr:
//! scheitert der Start trotzdem, antwortet der jeweilige Server nicht. Reine
//! Funktion über der Umgebung, damit sie ohne echte Sitzung testbar bleibt.

const std = @import("std");

pub const Env = struct {
    session_type: ?[]const u8 = null,
    wayland_display: ?[]const u8 = null,
    display: ?[]const u8 = null,
};

pub const Reason = enum {
    /// Wayland ist konfiguriert, der Compositor antwortet aber nicht.
    wayland_unreachable,
    /// X11 ist konfiguriert, der X-Server antwortet aber nicht.
    x11_unreachable,
    /// Weder Wayland noch X11 in der Umgebung: vermutlich ohne Sitzung gestartet.
    no_session,
};

pub fn classify(env: Env) Reason {
    if (env.session_type) |t| {
        if (std.mem.eql(u8, t, "wayland")) return .wayland_unreachable;
        if (std.mem.eql(u8, t, "x11")) return .x11_unreachable;
    }
    if (env.wayland_display != null) return .wayland_unreachable;
    if (env.display != null) return .x11_unreachable;
    return .no_session;
}

pub fn message(reason: Reason) []const u8 {
    return switch (reason) {
        .wayland_unreachable =>
        \\zid could not connect to the Wayland compositor.
        \\Check WAYLAND_DISPLAY and XDG_RUNTIME_DIR, and make sure the compositor is running.
        ,
        .x11_unreachable =>
        \\zid could not connect to the X server.
        \\Check DISPLAY and your X authority (xhost, XAUTHORITY), and make sure the X server is running.
        ,
        .no_session =>
        \\zid found no graphical session (neither WAYLAND_DISPLAY nor DISPLAY is set).
        \\Start zid from a Wayland or X11 session, or use --headless for a window-less run.
        ,
    };
}

const testing = std.testing;

test "X11-Sitzung meldet den X-Server, nicht das fehlende Backend" {
    try testing.expectEqual(Reason.x11_unreachable, classify(.{ .session_type = "x11", .display = ":0" }));
    try testing.expectEqual(Reason.x11_unreachable, classify(.{ .display = ":0" }));
}

test "Wayland gesetzt, aber Socket tot" {
    try testing.expectEqual(Reason.wayland_unreachable, classify(.{ .session_type = "wayland" }));
    try testing.expectEqual(Reason.wayland_unreachable, classify(.{ .wayland_display = "wayland-0" }));
}

test "gar keine Sitzung" {
    try testing.expectEqual(Reason.no_session, classify(.{}));
}

test "Wayland hat Vorrang vor DISPLAY (XWayland-Reste in der Umgebung)" {
    try testing.expectEqual(Reason.wayland_unreachable, classify(.{ .wayland_display = "wayland-0", .display = ":0" }));
}

test "jede Ursache nennt zid und ihren Server" {
    for ([_]Reason{ .wayland_unreachable, .x11_unreachable, .no_session }) |r| {
        const text = message(r);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "zid") != null);
    }
    try testing.expect(std.mem.indexOf(u8, message(.x11_unreachable), "X server") != null);
    try testing.expect(std.mem.indexOf(u8, message(.wayland_unreachable), "Wayland compositor") != null);
    // Keine Ursache darf noch behaupten, X11 sei grundsätzlich nicht unterstützt.
    for ([_]Reason{ .wayland_unreachable, .x11_unreachable, .no_session }) |r| {
        try testing.expect(std.mem.indexOf(u8, message(r), "session is X11") == null);
    }
}
