//! Clay Renderer für WGPU
//!
//! Konvertiert Clay Layout Render Commands in WGPU Draw Calls.
//! Unterstützt: Rectangle (farbige Boxen)

const std = @import("std");
const wgpu = @import("wgpu");
const clay = @import("clay");

const log = std.log.scoped(.clay_renderer);

/// Vertex für Rectangle Rendering
const RectangleVertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

/// Clay Renderer Hauptstruktur
pub const ClayRenderer = struct {
    allocator: std.mem.Allocator,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    render_pipeline: ?*wgpu.RenderPipeline = null,
    shader_module: ?*wgpu.ShaderModule = null,
    vertex_buffer: ?*wgpu.Buffer = null,
    vertex_buffer_size: u64 = 0,
    vertex_buffer_cursor: u64 = 0,
    swap_chain_format: wgpu.TextureFormat = .bgra8_unorm,

    // Viewport Dimensionen für Normalisierung
    viewport_width: f32 = 1.0,
    viewport_height: f32 = 1.0,
    scale_factor: f32 = 1.0,

    const Self = @This();

    /// Renderer initialisieren
    pub fn init(
        allocator: std.mem.Allocator,
        device: *wgpu.Device,
        queue: *wgpu.Queue,
        swap_chain_format: wgpu.TextureFormat,
        viewport_width: u32,
        viewport_height: u32,
        scale_factor: f32,
    ) !Self {
        log.debug("Initializing Clay renderer (scale={d:.2})", .{scale_factor});

        var self = Self{
            .allocator = allocator,
            .device = device,
            .queue = queue,
            .swap_chain_format = swap_chain_format,
            .viewport_width = @floatFromInt(viewport_width),
            .viewport_height = @floatFromInt(viewport_height),
            .scale_factor = scale_factor,
        };

        // Shader laden (zur Runtime)
        const shader_code = try std.fs.cwd().readFileAlloc(
            allocator,
            "zig-out/share/rectangle.wgsl",
            1024 * 1024,
        );
        defer allocator.free(shader_code);

        self.shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "rectangle.wgsl",
            .code = shader_code,
        })) orelse return error.ShaderCompileFailed;

        // Render Pipeline erstellen
        const color_targets = [_]wgpu.ColorTargetState{
            wgpu.ColorTargetState{
                .format = swap_chain_format,
                .blend = &wgpu.BlendState{
                    .color = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .src_alpha,
                        .dst_factor = .one_minus_src_alpha,
                    },
                    .alpha = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .one,
                        .dst_factor = .one_minus_src_alpha,
                    },
                },
            },
        };

        const vertex_buffers = [_]wgpu.VertexBufferLayout{
            .{
                .array_stride = @sizeOf(RectangleVertex),
                .step_mode = .vertex,
                .attribute_count = 2,
                .attributes = &[_]wgpu.VertexAttribute{
                    // Position: location 0
                    .{
                        .format = .float32x2,
                        .offset = 0,
                        .shader_location = 0,
                    },
                    // Color: location 1
                    .{
                        .format = .float32x4,
                        .offset = @sizeOf([2]f32),
                        .shader_location = 1,
                    },
                },
            },
        };

        const fragment_state = wgpu.FragmentState{
            .module = self.shader_module.?,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = color_targets[0..].ptr,
        };

        self.render_pipeline = device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
            .label = wgpu.StringView.fromSlice("clay_rectangle_pipeline"),
            .vertex = wgpu.VertexState{
                .module = self.shader_module.?,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
                .buffer_count = vertex_buffers.len,
                .buffers = vertex_buffers[0..].ptr,
            },
            .primitive = wgpu.PrimitiveState{
                .topology = .triangle_list,
                .front_face = .ccw,
                .cull_mode = .none,
            },
            .fragment = &fragment_state,
            .multisample = wgpu.MultisampleState{},
        }) orelse return error.PipelineCreateFailed;

        log.debug("Clay renderer initialized", .{});
        return self;
    }

    /// Renderer aufräumen
    pub fn deinit(self: *Self) void {
        log.debug("Clay renderer shutdown", .{});
        if (self.vertex_buffer) |buf| buf.release();
        if (self.render_pipeline) |p| p.release();
        if (self.shader_module) |s| s.release();
    }

    pub fn beginFrame(self: *Self) void {
        self.vertex_buffer_cursor = 0;
    }

    /// Vertex Buffer sicherstellen (wächst bei Bedarf)
    fn ensureVertexBuffer(self: *Self, needed_vertices: usize) !void {
        if (self.vertex_buffer != null and needed_vertices <= self.max_vertices) return;

        // Buffer freigeben falls vorhanden
        if (self.vertex_buffer) |buf| buf.release();

        // Neue Größe (mindestens needed, sonst 2x)
        self.max_vertices = @max(needed_vertices * 2, 4096);
        const buffer_size = @as(u64, @intCast(self.max_vertices)) * @sizeOf(RectangleVertex);

        self.vertex_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
            .label = wgpu.StringView.fromSlice("clay_vertex_buffer"),
            .size = buffer_size,
            .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
            .mapped_at_creation = 0,
        }) orelse return error.BufferCreateFailed;

        self.vertex_buffer_size = buffer_size;
        log.debug("Vertex buffer resized to {} vertices", .{self.max_vertices});
    }

    /// Viewport aktualisieren (bei Resize)
    pub fn setViewport(self: *Self, width: u32, height: u32) void {
        log.debug("Viewport resized to {}x{}", .{ width, height });
        self.viewport_width = @floatFromInt(width);
        self.viewport_height = @floatFromInt(height);
    }

    /// Clay Render Commands rendern
    pub fn renderClayLayout(
        self: *Self,
        render_pass: *wgpu.RenderPassEncoder,
        text_gpu: anytype,
        text_renderer: anytype,
        image_renderer: anytype,
        svg_gpu: anytype,
        svg_atlas: anytype,
        render_commands: []clay.RenderCommand,
    ) !void {
        if (render_commands.len == 0) return {};

        // Vertices für Rechtecke sammeln
        var rect_vertices = std.ArrayListUnmanaged(RectangleVertex){};
        defer rect_vertices.deinit(self.allocator);

        for (render_commands) |cmd| {
            switch (cmd.command_type) {
                .rectangle => {
                    const bbox = cmd.bounding_box;
                    const color = cmd.render_data.rectangle.background_color;

                    const r = color[0] / 255.0;
                    const g = color[1] / 255.0;
                    const b = color[2] / 255.0;
                    const a = color[3] / 255.0;

                    try self.appendRect(&rect_vertices, bbox.x, bbox.y, bbox.width, bbox.height, r, g, b, a);
                },
                .border => {
                    const bbox = cmd.bounding_box;
                    const border = cmd.render_data.border;
                    const color = border.color;
                    const r = color[0] / 255.0;
                    const g = color[1] / 255.0;
                    const b = color[2] / 255.0;
                    const a = color[3] / 255.0;

                    // Top border
                    if (border.width.top > 0) {
                        try self.appendRect(&rect_vertices, bbox.x, bbox.y, bbox.width, @floatFromInt(border.width.top), r, g, b, a);
                    }
                    // Bottom border
                    if (border.width.bottom > 0) {
                        try self.appendRect(&rect_vertices, bbox.x, bbox.y + bbox.height - @as(f32, @floatFromInt(border.width.bottom)), bbox.width, @floatFromInt(border.width.bottom), r, g, b, a);
                    }
                    // Left border
                    if (border.width.left > 0) {
                        try self.appendRect(&rect_vertices, bbox.x, bbox.y, @floatFromInt(border.width.left), bbox.height, r, g, b, a);
                    }
                    // Right border
                    if (border.width.right > 0) {
                        try self.appendRect(&rect_vertices, bbox.x + bbox.width - @as(f32, @floatFromInt(border.width.right)), bbox.y, @floatFromInt(border.width.right), bbox.height, r, g, b, a);
                    }
                },
                .text => {
                    // Wenn wir Rechtecke gepuffert haben, diese zuerst rendern um Z-Order zu erhalten
                    if (rect_vertices.items.len > 0) {
                        try self.flushRects(render_pass, rect_vertices.items);
                        rect_vertices.clearRetainingCapacity();
                    }

                    // Text rendern
                    const text_data = cmd.render_data.text;
                    
                    // Guard against null pointer or empty string to prevent segfaults
                    if (text_data.string_contents.length > 0 and @intFromPtr(text_data.string_contents.chars) != 0) {
                        const text_str = text_data.string_contents.chars[0..@intCast(text_data.string_contents.length)];
                        const bbox = cmd.bounding_box;

                        // Baseline berechnen: bbox.y + scaled_ascender
                        var baseline_y = bbox.y + @as(f32, @floatFromInt(text_data.font_size)) * 0.8; // Fallback
                        if (text_renderer.ts_ptr.getMetrics()) |metrics| {
                            const scale = @as(f32, @floatFromInt(text_data.font_size)) / metrics.point_size;
                            baseline_y = bbox.y + metrics.ascender * scale;
                        }

                        const col = text_data.text_color;
                        const r = col[0] / 255.0;
                        const g = col[1] / 255.0;
                        const b = col[2] / 255.0;
                        const a = col[3] / 255.0;

                        try text_gpu.renderText(
                            render_pass,
                            text_renderer,
                            text_str,
                            bbox.x,
                            baseline_y,
                            @floatFromInt(text_data.font_size),
                            self.scale_factor,
                            .{ r, g, b, a },
                        );
                    }
                },
                .image => {
                    // Flush rectangles first
                    if (rect_vertices.items.len > 0) {
                        try self.flushRects(render_pass, rect_vertices.items);
                        rect_vertices.clearRetainingCapacity();
                    }

                    const image_data = cmd.render_data.image;
                    if (image_data.image_data) |ptr| {
                        const bbox = cmd.bounding_box;

                        // Check if it's an SVG icon or a normal image
                        const svg = @import("../svg/mod.zig");
                        const magic_ptr: *const u64 = @ptrCast(@alignCast(ptr));
                        if (magic_ptr.* == svg.SvgRenderInfo.MAGIC) {
                            const info: *const svg.SvgRenderInfo = @ptrCast(@alignCast(ptr));

                            // Farbe aus SvgRenderInfo verwenden (nicht image.background_color)
                            const r = info.color[0] / 255.0;
                            const g = info.color[1] / 255.0;
                            const b = info.color[2] / 255.0;
                            const a = if (info.color[3] == 0) 1.0 else info.color[3] / 255.0;

                            if (svg_gpu) |sg| {
                                try sg.renderSvg(
                                    render_pass,
                                    svg_atlas.?,
                                    info.path_data,
                                    bbox.x,
                                    bbox.y,
                                    bbox.width,
                                    bbox.height,
                                    info.viewbox,
                                    .{ r, g, b, a },
                                );
                            }
                        } else {
                            const ImageTexture = @import("image_renderer.zig").ImageTexture;
                            const texture: *const ImageTexture = @ptrCast(@alignCast(ptr));

                            // Für normale Images: background_color als Tint verwenden
                            const tint = image_data.background_color;
                            const r = tint[0] / 255.0;
                            const g = tint[1] / 255.0;
                            const b = tint[2] / 255.0;
                            const a = if (tint[3] == 0) 1.0 else tint[3] / 255.0;

                            if (image_renderer) |ir| {
                                try ir.renderImage(
                                    render_pass,
                                    texture,
                                    bbox.x,
                                    bbox.y,
                                    bbox.width,
                                    bbox.height,
                                    .{ r, g, b, a },
                                );
                            }
                        }
                    }
                },
                .scissor_start => {
                    // Flush existing rects before changing scissor
                    if (rect_vertices.items.len > 0) {
                        try self.flushRects(render_pass, rect_vertices.items);
                        rect_vertices.clearRetainingCapacity();
                    }
                    
                    const bbox = cmd.bounding_box;
                    // Scissor rect must be within viewport bounds
                    const sx: u32 = @intFromFloat(@max(0, bbox.x));
                    const sy: u32 = @intFromFloat(@max(0, bbox.y));
                    const sw: u32 = @intFromFloat(@min(self.viewport_width - @as(f32, @floatFromInt(sx)), bbox.width));
                    const sh: u32 = @intFromFloat(@min(self.viewport_height - @as(f32, @floatFromInt(sy)), bbox.height));
                    
                    if (sw > 0 and sh > 0) {
                        render_pass.setScissorRect(sx, sy, sw, sh);
                    }
                },
                .scissor_end => {
                    // Flush rects before resetting scissor
                    if (rect_vertices.items.len > 0) {
                        try self.flushRects(render_pass, rect_vertices.items);
                        rect_vertices.clearRetainingCapacity();
                    }
                    
                    render_pass.setScissorRect(0, 0, @intFromFloat(self.viewport_width), @intFromFloat(self.viewport_height));
                },
                else => {},
            }
        }

        // Restliche Rechtecke flashen
        if (rect_vertices.items.len > 0) {
            try self.flushRects(render_pass, rect_vertices.items);
        }
    }

    fn appendRect(self: *Self, vertices: *std.ArrayListUnmanaged(RectangleVertex), x: f32, y: f32, w: f32, h: f32, r: f32, g: f32, b: f32, a: f32) !void {
        const x0 = self.normalizeX(x);
        const y0 = self.normalizeY(y);
        const x1 = self.normalizeX(x + w);
        const y1 = self.normalizeY(y + h);

        try vertices.append(self.allocator, .{ .position = .{ x0, y0 }, .color = .{ r, g, b, a } });
        try vertices.append(self.allocator, .{ .position = .{ x1, y0 }, .color = .{ r, g, b, a } });
        try vertices.append(self.allocator, .{ .position = .{ x0, y1 }, .color = .{ r, g, b, a } });
        try vertices.append(self.allocator, .{ .position = .{ x1, y0 }, .color = .{ r, g, b, a } });
        try vertices.append(self.allocator, .{ .position = .{ x1, y1 }, .color = .{ r, g, b, a } });
        try vertices.append(self.allocator, .{ .position = .{ x0, y1 }, .color = .{ r, g, b, a } });
    }

    fn flushRects(self: *Self, render_pass: *wgpu.RenderPassEncoder, vertices: []const RectangleVertex) !void {
        const data_size = vertices.len * @sizeOf(RectangleVertex);
        const total_needed = self.vertex_buffer_cursor + data_size;

        // Sicherstellen dass der Buffer gross genug ist für diesen Batch an seinem Offset
        if (self.vertex_buffer == null or self.vertex_buffer_size < total_needed) {
            // Wenn Resize nötig, vergrössern wir den Buffer.
            // Um Fragmentierung zu vermeiden, verdoppeln wir meistens.
            const new_capacity = @max(total_needed * 2, 65536);
            if (self.vertex_buffer) |buf| buf.release();
            
            self.vertex_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
                .label = wgpu.StringView.fromSlice("clay_vertex_buffer"),
                .size = new_capacity,
                .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
                .mapped_at_creation = 0,
            }) orelse return error.BufferCreateFailed;
            self.vertex_buffer_size = new_capacity;
            self.vertex_buffer_cursor = 0; // Reset nach Resize
            log.debug("Vertex buffer resized to {} bytes", .{self.vertex_buffer_size});
        }

        const offset = self.vertex_buffer_cursor;
        self.queue.writeBuffer(
            self.vertex_buffer.?,
            offset,
            @as(*const anyopaque, @ptrCast(vertices.ptr)),
            data_size,
        );
        self.vertex_buffer_cursor += data_size;

        render_pass.setPipeline(self.render_pipeline.?);
        render_pass.setVertexBuffer(0, self.vertex_buffer.?, offset, data_size);
        render_pass.draw(@intCast(vertices.len), 1, 0, 0);
    }

    /// X-Koordinate normalisieren (Pixel → NDC -1..1)
    fn normalizeX(self: Self, x: f32) f32 {
        return (x / self.viewport_width) * 2.0 - 1.0;
    }

    /// Y-Koordinate normalisieren (Pixel → NDC -1..1, invertiert)
    fn normalizeY(self: Self, y: f32) f32 {
        return -((y / self.viewport_height) * 2.0 - 1.0);
    }
};
