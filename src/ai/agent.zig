const std = @import("std");
const device_select = @import("device_select.zig");

/// Standardport für einen von uns gestarteten llama-server (Ollama hat 11434).
pub const default_llama_port: u16 = 8080;

pub const LlamaAgent = struct {
    allocator: std.mem.Allocator,
    process: ?*std.process.Child,
    model_path: []const u8,
    server_port: u16,
    connect_timeout_ns: u64,
    is_ollama: bool,
    /// "Quadro P1000", "CPU" oder "Ollama" für die Statuszeile (owned)
    device_label: []const u8 = "",

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

    pub fn pullModel(allocator: std.mem.Allocator, model_name: []const u8) !void {
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
            // Engine und Modell müssen da sein, sonst stirbt der Server leise nach dem Spawn.
            std.fs.cwd().access(llama_server_path, .{}) catch return error.EngineNotFound;
            std.fs.cwd().access(self.model_path, .{}) catch return error.ModelFileNotFound;

            // Gerät: diskrete GPU mit ≥ 3 GB, sonst CPU. Die iGPU ist laut Messung
            // (bitnet-colibri-bench) ein Drittel der CPU und wird übersprungen.
            const choice = detectDevice(allocator, llama_server_path);
            // detectDevice dupliziert id/name aus der Prozessausgabe; nach argv-Aufbau freigeben
            defer if (choice == .gpu) {
                allocator.free(choice.gpu.id);
                allocator.free(choice.gpu.name);
            };
            self.device_label = try allocator.dupe(u8, choice.label());
            errdefer allocator.free(self.device_label);

            const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
            defer allocator.free(port_str);
            const threads = @min(std.Thread.getCpuCount() catch 4, 8);
            const threads_str = try std.fmt.allocPrint(allocator, "{d}", .{threads});
            defer allocator.free(threads_str);

            var argv: std.ArrayListUnmanaged([]const u8) = .empty;
            defer argv.deinit(allocator);
            // -c 8192 passt bei 4B-Q4-Modellen samt KV-Cache in 4 GB VRAM (Bench-Einstellung).
            try argv.appendSlice(allocator, &.{ llama_server_path, "-m", self.model_path, "--port", port_str, "--jinja", "-c", "8192", "--log-disable" });
            switch (choice) {
                .gpu => |dev| try argv.appendSlice(allocator, &.{ "-dev", dev.id, "-ngl", "99" }),
                .cpu => try argv.appendSlice(allocator, &.{ "-dev", "none", "-ngl", "0", "-t", threads_str }),
            }
            std.log.info("llama-server: {s} on {s} (port {d})", .{ self.model_path, self.device_label, port });

            const proc = try allocator.create(std.process.Child);
            errdefer allocator.destroy(proc);

            proc.* = std.process.Child.init(argv.items, allocator);
            proc.env_map = null;
            proc.stdin_behavior = .Ignore;
            proc.stdout_behavior = .Ignore;
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

            // Kein synchroner Pull: das blockierte den UI-Start minutenlang.
            // Der Chat zeigt stattdessen einen "Pull model"-Knopf (ai_worker.taskOllamaPull).
            if (!try isModelInstalled(allocator, self.model_path)) {
                std.log.warn("Model {s} not installed in Ollama", .{self.model_path});
                return error.ModelNotInstalled;
            }

            self.device_label = try allocator.dupe(u8, "Ollama");
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
        if (self.device_label.len > 0) self.allocator.free(self.device_label);
        self.allocator.destroy(self);
    }

    /// `llama-server --list-devices` fragen und per device_select wählen.
    fn detectDevice(allocator: std.mem.Allocator, llama_server_path: []const u8) device_select.Choice {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ llama_server_path, "--list-devices" },
            .max_output_bytes = 64 * 1024,
        }) catch return .cpu;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        // Manche Builds schreiben die Liste auf stderr
        const text = if (std.mem.indexOf(u8, result.stdout, "Vulkan") != null or std.mem.indexOf(u8, result.stdout, "CUDA") != null) result.stdout else result.stderr;
        const choice = device_select.choose(text, 3000);
        // Slices zeigen in result.stdout/stderr → für den Rückgabewert kopieren wir nur das Label
        return switch (choice) {
            .cpu => .cpu,
            .gpu => |d| .{ .gpu = .{
                .id = allocator.dupe(u8, d.id) catch return .cpu,
                .name = allocator.dupe(u8, d.name) catch return .cpu,
                .total_mib = d.total_mib,
                .free_mib = d.free_mib,
            } },
        };
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
        return self.sendChatCompletionOpts(messages, should_stop, null);
    }

    /// `max_tokens`: Antwortlänge begrenzen (Warmup braucht nur ein Token; ohne
    /// Limit schrieb das Modell auf "ping" eine ganze Antwort und der Start
    /// dauerte auf kleinen GPUs minutenlang).
    pub fn sendChatCompletionOpts(self: *Self, messages: []const ChatMessage, should_stop: ?*const std.atomic.Value(bool), max_tokens: ?u32) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        var uri_buf: [128]u8 = undefined;
        const uri_str = try std.fmt.bufPrint(&uri_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{self.server_port});
        const json_payload = if (max_tokens) |mt|
            try std.json.Stringify.valueAlloc(self.allocator, .{
                .model = self.model_path,
                .messages = messages,
                .temperature = 0.7,
                .max_tokens = mt,
            }, .{})
        else
            try std.json.Stringify.valueAlloc(self.allocator, .{
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

    pub const DeltaSink = struct {
        ctx: *anyopaque,
        on_delta: *const fn (ctx: *anyopaque, delta: []const u8) void,
    };

    /// Gestreamte Chat-Completion (SSE, `stream: true`): jedes Textstück geht an
    /// `sink`, sobald es ankommt. `cancel` (Escape) und `should_stop` (Shutdown)
    /// beenden den Stream mit error.Cancelled; der Aufrufer hat den Teiltext.
    pub fn streamChatCompletion(
        self: *Self,
        messages: []const ChatMessage,
        should_stop: ?*const std.atomic.Value(bool),
        cancel: ?*const std.atomic.Value(bool),
        sink: DeltaSink,
    ) !void {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        var uri_buf: [128]u8 = undefined;
        const uri_str = try std.fmt.bufPrint(&uri_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{self.server_port});
        const uri = try std.Uri.parse(uri_str);

        const json_payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .model = self.model_path,
            .messages = messages,
            .temperature = 0.7,
            .stream = true,
        }, .{});
        defer self.allocator.free(json_payload);

        var attempt: u32 = 0;
        while (attempt < 10) : (attempt += 1) {
            if (isSet(should_stop) or isSet(cancel)) return error.Cancelled;
            var req = client.request(.POST, uri, .{
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "Accept", .value = "text/event-stream" },
                },
            }) catch |err| {
                if (err == error.ConnectionRefused and attempt < 9) {
                    sleepCancellable(should_stop, cancel) catch return error.Cancelled;
                    continue;
                }
                return err;
            };
            defer req.deinit();
            try req.sendBodyComplete(@constCast(json_payload));

            var redirect_buf: [4096]u8 = undefined;
            var response = try req.receiveHead(&redirect_buf);
            if (response.head.status != .ok) {
                std.log.err("Llama Server Error: {d}", .{@intFromEnum(response.head.status)});
                return error.LlamaServerError;
            }

            var reader_buf: [64 * 1024]u8 = undefined;
            const reader = response.reader(&reader_buf);
            while (true) {
                if (isSet(should_stop) or isSet(cancel)) return error.Cancelled;
                // null = Stream zu Ende (EndOfStream kommt hier als null, nicht als Fehler)
                const line = (try reader.takeDelimiter('\n')) orelse return;
                const trimmed = std.mem.trim(u8, line, " \r");
                if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
                const data = std.mem.trim(u8, trimmed["data:".len..], " ");
                if (std.mem.eql(u8, data, "[DONE]")) return;
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .ignore_unknown_fields = true }) catch continue;
                defer parsed.deinit();
                const choices = parsed.value.object.get("choices") orelse continue;
                if (choices != .array or choices.array.items.len == 0) continue;
                const delta = choices.array.items[0].object.get("delta") orelse continue;
                if (delta != .object) continue;
                const content = delta.object.get("content") orelse continue;
                if (content != .string or content.string.len == 0) continue;
                sink.on_delta(sink.ctx, content.string);
            }
        }
        return error.ConnectionRefused;
    }

    fn isSet(flag: ?*const std.atomic.Value(bool)) bool {
        if (flag) |f| return f.load(.acquire);
        return false;
    }

    /// 1 s in 100-ms-Schritten schlafen, bricht bei Stop/Cancel ab.
    fn sleepCancellable(should_stop: ?*const std.atomic.Value(bool), cancel: ?*const std.atomic.Value(bool)) !void {
        var slept: u32 = 0;
        while (slept < 10) : (slept += 1) {
            if (isSet(should_stop) or isSet(cancel)) return error.Cancelled;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
};
