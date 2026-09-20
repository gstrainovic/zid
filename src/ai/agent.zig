const std = @import("std");
const device_select = @import("device_select.zig");

/// Standardport für den llama-server, den zid selbst startet.
pub const default_llama_port: u16 = 8080;

pub const LlamaAgent = struct {
    allocator: std.mem.Allocator,
    process: ?*std.process.Child,
    model_path: []const u8,
    server_port: u16,
    connect_timeout_ns: u64,
    /// "Quadro P1000" oder "CPU" für die Statuszeile (owned)
    device_label: []const u8 = "",

    const Self = @This();

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

        {
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
            // enable_thinking=false: Denkende Modelle (gemma4) würden sonst erst 20–30 s
            // reasoning streamen; Qwen3-Instruct kennt den Schalter nicht, er ist dort wirkungslos.
            // `--reasoning-budget 0` ist der falsche Weg: gemma4 denkt dann im Antwortkanal weiter
            // (llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md).
            try argv.appendSlice(allocator, &.{ llama_server_path, "-m", self.model_path, "--port", port_str, "--jinja", "-c", "8192", "--log-disable", "--chat-template-kwargs", "{\"enable_thinking\":false}" });
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
    /// Gerätewahl per `llama-server --list-devices`; bei `.gpu` gehören id/name dem Aufrufer.
    pub fn detectDevice(allocator: std.mem.Allocator, llama_server_path: []const u8) device_select.Choice {
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
        /// Assistant: rohes OpenAI-`tool_calls`-Array (JSON), geht unverändert zurück
        tool_calls: ?[]const u8 = null,
        /// role = "tool": ID des beantworteten Aufrufs
        tool_call_id: ?[]const u8 = null,

        /// Optionale Felder nur schreiben, wenn gesetzt: `"tool_calls": null`
        /// bringt das Jinja-Template mancher Modelle durcheinander.
        pub fn jsonStringify(self: ChatMessage, jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write(self.role);
            try jw.objectField("content");
            try jw.write(self.content);
            if (self.tool_calls) |tc| {
                try jw.objectField("tool_calls");
                try jw.beginWriteRaw();
                try jw.writer.writeAll(tc);
                jw.endWriteRaw();
            }
            if (self.tool_call_id) |id| {
                try jw.objectField("tool_call_id");
                try jw.write(id);
            }
            try jw.endObject();
        }
    };

    /// Request-Body für /v1/chat/completions. `tools` ist ein fertiges JSON-Array
    /// (ai_tools.toolsJson) und wird roh eingefügt.
    fn buildPayload(self: *Self, messages: []const ChatMessage, stream: bool, tools: ?[]const u8, max_tokens: ?u32) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(self.model_path);
        try jw.objectField("messages");
        try jw.write(messages);
        try jw.objectField("temperature");
        try jw.write(0.7);
        if (stream) {
            try jw.objectField("stream");
            try jw.write(true);
            // Letzter Chunk trägt dann `usage` (llama-server auch `timings`), siehe logUsage.
            try jw.objectField("stream_options");
            try jw.beginObject();
            try jw.objectField("include_usage");
            try jw.write(true);
            try jw.endObject();
        }
        if (max_tokens) |mt| {
            try jw.objectField("max_tokens");
            try jw.write(mt);
        }
        if (tools) |t| {
            try jw.objectField("tools");
            try jw.beginWriteRaw();
            try jw.writer.writeAll(t);
            jw.endWriteRaw();
        }
        try jw.endObject();
        return out.toOwnedSlice();
    }

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
        const json_payload = try self.buildPayload(messages, false, null, max_tokens);
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
                // 503 während des Warmups: der Server lädt das Modell noch — kein Fehler, nur warten
                if (res.status == .service_unavailable) {
                    std.log.debug("llama-server still loading (503)", .{});
                    return error.ServerLoading;
                }
                const body = alloc_writer.written();
                if (res.status == .bad_request and isContextOverflow(body)) return error.ContextTooLong;
                std.log.err("Llama Server Error: {d} {s}", .{ res.status, body[0..@min(body.len, 400)] });
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

    pub const DeltaSink = struct {
        ctx: *anyopaque,
        on_delta: *const fn (ctx: *anyopaque, delta: []const u8) void,
    };

    /// Gestreamte Chat-Completion (SSE, `stream: true`): jedes Textstück geht an
    /// `sink`, sobald es ankommt. `cancel` (Escape) und `should_stop` (Shutdown)
    /// beenden den Stream mit error.Cancelled; der Aufrufer hat den Teiltext.
    /// Teil-Aufruf während des Streamings (Deltas werden je Index zusammengesetzt)
    const PartialCall = struct {
        id: std.ArrayListUnmanaged(u8) = .empty,
        name: std.ArrayListUnmanaged(u8) = .empty,
        args: std.ArrayListUnmanaged(u8) = .empty,
    };

    /// Gestreamte Chat-Completion. Textstücke gehen an `sink`; will das Modell
    /// Werkzeuge, kommt am Ende das komplette OpenAI-`tool_calls`-Array als JSON
    /// zurück (owned), sonst null.
    pub fn streamChatCompletion(
        self: *Self,
        messages: []const ChatMessage,
        tools: ?[]const u8,
        should_stop: ?*const std.atomic.Value(bool),
        cancel: ?*const std.atomic.Value(bool),
        sink: DeltaSink,
    ) !?[]u8 {
        var calls: std.ArrayListUnmanaged(PartialCall) = .empty;
        defer {
            for (calls.items) |*c| {
                c.id.deinit(self.allocator);
                c.name.deinit(self.allocator);
                c.args.deinit(self.allocator);
            }
            calls.deinit(self.allocator);
        }
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        var uri_buf: [128]u8 = undefined;
        const uri_str = try std.fmt.bufPrint(&uri_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{self.server_port});
        const uri = try std.Uri.parse(uri_str);

        const json_payload = try self.buildPayload(messages, true, tools, null);
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
                // 400 über der Kontextgrenze: llama-server kürzt nicht still, sondern lehnt ab.
                // Andere 400er (Schema, Template) nicht als Kontextfehler behandeln.
                var err_buf: [4096]u8 = undefined;
                var err_reader = response.reader(&err_buf);
                const body = err_reader.allocRemaining(self.allocator, .limited(16 * 1024)) catch "";
                defer if (body.len > 0) self.allocator.free(body);
                if (response.head.status == .bad_request and isContextOverflow(body)) {
                    std.log.info("llama-server: prompt exceeds the context window", .{});
                    return error.ContextTooLong;
                }
                std.log.err("Llama Server Error: {d} {s}", .{ @intFromEnum(response.head.status), body[0..@min(body.len, 400)] });
                return error.LlamaServerError;
            }

            var reader_buf: [64 * 1024]u8 = undefined;
            const reader = response.reader(&reader_buf);
            // finish_reason "length": Antwort lief ans Ende des Kontextfensters
            var truncated = false;
            while (true) {
                if (isSet(should_stop) or isSet(cancel)) return error.Cancelled;
                // null = Stream zu Ende (EndOfStream kommt hier als null, nicht als Fehler)
                const line = (try reader.takeDelimiter('\n')) orelse return try self.endStream(&calls, truncated);
                const trimmed = std.mem.trim(u8, line, " \r");
                if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
                const data = std.mem.trim(u8, trimmed["data:".len..], " ");
                if (std.mem.eql(u8, data, "[DONE]")) return try self.endStream(&calls, truncated);
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .ignore_unknown_fields = true }) catch continue;
                defer parsed.deinit();
                logUsage(parsed.value);
                if (finishReason(parsed.value)) |fr| {
                    if (std.mem.eql(u8, fr, "length")) truncated = true;
                }
                const choices = parsed.value.object.get("choices") orelse continue;
                if (choices != .array or choices.array.items.len == 0) continue;
                const delta = choices.array.items[0].object.get("delta") orelse continue;
                if (delta != .object) continue;
                if (delta.object.get("tool_calls")) |tcs| {
                    if (tcs == .array) try self.accumulateToolCalls(&calls, tcs.array.items);
                }
                const content = delta.object.get("content") orelse continue;
                if (content != .string or content.string.len == 0) continue;
                sink.on_delta(sink.ctx, content.string);
            }
        }
        return error.ConnectionRefused;
    }

    fn accumulateToolCalls(self: *Self, calls: *std.ArrayListUnmanaged(PartialCall), items: []const std.json.Value) !void {
        for (items) |item| {
            if (item != .object) continue;
            const idx_v = item.object.get("index");
            const idx: usize = if (idx_v != null and idx_v.? == .integer and idx_v.?.integer >= 0) @intCast(idx_v.?.integer) else calls.items.len;
            while (calls.items.len <= idx) try calls.append(self.allocator, .{});
            const c = &calls.items[idx];
            if (item.object.get("id")) |id| if (id == .string) try c.id.appendSlice(self.allocator, id.string);
            if (item.object.get("function")) |f| if (f == .object) {
                if (f.object.get("name")) |n| if (n == .string) try c.name.appendSlice(self.allocator, n.string);
                if (f.object.get("arguments")) |a| if (a == .string) try c.args.appendSlice(self.allocator, a.string);
            };
        }
    }

    /// Stream-Ende: abgeschnittene Antworten melden `error.ReplyTruncated` (der Worker zeigt den
    /// Teiltext mit Hinweis); abgeschnittene Werkzeugaufrufe werden nie ausgeführt, ihre
    /// Argumente wären unvollständiges JSON.
    fn endStream(self: *Self, calls: *std.ArrayListUnmanaged(PartialCall), truncated: bool) !?[]u8 {
        if (truncated) {
            std.log.warn("reply hit the end of the context window (finish_reason length), {d} tool call(s) dropped", .{calls.items.len});
            return error.ReplyTruncated;
        }
        return self.finishToolCalls(calls);
    }

    /// OpenAI-Form: [{"id","type":"function","function":{"name","arguments"}}]
    fn finishToolCalls(self: *Self, calls: *std.ArrayListUnmanaged(PartialCall)) !?[]u8 {
        if (calls.items.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginArray();
        for (calls.items, 0..) |c, i| {
            if (c.name.items.len == 0) continue;
            try jw.beginObject();
            try jw.objectField("id");
            if (c.id.items.len > 0) try jw.write(c.id.items) else try jw.print("\"call_{d}\"", .{i});
            try jw.objectField("type");
            try jw.write("function");
            try jw.objectField("function");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(c.name.items);
            try jw.objectField("arguments");
            try jw.write(if (c.args.items.len > 0) c.args.items else "{}");
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
        return try out.toOwnedSlice();
    }

    fn isSet(flag: ?*const std.atomic.Value(bool)) bool {
        if (flag) |f| return f.load(.acquire);
        return false;
    }

    /// Prompt- und Antwortgrösse aus dem letzten Stream-Chunk (llama-server: `usage` und
    /// `timings`). Macht sichtbar, was der Werkzeug-Prompt kostet: auf CPU steht die
    /// Prompt-Auswertung vor dem ersten Delta.
    fn logUsage(v: std.json.Value) void {
        if (v != .object) return;
        const usage = v.object.get("usage") orelse return;
        if (usage != .object) return;
        const p = usage.object.get("prompt_tokens") orelse return;
        const c = usage.object.get("completion_tokens") orelse std.json.Value{ .integer = 0 };
        if (p != .integer or c != .integer) return;
        var prompt_ms: f64 = 0;
        if (v.object.get("timings")) |t| if (t == .object) {
            if (t.object.get("prompt_ms")) |ms| prompt_ms = switch (ms) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0,
            };
        };
        std.log.info("usage: prompt_tokens={d} completion_tokens={d} prompt_ms={d:.0}", .{ p.integer, c.integer, prompt_ms });
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

/// `choices[0].finish_reason` eines Stream-Chunks, null solange keiner gesetzt ist.
/// "length" heisst: die Antwort lief ans Ende des Kontextfensters und ist abgeschnitten.
pub fn finishReason(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const choices = v.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const first = choices.array.items[0];
    if (first != .object) return null;
    const fr = first.object.get("finish_reason") orelse return null;
    return if (fr == .string) fr.string else null;
}

/// Fehler-Body von llama-server: `{"error":{"type":"exceed_context_size_error",…}}`. Nur dieser
/// Typ heisst „Prompt zu lang“; andere 400er (kaputtes Schema, Template) dürfen keine Kürzung auslösen.
pub fn isContextOverflow(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"exceed_context_size_error\"") != null;
}

test "finishReason: liest choices[0].finish_reason, null wenn keiner gesetzt" {
    const a = std.testing.allocator;
    const chunks = [_]struct { json: []const u8, want: ?[]const u8 }{
        .{ .json = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}", .want = "length" },
        .{ .json = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":null}]}", .want = null },
        .{ .json = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}", .want = "stop" },
        .{ .json = "{\"choices\":[]}", .want = null },
    };
    for (chunks) |c| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, c.json, .{});
        defer parsed.deinit();
        const got = finishReason(parsed.value);
        if (c.want) |w| try std.testing.expectEqualStrings(w, got.?) else try std.testing.expect(got == null);
    }
}

test "isContextOverflow: nur exceed_context_size_error zählt, andere 400er nicht" {
    try std.testing.expect(isContextOverflow(
        \\{"error":{"code":400,"message":"request (24017 tokens) exceeds the available context size (8192 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":24017,"n_ctx":8192}}
    ));
    try std.testing.expect(!isContextOverflow(
        \\{"error":{"code":400,"message":"Failed to parse tools","type":"invalid_request_error"}}
    ));
    try std.testing.expect(!isContextOverflow(""));
    try std.testing.expect(!isContextOverflow("<html>Bad Request</html>"));
}

