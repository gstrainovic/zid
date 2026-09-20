//! Selbsteinrichtung der KI als Vorgang: Zustand, Fortschritt, Hintergrundthread.
//!
//! Der Chat zeigt einen Knopf, sobald Engine oder Modell fehlen. Ein Klick startet
//! diesen Vorgang; er lädt nacheinander Engine (rund 30 MB) und Modell (rund 2,7 GB)
//! ins Datenverzeichnis. Gezeichnet wird währenddessen weiter, deshalb läuft alles
//! in einem eigenen Thread und der Zustand ist atomar.

const std = @import("std");
pub const setup = @import("setup.zig");
const install = @import("install.zig");
const download = @import("download");

const log = std.log.scoped(.ai_setup);

pub const State = enum(u8) { idle, running, done, failed };
pub const Step = enum(u8) { engine, model };

pub const SelfSetup = struct {
    allocator: std.mem.Allocator,
    /// Datenverzeichnis, in dem Engine und Modell landen.
    root: []u8,
    progress: download.Progress = .{},
    state: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    step: std.atomic.Value(u8) = .init(@intFromEnum(Step.engine)),
    thread: ?std.Thread = null,
    detail_buf: [256]u8 = undefined,
    detail_len: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{ .allocator = allocator, .root = try setup.dataRoot(allocator) };
    }

    pub fn deinit(self: *Self) void {
        if (self.thread) |t| t.join();
        self.allocator.free(self.root);
    }

    pub fn currentState(self: *const Self) State {
        return @enumFromInt(self.state.load(.monotonic));
    }

    pub fn currentStep(self: *const Self) Step {
        return @enumFromInt(self.step.load(.monotonic));
    }

    pub fn detail(self: *const Self) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    fn setDetail(self: *Self, text: []const u8) void {
        const n = @min(text.len, self.detail_buf.len);
        @memcpy(self.detail_buf[0..n], text[0..n]);
        self.detail_len = n;
    }

    /// Was im Datenverzeichnis fehlt.
    pub fn missing(self: *Self) setup.Status {
        const engine = setup.enginePath(self.allocator, self.root) catch return .missing_both;
        defer self.allocator.free(engine);
        const model = setup.modelPath(self.allocator, self.root) catch return .missing_both;
        defer self.allocator.free(model);
        return setup.statusOf(setup.present(engine), setup.present(model));
    }

    /// Fortschritt des laufenden Schritts in Prozent. Gemessen wird an der
    /// Teildatei, nicht an einem Zähler im Ladethread (siehe download.zig).
    pub fn percent(self: *Self) u8 {
        const dest = switch (self.currentStep()) {
            .engine => std.fs.path.join(self.allocator, &.{ self.root, "engines", setup.llama_tag, setup.engineAsset() }) catch return 0,
            .model => setup.modelPath(self.allocator, self.root) catch return 0,
        };
        defer self.allocator.free(dest);

        const got = download.receivedSoFar(self.allocator, dest);
        const total: u64 = switch (self.currentStep()) {
            .engine => 35_000_000,
            .model => setup.model_bytes,
        };
        if (got >= total) return 100;
        return @intCast(got * 100 / total);
    }

    /// Beide Teile im Hintergrund holen. Mehrfaches Starten ist wirkungslos.
    pub fn start(self: *Self) !void {
        if (self.currentState() == .running) return;
        self.state.store(@intFromEnum(State.running), .monotonic);
        self.detail_len = 0;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Self) void {
        const status = self.missing();
        if (status == .missing_engine or status == .missing_both) {
            self.step.store(@intFromEnum(Step.engine), .monotonic);
            install.engine(self.allocator, self.root, &self.progress) catch |err| {
                log.err("Engine-Installation fehlgeschlagen: {s}", .{@errorName(err)});
                self.setDetail(@errorName(err));
                self.state.store(@intFromEnum(State.failed), .monotonic);
                return;
            };
        }
        if (self.missing() != .ready) {
            self.step.store(@intFromEnum(Step.model), .monotonic);
            install.model(self.allocator, self.root, &self.progress) catch |err| {
                log.err("Modell-Installation fehlgeschlagen: {s}", .{@errorName(err)});
                self.setDetail(@errorName(err));
                self.state.store(@intFromEnum(State.failed), .monotonic);
                return;
            };
        }
        self.state.store(@intFromEnum(State.done), .monotonic);
        log.info("KI-Einrichtung abgeschlossen", .{});
    }
};

const testing = std.testing;

test "frisches Datenverzeichnis: beides fehlt, Zustand idle" {
    var s = SelfSetup{ .allocator = testing.allocator, .root = try testing.allocator.dupe(u8, "/gibt/es/nicht") };
    defer s.deinit();
    try testing.expectEqual(setup.Status.missing_both, s.missing());
    try testing.expectEqual(State.idle, s.currentState());
    try testing.expectEqual(Step.engine, s.currentStep());
    try testing.expectEqual(@as(u8, 0), s.percent());
}

test "vorhandene Dateien melden ready" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");

    var s = SelfSetup{ .allocator = testing.allocator, .root = base };
    defer s.deinit();

    const engine = try setup.enginePath(testing.allocator, base);
    defer testing.allocator.free(engine);
    try std.fs.cwd().makePath(std.fs.path.dirname(engine).?);
    try std.fs.cwd().writeFile(.{ .sub_path = engine, .data = "x" });
    try testing.expectEqual(setup.Status.missing_model, s.missing());

    const model = try setup.modelPath(testing.allocator, base);
    defer testing.allocator.free(model);
    try std.fs.cwd().makePath(std.fs.path.dirname(model).?);
    try std.fs.cwd().writeFile(.{ .sub_path = model, .data = "y" });
    try testing.expectEqual(setup.Status.ready, s.missing());
}

test "detail merkt sich den Fehlernamen" {
    var s = SelfSetup{ .allocator = testing.allocator, .root = try testing.allocator.dupe(u8, "/x") };
    defer s.deinit();
    s.setDetail("DownloadFailed");
    try testing.expectEqualStrings("DownloadFailed", s.detail());
}
