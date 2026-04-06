//! vkvg Renderer für 2D Graphics
//!
//! Verwendet vkvg für SVG Rendering, Icons und UI Decorations.

const std = @import("std");
const vkvg = @import("bindings.zig");
const clay = @import("clay");

const log = std.log.scoped(.vkvg_renderer);

/// Icon Definition
pub const Icon = struct {
    name: []const u8,
    svg_data: []const u8,
    width: f32,
    height: f32,
};

/// vkvg Renderer
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: ?*vkvg.Device = null,
    surface: ?*vkvg.Surface = null,
    context: ?*vkvg.Context = null,
    width: u32,
    height: u32,

    // Icons Cache
    icon_surfaces: std.StringHashMap(?*vkvg.Surface),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        physical_device: anytype,
        device: anytype,
        queue: anytype,
        queue_family_index: u32,
        width: u32,
        height: u32,
    ) !Self {
        log.info("Initializing vkvg renderer: {}x{}", .{ width, height });

        const vk_device = vkvg.deviceCreate(physical_device, device, queue, queue_family_index);
        if (vk_device == null) {
            log.err("Failed to create vkvg device", .{});
            return error.VkvgDeviceCreationFailed;
        }

        var icon_surfaces = std.StringHashMap(?*vkvg.Surface).init(allocator);

        return Self{
            .allocator = allocator,
            .device = vk_device,
            .surface = null,
            .context = null,
            .width = width,
            .height = height,
            .icon_surfaces = icon_surfaces,
        };
    }

    pub fn deinit(self: *Self) void {
        log.info("vkvg renderer shutdown", .{});

        // Icon surfaces freigeben
        var it = self.icon_surfaces.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |surf| {
                vkvg.surfaceDestroy(surf);
            }
        }
        self.icon_surfaces.deinit();

        if (self.context) |ctx| {
            vkvg.contextDestroy(ctx);
        }
        if (self.surface) |surf| {
            vkvg.surfaceDestroy(surf);
        }
        if (self.device) |dev| {
            vkvg.deviceDestroy(dev);
        }
    }

    /// SVG-Icon laden oder aus Cache holen
    pub fn loadIcon(self: *Self, name: []const u8, svg_data: []const u8) !?*vkvg.Surface {
        // Cache prüfen
        if (self.icon_surfaces.get(name)) |cached| {
            return cached;
        }

        // SVG-String in null-terminated Buffer kopieren
        const null_terminated = try self.allocator.dupeZ(u8, svg_data);
        defer self.allocator.free(null_terminated);

        // Temporäre Surface für SVG-Rendering
        const temp_surf = vkvg.surfaceCreate(self.device.?, 64, 64);
        if (temp_surf == null) {
            return error.VkvgSurfaceCreationFailed;
        }

        // SVG rendern
        const status = vkvg.svgRenderToSurfaceFromString(temp_surf, null_terminated, 64.0, 64.0);
        if (status != .success) {
            vkvg.surfaceDestroy(temp_surf);
            log.err("Failed to render SVG icon '{s}': {s}", .{ name, vkvg.statusString(status) });
            return error.VkvgSvgRenderFailed;
        }

        // Im Cache speichern
        try self.icon_surfaces.put(name, temp_surf);
        log.info("Icon loaded: {s}", .{name});
        return temp_surf;
    }

    /// Einfache geometrische Form auf Surface zeichnen (für UI Decorations)
    pub fn drawDecoration(
        self: *Self,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) void {
        if (self.context) |ctx| {
            vkvg.save(ctx);
            vkvg.setSourceRGBA(ctx, r, g, b, a);
            vkvg.rectangle(ctx, x, y, width, height);
            vkvg.fill(ctx);
            vkvg.restore(ctx);
        }
    }

    /// Gradient zeichnen
    pub fn drawLinearGradient(
        self: *Self,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        r0: f32, g0: f32, b0: f32, a0: f32,
        r1: f32, g1: f32, b1: f32, a1: f32,
    ) void {
        if (self.context) |ctx| {
            vkvg.save(ctx);
            vkvg.addLinearGradient(ctx, x, y, x + width, y, r0, g0, b0, a0, r1, g1, b1, a1);
            vkvg.rectangle(ctx, x, y, width, height);
            vkvg.fill(ctx);
            vkvg.restore(ctx);
        }
    }
};
