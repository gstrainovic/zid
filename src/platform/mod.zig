//! Platform-Abstraktion für zid
//!
//! Verwendet wio für cross-platform Window Management und Input.
//! Stellt Window Handle für WGPU Surface Creation bereit.

const std = @import("std");
const wio = @import("wio");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;

// Platform-spezifische Backend-Importe
const unix = if (is_linux) wio.backend else struct {};
const wayland = if (is_linux) unix.wayland else struct {};
const x11 = if (is_linux) unix.x11 else struct {};

pub const NativeWindow = @import("native_window.zig").NativeWindow;

const log = std.log.scoped(.platform);

/// Platform-spezifische Konfiguration
pub const PlatformConfig = struct {
    title: []const u8 = "zid",
    width: u32 = 1200,
    height: u32 = 800,
    min_width: u32 = 400,
    min_height: u32 = 300,
};

/// Window Event Types
pub const WindowEvent = union(enum) {
    resized: struct { width: u32, height: u32 },
    closed: void,
    focused: bool,
    key_pressed: struct { key: u32, mods: u32 },
    key_released: struct { key: u32, mods: u32 },
    text_input: []const u8,
    mouse_moved: struct { x: f64, y: f64 },
    mouse_pressed: struct { button: u8, x: f64, y: f64 },
    mouse_released: struct { button: u8, x: f64, y: f64 },
    mouse_scrolled: struct { delta: f64 },
};

/// Callback-Typen
pub const EventCallback = *const fn (event: WindowEvent, user_data: ?*anyopaque) void;

/// Haupt-Platform-Struktur
pub const Platform = struct {
    allocator: std.mem.Allocator,
    window: ?wio.Window = null,
    window_ptr: ?*wio.Window = null,
    config: PlatformConfig,
    running: bool = true,
    user_data: ?*anyopaque = null,
    event_callback: ?EventCallback = null,
    current_width: u32 = 0,
    current_height: u32 = 0,
    /// Zuletzt an wio gemeldete Cursorform (siehe `setCursor`)
    last_cursor: ?wio.Cursor = null,

    const Self = @This();

    /// Platform initialisieren
    pub fn init(allocator: std.mem.Allocator, config: PlatformConfig) !Self {
        log.debug("Initializing platform: {s} on {s}", .{
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
        });

        // wio initialisieren
        try wio.init(allocator, .{});

        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Platform aufräumen
    pub fn deinit(self: *Self) void {
        if (self.window) |*win| {
            win.destroy();
        }
        // wio deinitialisieren (gibt pollfds ArrayList und HashMap frei)
        wio.deinit();
        log.info("Platform shutdown", .{});
    }

    /// Mauszeiger-Form ändern
    pub fn setCursor(self: *Self, shape: wio.Cursor) void {
        // Nur bei Formwechsel an wio: unter Windows ruft wio jedes Mal GetCursorPos+SetCursorPos,
        // und bei gedrückter Taste erzeugt das ein WM_MOUSEMOVE, das den nächsten Frame weckt.
        // Der Frame-Loop lief damit beim Ziehen des Splitters ohne Pause (Log: `mouse: … dx=0`
        // in jedem Frame).
        if (self.last_cursor == shape) return;
        self.last_cursor = shape;
        if (self.window) |*win| {
            log.debug("cursor: {s}", .{@tagName(shape)});
            win.setCursor(shape);
        }
    }

    /// Window erstellen
    pub fn createWindow(self: *Self) !void {
        log.debug("Creating window: {s} {}x{}", .{
            self.config.title,
            self.config.width,
            self.config.height,
        });

        self.window = try wio.createWindow(.{
            .title = self.config.title,
            .size = .{
                .width = @intCast(self.config.width),
                .height = @intCast(self.config.height),
            },
        });

        // Pointer auf das Window setzen (für UI die Pointer braucht)
        self.window_ptr = &self.window.?;

        // Initiale Größe speichern
        self.current_width = self.config.width;
        self.current_height = self.config.height;

        log.debug("Window created successfully", .{});
    }

    /// Native Window Handle für WGPU Surface
    pub fn getWindowHandle(self: *const Self) ?wio.Window {
        return self.window;
    }

    /// Wayland Display Handle für WGPU Surface
    pub fn getWaylandDisplay(self: *const Self) ?*anyopaque {
        _ = self;
        if (unix.active != .wayland) return null;
        return @ptrCast(wayland.display);
    }

    /// Wayland Surface Handle für WGPU Surface (aus aktuellem Window)
    pub fn getWaylandSurface(self: *const Self) ?*anyopaque {
        if (self.window == null) return null;
        if (unix.active != .wayland) return null;
        const win = self.window.?;
        // wio.Window.backend ist unix.Window (union), .wayland gibt *wayland.Window
        return @ptrCast(win.backend.wayland.surface);
    }

    /// Handles des aktuellen Fensters, passend zu dem Backend, das wio beim Start
    /// aus der Umgebung gewählt hat (`XDG_SESSION_TYPE`, sonst Probieren).
    pub fn nativeWindow(self: *const Self) ?NativeWindow {
        const win = self.window orelse return null;
        // Windows: wio hält das HWND optional, ohne Fenster gibt es keine Surface.
        if (!is_linux) return .{ .win32 = win.backend.window orelse return null };
        return switch (unix.active) {
            .wayland => .{ .wayland = .{
                .display = @ptrCast(wayland.display),
                .surface = @ptrCast(win.backend.wayland.surface),
            } },
            .x11 => .{ .xlib = .{
                .display = @ptrCast(x11.display),
                .window = win.backend.x11.window,
            } },
        };
    }

    /// Event Loop starten (blocking)
    pub fn run(self: *Self) void {
        log.info("Starting event loop", .{});

        while (self.running) {
            // Events verarbeiten
            if (self.window) |*win| {
                while (win.getEvent()) |event| {
                    self.handleEvent(event);
                }
            }

            // Kurze Pause für CPU-Effizienz
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        log.info("Event loop ended", .{});
    }

    /// Text-Input Modus umschalten (wichtig für wio/Windows)
    pub fn setTextInput(self: *Self, enabled: bool) void {
        if (self.window) |*win| {
            if (enabled) {
                win.enableTextInput(.{});
            } else {
                win.disableTextInput();
            }
        }
    }

    /// Läuft die App noch?
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// Einzelnes Event von außen verarbeiten (für manuellen Render Loop)
    pub fn handleEventExternal(self: *Self, event: wio.Event) void {
        self.handleEvent(event);
    }

    /// Einzelne Event verarbeiten
    fn handleEvent(self: *Self, event: wio.Event) void {
        switch (event) {
            .size_logical => |size| {
                self.current_width = size.width;
                self.current_height = size.height;
                if (self.event_callback) |cb| {
                    cb(WindowEvent{ .resized = .{
                        .width = size.width,
                        .height = size.height,
                    } }, self.user_data);
                }
            },
            .size_physical => |size| {
                if (self.event_callback) |cb| {
                    cb(WindowEvent{ .resized = .{
                        .width = size.width,
                        .height = size.height,
                    } }, self.user_data);
                }
            },
            .close => {
                // Nicht selbst beenden: main.zig fragt über UI.requestQuit nach ungespeicherten
                // Änderungen und beendet über `quit_confirmed`
                if (self.event_callback) |cb| {
                    cb(WindowEvent{ .closed = {} }, self.user_data);
                }
            },
            .button_press => |button| {
                // Keyboard oder Mouse?
                if (isMouseButton(button)) {
                    if (self.event_callback) |cb| {
                        cb(WindowEvent{ .mouse_pressed = .{
                            .button = mouseButtonToU8(button),
                            .x = 0, // Muss aus mouse Event kommen
                            .y = 0,
                        } }, self.user_data);
                    }
                } else {
                    if (self.event_callback) |cb| {
                        cb(WindowEvent{ .key_pressed = .{
                            .key = @intFromEnum(button),
                            .mods = 0,
                        } }, self.user_data);
                    }
                }
            },
            .button_repeat => |button| {
                if (!isMouseButton(button)) {
                    if (self.event_callback) |cb| {
                        cb(WindowEvent{ .key_pressed = .{
                            .key = @intFromEnum(button),
                            .mods = 0,
                        } }, self.user_data);
                    }
                }
            },
            .button_release => |button| {
                if (isMouseButton(button)) {
                    if (self.event_callback) |cb| {
                        cb(WindowEvent{ .mouse_released = .{
                            .button = mouseButtonToU8(button),
                            .x = 0,
                            .y = 0,
                        } }, self.user_data);
                    }
                } else {
                    if (self.event_callback) |cb| {
                        cb(WindowEvent{ .key_released = .{
                            .key = @intFromEnum(button),
                            .mods = 0,
                        } }, self.user_data);
                    }
                }
            },
            .char => |char_code| {
                if (self.event_callback) |cb| {
                    // u21 zu UTF-8 konvertieren
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(char_code, &buf) catch 0;
                    cb(WindowEvent{ .text_input = buf[0..len] }, self.user_data);
                }
            },
            .mouse => |pos| {
                if (self.event_callback) |cb| {
                    cb(WindowEvent{ .mouse_moved = .{
                        .x = @floatFromInt(pos.x),
                        .y = @floatFromInt(pos.y),
                    } }, self.user_data);
                }
            },
            .scroll_vertical => |delta| {
                if (self.event_callback) |cb| {
                    cb(WindowEvent{ .mouse_scrolled = .{
                        .delta = delta,
                    } }, self.user_data);
                }
            },
            else => {},
        }
    }

    fn isMouseButton(button: wio.Button) bool {
        return switch (button) {
            .mouse_left, .mouse_right, .mouse_middle, .mouse_back, .mouse_forward => true,
            else => false,
        };
    }

    fn mouseButtonToU8(button: wio.Button) u8 {
        return switch (button) {
            .mouse_left => 0,
            .mouse_right => 1,
            .mouse_middle => 2,
            .mouse_back => 3,
            .mouse_forward => 4,
            else => 0,
        };
    }

    /// Event Callback setzen
    pub fn setEventCallback(self: *Self, callback: EventCallback, user_data: ?*anyopaque) void {
        self.event_callback = callback;
        self.user_data = user_data;
    }

    /// Window schließen anfordern
    pub fn requestClose(self: *Self) void {
        self.running = false;
    }

    /// Window Size holen
    pub fn getSize(self: *const Self) struct { width: u32, height: u32 } {
        return .{
            .width = self.current_width,
            .height = self.current_height,
        };
    }
};
