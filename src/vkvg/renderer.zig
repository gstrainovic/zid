//! vkvg Renderer für 2D Graphics
//!
//! Verwendet vkvg für 2D Rendering mit Vulkan.

const std = @import("std");
const vkvg = @import("bindings.zig");

const log = std.log.scoped(.vkvg_renderer);

/// vkvg Renderer
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: ?vkvg.Device = null,
    surface: ?vkvg.Surface = null,
    context: ?vkvg.Context = null,
    width: u32,
    height: u32,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        instance: std.meta.Child(@TypeOf(std.mem.zeroes(vkvg.DeviceCreateInfo).instance)),
        physical_device: std.meta.Child(@TypeOf(std.mem.zeroes(vkvg.DeviceCreateInfo).phy)),
        device: std.meta.Child(@TypeOf(std.mem.zeroes(vkvg.DeviceCreateInfo).vkdev)),
        queue_family_index: u32,
        width: u32,
        height: u32,
    ) !Self {
        log.info("Initializing vkvg renderer: {}x{}", .{ width, height });

        var info = vkvg.DeviceCreateInfo{
            .instance = instance,
            .phy = physical_device,
            .vkdev = device,
            .qFamIdx = queue_family_index,
            .qIndex = 0,
            .threadAware = false,
        };

        const vk_device = vkvg.deviceCreate(&info);
        if (vk_device == null) {
            log.err("Failed to create vkvg device", .{});
            return error.VkvgDeviceCreationFailed;
        }

        return Self{
            .allocator = allocator,
            .device = vk_device,
            .surface = null,
            .context = null,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Self) void {
        log.info("vkvg renderer shutdown", .{});

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

    /// Rechteck zeichnen
    pub fn drawRectangle(
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

    /// Linie zeichnen
    pub fn drawLine(
        self: *Self,
        x1: f32, y1: f32,
        x2: f32, y2: f32,
        r: f32, g: f32, b: f32, a: f32,
        line_width: f32,
    ) void {
        if (self.context) |ctx| {
            vkvg.save(ctx);
            vkvg.setSourceRGBA(ctx, r, g, b, a);
            vkvg.setLineWidth(ctx, line_width);
            vkvg.moveTo(ctx, x1, y1);
            vkvg.lineTo(ctx, x2, y2);
            vkvg.stroke(ctx);
            vkvg.restore(ctx);
        }
    }

    /// Kreis zeichnen
    pub fn drawCircle(
        self: *Self,
        cx: f32,
        cy: f32,
        radius: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) void {
        if (self.context) |ctx| {
            vkvg.save(ctx);
            vkvg.setSourceRGBA(ctx, r, g, b, a);
            vkvg.arc(ctx, cx, cy, radius, 0, 2 * std.math.pi);
            vkvg.fill(ctx);
            vkvg.restore(ctx);
        }
    }
};
