//! Animation System für zid
//!
//! Einfache Animationen für UI Components: Fade, Slide, Scale.

const std = @import("std");

const log = std.log.scoped(.animation);

/// Animation Typ
pub const AnimationType = enum {
    fade_in,
    fade_out,
    slide_in_left,
    slide_in_right,
    scale_up,
    scale_down,
};

/// Animation State
pub const Animation = struct {
    type: AnimationType,
    duration_ms: f32,
    elapsed_ms: f32 = 0.0,
    is_running: bool = false,
    is_complete: bool = false,

    const Self = @This();

    /// Animation starten
    pub fn start(self: *Self, anim_type: AnimationType, duration: f32) void {
        self.type = anim_type;
        self.duration_ms = duration;
        self.elapsed_ms = 0.0;
        self.is_running = true;
        self.is_complete = false;
        log.info("Animation started: {s} ({d}ms)", .{ @tagName(anim_type), duration });
    }

    /// Animation updaten (pro Frame aufrufen)
    pub fn update(self: *Self, delta_ms: f32) void {
        if (!self.is_running) return;

        self.elapsed_ms += delta_ms;
        if (self.elapsed_ms >= self.duration_ms) {
            self.elapsed_ms = self.duration_ms;
            self.is_running = false;
            self.is_complete = true;
            log.info("Animation complete: {s}", .{@tagName(self.type)});
        }
    }

    /// Progress (0.0 - 1.0)
    pub fn progress(self: Self) f32 {
        if (self.duration_ms == 0) return 1.0;
        return @min(1.0, self.elapsed_ms / self.duration_ms);
    }

    /// Eased progress (ease-in-out)
    pub fn easedProgress(self: Self) f32 {
        const t = self.progress();
        return t * t * (3.0 - 2.0 * t);
    }

    /// Opacity basierend auf Animation (für Fade)
    pub fn opacity(self: Self) f32 {
        return switch (self.type) {
            .fade_in => self.easedProgress(),
            .fade_out => 1.0 - self.easedProgress(),
            else => 1.0,
        };
    }

    /// Offset X basierend auf Animation (für Slide)
    pub fn offsetX(self: Self, total_distance: f32) f32 {
        return switch (self.type) {
            .slide_in_left => -total_distance * (1.0 - self.easedProgress()),
            .slide_in_right => total_distance * (1.0 - self.easedProgress()),
            else => 0.0,
        };
    }

    /// Scale basierend auf Animation (für Scale)
    pub fn scale(self: Self) f32 {
        return switch (self.type) {
            .scale_up => 0.5 + 0.5 * self.easedProgress(),
            .scale_down => 1.0 - 0.5 * self.easedProgress(),
            else => 1.0,
        };
    }
};

/// Animation Manager - verwaltet mehrere Animationen
pub const AnimationManager = struct {
    allocator: std.mem.Allocator,
    animations: std.ArrayListUnmanaged(Animation),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .animations = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.animations.deinit(self.allocator);
    }

    /// Neue Animation hinzufügen
    pub fn addAnimation(self: *Self, anim_type: AnimationType, duration: f32) !*Animation {
        try self.animations.append(self.allocator, Animation{
            .type = anim_type,
            .duration_ms = duration,
        });
        const anim = &self.animations.items[self.animations.items.len - 1];
        anim.is_running = true;
        return anim;
    }

    /// Alle Animationen updaten
    pub fn update(self: *Self, delta_ms: f32) void {
        for (self.animations.items) |*anim| {
            anim.update(delta_ms);
        }
    }
};
