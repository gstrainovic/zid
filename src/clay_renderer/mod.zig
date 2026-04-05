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
    swap_chain_format: wgpu.TextureFormat = .bgra8_unorm,

    // Viewport Dimensionen für Normalisierung
    viewport_width: f32 = 1.0,
    viewport_height: f32 = 1.0,

    // Vertex Buffer Kapazität (wächst bei Bedarf)
    max_vertices: usize = 4096,

    const Self = @This();

    /// Renderer initialisieren
    pub fn init(
        allocator: std.mem.Allocator,
        device: *wgpu.Device,
        queue: *wgpu.Queue,
        swap_chain_format: wgpu.TextureFormat,
        viewport_width: u32,
        viewport_height: u32,
    ) !Self {
        log.info("Initializing Clay renderer", .{});

        var self = Self{
            .allocator = allocator,
            .device = device,
            .queue = queue,
            .swap_chain_format = swap_chain_format,
            .viewport_width = @floatFromInt(viewport_width),
            .viewport_height = @floatFromInt(viewport_height),
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

        // Vertex Buffer erstellen
        try self.ensureVertexBuffer(self.max_vertices);

        log.info("Clay renderer initialized", .{});
        return self;
    }

    /// Renderer aufräumen
    pub fn deinit(self: *Self) void {
        log.info("Clay renderer shutdown", .{});
        if (self.vertex_buffer) |buf| buf.release();
        if (self.render_pipeline) |p| p.release();
        if (self.shader_module) |s| s.release();
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
        log.info("Vertex buffer resized to {} vertices", .{self.max_vertices});
    }

    /// Viewport aktualisieren (bei Resize)
    pub fn setViewport(self: *Self, width: u32, height: u32) void {
        self.viewport_width = @floatFromInt(width);
        self.viewport_height = @floatFromInt(height);
    }

    /// Clay Render Commands rendern
    pub fn renderClayLayout(
        self: *Self,
        render_pass: *wgpu.RenderPassEncoder,
        render_commands: []clay.RenderCommand,
    ) !void {
        if (render_commands.len == 0) return {};

        // Vertices sammeln
        var vertices = std.ArrayList(RectangleVertex){};
        defer vertices.deinit(self.allocator);

        for (render_commands) |cmd| {
            switch (cmd.command_type) {
                .rectangle => {
                    const bbox = cmd.bounding_box;
                    const color = cmd.render_data.rectangle.background_color;

                    // Rectangle zu 2 Dreiecken (6 Vertices)
                    const x0 = self.normalizeX(bbox.x);
                    const y0 = self.normalizeY(bbox.y);
                    const x1 = self.normalizeX(bbox.x + bbox.width);
                    const y1 = self.normalizeY(bbox.y + bbox.height);

                    const r = color[0] / 255.0;
                    const g = color[1] / 255.0;
                    const b = color[2] / 255.0;
                    const a = color[3] / 255.0;

                    // Dreieck 1: oben-links, oben-rechts, unten-links
                    try vertices.append(self.allocator, .{
                        .position = .{ x0, y0 },
                        .color = .{ r, g, b, a },
                    });
                    try vertices.append(self.allocator, .{
                        .position = .{ x1, y0 },
                        .color = .{ r, g, b, a },
                    });
                    try vertices.append(self.allocator, .{
                        .position = .{ x0, y1 },
                        .color = .{ r, g, b, a },
                    });

                    // Dreieck 2: oben-rechts, unten-rechts, unten-links
                    try vertices.append(self.allocator, .{
                        .position = .{ x1, y0 },
                        .color = .{ r, g, b, a },
                    });
                    try vertices.append(self.allocator, .{
                        .position = .{ x1, y1 },
                        .color = .{ r, g, b, a },
                    });
                    try vertices.append(self.allocator, .{
                        .position = .{ x0, y1 },
                        .color = .{ r, g, b, a },
                    });
                },
                else => {}, // TEXT, IMAGE, etc. später
            }
        }

        if (vertices.items.len == 0) return;

        // Vertex Buffer updaten
        try self.ensureVertexBuffer(vertices.items.len);
        const data_size = vertices.items.len * @sizeOf(RectangleVertex);
        self.queue.writeBuffer(
            self.vertex_buffer.?,
            0,
            @as(*const anyopaque, @ptrCast(vertices.items.ptr)),
            data_size,
        );

        // Rendern
        render_pass.setPipeline(self.render_pipeline.?);
        render_pass.setVertexBuffer(0, self.vertex_buffer.?, 0, self.vertex_buffer_size);
        render_pass.draw(@intCast(vertices.items.len), 1, 0, 0);
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
