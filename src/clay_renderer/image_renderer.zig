//! Image Rendering - Pixeldaten → wgpu Texture → Textured Quad
//!
//! Unterstützt:
//! - Laden von RGBA Pixeldaten als wgpu Textur
//! - Textured Quad Rendering mit Tint und Opacity
//! - Test Pattern Generator für Debugging

const std = @import("std");
const wgpu = @import("wgpu");

const log = std.log.scoped(.image_renderer);

/// Vertex für Textured Quad Rendering
/// 2 floats position + 2 floats UV + 4 floats color = 8 floats = 32 bytes
pub const TexturedVertex = extern struct {
    position: [2]f32,   // NDC coordinates (-1 to 1)
    tex_coord: [2]f32,  // UV coordinates (0 to 1)
    color: [4]f32,      // Tint color with alpha
};

/// Eine Image-Textur die gerendert werden kann
pub const ImageTexture = struct {
    texture: *wgpu.Texture,
    view: *wgpu.TextureView,
    sampler: *wgpu.Sampler,
    width: u32,
    height: u32,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.view.release();
        self.sampler.release();
        self.texture.release();
    }
};

/// Image Renderer - verwaltet Texturen und rendert Textured Quads
pub const ImageRenderer = struct {
    allocator: std.mem.Allocator,
    device: *wgpu.Device,
    queue: *wgpu.Queue,
    render_pipeline: ?*wgpu.RenderPipeline = null,
    shader_module: ?*wgpu.ShaderModule = null,
    bind_group_layout: *wgpu.BindGroupLayout,
    swap_chain_format: wgpu.TextureFormat,

    // Vertex Buffer für Batching/Instancing
    vertex_buffer: ?*wgpu.Buffer = null,
    vertex_buffer_size: u64 = 0,
    vertex_buffer_cursor: u64 = 0,

    // Viewport Dimensionen
    viewport_width: f32 = 1.0,
    viewport_height: f32 = 1.0,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        device: *wgpu.Device,
        queue: *wgpu.Queue,
        swap_chain_format: wgpu.TextureFormat,
        viewport_width: u32,
        viewport_height: u32,
    ) !Self {
        log.debug("Initializing Image Renderer", .{});

        var self = Self{
            .allocator = allocator,
            .device = device,
            .queue = queue,
            .swap_chain_format = swap_chain_format,
            .viewport_width = @floatFromInt(viewport_width),
            .viewport_height = @floatFromInt(viewport_height),
            .bind_group_layout = undefined,
        };

        // Shader laden
        const shader_code = try std.fs.cwd().readFileAlloc(
            allocator,
            "zig-out/share/texture.wgsl",
            1024 * 1024,
        );
        defer allocator.free(shader_code);

        self.shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "texture.wgsl",
            .code = shader_code,
        })) orelse return error.ShaderCompileFailed;

        // Bind Group Layout: texture_2d + sampler
        const bind_group_layout_entries = [_]wgpu.BindGroupLayoutEntry{
            // Binding 0: sampled texture
            .{
                .binding = 0,
                .visibility = wgpu.ShaderStages.fragment,
                .texture = .{
                    .sample_type = .float,
                    .view_dimension = .@"2d",
                    .multisampled = 0,
                },
            },
            // Binding 1: sampler
            .{
                .binding = 1,
                .visibility = wgpu.ShaderStages.fragment,
                .sampler = .{
                    .type = wgpu.SamplerBindingType.filtering,
                },
            },
        };

        self.bind_group_layout = device.createBindGroupLayout(&wgpu.BindGroupLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("image_bind_group_layout"),
            .entry_count = bind_group_layout_entries.len,
            .entries = bind_group_layout_entries[0..].ptr,
        }) orelse return error.BindGroupLayoutCreateFailed;

        // Pipeline Layout
        const pipeline_layout = device.createPipelineLayout(&wgpu.PipelineLayoutDescriptor{
            .label = wgpu.StringView.fromSlice("image_pipeline_layout"),
            .bind_group_layout_count = 1,
            .bind_group_layouts = &[_]*wgpu.BindGroupLayout{self.bind_group_layout},
        }) orelse return error.PipelineLayoutCreateFailed;
        defer pipeline_layout.release();

        // Render Pipeline
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
                .array_stride = @sizeOf(TexturedVertex),
                .step_mode = .vertex,
                .attribute_count = 3,
                .attributes = &[_]wgpu.VertexAttribute{
                    // Position: location 0
                    .{
                        .format = .float32x2,
                        .offset = 0,
                        .shader_location = 0,
                    },
                    // TexCoord: location 1
                    .{
                        .format = .float32x2,
                        .offset = @sizeOf([2]f32),
                        .shader_location = 1,
                    },
                    // Color: location 2
                    .{
                        .format = .float32x4,
                        .offset = @sizeOf([2]f32) + @sizeOf([2]f32),
                        .shader_location = 2,
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
            .label = wgpu.StringView.fromSlice("image_pipeline"),
            .layout = pipeline_layout,
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

        log.debug("Image Renderer initialized", .{});
        return self;
    }

    pub fn deinit(self: *Self) void {
        log.debug("Image Renderer shutdown", .{});
        if (self.vertex_buffer) |b| b.release();
        self.bind_group_layout.release();
        if (self.render_pipeline) |p| p.release();
        if (self.shader_module) |s| s.release();
    }

    pub fn beginFrame(self: *Self) void {
        self.vertex_buffer_cursor = 0;
    }

    /// Erstelle eine Textur aus RGBA Pixeldaten
    pub fn createTextureFromPixels(
        self: *Self,
        pixels: []const u8,
        width: u32,
        height: u32,
    ) !ImageTexture {
        log.debug("Creating texture {}x{}", .{ width, height });

        const texture = self.device.createTexture(&wgpu.TextureDescriptor{
            .label = wgpu.StringView.fromSlice("image_texture"),
            .usage = wgpu.TextureUsages.texture_binding | wgpu.TextureUsages.copy_dst,
            .dimension = .@"2d",
            .size = .{
                .width = width,
                .height = height,
                .depth_or_array_layers = 1,
            },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        }) orelse return error.TextureCreateFailed;

        const view = texture.createView(&wgpu.TextureViewDescriptor{
            .label = wgpu.StringView.fromSlice("image_texture_view"),
        }) orelse return error.TextureViewCreateFailed;

        const sampler = self.device.createSampler(&wgpu.SamplerDescriptor{
            .label = wgpu.StringView.fromSlice("image_sampler"),
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .lod_min_clamp = 0.0,
            .lod_max_clamp = 1.0,
            .max_anisotropy = 1,
        }) orelse return error.SamplerCreateFailed;

        // Upload pixel data to texture
        const destination = wgpu.TexelCopyTextureInfo{
            .texture = texture,
            .mip_level = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = .all,
        };
        const data_layout = wgpu.TexelCopyBufferLayout{
            .offset = 0,
            .bytes_per_row = width * 4, // 4 bytes per pixel (RGBA)
            .rows_per_image = height,
        };
        const write_size = wgpu.Extent3D{
            .width = width,
            .height = height,
            .depth_or_array_layers = 1,
        };
        self.queue.writeTexture(
            &destination,
            pixels.ptr,
            pixels.len,
            &data_layout,
            &write_size,
        );

        return ImageTexture{
            .texture = texture,
            .view = view,
            .sampler = sampler,
            .width = width,
            .height = height,
        };
    }

    /// Lade eine Textur aus einer Datei (PNG via zigimg, SVG via cairo-rasterizer)
    pub fn createTextureFromPath(
        self: *Self,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !ImageTexture {
        log.debug("Loading image from path: {s}", .{path});

        if (std.ascii.endsWithIgnoreCase(path, ".svg")) {
            return self.createTextureFromSvg(allocator, path);
        }

        const zigimg = @import("zigimg");

        const file_data = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
        defer allocator.free(file_data);

        var img = try zigimg.Image.fromMemory(allocator, file_data);
        defer img.deinit(allocator);

        try img.convert(allocator, .rgba32);

        const src_pixels = switch (img.pixels) {
            .rgba32 => |buf| buf,
            else => return error.UnsupportedFormat,
        };
        const pixels = std.mem.sliceAsBytes(src_pixels);

        return self.createTextureFromPixels(pixels, @intCast(img.width), @intCast(img.height));
    }

    const ViewBox = struct { w: f32, h: f32 };

    /// Parse viewBox width + height aus SVG-Datei.
    /// Fallback: 24×24 (Lucide-Default).
    fn parseSvgViewBox(src: []const u8) ViewBox {
        const fallback = ViewBox{ .w = 24.0, .h = 24.0 };
        const needle = "viewBox";
        const vb_pos = std.mem.indexOf(u8, src, needle) orelse return fallback;
        var i = vb_pos + needle.len;
        while (i < src.len and src[i] != '"' and src[i] != '\'') : (i += 1) {}
        if (i >= src.len) return fallback;
        i += 1;
        const start = i;
        while (i < src.len and src[i] != '"' and src[i] != '\'') : (i += 1) {}
        const content = src[start..i];

        var it = std.mem.tokenizeAny(u8, content, " ,\t\n");
        _ = it.next() orelse return fallback;
        _ = it.next() orelse return fallback;
        const w_str = it.next() orelse return fallback;
        const h_str = it.next() orelse return fallback;
        const w = std.fmt.parseFloat(f32, w_str) catch return fallback;
        const h = std.fmt.parseFloat(f32, h_str) catch return fallback;
        if (w <= 0 or h <= 0) return fallback;
        return ViewBox{ .w = w, .h = h };
    }

    /// Lade SVG-Datei und rastere zu RGBA-Textur.
    /// Output: weiße Pixel mit Alpha-Mask — Tint-Farbe liefert image_view via background_color.
    /// Rasterisiert im Quadrat (max-dim = 512), extrahiert danach den Content-Rect
    /// in eine aspect-korrekte Textur.
    pub fn createTextureFromSvg(
        self: *Self,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !ImageTexture {
        const svg_mod = @import("../svg/mod.zig");

        const file_data = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
        defer allocator.free(file_data);

        const vb = parseSvgViewBox(file_data);
        const max_dim: u32 = 512;
        const vb_max = @max(vb.w, vb.h);

        // Square-Buffer rasterisieren (Rasterizer ist square-only)
        const sq_buffer = try allocator.alloc(u8, max_dim * max_dim * 4);
        defer allocator.free(sq_buffer);

        _ = svg_mod.rasterize(allocator, file_data, vb_max, max_dim, sq_buffer) catch |err| {
            log.err("SVG rasterize failed for '{s}': {}", .{ path, err });
            return error.SvgRasterizeFailed;
        };

        // Tight content dimensions (Pixel): viewBox dims × scale
        const scale: f32 = @as(f32, @floatFromInt(max_dim)) / vb_max;
        const content_w: u32 = @intFromFloat(@round(vb.w * scale));
        const content_h: u32 = @intFromFloat(@round(vb.h * scale));
        const w = @max(content_w, 1);
        const h = @max(content_h, 1);

        // Content-Rect in aspect-korrekten Buffer kopieren, RGB=weiß setzen.
        const out = try allocator.alloc(u8, w * h * 4);
        defer allocator.free(out);
        for (0..h) |y| {
            for (0..w) |x| {
                const src_idx = (y * max_dim + x) * 4;
                const dst_idx = (y * w + x) * 4;
                const a = sq_buffer[src_idx + 3];
                out[dst_idx + 0] = 255;
                out[dst_idx + 1] = 255;
                out[dst_idx + 2] = 255;
                out[dst_idx + 3] = a;
            }
        }

        return self.createTextureFromPixels(out, w, h);
    }

    /// Erstelle ein Test-Pattern (Checkerboard)
    pub fn createTestPattern(self: *Self, width: u32, height: u32) !ImageTexture {
        const pixels = try self.allocator.alloc(u8, width * height * 4);
        defer self.allocator.free(pixels);

        for (0..height) |y| {
            for (0..width) |x| {
                const i = (y * width + x) * 4;
                const checker = ((x / 16) + (y / 16)) % 2 == 0;
                if (checker) {
                    pixels[i + 0] = 255;
                    pixels[i + 1] = 0;
                    pixels[i + 2] = 255;
                    pixels[i + 3] = 255;
                } else {
                    pixels[i + 0] = 0;
                    pixels[i + 1] = 255;
                    pixels[i + 2] = 0;
                    pixels[i + 3] = 255;
                }
            }
        }

        return self.createTextureFromPixels(pixels, width, height);
    }

    /// Viewport aktualisieren (bei Resize)
    pub fn setViewport(self: *Self, width: u32, height: u32) void {
        log.debug("Image Renderer viewport resized to {}x{}", .{ width, height });
        self.viewport_width = @floatFromInt(width);
        self.viewport_height = @floatFromInt(height);
    }

    /// Rendere ein Textured Quad
    pub fn renderImage(
        self: *Self,
        render_pass: *wgpu.RenderPassEncoder,
        image: *const ImageTexture,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        tint: [4]f32,
    ) !void {
        // Vertices für Quad erstellen
        var vertices: [6]TexturedVertex = undefined;

        const x0_ndc = self.normalizeX(x);
        const y0_ndc = self.normalizeY(y);
        const x1_ndc = self.normalizeX(x + width);
        const y1_ndc = self.normalizeY(y + height);

        // Triangle 1
        vertices[0] = .{ .position = .{ x0_ndc, y0_ndc }, .tex_coord = .{ 0.0, 0.0 }, .color = tint };
        vertices[1] = .{ .position = .{ x1_ndc, y0_ndc }, .tex_coord = .{ 1.0, 0.0 }, .color = tint };
        vertices[2] = .{ .position = .{ x0_ndc, y1_ndc }, .tex_coord = .{ 0.0, 1.0 }, .color = tint };

        // Triangle 2
        vertices[3] = .{ .position = .{ x1_ndc, y0_ndc }, .tex_coord = .{ 1.0, 0.0 }, .color = tint };
        vertices[4] = .{ .position = .{ x1_ndc, y1_ndc }, .tex_coord = .{ 1.0, 1.0 }, .color = tint };
        vertices[5] = .{ .position = .{ x0_ndc, y1_ndc }, .tex_coord = .{ 0.0, 1.0 }, .color = tint };

        const data_size = @sizeOf(TexturedVertex) * 6;
        const total_needed = self.vertex_buffer_cursor + data_size;

        // Buffer sicherstellen
        if (self.vertex_buffer == null or self.vertex_buffer_size < total_needed) {
            const new_capacity = @max(total_needed * 2, 65536);
            if (self.vertex_buffer) |buf| buf.release();
            
            self.vertex_buffer = self.device.createBuffer(&wgpu.BufferDescriptor{
                .label = wgpu.StringView.fromSlice("image_vertex_buffer"),
                .size = new_capacity,
                .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
                .mapped_at_creation = 0,
            }) orelse return error.BufferCreateFailed;
            self.vertex_buffer_size = new_capacity;
            self.vertex_buffer_cursor = 0;
            log.debug("Image vertex buffer resized to {} bytes", .{self.vertex_buffer_size});
        }

        const offset = self.vertex_buffer_cursor;
        self.queue.writeBuffer(
            self.vertex_buffer.?,
            offset,
            @as(*const anyopaque, @ptrCast(vertices[0..].ptr)),
            data_size,
        );
        self.vertex_buffer_cursor += data_size;

        // Bind Group für diese Textur erstellen
        const bind_group_entries = [_]wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = null,
                .offset = 0,
                .size = 0,
                .sampler = null,
                .texture_view = image.view,
            },
            .{
                .binding = 1,
                .buffer = null,
                .offset = 0,
                .size = 0,
                .sampler = image.sampler,
                .texture_view = null,
            },
        };

        const bind_group = self.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice("image_bind_group"),
            .layout = self.bind_group_layout,
            .entry_count = bind_group_entries.len,
            .entries = bind_group_entries[0..].ptr,
        }) orelse return error.BindGroupCreateFailed;
        defer bind_group.release();

        // Render
        render_pass.setPipeline(self.render_pipeline.?);
        render_pass.setBindGroup(0, bind_group, 0, null);
        render_pass.setVertexBuffer(0, self.vertex_buffer.?, offset, data_size);
        render_pass.draw(6, 1, 0, 0);
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
