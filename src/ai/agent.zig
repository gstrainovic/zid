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

        const argv = &[_][]const u8{
            llama_server_path,
            "-m",
            self.model_path,
            "--port",
            port_str,
            "-c",
            "8192",
            "-ngl",
            "99", // Offload all layers to GPU
        };

        self.process = try allocator.create(std.process.Child);
        self.process.* = std.process.Child.init(argv, allocator);
        
        // Force NVIDIA GPU (Index 1 according to logs)
        var env_map = try std.process.getEnvMap(allocator);
        // Note: We are using the arena or caller must ensure this stays valid if spawn() uses it later.
        // Child.spawn() copies the env_map into its own structures in some versions, 
        // but in Zig 0.15 it's safer to keep it valid until spawn() returns.
        try env_map.put("GGML_VULKAN_DEVICE", "1");
        self.process.env_map = &env_map;

        self.process.stdin_behavior = .Ignore;
        self.process.stdout_behavior = .Inherit;
        self.process.stderr_behavior = .Inherit;

        try self.process.spawn();
        env_map.deinit();

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

    /// Sends a chat completion request to the local llama-server
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

        var alloc_writer = std.io.Writer.Allocating.init(self.allocator);
        defer alloc_writer.deinit();

        const res = try client.fetch(.{
            .location = .{ .url = uri_str },
            .method = .POST,
            .payload = json_payload,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .response_writer = &alloc_writer.writer,
        });

        if (res.status != .ok) {
            std.log.err("Llama Server Error: {d}", .{res.status});
            return error.LlamaServerError;
        }

        var response_body = alloc_writer.toArrayList();
        defer response_body.deinit(self.allocator);

        // Parse response (OpenAI format): {"choices": [{"message": {"content": "..."}}]}
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body.items, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const content = parsed.value.object.get("choices").?.array.items[0].object.get("message").?.object.get("content").?.string;
        return self.allocator.dupe(u8, content);
    }
};
