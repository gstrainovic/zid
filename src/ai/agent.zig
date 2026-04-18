const std = @import("std");

pub const LlamaAgent = struct {
    allocator: std.mem.Allocator,
    process: *std.process.Child,
    model_path: []const u8,
    server_port: u16,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, llama_server_path: []const u8, model_path: []const u8, port: u16) !*Self {
        var self = try allocator.create(Self);
        self.allocator = allocator;
        self.model_path = try allocator.dupe(u8, model_path);
        self.server_port = port;

        var port_str_buf: [16]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_str_buf, "{d}", .{port});

        var ctx_size: u32 = 8192; // Default context size
        
        // Dynamisch den VRAM auslesen für Context Management
        if (std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits" },
        })) |res| {
            defer allocator.free(res.stdout);
            defer allocator.free(res.stderr);
            if (res.term == .Exited and res.term.Exited == 0) {
                const trimmed = std.mem.trim(u8, res.stdout, " \r\n");
                // Bei mehreren GPUs nimmt er hier den ersten Wert
                var lines = std.mem.tokenizeAny(u8, trimmed, "\r\n");
                if (lines.next()) |first_line| {
                    if (std.fmt.parseInt(u32, std.mem.trim(u8, first_line, " "), 10)) |free_mb| {
                        // Gemma 4 E2B Q4_K_M benötigt ca. 1.6 GB. 
                        // Wir nehmen 2048 MB als sicheren Puffer für Modell und OS an.
                        if (free_mb > 2048) {
                            const avail_mb = free_mb - 2048;
                            // Konservative Schätzung: 1 MB reicht für ca. 10-20 Tokens (KV Cache)
                            // Wir nutzen avail_mb * 10 und deckeln bei 16384.
                            ctx_size = @min(16384, avail_mb * 10);
                        } else {
                            ctx_size = 2048; // Minimaler Fallback bei wenig VRAM
                        }
                        std.log.info("Dynamic Context Size: {d} (Free VRAM: {d} MB)", .{ctx_size, free_mb});
                    } else |_| {}
                }
            }
        } else |_| {}

        var ctx_str_buf: [16]u8 = undefined;
        const ctx_str = try std.fmt.bufPrint(&ctx_str_buf, "{d}", .{ctx_size});

        const argv = &[_][]const u8{
            llama_server_path,
            "-m",
            self.model_path,
            "--port",
            port_str,
            "-c",
            ctx_str,
            "-ngl",
            "99", // Offload all layers to GPU
        };

        self.process = try allocator.create(std.process.Child);
        self.process.* = std.process.Child.init(argv, allocator);
        
        // Inherit current environment (respects GGML_VULKAN_DEVICE export)
        self.process.env_map = null;

        self.process.stdin_behavior = .Ignore;
        self.process.stdout_behavior = .Inherit;
        self.process.stderr_behavior = .Inherit;

        try self.process.spawn();

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.process.kill()) |term| {
            _ = term;
        } else |_| {}
        _ = self.process.wait() catch {};
        self.allocator.destroy(self.process);
        self.allocator.free(self.model_path);
        self.allocator.destroy(self);
    }

    /// ChatMessage struct to represent user and system messages
    pub const ChatMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    /// Sends a chat completion request to the local llama-server with retries
    pub fn sendChatCompletion(self: *Self, messages: []const ChatMessage) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var uri_buf: [128]u8 = undefined;
        const uri_str = try std.fmt.bufPrint(&uri_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{self.server_port});

        // Prepare JSON payload
        const json_payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .messages = messages,
            .temperature = 0.7,
        }, .{});
        defer self.allocator.free(json_payload);

        // Retry loop (Wait for server to be ready)
        var attempt: u32 = 0;
        const max_attempts = 10;
        while (attempt < max_attempts) : (attempt += 1) {
            var alloc_writer = std.io.Writer.Allocating.init(self.allocator);
            defer alloc_writer.deinit();

            const res = client.fetch(.{
                .location = .{ .url = uri_str },
                .method = .POST,
                .payload = json_payload,
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .response_writer = &alloc_writer.writer,
            }) catch |err| {
                if (err == error.ConnectionRefused and attempt < max_attempts - 1) {
                    std.Thread.sleep(1 * std.time.ns_per_s);
                    continue;
                }
                return err;
            };

            if (res.status != .ok) {
                std.log.err("Llama Server Error: {d}", .{res.status});
                return error.LlamaServerError;
            }

            var response_body = alloc_writer.toArrayList();
            defer response_body.deinit(self.allocator);

            // Parse response (OpenAI format): {"choices": [{"message": {"content": "..."}}]}
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body.items, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            const choices = parsed.value.object.get("choices") orelse return error.InvalidResponse;
            const msg_obj = choices.array.items[0].object.get("message") orelse return error.InvalidResponse;
            const content = msg_obj.object.get("content") orelse return error.InvalidResponse;
            
            return self.allocator.dupe(u8, content.string);
        }
        return error.ConnectionRefused;
    }
};
