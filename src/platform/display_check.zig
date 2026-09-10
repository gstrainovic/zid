//! Erklärt einen fehlgeschlagenen Fensterstart. zid wird nur mit dem
//! Wayland-Backend von wio gebaut, unter einer X11-Sitzung gibt es also
//! keinen erreichbaren Compositor. Reine Funktion über der Umgebung, damit
//! sie ohne echte Sitzung testbar bleibt.

const std = @import("std");

pub const Env = struct {
    session_type: ?[]const u8 = null,
    wayland_display: ?[]const u8 = null,
    display: ?[]const u8 = null,
};

pub const Reason = enum {
    /// X11-Sitzung: der Compositor fehlt grundsätzlich.
    x11_session,
    /// Wayland ist konfiguriert, der Socket antwortet aber nicht.
    compositor_unreachable,
    /// Weder Wayland noch X11 in der Umgebung: vermutlich ohne Sitzung gestartet.
    no_session,
};

pub fn classify(env: Env) Reason {
    if (env.session_type) |t| {
        if (std.mem.eql(u8, t, "x11")) return .x11_session;
        if (std.mem.eql(u8, t, "wayland")) return .compositor_unreachable;
    }
    if (env.wayland_display != null) return .compositor_unreachable;
    if (env.display != null) return .x11_session;
    return .no_session;
}

pub fn message(reason: Reason) []const u8 {
    return switch (reason) {
        .x11_session =>
        \\zid needs a Wayland compositor, but this session is X11.
        \\Log in with a Wayland session (GNOME on Wayland, KDE on Wayland, sway, ...) and start zid again.
        ,
        .compositor_unreachable =>
        \\zid could not connect to the Wayland compositor.
        \\Check WAYLAND_DISPLAY and XDG_RUNTIME_DIR, and make sure the compositor is running.
        ,
        .no_session =>
        \\zid found no graphical session (neither WAYLAND_DISPLAY nor DISPLAY is set).
        \\Start zid from a Wayland session, or use --headless for a window-less run.
        ,
    };
}

const testing = std.testing;

test "X11-Sitzung wird als solche erkannt" {
    try testing.expectEqual(Reason.x11_session, classify(.{ .session_type = "x11", .display = ":0" }));
    try testing.expectEqual(Reason.x11_session, classify(.{ .display = ":0" }));
}

test "Wayland gesetzt, aber Socket tot" {
    try testing.expectEqual(Reason.compositor_unreachable, classify(.{ .session_type = "wayland" }));
    try testing.expectEqual(Reason.compositor_unreachable, classify(.{ .wayland_display = "wayland-0" }));
}

test "gar keine Sitzung" {
    try testing.expectEqual(Reason.no_session, classify(.{}));
}

test "Wayland hat Vorrang vor DISPLAY (XWayland-Reste in der Umgebung)" {
    try testing.expectEqual(Reason.compositor_unreachable, classify(.{ .wayland_display = "wayland-0", .display = ":0" }));
}

test "jede Ursache nennt Wayland im Text" {
    for ([_]Reason{ .x11_session, .compositor_unreachable, .no_session }) |r| {
        const text = message(r);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "zid") != null);
    }
    try testing.expect(std.mem.indexOf(u8, message(.x11_session), "Wayland compositor") != null);
}
