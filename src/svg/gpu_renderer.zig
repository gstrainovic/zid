//! GPU SVG Renderer für vulkan-ed
//!
//! Rendert SVG Icons aus einem Texture Atlas.
//! Basierend auf dem TextRendererGPU.

const std = @import("std");
const wgpu = @import("wgpu");
const svg = @import("mod.zig");
const nanosvg = @import("nanosvg");

const log = std.log.scoped(.svg_renderer_gpu);

pub const SvgRendererGPU = struct {
    allocator: std.mem.Allocator,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    atlas_texture: ?*wgpu.Texture = null,
    atlas_texture_view: ?*wgpu.TextureView = null,
    sampler: ?*wgpu.Sampler = null,
    pipeline: ?*wgpu.RenderPipeline = null,
    shader_module: ?*wgpu.ShaderModule = null,
    bind_group_layout: ?*wgpu.BindGroupLayout = null,
    pipeline_layout: ?*wgpu.PipelineLayout = null,
    vertex_buffer: ?*wgpu.Buffer = null,
    vertex_buffer_size: usize = 0,
    vertex_buffer_cursor: usize = 0,
    swap_chain_format: wgpu.TextureFormat = .bgra8_unorm,
    viewport_width: f32 = 1200,
    viewport_height: f32 = 800,
    last_atlas_generation: u32 = 0,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        device: *wgpu.Device,
        queue: *wgpu.Queue,
        swap_chain_format: wgpu.TextureFormat,
        viewport_width: u32,
        viewport_height: u32,
    ) !Self {
        log.debug("Initializing GPU SVG renderer", .{});

        // Wir nutzen den gleichen Shader wie für Text, da beide Quads mit Textur rendern.
        // Falls wir spezielle SVG-Shader brauchen (z.B. für Tinting), können wir sie später hinzufügen.
        const shader_code = try std.fs.cwd().readFileAlloc(
            allocator,
            "zig-out/share/text_atlas.wgsl",
            1024 * 1024,
        );
        defer allocator.free(shader_code);

        const shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "svg_atlas.wgsl",
            .code = shader_code,
        })) orelse return error.ShaderCompileFailed;

        const sampler = device.createSampler(&wgpu.SamplerDescriptor{
            .label = wgpu.StringView.fromSlice("svg_sampler"),
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        }) orelse return error.SamplerCreateFailed;

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
                .array_stride = 8 * @sizeOf(f32), // pos: 2, uv: 2, color: 4
                .step_mode = .vertex,
                .attribute_count = 3,
                .attributes = &[_]wgpu.VertexAttribute{
                    .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
                    .{ .format = .float32x2, .offset = 2 * @sizeOf(f32), .shader_location = 1 },
                    .{ .format = .float32x4, .offset = 4 * @sizeOf(f32), .shader_location = 2 },
                },
            },
        };

        const bind_group_layout_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{
                    .sample_type = .float,
                    .view_dimension = .@"2d",
                    .multisampled = 0,
                },
            },
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{
                    .@"type" = .filtering,
                },
            },
        };

        const bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("svg_bind_group_layout"),
            .entry_count = bind_group_layout_entries.len,
            .entries = &bind_group_layout_entries,
        }) orelse return error.BindGroupLayoutCreateFailed;

        const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("svg_pipeline_layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = &[_]*wgpu.BindGroupLayout{bind_group_layout},
        }) orelse return error.PipelineLayoutCreateFailed;

        const fragment_state = wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = color_targets[0..].ptr,
        };

        const pipeline = device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
            .label = wgpu.StringView.fromSlice("svg_pipeline"),
            .layout = pipeline_layout,
            .vertex = wgpu.VertexState{
                .module = shader_module,
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

        return Self{
            .allocator = allocator,
            .device = device,
            .queue = queue,
            .shader_module = shader_module,
            .sampler = sampler,
            .pipeline = pipeline,
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .swap_chain_format = swap_chain_format,
            .viewport_width = @floatFromInt(viewport_width),
            .viewport_height = @floatFromInt(viewport_height),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.vertex_buffer) |b| b.release();
        if (self.atlas_texture_view) |v| v.release();
        if (self.atlas_texture) |t| t.release();
        if (self.bind_group_layout) |l| l.release();
        if (self.pipeline_layout) |l| l.release();
        if (self.sampler) |s| s.release();
        if (self.pipeline) |p| p.release();
        if (self.shader_module) |s| s.release();
    }

    pub fn beginFrame(self: *Self) void {
        self.vertex_buffer_cursor = 0;
    }

    pub fn updateAtlas(self: *Self, atlas_data: []const u8, atlas_size: u32) !void {
        if (self.atlas_texture) |t| t.release();
        if (self.atlas_texture_view) |v| v.release();

        const texture = self.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice("svg_atlas"),
            .size = .{ .width = atlas_size, .height = atlas_size, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
        }) orelse return error.TextureCreateFailed;

        const destination = wgpu.TexelCopyTextureInfo{
            .texture = texture,
            .mip_level = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = .all,
        };
        const data_layout = wgpu.TexelCopyBufferLayout{
            .offset = 0,
            .bytes_per_row = atlas_size * 4,
            .rows_per_image = atlas_size,
        };
        const write_size = wgpu.Extent3D{
            .width = atlas_size,
            .height = atlas_size,
            .depth_or_array_layers = 1,
        };
        self.queue.writeTexture(
            &destination,
            atlas_data.ptr,
            atlas_data.len,
            &data_layout,
            &write_size,
        );

        const view = texture.createView(&wgpu.TextureViewDescriptor{
            .label = wgpu.StringView.fromSlice("svg_atlas_view"),
        }) orelse return error.TextureViewCreateFailed;

        self.atlas_texture = texture;
        self.atlas_texture_view = view;
    }

    pub fn renderSvg(
        self: *Self,
        render_pass: *wgpu.RenderPassEncoder,
        svg_atlas: *svg.SvgAtlas,
        path_data: []const u8,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        viewbox: f32,
        color: [4]f32,
    ) !void {
        // SVG aus Atlas holen oder rasterisieren
        // SvgKey.init braucht logical_size. Wir nehmen max(width, height)
        const logical_size = @max(width, height);
        
        const cached = svg_atlas.getOrRasterize(
            path_data,
            viewbox,
            logical_size,
            true, // has_fill
            null, // stroke_width
        ) catch |err| {
            if (err == error.RasterizationDeferred) return; // Später rendern
            return err;
        };

        // Atlas Update falls nötig
        if (self.atlas_texture_view == null or svg_atlas.getGeneration() != self.last_atlas_generation) {
            const atlas = svg_atlas.getAtlas();
            try self.updateAtlas(atlas.getData(), atlas.size);
            self.last_atlas_generation = svg_atlas.getGeneration();
        }

        const uv = cached.uv();
        const r = color[0];
        const g = color[1];
        const b = color[2];
        const a = color[3];

        // NDC (-1 bis 1)
        const ndc_x0 = (x / self.viewport_width) * 2.0 - 1.0;
        const ndc_y0 = -((y / self.viewport_height) * 2.0 - 1.0);
        const ndc_x1 = ((x + width) / self.viewport_width) * 2.0 - 1.0;
        const ndc_y1 = -(((y + height) / self.viewport_height) * 2.0 - 1.0);

        var vertices = [_]f32{
            ndc_x0, ndc_y0, uv.u0, uv.v0, r, g, b, a,
            ndc_x1, ndc_y0, uv.u1, uv.v0, r, g, b, a,
            ndc_x0, ndc_y1, uv.u0, uv.v1, r, g, b, a,
            ndc_x1, ndc_y0, uv.u1, uv.v0, r, g, b, a,
            ndc_x1, ndc_y1, uv.u1, uv.v1, r, g, b, a,
            ndc_x0, ndc_y1, uv.u0, uv.v1, r, g, b, a,
        };

        const needed_size = vertices.len * @sizeOf(f32);
        const total_needed = self.vertex_buffer_cursor + needed_size;

        if (self.vertex_buffer == null or self.vertex_buffer_size < total_needed) {
            if (self.vertex_buffer) |buf| buf.release();
            self.vertex_buffer_size = @max(total_needed * 2, 65536);
            self.vertex_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
                .label = wgpu.StringView.fromSlice("svg_vertex_buffer"),
                .size = self.vertex_buffer_size,
                .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
                .mapped_at_creation = 0,
            }) orelse return;
            self.vertex_buffer_cursor = 0;
        }

        const offset = self.vertex_buffer_cursor;
        self.queue.writeBuffer(
            self.vertex_buffer.?,
            offset,
            @as(*const anyopaque, @ptrCast(&vertices)),
            needed_size,
        );
        self.vertex_buffer_cursor += needed_size;

        const bind_group = self.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("svg_bind_group"),
            .layout = self.bind_group_layout.?,
            .entry_count = 2,
            .entries = &[_]wgpu.BindGroupEntry{
                .{
                    .binding = 0,
                    .texture_view = self.atlas_texture_view.?,
                    .sampler = null,
                },
                .{
                    .binding = 1,
                    .texture_view = null,
                    .sampler = self.sampler.?,
                },
            },
        }) orelse return;
        defer bind_group.release();

        render_pass.setPipeline(self.pipeline.?);
        render_pass.setVertexBuffer(0, self.vertex_buffer.?, offset, needed_size);
        render_pass.setBindGroup(0, bind_group, 0, null);
        render_pass.draw(6, 1, 0, 0);
    }

    pub fn setViewport(self: *Self, width: u32, height: u32) void {
        self.viewport_width = @floatFromInt(width);
        self.viewport_height = @floatFromInt(height);
    }
};
