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
        }

        render_pass.end();
        render_pass.release();

        const command_buffer = command_encoder.finish(&wgpu.CommandBufferDescriptor{
            .label = wgpu.StringView{},
        }) orelse return;
        defer command_buffer.release();

        self.queue.?.submit(&[_]*wgpu.CommandBuffer{command_buffer});
    }
};
