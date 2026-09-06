//! GPU Text Renderer für vulkan-ed
//!
//! Rendert Text als GPU-Quads mit Glyph-Atlas Textur.

const std = @import("std");
const wgpu = @import("wgpu");
const text = @import("mod.zig");
const glyph_layout = @import("glyph_layout.zig");

const log = std.log.scoped(.text_renderer_gpu);

pub const TextRendererGPU = struct {
    allocator: std.mem.Allocator,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    atlas_texture: ?*wgpu.Texture = null,
    atlas_texture_view: ?*wgpu.TextureView = null,
    sampler: ?*wgpu.Sampler = null,
    pipeline: ?*wgpu.RenderPipeline = null,
    text_pipeline: ?*wgpu.RenderPipeline = null,
    shader_module: ?*wgpu.ShaderModule = null,
    text_shader_module: ?*wgpu.ShaderModule = null,
    bind_group_layout: ?*wgpu.BindGroupLayout = null,
    pipeline_layout: ?*wgpu.PipelineLayout = null,
    vertex_buffer: ?*wgpu.Buffer = null,
    text_vertex_buffer: ?*wgpu.Buffer = null,
    text_vertex_buffer_size: usize = 0,
    text_vertex_buffer_cursor: usize = 0, // Aktuelle Position im Buffer
    text_vertex_count: u32 = 0,
    swap_chain_format: wgpu.TextureFormat = .bgra8_unorm,
    viewport_width: f32 = 1200,
    viewport_height: f32 = 800,
    atlas_size: u32 = 512,
    cached_glyphs: std.AutoHashMap(u21, GlyphQuad),
    last_atlas_generation: u32 = 0, // Trackt ob Atlas sich geändert hat

    batch_vertices: std.ArrayListUnmanaged(f32) = .empty,

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
        log.debug("Initializing GPU text renderer", .{});

        // Shader laden
        const shader_code = try std.fs.cwd().readFileAlloc(
            allocator,
            "zig-out/share/text_atlas.wgsl",
            1024 * 1024,
        );
        defer allocator.free(shader_code);

        const shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "text_atlas.wgsl",
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
        .array_stride = 8 * @sizeOf(f32), // pos: 2, uv: 2, color: 4
        .step_mode = .vertex,
        .attribute_count = 3,
        .attributes = &[_]wgpu.VertexAttribute{
            // pos
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            // uv
            .{ .format = .float32x2, .offset = 2 * @sizeOf(f32), .shader_location = 1 },
            // color
            .{ .format = .float32x4, .offset = 4 * @sizeOf(f32), .shader_location = 2 },
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
            .text_pipeline = null, // Wird bei erstem renderText erstellt
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .swap_chain_format = swap_chain_format,
            .viewport_width = @floatFromInt(viewport_width),
            .viewport_height = @floatFromInt(viewport_height),
            .cached_glyphs = std.AutoHashMap(u21, GlyphQuad).init(allocator),
            .batch_vertices = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        log.debug("GPU text renderer shutdown", .{});
        self.batch_vertices.deinit(self.allocator);
        if (self.text_vertex_buffer) |b| b.release();
        if (self.vertex_buffer) |b| b.release();
        if (self.atlas_texture_view) |v| v.release();
        if (self.atlas_texture) |t| t.release();
        if (self.bind_group_layout) |l| l.release();
        if (self.pipeline_layout) |l| l.release();
        if (self.text_pipeline) |p| p.release();
        if (self.text_shader_module) |s| s.release();
        if (self.sampler) |s| s.release();
        if (self.pipeline) |p| p.release();
        if (self.shader_module) |s| s.release();
        self.cached_glyphs.deinit();
    }

    pub fn beginFrame(self: *Self) void {
        self.text_vertex_buffer_cursor = 0;
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
    }

    /// Text rendern mit echtem Glyph-Atlas Rendering
    /// Verwendet Gooey's 3-Phasen-Pipeline: shapeTextInto → resolveGlyphBatch → emit Quads
    pub fn renderText(
        self: *Self,
        render_pass: *wgpu.RenderPassEncoder,
        text_renderer: *text.TextRenderer,
        text_str: []const u8,
        x: f32,
        y: f32,
        font_size: f32,
        scale_factor: f32,
        color: [4]f32,
    ) !void {
        if (text_str.len == 0) return;

        const ts = text_renderer.ts_ptr;

        const r = color[0];
        const g = color[1];
        const b = color[2];
        const a = color[3];

        // size_scale = font_size / metrics.point_size
        const size_scale = if (ts.getMetrics()) |metrics|
            font_size / metrics.point_size
        else
            1.0;

        // === Phase 1: Text shapen (echte Glyph-Metriken vom Font) ===
        // Runs bis max_batch_glyphs kommen ohne Heap aus dem Shape-Cache; längere Runs
        // (Binärdateien ohne Zeilenumbruch, sehr lange Zeilen) liefert shapeTextInto als
        // owned Heap-Slice mit beliebig vielen Glyphen. Die Stack-Puffer unten sind fix,
        // deshalb werden die Glyphen blockweise verarbeitet (früher: index out of bounds).
        const max_batch = glyph_layout.max_batch_glyphs;
        var glyph_buf: [max_batch]text.ShapedGlyph = undefined;
        var shaped = try ts.shapeTextInto(text_str, null, &glyph_buf);
        defer if (shaped.owned) shaped.deinit(ts.allocator);

        if (shaped.glyphs.len == 0) return;

        var device_x: [max_batch]f32 = undefined;
        var device_y: [max_batch]f32 = undefined;
        var subpixel_x: [max_batch]u8 = undefined;
        var cached_results: [max_batch]text.CachedGlyph = undefined;

        var pen_x = x;
        var offset: usize = 0;
        while (offset < shaped.glyphs.len) : (offset += max_batch) {
            const chunk = shaped.glyphs[offset..@min(offset + max_batch, shaped.glyphs.len)];
            const n = chunk.len;

            // === Phase 2: Device-Positionen + Subpixel-Offsets berechnen ===
            pen_x = glyph_layout.computeGlyphDevicePositions(
                chunk,
                pen_x,
                y, // baseline_y
                size_scale,
                scale_factor,
                device_x[0..n],
                device_y[0..n],
                subpixel_x[0..n],
            );

            // === Phase 3: Glyphs aus dem Atlas holen (batch, ein Lock) ===
            try ts.resolveGlyphBatch(chunk, font_size, subpixel_x[0..n], cached_results[0..n]);

            // Wenn sich der Atlas geändert hat (neue Glyphen gerastert), auf GPU hochladen
            // Auch beim ersten Mal hochladen (atlas_texture_view == null)
            if (self.atlas_texture_view == null or text_renderer.atlasGeneration() != self.last_atlas_generation) {
                if (self.batch_vertices.items.len > 0) {
                    try self.flush(render_pass);
                }
                try self.updateAtlas(text_renderer.getAtlasData(), text_renderer.getAtlasSize());
                self.last_atlas_generation = text_renderer.atlasGeneration();
            }

            // === Phase 4: GPU Vertices aus echten Glyph-Metriken bauen ===
            for (cached_results[0..n], device_x[0..n], device_y[0..n]) |cached, dev_x, dev_y| {
                if (cached.region.width == 0 or cached.region.height == 0) continue;

                // UV aus cached atlas_size (thread-safe, auch wenn Atlas wächst)
                const uv = cached.uv();

                const glyph_w: f32 = @floatFromInt(cached.region.width);
                const glyph_h: f32 = @floatFromInt(cached.region.height);

                // Device-Pixel Position: floor(device) + raster_offset → zurück zu logical
                const glyph_x = (@floor(dev_x) + @as(f32, @floatFromInt(cached.offset_x))) / scale_factor;
                const glyph_y = (@floor(dev_y) - @as(f32, @floatFromInt(cached.offset_y))) / scale_factor;

                // NDC (-1 bis 1)
                const ndc_x0 = (glyph_x / self.viewport_width) * 2.0 - 1.0;
                const ndc_y0 = -((glyph_y / self.viewport_height) * 2.0 - 1.0);
                const ndc_x1 = ((glyph_x + glyph_w) / self.viewport_width) * 2.0 - 1.0;
                const ndc_y1 = -(((glyph_y + glyph_h) / self.viewport_height) * 2.0 - 1.0);

                // 2 Dreiecke = 6 Vertices (pos: 2f32 + uv: 2f32 + color: 4f32)
                try self.batch_vertices.appendSlice(self.allocator, &.{
                    ndc_x0, ndc_y0, uv.u0, uv.v0, r, g, b, a,
                    ndc_x1, ndc_y0, uv.u1, uv.v0, r, g, b, a,
                    ndc_x0, ndc_y1, uv.u0, uv.v1, r, g, b, a,
                    ndc_x1, ndc_y0, uv.u1, uv.v0, r, g, b, a,
                    ndc_x1, ndc_y1, uv.u1, uv.v1, r, g, b, a,
                    ndc_x0, ndc_y1, uv.u0, uv.v1, r, g, b, a,
                });
            }
        }
    }

    pub fn hasBufferedText(self: *Self) bool {
        return self.batch_vertices.items.len > 0;
    }

    pub fn flush(self: *Self, render_pass: *wgpu.RenderPassEncoder) !void {
        if (self.batch_vertices.items.len == 0) return;

        // Atlas Bind Group
        const bind_group = self.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("text_bind_group"),
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
        }) orelse return error.BindGroupCreateFailed;
        defer bind_group.release();

        const needed_size = self.batch_vertices.items.len * @sizeOf(f32);
        const total_needed = self.text_vertex_buffer_cursor + needed_size;
        
        if (self.text_vertex_buffer == null or self.text_vertex_buffer_size < total_needed) {
            if (self.text_vertex_buffer) |buf| buf.release();
            self.text_vertex_buffer_size = @max(total_needed * 2, 65536);
            self.text_vertex_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
                .label = wgpu.StringView.fromSlice("text_vertex_buffer"),
                .size = self.text_vertex_buffer_size,
                .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
                .mapped_at_creation = 0,
            }) orelse return error.BufferCreateFailed;
            self.text_vertex_buffer_cursor = 0;
        }

        const offset = self.text_vertex_buffer_cursor;
        self.queue.writeBuffer(
            self.text_vertex_buffer.?,
            offset,
            @as(*const anyopaque, @ptrCast(self.batch_vertices.items.ptr)),
            needed_size,
        );
        self.text_vertex_buffer_cursor += needed_size;

        render_pass.setPipeline(self.pipeline.?);
        render_pass.setVertexBuffer(0, self.text_vertex_buffer.?, offset, needed_size);
        render_pass.setBindGroup(0, bind_group, 0, null);
        const vertex_count = self.batch_vertices.items.len / 8;
        render_pass.draw(@intCast(vertex_count), 1, 0, 0);

        self.batch_vertices.clearRetainingCapacity();
    }

    pub fn setViewport(self: *Self, width: u32, height: u32) void {
        self.viewport_width = @floatFromInt(width);
        self.viewport_height = @floatFromInt(height);
    }
};
