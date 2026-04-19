const std = @import("std");

pub const LlamaAgent = struct {
    allocator: std.mem.Allocator,
    process: ?*std.process.Child,
    model_path: []const u8,
    server_port: u16,
    connect_timeout_ns: u64,
    is_ollama: bool,

    const Self = @This();

    fn isOllamaInstalled(allocator: std.mem.Allocator) !bool {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "ollama", "--version" },
        }) catch return false;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        return result.term == .Exited and result.term.Exited == 0;
    }

    fn isOllamaDaemonRunning(allocator: std.mem.Allocator) !bool {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();
        const uri = try std.Uri.parse("http://127.0.0.1:11434/api/tags");
        _ = client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
        }) catch return false;
        return true;
    }

    fn isModelInstalled(allocator: std.mem.Allocator, model_name: []const u8) !bool {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "ollama", "list" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) return false;

        var lines = std.mem.tokenizeAny(u8, result.stdout, "\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (std.mem.startsWith(u8, trimmed, model_name)) return true;
        }
        return false;
    }

    fn pullModel(allocator: std.mem.Allocator, model_name: []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "ollama", "pull", model_name },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            return error.OllamaPullFailed;
        }
    }

    pub fn init(allocator: std.mem.Allocator, llama_server_path: []const u8, model_path: []const u8, port: u16) !*Self {
        return initWithTimeout(allocator, llama_server_path, model_path, port, 5 * std.time.ns_per_s);
    }

    pub fn initWithTimeout(allocator: std.mem.Allocator, llama_server_path: []const u8, model_path: []const u8, port: u16, timeout_ns: u64) !*Self {
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.model_path = try allocator.dupe(u8, model_path);
        errdefer allocator.free(self.model_path);

        self.server_port = port;
        self.connect_timeout_ns = timeout_ns;

        const is_ollama = std.mem.eql(u8, llama_server_path, "ollama");
        self.is_ollama = is_ollama;

        if (!is_ollama) {
            var ctx_size: u32 = 8192;
            // VRAM Check
            if (std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits" },
            })) |res| {
                defer allocator.free(res.stdout);
                defer allocator.free(res.stderr);
                if (res.term == .Exited and res.term.Exited == 0) {
                    const trimmed = std.mem.trim(u8, res.stdout, " \r\n");
                    var lines = std.mem.tokenizeAny(u8, trimmed, "\r\n");
                    if (lines.next()) |first_line| {
                        if (std.fmt.parseInt(u32, std.mem.trim(u8, first_line, " "), 10)) |free_mb| {
                            if (free_mb > 2048) {
                                ctx_size = @min(16384, (free_mb - 2048) * 10);
                            } else {
                                ctx_size = 2048;
                            }
                            std.log.info("Dynamic Context Size: {d} (Free VRAM: {d} MB)", .{ctx_size, free_mb});
                        } else |_| {}
                    }
                }
            } else |_| {}

            const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
            defer allocator.free(port_str);
            const ctx_str = try std.fmt.allocPrint(allocator, "{d}", .{ctx_size});
            defer allocator.free(ctx_str);

            const argv = &[_][]const u8{
                llama_server_path,
                "-m",
                self.model_path,
                "--port",
                port_str,
                "-c",
                ctx_str,
                "-ngl",
                "99",
            };

            const proc = try allocator.create(std.process.Child);
            errdefer allocator.destroy(proc);

            proc.* = std.process.Child.init(argv, allocator);
            proc.env_map = null;
            proc.stdin_behavior = .Ignore;
            proc.stdout_behavior = .Inherit;
            proc.stderr_behavior = .Inherit;

            try proc.spawn();
            self.process = proc;
        } else {
            // Ollama auto-start logic
            self.server_port = 11434;
            self.process = null;

            if (!try isOllamaInstalled(allocator)) {
                return error.OllamaNotInstalled;
            }

            if (!try isOllamaDaemonRunning(allocator)) {
                std.log.info("Ollama daemon not running, starting...", .{});
                const argv = &[_][]const u8{ "ollama", "serve" };
                var proc = std.process.Child.init(argv, allocator);
                proc.stdin_behavior = .Ignore;
                proc.stdout_behavior = .Inherit;
                proc.stderr_behavior = .Inherit;
                try proc.spawn();

                const p = try allocator.create(std.process.Child);
                p.* = proc;
                self.process = p;

                var waited: u64 = 0;
                while (waited < timeout_ns) : (waited += 100 * std.time.ns_per_ms) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    if (try isOllamaDaemonRunning(allocator)) break;
                }
                if (!try isOllamaDaemonRunning(allocator)) {
                    return error.OllamaFailedToStart;
                }
                std.log.info("Ollama daemon started", .{});
            }

            if (!try isModelInstalled(allocator, self.model_path)) {
                std.log.info("Model {s} not installed, pulling...", .{self.model_path});
                try pullModel(allocator, self.model_path);
                std.log.info("Model {s} pulled successfully", .{self.model_path});
            }

            std.log.info("Using Ollama with model {s} on port 11434", .{self.model_path});
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.process) |proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.allocator.destroy(proc);
        }
        self.allocator.free(self.model_path);
        self.allocator.destroy(self);
    }

    /// ChatMessage struct to represent user and system messages
    pub const ChatMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    /// Sends a chat completion request to the local llama-server with retries
    /// Returns error if should_stop is set OR connection fails after max_attempts.
    pub fn sendChatCompletion(self: *Self, messages: []const ChatMessage) ![]u8 {
        return sendChatCompletionWithStop(self, messages, null);
    }

    /// Same as sendChatCompletion but checks should_stop during retry loop.
    pub fn sendChatCompletionWithStop(self: *Self, messages: []const ChatMessage, should_stop: ?*const std.atomic.Value(bool)) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var uri_buf: [128]u8 = undefined;
        const uri_str = try std.fmt.bufPrint(&uri_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{self.server_port});

        // Prepare JSON payload
        const json_payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .model = self.model_path,
            .messages = messages,
            .temperature = 0.7,
        }, .{});
        defer self.allocator.free(json_payload);

        // Retry loop (Wait for server to be ready)
        var attempt: u32 = 0;
        const max_attempts = 10;
        while (attempt < max_attempts) : (attempt += 1) {
            // Check cancellation before each attempt
            if (should_stop) |s| if (s.load(.acquire)) return error.Cancelled;

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
                    // Split 1s sleep into 10x100ms for responsive shutdown
                    var slept: u32 = 0;
                    while (slept < 10) : (slept += 1) {
                        if (should_stop) |s| if (s.load(.acquire)) return error.Cancelled;
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                    }
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

            // Ollama uses "message.content", standard OpenAI also uses "message.content"
            const choices = parsed.value.object.get("choices") orelse return error.InvalidResponse;
            const msg_obj = choices.array.items[0].object.get("message") orelse return error.InvalidResponse;
            const content = msg_obj.object.get("content") orelse return error.InvalidResponse;

            return self.allocator.dupe(u8, content.string);
        }
        return error.ConnectionRefused;
    }
};
