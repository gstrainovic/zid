//! GPU Text Renderer für vulkan-ed
//!
//! Rendert Text als GPU-Quads mit Glyph-Atlas Textur.

const std = @import("std");
const wgpu = @import("wgpu");
const text = @import("mod.zig");

const log = std.log.scoped(.text_renderer_gpu);

pub const TextRendererGPU = struct {
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
    swap_chain_format: wgpu.TextureFormat = .bgra8_unorm,
    viewport_width: f32 = 1200,
    viewport_height: f32 = 800,
    atlas_size: u32 = 512,
    cached_glyphs: std.AutoHashMap(u21, GlyphQuad),

    const Self = @This();

    pub const GlyphQuad = struct {
        x0: f32, y0: f32, x1: f32, y1: f32,
        u0: f32, v0: f32, u1: f32, v1: f32,
        advance: f32 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        device: *wgpu.Device,
        queue: *wgpu.Queue,
        swap_chain_format: wgpu.TextureFormat,
        viewport_width: u32,
        viewport_height: u32,
    ) !Self {
        log.info("Initializing GPU text renderer", .{});

        // Shader laden
        const shader_code = try std.fs.cwd().readFileAlloc(
            allocator,
            "zig-out/share/text.wgsl",
            1024 * 1024,
        );
        defer allocator.free(shader_code);

        const shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "text.wgsl",
            .code = shader_code,
        })) orelse return error.ShaderCompileFailed;

        // Sampler erstellen
        const sampler = device.createSampler(&wgpu.SamplerDescriptor{
            .label = wgpu.StringView.fromSlice("text_sampler"),
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
        }) orelse return error.SamplerCreateFailed;

        // Pipeline erstellen
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
                .array_stride = 8 * @sizeOf(f32), // pos(2) + uv(2)
                .step_mode = .vertex,
                .attribute_count = 2,
                .attributes = &[_]wgpu.VertexAttribute{
                    .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
                    .{ .format = .float32x2, .offset = 2 * @sizeOf(f32), .shader_location = 1 },
                },
            },
        };

        // Pipeline erstellen mit bind group layout
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
            .label = wgpu.StringView.fromSlice("text_bind_group_layout"),
            .entry_count = bind_group_layout_entries.len,
            .entries = &bind_group_layout_entries,
        }) orelse return error.BindGroupLayoutCreateFailed;

        const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("text_pipeline_layout"),
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
            .label = wgpu.StringView.fromSlice("text_pipeline"),
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
            .cached_glyphs = std.AutoHashMap(u21, GlyphQuad).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        log.info("GPU text renderer shutdown", .{});
        if (self.vertex_buffer) |b| b.release();
        if (self.atlas_texture_view) |v| v.release();
        if (self.atlas_texture) |t| t.release();
        if (self.bind_group_layout) |l| l.release();
        if (self.pipeline_layout) |l| l.release();
        if (self.sampler) |s| s.release();
        if (self.pipeline) |p| p.release();
        if (self.shader_module) |s| s.release();
        self.cached_glyphs.deinit();
    }

    /// Atlas-Textur von CPU auf GPU updaten
    pub fn updateAtlas(self: *Self, atlas_data: []const u8, atlas_size: u32) !void {
        if (self.atlas_texture) |t| {
            t.release();
        }
        if (self.atlas_texture_view) |v| {
            v.release();
        }

        self.atlas_size = atlas_size;
        const texture = self.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice("glyph_atlas"),
            .size = .{ .width = atlas_size, .height = atlas_size, .depth_or_array_layers = 1 },
            .format = .r8_unorm,
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
        }) orelse return error.TextureCreateFailed;

        // Atlas-Daten uploaden
        const destination = wgpu.TexelCopyTextureInfo{
            .texture = texture,
            .mip_level = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = .all,
        };
        const data_layout = wgpu.TexelCopyBufferLayout{
            .offset = 0,
            .bytes_per_row = atlas_size,
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
            .label = wgpu.StringView.fromSlice("glyph_atlas_view"),
        }) orelse return error.TextureViewCreateFailed;

        self.atlas_texture = texture;
        self.atlas_texture_view = view;

        log.info("Atlas updated: {}x{}", .{ atlas_size, atlas_size });
    }

    /// Text rendern
    pub fn renderText(
        self: *Self,
        render_pass: *wgpu.RenderPassEncoder,
        text_renderer: *text.TextRenderer,
        text_str: []const u8,
        x: f32,
        y: f32,
    ) !void {
        _ = self;
        _ = render_pass;
        _ = text_renderer;
        _ = text_str;
        _ = x;
        _ = y;
        // TODO: Text rendering implementation pending
        return;
    }

    pub fn setViewport(self: *Self, width: u32, height: u32) void {
        self.viewport_width = @floatFromInt(width);
        self.viewport_height = @floatFromInt(height);
    }
};
