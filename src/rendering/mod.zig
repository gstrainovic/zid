//! Rendering-Modul für vulkan-ed
//!
//! Verwendet WGPU für cross-platform GPU Rendering.

const std = @import("std");
const builtin = @import("builtin");
const wgpu = @import("wgpu");
const clay = @import("clay");

const log = std.log.scoped(.rendering);

// Forward declaration
const image_renderer = @import("../clay_renderer/image_renderer.zig");

/// Image Daten für Rendering
pub const ImageToRender = struct {
    image: image_renderer.ImageTexture,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    tint_r: f32 = 1.0,
    tint_g: f32 = 1.0,
    tint_b: f32 = 1.0,
    tint_a: f32 = 1.0,
};

/// Renderer Konfiguration
pub const RendererConfig = struct {
    vsync: bool = true,
    clear_color: [4]f32 = .{ 0.15, 0.15, 0.2, 1.0 },
};

/// Dreieck Shader Pfad (wird zur Runtime geladen)
pub const triangle_shader_path = "zig-out/share/triangle.wgsl";

/// Renderer Hauptstruktur
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    config: RendererConfig,
    instance: ?*wgpu.Instance = null,
    adapter: ?*wgpu.Adapter = null,
    device: ?*wgpu.Device = null,
    queue: ?*wgpu.Queue = null,
    surface: ?*wgpu.Surface = null,
    shader_module: ?*wgpu.ShaderModule = null,
    render_pipeline: ?*wgpu.RenderPipeline = null,
    swap_chain_format: wgpu.TextureFormat = .bgra8_unorm,
    width: u32 = 0,
    height: u32 = 0,

    const Self = @This();

/// Globale Renderer-Zeiger für Headless-Screenshot
pub var g_renderer_ptr: ?*Renderer = null;
pub var g_clay_rdr: ?*@import("../clay_renderer/mod.zig").ClayRenderer = null;
pub var g_text_gpu: ?*@import("../text/mod.zig").GPURenderer = null;
pub var g_text_renderer: ?*@import("../text/mod.zig").TextRenderer = null;
pub var g_image_rdr: ?*@import("../clay_renderer/image_renderer.zig").ImageRenderer = null;
pub var g_svg_gpu: ?*@import("../svg/gpu_renderer.zig").SvgRendererGPU = null;
pub var g_svg_atlas: ?*@import("../svg/mod.zig").SvgAtlas = null;
pub var g_viewport_width: u32 = 1200;
pub var g_viewport_height: u32 = 800;

/// Renderer initialisieren
    pub fn init(allocator: std.mem.Allocator, config: RendererConfig) !Self {
        log.debug("Initializing renderer (WGPU backend, Vulkan forced via WGPU_BACKEND=vulkan)", .{});

        // WGPU Instance erstellen (NUR Vulkan)
        var extras = wgpu.InstanceExtras{
            .backends = wgpu.InstanceBackends.vulkan,
            .flags = wgpu.InstanceFlags.default,
            .dx12_shader_compiler = .@"undefined",
            .gles3_minor_version = .automatic,
            .gl_fence_behavior = .gl_fence_behaviour_normal,
            .dxc_max_shader_model = .dxc_max_shader_model_v6_0,
        };

        const base_descriptor = wgpu.InstanceDescriptor{
            .features = .{
                .timed_wait_any_enable = 0,
                .timed_wait_any_max_count = 0,
            },
        };
        const descriptor = base_descriptor.withNativeExtras(&extras);

        const instance = wgpu.Instance.create(&descriptor) orelse return error.NoInstance;

        // Adapter anfordern (Vulkan)
        const request_options = wgpu.RequestAdapterOptions{
            .backend_type = wgpu.BackendType.vulkan,
            .feature_level = wgpu.FeatureLevel.core,
        };
        const adapter_result = instance.requestAdapterSync(&request_options, 200_000_000);
        const adapter = switch (adapter_result.status) {
            .success => adapter_result.adapter.?,
            else => {
                instance.release();
                return error.NoAdapter;
            },
        };

        // Device anfordern (null = defaults verwenden)
        const device_result = adapter.requestDeviceSync(instance, null, 0);
        const device = switch (device_result.status) {
            .success => device_result.device.?,
            else => {
                adapter.release();
                instance.release();
                return error.NoDevice;
            },
        };

        const queue = device.getQueue() orelse {
            device.release();
            adapter.release();
            instance.release();
            return error.NoQueue;
        };

        // Shader-Datei laden (zur Runtime)
        const shader_code = try std.fs.cwd().readFileAlloc(allocator, triangle_shader_path, 1024 * 1024);
        defer allocator.free(shader_code);

        // Shader-Modul laden (WGSL)
        const shader_module = device.createShaderModule(&wgpu.shaderModuleWGSLDescriptor(.{
            .label = "triangle.wgsl",
            .code = shader_code,
        })) orelse {
            queue.release();
            device.release();
            adapter.release();
            instance.release();
            return error.ShaderCompileFailed;
        };

        // Render Pipeline erstellen
        const color_targets = [_]wgpu.ColorTargetState{
            wgpu.ColorTargetState{
                .format = .bgra8_unorm,
                .blend = &wgpu.BlendState{
                    .color = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .src_alpha,
                        .dst_factor = .one_minus_src_alpha,
                    },
                    .alpha = wgpu.BlendComponent{
                        .operation = .add,
                        .src_factor = .zero,
                        .dst_factor = .one,
                    },
                },
            },
        };

        const fragment_state = wgpu.FragmentState{
            .module = shader_module,
            .entry_point = wgpu.StringView.fromSlice("fs_main"),
            .target_count = color_targets.len,
            .targets = color_targets[0..].ptr,
        };

        const render_pipeline = device.createRenderPipeline(&wgpu.RenderPipelineDescriptor{
            .label = wgpu.StringView.fromSlice("triangle_pipeline"),
            .vertex = wgpu.VertexState{
                .module = shader_module,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
            },
            .primitive = wgpu.PrimitiveState{
                .topology = .triangle_list,
                .front_face = .ccw,
                .cull_mode = .none,
            },
            .fragment = &fragment_state,
            .multisample = wgpu.MultisampleState{},
        }) orelse {
            shader_module.release();
            queue.release();
            device.release();
            adapter.release();
            instance.release();
            return error.PipelineCreateFailed;
        };

        log.debug("WGPU initialized: instance={*} adapter={*} device={*}", .{ instance, adapter, device });

        return Self{
            .allocator = allocator,
            .config = config,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .shader_module = shader_module,
            .render_pipeline = render_pipeline,
        };
    }

    /// Renderer aufräumen
    pub fn deinit(self: *Self) void {
        log.info("Renderer shutdown", .{});
        if (self.render_pipeline) |p| p.release();
        if (self.shader_module) |s| s.release();
        if (self.surface) |surface| surface.release();
        if (self.queue) |queue| queue.release();
        if (self.device) |device| device.release();
        if (self.adapter) |adapter| adapter.release();
        if (self.instance) |instance| instance.release();
    }

    /// Surface vom wio Window erstellen (Linux/Wayland oder Windows)
    pub fn setWindow(self: *Self, display: ?*anyopaque, surface_handle: ?*anyopaque) !void {
        if (self.instance == null) return error.NoInstance;
        if (surface_handle == null) return error.NoSurfaceHandle;

        const descriptor = if (builtin.os.tag == .linux)
            wgpu.surfaceDescriptorFromWaylandSurface(.{
                .display = display orelse return error.NoWaylandDisplay,
                .surface = surface_handle.?,
            })
        else if (builtin.os.tag == .windows)
            wgpu.surfaceDescriptorFromWindowsHWND(.{
                .hinstance = @ptrCast(std.os.windows.kernel32.GetModuleHandleW(null) orelse return error.NoHinstance),
                .hwnd = surface_handle.?,
            })
        else
            @compileError("Unsupported platform for surface creation");

        self.surface = self.instance.?.createSurface(&descriptor);
        if (self.surface == null) return error.NoSurface;

        log.debug("WGPU surface created: {*}", .{self.surface});
    }

    /// Swap Chain konfigurieren
    pub fn configureSwapChain(self: *Self, width: u32, height: u32) !void {
        if (self.device == null) return error.NoDevice;
        if (self.surface == null) return error.NoSurface;

        self.width = width;
        self.height = height;

        const config = wgpu.SurfaceConfiguration{
            .usage = wgpu.TextureUsages.render_attachment,
            .format = self.swap_chain_format,
            .width = width,
            .height = height,
            .present_mode = if (self.config.vsync) .fifo else .immediate,
            .alpha_mode = .auto,
            .view_format_count = 0,
            .view_formats = &[0]wgpu.TextureFormat{},
            .device = self.device.?,
        };

        self.surface.?.configure(&config);
        log.debug("Swap chain configured: {}x{}", .{ width, height });
    }

    /// Frame starten
    pub fn beginFrame(self: *Self) ?*wgpu.TextureView {
        if (self.surface == null) return null;

        var surface_texture: wgpu.SurfaceTexture = undefined;
        self.surface.?.getCurrentTexture(&surface_texture);
        if (surface_texture.status != .success_optimal and surface_texture.status != .success_suboptimal) return null;

        return surface_texture.texture.?.createView(&wgpu.TextureViewDescriptor{
            .label = wgpu.StringView{},
        });
    }

    /// Frame beenden und präsentieren
    pub fn endFrame(self: *Self, texture_view: ?*wgpu.TextureView) void {
        if (texture_view) |view| view.release();
        _ = self.surface.?.present();
    }

    /// Viewport Resize
    pub fn resize(self: *Self, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return;
        log.debug("Viewport resized: {}x{}", .{ width, height });
        try self.configureSwapChain(width, height);
    }

    /// Clear Color setzen
    pub fn setClearColor(self: *Self, r: f32, g: f32, b: f32, a: f32) void {
        self.config.clear_color = .{ r, g, b, a };
    }

    /// Frame rendern (Clear + Dreieck + Present)
    pub fn renderFrame(self: *Self) void {
        const texture_view = self.beginFrame() orelse return;
        defer self.endFrame(texture_view);

        const command_encoder = self.device.?.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView{},
        }) orelse return;
        defer command_encoder.release();

        const color_attachments = [_]wgpu.ColorAttachment{
            .{
                .view = texture_view,
                .resolve_target = null,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = wgpu.Color{
                    .r = self.config.clear_color[0],
                    .g = self.config.clear_color[1],
                    .b = self.config.clear_color[2],
                    .a = self.config.clear_color[3],
                },
            },
        };

        const render_pass_desc = wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        };

        const render_pass = command_encoder.beginRenderPass(&render_pass_desc) orelse return;

        // Dreieck rendern
        render_pass.setPipeline(self.render_pipeline.?);
        render_pass.draw(3, 1, 0, 0);

        render_pass.end();
        render_pass.release();

        const command_buffer = command_encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView{},
        }) orelse return;
        defer command_buffer.release();

        self.queue.?.submit(&[_]*wgpu.CommandBuffer{command_buffer});
    }

    /// Frame rendern NUR mit Clay-Rechtecken (für Phase 3 Verifikation)
    pub fn renderFrameClayOnly(
        self: *Self,
        clay_rdr: anytype,
        clay_commands: []clay.RenderCommand,
    ) void {
        const texture_view = self.beginFrame() orelse return;
        defer self.endFrame(texture_view);

        const command_encoder = self.device.?.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView{},
        }) orelse return;
        defer command_encoder.release();

        const color_attachments = [_]wgpu.ColorAttachment{
            .{
                .view = texture_view,
                .resolve_target = null,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = wgpu.Color{
                    .r = self.config.clear_color[0],
                    .g = self.config.clear_color[1],
                    .b = self.config.clear_color[2],
                    .a = self.config.clear_color[3],
                },
            },
        };

        const render_pass_desc = wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        };

        const render_pass = command_encoder.beginRenderPass(&render_pass_desc) orelse return;

        // NUR Clay Rechtecke rendern (KEIN Dreieck, KEIN Text)
        clay_rdr.renderClayLayout(render_pass, clay_commands) catch return;

        render_pass.end();
        render_pass.release();

        const command_buffer = command_encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView{},
        }) orelse return;
        defer command_buffer.release();

        self.queue.?.submit(&[_]*wgpu.CommandBuffer{command_buffer});
    }

    /// Frame rendern mit Clay UI + Text + Images + SVGs (Clear + Clay + Text + Images + SVGs + Present)
    pub fn renderFrameWithText(
        self: *Self,
        clay_rdr: anytype,
        text_gpu: anytype,
        text_renderer: anytype,
        clay_commands: []clay.RenderCommand,
        text_str: []const u8,
        text_x: f32,
        text_y: f32,
        image_rdr: ?*image_renderer.ImageRenderer,
        images: []const ImageToRender,
        svg_gpu: ?*@import("../svg/gpu_renderer.zig").SvgRendererGPU,
        svg_atlas: ?*@import("../svg/mod.zig").SvgAtlas,
    ) void {
        const texture_view = self.beginFrame() orelse return;
        defer self.endFrame(texture_view);

        const command_encoder = self.device.?.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = wgpu.StringView{},
        }) orelse return;
        defer command_encoder.release();

        const color_attachments = [_]wgpu.ColorAttachment{
            .{
                .view = texture_view,
                .resolve_target = null,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = wgpu.Color{
                    .r = self.config.clear_color[0],
                    .g = self.config.clear_color[1],
                    .b = self.config.clear_color[2],
                    .a = self.config.clear_color[3],
                },
            },
        };

        const render_pass_desc = wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        };

        const render_pass = command_encoder.beginRenderPass(&render_pass_desc) orelse return;

        // 0. Renderer vorbereiten (Buffer Offset reset)
        clay_rdr.beginFrame();
        text_gpu.beginFrame();
        if (image_rdr) |img_renderer| {
            img_renderer.beginFrame();
        }
        if (svg_gpu) |sg| {
            sg.beginFrame();
            if (svg_atlas) |sa| {
                sa.resetFrameBudget();
            }
        }

        // 1. Clay UI rendern (Rechtecke + Text + Images + SVGs in korrekter Z-Order)
        clay_rdr.renderClayLayout(render_pass, text_gpu, text_renderer, image_rdr, svg_gpu, svg_atlas, clay_commands) catch return;

        // 2. Images rendern (über Clay UI - Legacy/Direct Rendering)
        if (image_rdr) |img_renderer| {
            if (images.len > 0) {
                for (images) |img| {
                    img_renderer.renderImage(
                        render_pass,
                        &img.image,
                        img.x,
                        img.y,
                        img.width,
                        img.height,
                        .{ img.tint_r, img.tint_g, img.tint_b, img.tint_a },
                    ) catch |err| {
                        log.err("Failed to render image: {}", .{err});
                    };
                }
            }
        }

        // 3. Zusätzlicher Text (optional)
        if (text_str.len > 0) {
            text_gpu.renderText(
                render_pass,
                text_renderer,
                text_str,
                text_x,
                text_y,
                text_renderer.config.size,
                1.0,
                .{ 1.0, 1.0, 1.0, 1.0 },
            ) catch {};
            text_gpu.flush(render_pass) catch {};
        }

        render_pass.end();
        render_pass.release();

        const command_buffer = command_encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView{},
        }) orelse return;
        defer command_buffer.release();

        self.queue.?.submit(&[_]*wgpu.CommandBuffer{command_buffer});
    }

    /// Headless Screenshot: rendert in Offscreen-Textur, kopiert Pixel in Buffer, gibt PPM-Pfad zurück.
    /// Kein Fenster, kein Surface — komplett unsichtbar.
    pub fn headlessScreenshot(self: *Self, alloc: std.mem.Allocator, path: []const u8) !void {
        const w = if (self.width == 0) g_viewport_width else self.width;
        const h = if (self.height == 0) g_viewport_height else self.height;

        const rgba = try self.headlessRenderToBuffer(alloc, w, h, null, null, null, null, null, null, null);
        defer alloc.free(rgba);

        // PPM schreiben (nur RGB, keine Alpha-Kanäle)
        var file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        var header: [256]u8 = undefined;
        const header_slice = std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ w, h }) catch unreachable;
        try file.writeAll(header_slice);
        // PPM P6: 3 bytes per pixel (RGB) - RGBA hat 4 Bytes/Pixel
        var src_idx: usize = 0;
        var pixel_count: usize = 0;
        while (pixel_count < w * h) : (pixel_count += 1) {
            try file.writeAll(rgba[src_idx..src_idx + 3]); // R, G, B
            src_idx += 4;
        }
    }

    /// Rendert UI in Offscreen-Textur und gibt RGBA-Pixel zurück.
    pub fn headlessRenderToBuffer(
        self: *Self,
        alloc: std.mem.Allocator,
        w: u32,
        h: u32,
        clay_rdr: ?*@import("../clay_renderer/mod.zig").ClayRenderer,
        text_gpu: ?*@import("../text/mod.zig").GPURenderer,
        text_renderer: ?*@import("../text/mod.zig").TextRenderer,
        image_rdr: ?*@import("../clay_renderer/image_renderer.zig").ImageRenderer,
        svg_gpu: ?*@import("../svg/gpu_renderer.zig").SvgRendererGPU,
        svg_atlas: ?*@import("../svg/mod.zig").SvgAtlas,
        render_commands: ?[]clay.RenderCommand,
    ) ![]u8 {
        const bytes_per_pixel: u32 = 4;
        const bytes_per_row = (w * bytes_per_pixel + 255) / 256 * 256; // 256-aligned
        const buffer_size = bytes_per_row * h;

        // Offscreen Textur erstellen
        const tex_desc = wgpu.TextureDescriptor{
            .usage = wgpu.TextureUsages.render_attachment | wgpu.TextureUsages.copy_src,
            .dimension = .@"2d",
            .size = .{ .width = w, .height = h, .depth_or_array_layers = 1 },
            .format = .bgra8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        };
        const offscreen_tex = self.device.?.createTexture(&tex_desc) orelse return error.TextureCreateFailed;
        defer offscreen_tex.release();

        const offscreen_view = offscreen_tex.createView(&.{}) orelse return error.ViewCreateFailed;
        defer offscreen_view.release();

        // Readback Buffer erstellen
        const buf_desc = wgpu.BufferDescriptor{
            .usage = wgpu.BufferUsages.map_read | wgpu.BufferUsages.copy_dst,
            .size = buffer_size,
            .mapped_at_creation = 0,
        };
        const readback_buf = self.device.?.createBuffer(&buf_desc) orelse return error.BufferCreateFailed;
        defer readback_buf.release();

        // CommandEncoder für Offscreen-Rendering
        const enc = self.device.?.createCommandEncoder(&.{}) orelse return error.EncoderCreateFailed;
        defer enc.release();

        const color_attachments = [_]wgpu.ColorAttachment{.{
            .view = offscreen_view,
            .resolve_target = null,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = wgpu.Color{
                .r = self.config.clear_color[0],
                .g = self.config.clear_color[1],
                .b = self.config.clear_color[2],
                .a = self.config.clear_color[3],
            },
        }};

        const render_pass_desc = wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        };

        const pass = enc.beginRenderPass(&render_pass_desc) orelse return error.PassCreateFailed;

        // UI rendern wenn Commands vorhanden
        if (render_commands) |commands| {
            // Wie im Fenster-Pfad: pro Render-Durchgang dürfen 4 neue SVGs
            // rasterisiert werden. Ohne Reset blieben neue Icons headless
            // nach dem ersten Screenshot dauerhaft "deferred".
            if (svg_atlas) |sa| sa.resetFrameBudget();
            if (clay_rdr) |cr| {
                if (text_gpu) |tg| {
                    if (text_renderer) |tr| {
                        cr.renderClayLayout(pass, tg, tr, image_rdr, svg_gpu, svg_atlas, commands) catch |err| {
                            log.err("headless renderClayLayout failed: {}", .{err});
                        };
                    }
                }
            }
        }

        pass.end();
        pass.release();

        // Kopiere Textur in Buffer
        const copy_src = wgpu.TexelCopyTextureInfo{
            .origin = wgpu.Origin3D{},
            .texture = offscreen_tex,
        };
        const copy_dst = wgpu.TexelCopyBufferInfo{
            .layout = wgpu.TexelCopyBufferLayout{
                .offset = 0,
                .bytes_per_row = bytes_per_row,
                .rows_per_image = h,
            },
            .buffer = readback_buf,
        };
        const output_extent = wgpu.Extent3D{
            .width = w,
            .height = h,
            .depth_or_array_layers = 1,
        };
        enc.copyTextureToBuffer(&copy_src, &copy_dst, &output_extent);

        const cmd = enc.finish(&.{}) orelse return error.CmdCmdBufferCreateFailed;
        defer cmd.release();

        self.queue.?.submit(&[_]*wgpu.CommandBuffer{cmd});
        _ = self.device.?.poll(true, null);

        // Buffer mappen und Pixel lesen
        var pixel_data: []u8 = undefined;
        var map_complete = false;
        _ = readback_buf.mapAsync(wgpu.MapModes.read, 0, buffer_size, wgpu.BufferMapCallbackInfo{
            .callback = struct {
                fn callback(status: wgpu.MapAsyncStatus, _: wgpu.StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                    _ = status;
                    const completed: *bool = @ptrCast(@alignCast(userdata1));
                    completed.* = true;
                }
            }.callback,
            .userdata1 = @ptrCast(&map_complete),
        });
        while (!map_complete) {
            _ = self.device.?.poll(true, null);
        }

        const mapped: [*]u8 = @ptrCast(@alignCast(readback_buf.getMappedRange(0, buffer_size).?));
        pixel_data = mapped[0..buffer_size];
        readback_buf.unmap();

        // BGRA → RGBA konvertieren (nur die effektiven Pixel, ohne Padding)
        const rgba_size = w * h * 4;
        var rgba = try alloc.alloc(u8, rgba_size);
        var dst: usize = 0;
        var row: usize = 0;
        while (row < h) : (row += 1) {
            var col: usize = 0;
            while (col < w * 4) : (col += 4) {
                const src = row * bytes_per_row + col;
                rgba[dst + 0] = pixel_data[src + 2];
                rgba[dst + 1] = pixel_data[src + 1];
                rgba[dst + 2] = pixel_data[src + 0];
                rgba[dst + 3] = pixel_data[src + 3];
                dst += 4;
            }
        }

        return rgba;
    }
};
