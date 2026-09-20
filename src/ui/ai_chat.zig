const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const Theme = @import("theme.zig").Theme;
const agent = @import("agent");
const scheduler_mod = @import("scheduler");
const ai_worker = @import("ai_worker");
const flow_core = @import("flow_core");
const CodeEditor = @import("../editor/mod.zig").CodeEditor;
const chat_markdown = @import("chat_markdown");
const MarkdownView = @import("markdown_view.zig").MarkdownView;
const ui_mod = @import("mod.zig");
const ai_tools = @import("ai_tools");
const ai_history = @import("ai_history");

/// Zeichenbudget für die mitgeschickte Historie. llama-server läuft mit `-c 8192`; Tools-Schema
/// (~6,5 k Zeichen) und Systemprompt kosten ~2 k Tokens, die Antwort braucht Platz, und ein
/// 8000-Token-Prompt dauerte auf der P1000 123 s. 12 000 Zeichen ≈ 3–4 k Tokens.
pub const history_budget_chars: usize = 12_000;

const ai_selfsetup = @import("ai_selfsetup");

const log = std.log.scoped(.ai_chat);

pub const AgentStatus = enum { none, initializing, ready, failed };

pub const ChatMessage = struct {
    role: []const u8,
    /// Roher Text, geht so an die API und in die Zwischenablage.
    content: []const u8,
    /// Anzeige-Markdown (Tool-Calls als Codeblock) mit eigenem Renderer.
    md: MarkdownView,
    /// Assistant: rohes OpenAI-tool_calls-Array (owned), geht unverändert zurück
    tool_calls_json: ?[]u8 = null,
    /// role = "tool": beantworteter Aufruf (owned)
    tool_call_id: ?[]u8 = null,
};

/// Mehr Runden hintereinander deuten auf eine Schleife des Modells hin.
pub const max_tool_rounds: u32 = 8;

const message_font_size: u16 = 16;
const message_text_color: clay.Color = .{ 240, 240, 240, 255 };

pub const AIChatState = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(ChatMessage),
    agent: ?*agent.LlamaAgent = null,
    scheduler: ?*scheduler_mod.Scheduler = null,

    /// Eigene Kopien (initAgent dupliziert), leer = nicht konfiguriert
    server_path: []const u8 = "",
    model_path: []const u8 = "",
    /// Echter Verbindungszustand für Statuspunkt und Fehlermeldungen
    agent_status: AgentStatus = .none,
    status_detail_buf: [256]u8 = undefined,
    status_detail_len: usize = 0,
    title_buf: [160]u8 = undefined,
    /// Gestreamte Antwort, die gerade wächst (bis ai_chat_reply/cancelled kommt)
    stream_text: std.ArrayListUnmanaged(u8) = .empty,
    stream_md: ?MarkdownView = null,
    stream_dirty: bool = false,
    /// Escape setzt das Flag; der Worker beendet den Stream
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// OpenAI-`tools`-Array aus ai_tools.toolsJson (owned)
    tools_json: []u8 = "",
    /// Vom Modell angeforderte, noch nicht ausgeführte Aufrufe (UI.update arbeitet sie ab)
    pending_tools: std.ArrayListUnmanaged(ai_tools.ToolCall) = .empty,
    /// Aufrufe, deren Ergebnis noch fehlt; bei 0 geht die Runde ans Modell zurück
    awaiting_tool_results: usize = 0,
    /// Werkzeugrunden seit der letzten Benutzerfrage
    tool_rounds: u32 = 0,

    is_loading: bool = false,
    /// Selbsteinrichtung: Engine und Modell ins Datenverzeichnis holen, wenn zid
    /// ohne Quellbaum läuft (installierte Fassung). Null = nicht verfügbar.
    /// Eigentum des Chats: `deinit` gibt ihn frei.
    self_setup: ?*ai_selfsetup.SelfSetup = null,
    /// Nach abgeschlossener Einrichtung einmalig den Agenten neu verbinden.
    self_setup_applied: bool = false,
    /// Die Frage nach der Einrichtung steht einmal im Verlauf, nicht in jedem Frame.
    setup_prompted: bool = false,
    /// „Später" gedrückt: bis zum nächsten Start keine Antwortknöpfe mehr.
    setup_dismissed: bool = false,
    is_downloading: bool = false,
    is_initializing: bool = false,
    download_progress: f32 = 0,
    model_exists: bool = false,
    last_copy_time: i64 = 0,
    /// Textauswahl in einer Nachrichten-Bubble: Index der Nachricht, deren MarkdownView den
    /// Anker hält (unter `mutex`, weil der Worker Nachrichten anhängt).
    sel_msg: ?usize = null,
    /// Klick ohne Ziehen auf eine Bubble: ganze Nachricht kopieren (im Render, dort ist das Fenster).
    pending_copy_msg: ?usize = null,

    mutex: std.Thread.Mutex = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    scroll_offset_y: f32 = 0,
    viewport_height: f32 = 0,
    content_height: f32 = 0,
    last_input_time_ms: i64 = 0,
    ui_time_ms: f32 = 0,

    width: f32 = 350.0,

    // Messages-Scrollbar Bounds (im render aus bounding_box gefüllt)
    msg_sb_track_x: f32 = 0,
    msg_sb_track_y: f32 = 0,
    msg_sb_track_h: f32 = 0,
    msg_sb_thumb_y: f32 = 0,
    msg_sb_thumb_h: f32 = 0,
    msg_sb_visible: bool = false,
    msg_sb_dragging: bool = false,
    msg_sb_drag_offset: f32 = 0,

    /// Eingabefeld: derselbe CodeEditor wie die Datei-Tabs, ohne Gutter/Minimap, mit Word-Wrap
    input_editor: CodeEditor,
    input_buffer: *flow_core.Buffer,
    input_height: f32 = 120,
    input_splitter_dragging: bool = false,
    input_splitter_offset: f32 = 0,
    input_splitter_y: f32 = 0,
    input_splitter_h: f32 = splitter_height,
    input_bounds_valid: bool = false,
    input_bounds_x: f32 = 0,
    input_bounds_y: f32 = 0,
    input_bounds_w: f32 = 0,
    input_bounds_h: f32 = 0,

    const Self = @This();

    const model_filename = "models/gemma-4-E2B-it-Q4_K_M.gguf";

    pub fn init(allocator: std.mem.Allocator) !Self {
        var exists = false;
        if (std.fs.cwd().access(model_filename, .{})) |_| {
            exists = true;
        } else |_| {}

        const input_buf = try flow_core.Buffer.create(allocator);
        errdefer input_buf.deinit();

        var state = Self{
            .allocator = allocator,
            .messages = .empty,
            .input_editor = CodeEditor.init(allocator, input_buf),
            .input_buffer = input_buf,
            .model_exists = exists,
        };
        state.input_editor.show_gutter = false;
        state.input_editor.show_minimap = false;
        state.input_editor.show_indent_guides = false;
        state.input_editor.compact_menu = true;
        state.input_editor.word_wrap = true;
        state.input_editor.bg_color = .{ 28, 28, 34, 255 };
        state.tools_json = ai_tools.toolsJson(allocator) catch "";
        // Buffer.create liefert einen Root ohne Zeilenanfang (keine Zeile 0).
        // Erst load_from_string("") via setText macht den Puffer beschreibbar,
        // sonst verwirft der Rope-Walker jedes Zeichen nach dem ersten.
        state.input_editor.setText("");

        return state;
    }

    pub fn setScheduler(self: *Self, sched: *scheduler_mod.Scheduler) void {
        self.scheduler = sched;
        if (self.agent != null and self.is_initializing) {
            self.submitWarmup() catch |err| log.err("deferred warmup submit failed: {}", .{err});
        }
    }

    pub fn deinit(self: *Self) void {
        self.stop_flag.store(true, .seq_cst);

        // Der Vorgang gehört dem Chat, sobald er ihm übergeben wurde (UI.init legt ihn
        // an). `deinit` wartet auf den Ladethread, sonst schriebe er in freigegebenen
        // Speicher weiter.
        if (self.self_setup) |st| {
            st.deinit();
            self.allocator.destroy(st);
            self.self_setup = null;
        }

        for (self.messages.items) |*msg| {
            msg.md.deinit();
            self.allocator.free(msg.content);
            self.allocator.free(msg.role);
            if (msg.tool_calls_json) |t| self.allocator.free(t);
            if (msg.tool_call_id) |t| self.allocator.free(t);
        }
        self.messages.deinit(self.allocator);
        for (self.pending_tools.items) |c| c.deinit(self.allocator);
        self.pending_tools.deinit(self.allocator);
        if (self.tools_json.len > 0) self.allocator.free(self.tools_json);
        self.input_editor.deinit();
        self.input_buffer.deinit();
        if (self.agent) |a| a.deinit();
        self.clearStream();
        self.stream_text.deinit(self.allocator);
        if (self.server_path.len > 0) self.allocator.free(self.server_path);
        if (self.model_path.len > 0) self.allocator.free(self.model_path);
    }


    pub fn statusDetail(self: *const Self) []const u8 {
        return self.status_detail_buf[0..self.status_detail_len];
    }

    fn setStatus(self: *Self, status: AgentStatus, detail: []const u8) void {
        self.agent_status = status;
        const n = @min(detail.len, self.status_detail_buf.len);
        @memcpy(self.status_detail_buf[0..n], detail[0..n]);
        self.status_detail_len = n;
    }

    /// Kopfzeile: Modell und Gerät, z.B. "Qwen3-4B-Instruct-2507-Q4_K_M · Quadro P1000"
    pub fn agentTitle(self: *Self) []const u8 {
        const model = blk: {
            const base = std.fs.path.basename(self.model_path);
            break :blk if (std.mem.endsWith(u8, base, ".gguf")) base[0 .. base.len - 5] else base;
        };
        if (model.len == 0) return "AI Agent";
        const device = if (self.agent) |a| a.device_label else "";
        if (device.len > 0) {
            return std.fmt.bufPrint(&self.title_buf, "{s} · {s}", .{ model, device }) catch model;
        }
        return std.fmt.bufPrint(&self.title_buf, "{s}", .{model}) catch model;
    }

    fn clearStream(self: *Self) void {
        self.stream_text.clearRetainingCapacity();
        if (self.stream_md) |*md| md.deinit();
        self.stream_md = null;
        self.stream_dirty = false;
    }

    /// Delta einer gestreamten Antwort (Main-Thread, aus dem Scheduler-Ergebnis).
    pub fn handleDelta(self: *Self, payload: []const u8) void {
        if (!self.is_loading) return;
        self.stream_text.appendSlice(self.allocator, payload) catch return;
        self.stream_dirty = true;
        self.scroll_offset_y = 999999;
    }

    /// Escape: laufende Antwort abbrechen. Der Teiltext bleibt als Nachricht.
    pub fn cancelRequest(self: *Self) void {
        if (self.is_loading) self.cancel_flag.store(true, .release);
    }

    pub fn handleCancelled(self: *Self, payload: []const u8) void {
        var buf: [4096]u8 = undefined;
        const msg: []const u8 = if (payload.len > 0)
            std.fmt.bufPrint(&buf, "{s}\n\n(abgebrochen)", .{payload[0..@min(payload.len, buf.len - 24)]}) catch payload
        else
            "(abgebrochen)";
        self.addMessage("assistant", msg) catch {};
        self.clearStream();
        self.is_loading = false;
    }

    /// Kurztext neben dem Statuspunkt
    pub fn statusText(self: *const Self) []const u8 {
        return switch (self.agent_status) {
            .none => "Not connected",
            .initializing => "Initializing...",
            .ready => "Ready",
            .failed => "Failed",
        };
    }

    pub fn initAgent(self: *Self, server_path: []const u8, model_path: []const u8) !void {
        if (self.agent) |a| {
            a.deinit();
            self.agent = null;
        }

        if (server_path.ptr != self.server_path.ptr) {
            const sp = try self.allocator.dupe(u8, server_path);
            if (self.server_path.len > 0) self.allocator.free(self.server_path);
            self.server_path = sp;
        }
        if (model_path.ptr != self.model_path.ptr) {
            const mp = try self.allocator.dupe(u8, model_path);
            if (self.model_path.len > 0) self.allocator.free(self.model_path);
            self.model_path = mp;
        }

        self.agent = agent.LlamaAgent.init(self.allocator, self.server_path, self.model_path, agent.default_llama_port) catch |err| {
            log.err("Failed to initialize AI Agent: {}", .{err});
            var detail_buf: [256]u8 = undefined;
            const detail: []const u8 = switch (err) {
                error.EngineNotFound => std.fmt.bufPrint(&detail_buf, "llama-server not found: {s}", .{self.server_path}) catch "llama-server not found",
                error.ModelFileNotFound => std.fmt.bufPrint(&detail_buf, "model file not found: {s}", .{self.model_path}) catch "model file not found",
                else => @errorName(err),
            };
            self.setStatus(.failed, detail);
            return err;
        };
        self.model_exists = true;

        self.setStatus(.initializing, "");
        self.is_initializing = true;
        self.submitWarmup() catch |err| switch (err) {
            error.NoScheduler => {},
            else => return err,
        };
    }

    fn submitWarmup(self: *Self) !void {
        const a = self.agent orelse return error.NoAgent;
        const sched = self.scheduler orelse return error.NoScheduler;
        const params = try ai_worker.WarmupParams.init(self.allocator, a, &sched.should_stop);
        if (!sched.submit(.{ .func = ai_worker.taskWarmup, .data = params })) {
            params.deinit();
            self.is_initializing = false;
            return error.SchedulerQueueFull;
        }
    }

    pub fn handleWarmupDone(self: *Self) void {
        self.mutex.lock();
        self.is_initializing = false;
        self.mutex.unlock();
        self.setStatus(.ready, "");
        log.info("AI Agent is warm and ready.", .{});
    }

    pub fn handleWarmupError(self: *Self, payload: []const u8) void {
        log.err("AI warmup failed: {s}", .{payload});
        self.mutex.lock();
        self.is_initializing = false;
        self.mutex.unlock();
        self.setStatus(.failed, payload);
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "AI agent failed to start: {s}", .{payload}) catch "AI agent failed to start.";
        self.addMessage("assistant", msg) catch {};
    }

    /// Selbsteinrichtung anbieten? Nur wenn ein Vorgang bereitsteht, der Agent nicht
    /// läuft und im Datenverzeichnis noch etwas fehlt.
    pub fn needsSelfSetup(self: *Self) bool {
        const st = self.self_setup orelse return false;
        // Läuft oder startet gerade ein Agent, gibt es nichts
        // einzurichten. Erst wenn das scheitert oder nie kam, ist der Knopf richtig.
        if (self.agent_status == .ready or self.agent_status == .initializing) return false;
        return st.missing() != .ready;
    }

    /// Einrichtung starten (Knopf im Chat).
    pub fn startSelfSetup(self: *Self) void {
        const st = self.self_setup orelse return;
        st.start() catch |err| log.err("Einrichtung startet nicht: {s}", .{@errorName(err)});
    }

    /// Jeden Frame: Frage stellen, Abschluss melden, Agenten verbinden.
    pub fn pollSelfSetup(self: *Self) void {
        const st = self.self_setup orelse return;

        // Der Chat sagt selbst, was ihm fehlt — als Nachricht im Verlauf, nicht als
        // Leiste über dem Fenster. Antworten kann man mit den Knöpfen darunter.
        if (!self.setup_prompted and self.needsSelfSetup()) {
            self.setup_prompted = true;
            self.addMessage("assistant",
                \\Ich bin noch nicht eingerichtet: mir fehlen der lokale Server und das Sprachmodell.
                \\
                \\Soll ich beides jetzt laden? Das sind **llama-server** (30 MB) und **gemma-4-E2B** (2,7 GB).
                \\Beides landet in deinem Benutzerverzeichnis, und nichts davon verlässt diesen Rechner.
            ) catch {};
        }

        if (st.currentState() == .failed and !self.self_setup_applied) {
            self.self_setup_applied = true;
            var buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Die Einrichtung ist fehlgeschlagen: {s}. Mit „Erneut versuchen\" geht es weiter, schon geladene Teile bleiben erhalten.", .{st.detail()}) catch "Die Einrichtung ist fehlgeschlagen.";
            self.addMessage("assistant", msg) catch {};
            return;
        }

        if (st.currentState() != .done or self.self_setup_applied) return;
        self.self_setup_applied = true;
        self.addMessage("assistant", "Fertig eingerichtet. Frag mich etwas.") catch {};

        const engine = ai_selfsetup.setup.enginePath(self.allocator, st.root) catch return;
        defer self.allocator.free(engine);
        const model = ai_selfsetup.setup.modelPath(self.allocator, st.root) catch return;
        defer self.allocator.free(model);
        self.initAgent(engine, model) catch |err| {
            log.err("Agent nach der Einrichtung nicht startbar: {s}", .{@errorName(err)});
        };
    }

    /// Erklärung, warum gerade nicht gesendet werden kann (null = bereit).
    fn notReadyMessage(self: *Self) ?[]const u8 {
        if (self.agent_status == .ready and self.agent != null) return null;
        var buf: [400]u8 = undefined;
        const msg: []const u8 = switch (self.agent_status) {
            .ready, .none => "AI is not connected. Use the setup button above and zid downloads llama-server and the model itself. Override with LLAMA_SERVER_PATH / LLAMA_MODEL_PATH.",
            .initializing => "AI agent is still initializing, please try again in a moment.",
            .failed => std.fmt.bufPrint(&buf, "AI agent failed to start: {s}", .{self.statusDetail()}) catch "AI agent failed to start.",
        };
        return self.allocator.dupe(u8, msg) catch null;
    }

    pub fn addMessage(self: *Self, role: []const u8, content: []const u8) !void {
        return self.addMessageFull(role, content, null, null, null);
    }

    /// `display` überschreibt die Anzeige (Markdown); null = aus dem Inhalt ableiten.
    fn addMessageFull(self: *Self, role: []const u8, content: []const u8, tool_calls_json: ?[]const u8, tool_call_id: ?[]const u8, display_override: ?[]const u8) !void {
        const dupe_role = try self.allocator.dupe(u8, role);
        errdefer self.allocator.free(dupe_role);
        const dupe_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(dupe_content);
        const dupe_tc: ?[]u8 = if (tool_calls_json) |t| try self.allocator.dupe(u8, t) else null;
        errdefer if (dupe_tc) |t| self.allocator.free(t);
        const dupe_id: ?[]u8 = if (tool_call_id) |t| try self.allocator.dupe(u8, t) else null;
        errdefer if (dupe_id) |t| self.allocator.free(t);

        const display = if (display_override) |d|
            try self.allocator.dupe(u8, d)
        else if (std.mem.eql(u8, role, "system"))
            try chat_markdown.wrapToolResult(self.allocator, content)
        else
            try chat_markdown.toDisplayMarkdown(self.allocator, content);
        defer self.allocator.free(display);

        var md = MarkdownView.init(self.allocator, display, "");
        errdefer md.deinit();
        md.font_size = message_font_size;
        md.text_color = message_text_color;

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.messages.append(self.allocator, .{
            .role = dupe_role,
            .content = dupe_content,
            .md = md,
            .tool_calls_json = dupe_tc,
            .tool_call_id = dupe_id,
        });
        self.scroll_offset_y = 999999;
    }

    // ─── Werkzeuge ───────────────────────────────────────────────────────────

    /// Worker-Ergebnis ai_chat_tool_calls: Assistant-Nachricht anlegen und die
    /// Aufrufe für UI.update bereitstellen. Ausgeführt wird auf dem Main-Thread.
    pub fn handleToolCalls(self: *Self, payload: []const u8) void {
        self.clearStream();
        const env = ai_tools.parseEnvelope(self.allocator, payload) catch |err| {
            log.err("tool_calls envelope invalid: {}", .{err});
            self.addMessage("assistant", "The model returned an unreadable tool call.") catch {};
            self.is_loading = false;
            return;
        };
        defer self.allocator.free(env.content);
        defer self.allocator.free(env.tool_calls_json);
        defer self.allocator.free(env.calls);

        // Anzeige: Text (falls vorhanden) + Liste der Aufrufe
        var display: std.ArrayListUnmanaged(u8) = .empty;
        defer display.deinit(self.allocator);
        if (env.content.len > 0) {
            display.appendSlice(self.allocator, env.content) catch {};
            display.appendSlice(self.allocator, "\n\n") catch {};
        }
        for (env.calls) |c| {
            const summary = ai_tools.summarizeCall(self.allocator, c) catch continue;
            defer self.allocator.free(summary);
            display.appendSlice(self.allocator, "🔧 `") catch {};
            display.appendSlice(self.allocator, summary) catch {};
            display.appendSlice(self.allocator, "`\n") catch {};
        }
        self.addMessageFull("assistant", env.content, env.tool_calls_json, null, display.items) catch {};

        self.tool_rounds += 1;
        if (self.tool_rounds > max_tool_rounds) {
            for (env.calls) |c| {
                self.addMessageFull("tool", "{\"error\":\"tool round limit reached; answer the user without further tools\"}", null, c.id, "⛔ tool round limit reached") catch {};
                c.deinit(self.allocator);
            }
            self.addMessage("assistant", "(Werkzeug-Limit erreicht, ich höre hier auf.)") catch {};
            self.is_loading = false;
            return;
        }
        for (env.calls) |c| self.pending_tools.append(self.allocator, c) catch c.deinit(self.allocator);
        self.awaiting_tool_results = env.calls.len;
        if (env.calls.len == 0) {
            self.is_loading = false;
        }
    }

    /// Nächsten offenen Aufruf entnehmen (Eigentum geht an den Aufrufer).
    pub fn takePendingToolCall(self: *Self) ?ai_tools.ToolCall {
        if (self.pending_tools.items.len == 0) return null;
        return self.pending_tools.orderedRemove(0);
    }

    /// Ergebnis eines Aufrufs eintragen; ist die Runde komplett, geht sie ans Modell.
    pub fn pushToolResult(self: *Self, call: *const ai_tools.ToolCall, result_json: []const u8) void {
        // Fehler sind immer `{"error":…}`; read_file liefert rohen Dateiinhalt, der das Wort enthalten darf
        const ok = !std.mem.startsWith(u8, result_json, "{\"error\"");
        var disp_buf: [512]u8 = undefined;
        const preview = result_json[0..@min(result_json.len, 300)];
        const display = std.fmt.bufPrint(&disp_buf, "{s} **{s}** → `{s}{s}`", .{
            if (ok) "✅" else "⚠️", call.name, preview, if (result_json.len > 300) "…" else "",
        }) catch result_json;
        self.addMessageFull("tool", result_json, null, call.id, display) catch {};
        if (self.awaiting_tool_results > 0) self.awaiting_tool_results -= 1;
        if (self.awaiting_tool_results == 0 and self.pending_tools.items.len == 0) {
            self.submitCompletion() catch |err| {
                log.err("submitCompletion after tools failed: {}", .{err});
                self.is_loading = false;
            };
        }
    }

    pub fn sendMessage(self: *Self) !void {
        const text = self.input_buffer.store_to_string_cached(self.input_buffer.root, self.input_buffer.file_eol_mode);
        std.log.debug("SEND: buffer len={d} text={s}", .{ text.len, text });
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        if (self.is_loading) return;

        const user_text = try self.allocator.dupe(u8, text);
        defer self.allocator.free(user_text);
        try self.addMessage("user", user_text);
        self.input_editor.setText("");

        // Kein Agent: sofort erklären statt endlos "Gemma is thinking..."
        if (self.notReadyMessage()) |msg| {
            defer self.allocator.free(msg);
            try self.addMessage("assistant", msg);
            return;
        }

        self.tool_rounds = 0;
        self.is_loading = true;
        self.submitCompletion() catch |err| {
            self.is_loading = false;
            var buf: [200]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Could not send: {s}", .{@errorName(err)}) catch "Could not send.";
            try self.addMessage("assistant", msg);
        };
    }

    fn submitCompletion(self: *Self) !void {
        const a = self.agent orelse return error.NoAgent;
        const sched = self.scheduler orelse return error.NoScheduler;

        var api_messages: std.ArrayListUnmanaged(agent.LlamaAgent.ChatMessage) = .empty;
        defer api_messages.deinit(self.allocator);

        try api_messages.append(self.allocator, .{
            .role = "system",
            // Kurz halten: Verhaltensregeln (wo Dateien erscheinen, Bestätigungen,
            // Pfadgrenzen) stecken in agent_actions.zig, nicht im Prompt.
            .content = "You are the coding assistant built into the zid editor. " ++
                "Use the tools to act; paths are relative to the project root. " ++
                "After tool results, answer briefly in the user's language.",
        });

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var entries: std.ArrayListUnmanaged(ai_history.Entry) = .empty;
            defer entries.deinit(self.allocator);
            for (self.messages.items) |m| {
                const role: ai_history.Role = if (std.mem.eql(u8, m.role, "tool")) .tool else if (std.mem.eql(u8, m.role, "assistant")) .assistant else .user;
                const extra = if (m.tool_calls_json) |t| t.len else 0;
                try entries.append(self.allocator, .{ .role = role, .chars = m.content.len + extra });
            }
            const from = ai_history.keepFrom(entries.items, history_budget_chars);
            if (from > 0) log.info("chat history trimmed: sending {d} of {d} messages", .{ self.messages.items.len - from, self.messages.items.len });
            for (self.messages.items[from..]) |m| {
                try api_messages.append(self.allocator, .{ .role = m.role, .content = m.content, .tool_calls = m.tool_calls_json, .tool_call_id = m.tool_call_id });
            }
        }

        self.cancel_flag.store(false, .release);
        self.clearStream();
        const tools: ?[]const u8 = if (self.tools_json.len > 0) self.tools_json else null;
        const params = try ai_worker.ChatParams.initStreaming(self.allocator, a, api_messages.items, sched, &sched.should_stop, &self.cancel_flag, tools);
        if (!sched.submit(.{ .func = ai_worker.taskChatCompletion, .data = params })) {
            params.deinit();
            self.is_loading = false;
            return error.SchedulerQueueFull;
        }
    }

    pub fn handleReply(self: *Self, payload: []const u8) void {
        self.clearStream();
        self.addMessage("assistant", payload) catch {};
        self.is_loading = false;
    }

    pub fn handleError(self: *Self, payload: []const u8) void {
        self.clearStream();
        if (std.mem.eql(u8, payload, "ContextTooLong") and self.shrinkLargestToolResult()) {
            self.submitCompletion() catch |err| {
                log.err("resubmit after shrinking failed: {}", .{err});
                self.addMessage("assistant", "Error communicating with AI agent.") catch {};
                self.is_loading = false;
            };
            return;
        }
        log.err("AI task error: {s}", .{payload});
        const text = if (std.mem.eql(u8, payload, "ContextTooLong"))
            "The request exceeds the model's context window (8192 tokens). Start a new chat or ask about a smaller file."
        else if (std.mem.eql(u8, payload, "ReplyTruncated"))
            "The reply hit the end of the context window (8192 tokens) and was cut off; a cut-off tool call was not run. Start a new chat or ask about a smaller part."
        else
            "Error communicating with AI agent.";
        self.addMessage("assistant", text) catch {};
        self.is_loading = false;
    }

    /// Größtes Werkzeugergebnis der laufenden Runde kürzen (ai_tools.shrinkToolResult).
    /// false = nichts mehr zu kürzen, der Kontextfehler geht an den Benutzer.
    fn shrinkLargestToolResult(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i = self.messages.items.len;
        var largest: ?usize = null;
        while (i > 0) {
            i -= 1;
            const m = self.messages.items[i];
            if (std.mem.eql(u8, m.role, "user")) break;
            if (!std.mem.eql(u8, m.role, "tool")) continue;
            if (largest == null or m.content.len > self.messages.items[largest.?].content.len) largest = i;
        }
        const idx = largest orelse return false;
        const msg = &self.messages.items[idx];
        const shrunk = (ai_tools.shrinkToolResult(self.allocator, msg.content) catch null) orelse return false;
        log.info("context too long: tool result shrunk from {d} to {d} bytes, resending", .{ msg.content.len, shrunk.len });
        self.allocator.free(msg.content);
        msg.content = shrunk;
        return true;
    }

    pub fn triggerDownload(self: *Self) !void {
        if (self.is_downloading or self.model_exists) return;
        const sched = self.scheduler orelse return error.NoScheduler;

        const url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf";

        const sink: ai_worker.ProgressSink = .{
            .value = &self.download_progress,
            .mutex = &self.mutex,
            .stop_flag = &self.stop_flag,
        };
        const params = try ai_worker.DownloadParams.init(self.allocator, url, model_filename, sink);
        if (!sched.submit(.{ .func = ai_worker.taskDownload, .data = params })) {
            params.deinit();
            return error.SchedulerQueueFull;
        }
        self.is_downloading = true;
    }

    pub fn handleDownloadDone(self: *Self) void {
        self.mutex.lock();
        self.model_exists = true;
        self.is_downloading = false;

        self.mutex.unlock();

        if (self.server_path.len > 0 and self.model_path.len > 0) {
            self.initAgent(self.server_path, self.model_path) catch |err| {
                log.err("initAgent after download failed: {}", .{err});
            };
        }
        log.info("Download complete.", .{});
    }

    pub fn handleDownloadError(self: *Self, payload: []const u8) void {
        log.err("AI download failed: {s}", .{payload});
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_downloading = false;
    }

    pub fn handleKeyPress(self: *Self, key: wio.Button) bool {
        switch (key) {
            .escape => {
                if (self.hasSelection()) {
                    self.clearSelections();
                    return true;
                }
                if (self.is_loading) {
                    self.cancelRequest();
                    return true;
                }
                return false;
            },
            .enter => {
                // Enter sendet, Shift+Enter macht eine neue Zeile (wie VS Code/Zed-Chat)
                if (self.input_editor.mods.shift) {
                    // Direkt als Aktion: die Keymap kennt Enter nur ohne Modifier
                    self.input_editor.dispatchAction(.InsertNewline);
                    return true;
                }
                self.sendMessage() catch |err| log.err("Send message failed: {}", .{err});
                return true;
            },
            .backspace => {
                self.input_editor.handleKeyPress(key);
                return true;
            },
            else => {
                self.input_editor.handleKeyPress(key);
                return false;
            },
        }
    }

    pub fn handleChar(self: *Self, char_code: u21) void {
        self.input_editor.handleChar(char_code);
    }

    pub fn setShiftState(self: *Self, pressed: bool) void {
        self.input_editor.setShiftState(pressed);
    }

    pub fn setCtrlState(self: *Self, pressed: bool) void {
        self.input_editor.setCtrlState(pressed);
    }

    pub fn setAltState(self: *Self, pressed: bool) void {
        self.input_editor.setAltState(pressed);
    }

    pub fn updateTimeMs(self: *Self, delta_ms: f32) void {
        self.ui_time_ms += delta_ms;
        self.input_editor.time_ms += delta_ms;
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, button: wio.Button) void {
        if (button == .mouse_left) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.sel_msg = null;
            for (self.messages.items, 0..) |*msg, idx| {
                msg.md.clearSelection();
                if (self.sel_msg == null and bubbleHit(idx, x, y)) {
                    if (msg.md.beginSelection(null, x, y)) self.sel_msg = idx;
                }
            }
        }
        self.input_editor.handleMouseDown(x, y, button);
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        // Handle splitter dragging
        if (self.input_splitter_dragging) {
            const new_height = self.input_height + (self.input_splitter_y + self.input_splitter_h - y);
            self.input_height = @max(40, @min(400, new_height));
        }
        if (self.sel_msg) |idx| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (idx < self.messages.items.len) self.messages.items[idx].md.handleMouseMove(x, y);
        }
        self.input_editor.handleMouseMove(x, y);
    }

    pub fn handleMouseUp(self: *Self) void {
        self.input_splitter_dragging = false;
        if (self.sel_msg) |idx| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (idx < self.messages.items.len) {
                const v = &self.messages.items[idx].md;
                v.handleMouseUp();
                // Klick ohne Ziehen: wie bisher die ganze Nachricht kopieren
                if (!v.hasSelection()) self.pending_copy_msg = idx;
            }
        }
        self.input_editor.handleMouseUp();
    }

    /// Liegt (x, y) in der Bubble der Nachricht `idx` (Clay-Box aus dem Vorframe)?
    fn bubbleHit(idx: usize, x: f32, y: f32) bool {
        var buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "ai_msg_{d}", .{idx}) catch return false;
        const data = clay.getElementData(clay.ElementId.ID(id));
        if (!data.found) return false;
        const b = data.bounding_box;
        return x >= b.x and x <= b.x + b.width and y >= b.y and y <= b.y + b.height;
    }

    /// Markierter Text einer Bubble (Ctrl+C), gehört dem Aufrufer; null ohne Auswahl.
    pub fn selectedText(self: *Self, alloc: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.messages.items) |*msg| {
            if (msg.md.hasSelection()) return msg.md.selectedText(alloc);
        }
        return null;
    }

    pub fn hasSelection(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.messages.items) |*msg| if (msg.md.hasSelection()) return true;
        return false;
    }

    pub fn clearSelections(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.messages.items) |*msg| msg.md.clearSelection();
        self.sel_msg = null;
    }

    /// Messages-Scrollbar: Mouse-Down
    pub fn handleMsgSbMouseDown(self: *Self, x: f32, y: f32) bool {
        if (!self.msg_sb_visible) return false;
        const in_track_x = x >= self.msg_sb_track_x and x <= self.msg_sb_track_x + 8.0;
        const in_track_y = y >= self.msg_sb_track_y and y <= self.msg_sb_track_y + self.msg_sb_track_h;
        if (!(in_track_x and in_track_y)) return false;

        if (y >= self.msg_sb_thumb_y and y <= self.msg_sb_thumb_y + self.msg_sb_thumb_h) {
            self.msg_sb_dragging = true;
            self.msg_sb_drag_offset = y - self.msg_sb_thumb_y;
        } else {
            self.msg_sb_drag_offset = self.msg_sb_thumb_h / 2.0;
            self.msg_sb_dragging = true;
            self.scrollMsgToFraction((y - self.msg_sb_drag_offset - self.msg_sb_track_y) / @max(1.0, self.msg_sb_track_h - self.msg_sb_thumb_h));
        }
        return true;
    }

    pub fn handleMsgSbMouseMove(self: *Self, _: f32, y: f32) void {
        if (!self.msg_sb_dragging) return;
        const usable = @max(1.0, self.msg_sb_track_h - self.msg_sb_thumb_h);
        const frac = (y - self.msg_sb_drag_offset - self.msg_sb_track_y) / usable;
        self.scrollMsgToFraction(frac);
    }

    pub fn handleMsgSbMouseUp(self: *Self) void {
        self.msg_sb_dragging = false;
    }

    fn scrollMsgToFraction(self: *Self, frac: f32) void {
        const max_scroll = @max(0.0, self.content_height - self.viewport_height);
        const clamped = std.math.clamp(frac, 0.0, 1.0);
        self.scroll_offset_y = clamped * max_scroll;
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        const scroll_speed: f32 = 40.0;
        if (delta > 0) {
            self.scroll_offset_y = @max(0, self.scroll_offset_y - @as(f32, @floatFromInt(delta)) * scroll_speed);
        } else if (delta < 0) {
            const max_scroll = @max(0, self.content_height - self.viewport_height);
            self.scroll_offset_y = @min(max_scroll, self.scroll_offset_y + @as(f32, @floatFromInt(-delta)) * scroll_speed);
        }
    }

    pub fn setWindow(self: *Self, win: ?*wio.Window) void {
        self.input_editor.window = win;
    }
};

const scrollbar_width: f32 = 8.0;
const splitter_height: f32 = 6.0;
const splitter_hit_height: f32 = 12.0;

/// Zeiger über dem Element? Über die Box aus dem letzten Layout gerechnet, nicht
/// über `clay.pointerOver`: im Frame des RPC-Klicks kennt Clay die neue Zeigerposition
/// noch nicht, der Klick ginge verloren (dasselbe Problem wie in `pdf_view.zig`).
fn overElement(id: clay.ElementId, mouse_x: f32, mouse_y: f32) bool {
    const data = clay.getElementData(id);
    if (!data.found) return false;
    const b = data.bounding_box;
    return mouse_x >= b.x and mouse_x < b.x + b.width and mouse_y >= b.y and mouse_y < b.y + b.height;
}

/// Farbe aufhellen (Hover-Zustand der Schaltflächen).
fn brighten(c: clay.Color, amount: f32) clay.Color {
    return .{
        @min(255, c[0] + amount),
        @min(255, c[1] + amount),
        @min(255, c[2] + amount),
        c[3],
    };
}

pub fn renderAIChat(
    arena: std.mem.Allocator,
    state: *AIChatState,
    theme: Theme,
    mouse_pressed: bool,
    window: ?*wio.Window,
    ui_ptr: *ui_mod.UI,
) void {
    state.input_editor.window = window;

    // "Ans Ende scrollen" (999999) VOR dem Layout auflösen: sonst rendert dieser Frame
    // mit child_offset -999999 ins Leere. Beim Streaming setzt jedes Delta den Marker,
    // dann wäre der Chat fast dauernd leer. content_height stammt aus dem letzten Frame.
    if (state.scroll_offset_y == 999999.0) {
        state.scroll_offset_y = @max(0.0, state.content_height - state.viewport_height);
    }

    clay.UI()(.{
        .id = clay.ElementId.ID("ai_chat_root"),
        .layout = .{
            .sizing = .grow,
            .direction = .top_to_bottom,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
            .child_gap = 8,
        },
        .background_color = theme.surface,
    })({
        // ── Header ──────────────────────────────────────────────────────
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .left_to_right,
                .child_gap = 8,
                .child_alignment = .{ .y = .center },
            },
        })({
            clay.text(state.agentTitle(), .{ .font_size = 20, .color = theme.primary, .wrap_mode = .none });

            const status_color: clay.Color = switch (state.agent_status) {
                .ready => .{ 100, 255, 100, 255 },
                .initializing => .{ 255, 200, 100, 255 },
                .none, .failed => .{ 255, 90, 90, 255 },
            };
            clay.UI()(.{
                .id = clay.ElementId.ID("ai_status_dot"),
                .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(10) } },
                .background_color = status_color,
                .corner_radius = .all(5),
            })({});
            clay.text(state.statusText(), .{ .font_size = 12, .color = .{ 150, 150, 150, 255 } });
        });

        state.pollSelfSetup();

        // Fortschritt des alten Modell-Downloads (Repo-Pfad).
        if (state.is_downloading) {
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(6) } },
                .background_color = .{ 40, 40, 45, 255 },
                .corner_radius = .all(3),
            })({
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .percent(state.download_progress), .h = .grow } },
                    .background_color = theme.primary,
                    .corner_radius = .all(3),
                })({});
            });
        }

        // ── Messages area (clip + scrollbar) ────────────────────────────
        const viewport_id = clay.ElementId.ID("ai_chat_viewport");
        const content_id = clay.ElementId.ID("ai_chat_content");

        clay.UI()(.{
            .id = clay.ElementId.ID("ai_messages_row"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right,
            },
        })({
            // Clipped scroll area
            clay.UI()(.{
                .id = viewport_id,
                .layout = .{ .sizing = .grow },
                .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -state.scroll_offset_y } },
            })({
                clay.UI()(.{
                    .id = content_id,
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = 6,
                    },
                })({
                    state.mutex.lock();
                    defer state.mutex.unlock();
                    for (state.messages.items, 0..) |*msg, idx| {
                        const is_user = std.mem.eql(u8, msg.role, "user");
                        const msg_id = clay.ElementId.ID(std.fmt.allocPrint(arena, "ai_msg_{d}", .{idx}) catch "ai_msg_x");
                        const hovered = clay.pointerOver(msg_id);

                        if (state.pending_copy_msg == idx) {
                            state.pending_copy_msg = null;
                            if (window) |win| {
                                win.setClipboardText(msg.content);
                                state.last_copy_time = std.time.milliTimestamp();
                            }
                        }

                        const now = std.time.milliTimestamp();
                        const show_copied = !is_user and (now - state.last_copy_time < 2000);

                        const bg: clay.Color = if (is_user)
                            (if (hovered) .{ 60, 60, 105, 255 } else .{ 50, 50, 85, 255 })
                        else
                            (if (hovered) .{ 50, 50, 58, 255 } else .{ 40, 40, 48, 255 });

                        clay.UI()(.{
                            .id = msg_id,
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fit },
                                .direction = .top_to_bottom,
                                .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
                            },
                            .background_color = bg,
                            .corner_radius = .all(4),
                        })({
                            const is_tool = std.mem.eql(u8, msg.role, "tool");
                            clay.text(
                                if (is_user) "You:" else if (is_tool) "Tool:" else if (show_copied) "AI (Copied!):" else "AI:",
                                .{ .font_size = 12, .color = if (is_user) .{ 180, 180, 255, 255 } else if (show_copied) theme.primary else .{ 150, 230, 150, 255 } },
                            );
                            msg.md.renderDocument(arena, theme, ui_ptr);
                        });
                    }

                    if (state.is_loading) {
                        if (state.stream_text.items.len > 0) {
                            // Wachsende Antwort: Markdown nur neu bauen, wenn Text dazukam
                            if (state.stream_dirty or state.stream_md == null) {
                                if (state.stream_md) |*old| old.deinit();
                                state.stream_md = null;
                                if (chat_markdown.toDisplayMarkdown(state.allocator, state.stream_text.items)) |display| {
                                    defer state.allocator.free(display);
                                    var md = MarkdownView.init(state.allocator, display, "");
                                    md.font_size = message_font_size;
                                    md.text_color = message_text_color;
                                    state.stream_md = md;
                                } else |_| {}
                                state.stream_dirty = false;
                            }
                            clay.UI()(.{
                                .id = clay.ElementId.ID("ai_stream_msg"),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fit },
                                    .direction = .top_to_bottom,
                                    .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
                                },
                                .background_color = .{ 40, 40, 48, 255 },
                                .corner_radius = .all(4),
                            })({
                                clay.text("AI (Esc = abbrechen):", .{ .font_size = 12, .color = .{ 150, 230, 150, 255 } });
                                if (state.stream_md) |*md| md.renderDocument(arena, theme, ui_ptr);
                            });
                        } else {
                            clay.text("AI is thinking... (Esc = abbrechen)", .{ .font_size = 14, .color = .{ 150, 150, 150, 255 } });
                        }
                    }
                });
            });

            // Scrollbar track + thumb (only when content overflows)
            const track_id = clay.ElementId.ID("ai_chat_scrollbar_track");
            const overflow = state.content_height > state.viewport_height and state.viewport_height > 0;
            state.msg_sb_visible = overflow;
            clay.UI()(.{
                .id = track_id,
                .layout = .{
                    .sizing = .{ .w = .fixed(scrollbar_width), .h = .grow },
                },
                .background_color = if (overflow) .{ 35, 35, 42, 255 } else .{ 0, 0, 0, 0 },
                .corner_radius = .all(3),
            })({
                if (overflow) {
                    const track_data = clay.getElementData(track_id);
                    if (track_data.found) {
                        const track_h = track_data.bounding_box.height;
                        const thumb_ratio = state.viewport_height / state.content_height;
                        const thumb_h = @max(20.0, track_h * thumb_ratio);
                        const max_scroll = state.content_height - state.viewport_height;
                        const scroll_frac = if (max_scroll > 0) state.scroll_offset_y / max_scroll else 0.0;
                        const thumb_y = scroll_frac * (track_h - thumb_h);

                        state.msg_sb_track_x = track_data.bounding_box.x;
                        state.msg_sb_track_y = track_data.bounding_box.y;
                        state.msg_sb_track_h = track_h;
                        state.msg_sb_thumb_y = track_data.bounding_box.y + thumb_y;
                        state.msg_sb_thumb_h = thumb_h;

                        clay.UI()(.{
                            .floating = .{
                                .attach_to = .to_parent,
                                .attach_points = .{ .element = .left_top, .parent = .left_top },
                                .offset = .{ .x = 0, .y = thumb_y },
                                .z_index = 10,
                            },
                            .layout = .{ .sizing = .{ .w = .fixed(scrollbar_width), .h = .fixed(thumb_h) } },
                            .background_color = if (state.msg_sb_dragging) .{ 130, 130, 170, 230 } else .{ 90, 90, 120, 210 },
                            .corner_radius = .all(3),
                        })({});
                    }
                }
            });
        });

        // Update scroll bounds
        const vp_data = clay.getElementData(viewport_id);
        const ct_data = clay.getElementData(content_id);
        if (vp_data.found) state.viewport_height = vp_data.bounding_box.height;
        if (ct_data.found) state.content_height = ct_data.bounding_box.height;
        const max_scroll = @max(0.0, state.content_height - state.viewport_height);
        if (state.scroll_offset_y == 999999.0) {
            state.scroll_offset_y = max_scroll;
        } else if (state.scroll_offset_y > max_scroll) {
            state.scroll_offset_y = max_scroll;
        }

        // ── Antwortknöpfe zur Einrichtungsfrage ─────────────────────────
        // Stehen direkt über der Eingabe, wo man im Chat antwortet. Läuft der Download,
        // zeigt dieselbe Zeile Schritt, Prozent und Balken.
        if (state.self_setup) |st| {
            const running = st.currentState() == .running;
            const failed = st.currentState() == .failed;
            const show = running or ((state.needsSelfSetup() or failed) and !state.setup_dismissed);
            if (show) {
                clay.UI()(.{
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
                        .direction = .top_to_bottom,
                        .child_gap = 8,
                    },
                })({
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 8 },
                    })({
                        const yes_id = clay.ElementId.ID("ai_setup_btn");
                        const yes_hovered = overElement(yes_id, ui_ptr.mouse_x, ui_ptr.mouse_y);
                        if (yes_hovered and mouse_pressed and !running) state.startSelfSetup();

                        // Text in den Frame-Arena, nicht auf den Stack: Clay hält den
                        // Zeiger bis zum Zeichnen, ein Stack-Puffer ist bis dahin
                        // ungültig und die Schaltfläche zeigte Ersatzzeichen.
                        const yes_label: []const u8 = if (running)
                            std.fmt.allocPrint(arena, "{s} laden … {d} %", .{
                                switch (st.currentStep()) {
                                    .engine => "Server",
                                    .model => "Modell",
                                },
                                st.percent(),
                            }) catch "laden …"
                        else if (failed)
                            "Erneut versuchen"
                        else
                            "Ja, laden";

                        clay.UI()(.{
                            .id = yes_id,
                            .layout = .{
                                .sizing = .{ .w = .fit, .h = .fit },
                                .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 },
                                .child_alignment = .{ .x = .center, .y = .center },
                            },
                            .background_color = if (running)
                                theme.surface
                            else if (yes_hovered)
                                brighten(theme.primary, 30)
                            else
                                theme.primary,
                            .corner_radius = .all(6),
                            .border = .{
                                .width = .all(2),
                                .color = if (running) theme.border else if (yes_hovered) theme.border_focus else theme.accent,
                            },
                        })({
                            clay.text(yes_label, .{
                                .font_size = 15,
                                .color = if (running) theme.text else theme.text_on_primary,
                                .wrap_mode = .none,
                            });
                        });

                        if (!running) {
                            const later_id = clay.ElementId.ID("ai_setup_later_btn");
                            const later_hovered = overElement(later_id, ui_ptr.mouse_x, ui_ptr.mouse_y);
                            if (later_hovered and mouse_pressed) state.setup_dismissed = true;
                            clay.UI()(.{
                                .id = later_id,
                                .layout = .{
                                    .sizing = .{ .w = .fit, .h = .fit },
                                    .padding = .{ .left = 16, .right = 16, .top = 10, .bottom = 10 },
                                    .child_alignment = .{ .x = .center, .y = .center },
                                },
                                .background_color = if (later_hovered) theme.border else theme.surface,
                                .corner_radius = .all(6),
                                .border = .{ .width = .all(2), .color = theme.border },
                            })({
                                clay.text("Später", .{ .font_size = 15, .color = theme.text, .wrap_mode = .none });
                            });
                        }
                    });

                    if (running) {
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(6) } },
                            .background_color = .{ 40, 40, 45, 255 },
                            .corner_radius = .all(3),
                        })({
                            clay.UI()(.{
                                .layout = .{ .sizing = .{ .w = .percent(@as(f32, @floatFromInt(st.percent())) / 100.0), .h = .grow } },
                                .background_color = theme.primary,
                                .corner_radius = .all(3),
                            })({});
                        });
                    }
                });
            }
        }

        // ── Splitter (draggable) ────────────────────────────────────────
        const splitter_id = clay.ElementId.ID("ai_chat_splitter");
        const splitter_hovered = clay.pointerOver(splitter_id);

        // Splitter dragging logic
        if (state.input_splitter_dragging and mouse_pressed) {
            // Handled in mouse move
        } else if (splitter_hovered and mouse_pressed) {
            state.input_splitter_dragging = true;
        }

        clay.UI()(.{
            .id = splitter_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(splitter_height) },
            },
            .background_color = if (state.input_splitter_dragging or splitter_hovered) theme.border else .{ 20, 20, 25, 255 },
        })({});

        // Store splitter bounds for drag handling
        const splitter_data = clay.getElementData(splitter_id);
        if (splitter_data.found) {
            state.input_splitter_y = splitter_data.bounding_box.y;
            state.input_splitter_h = splitter_data.bounding_box.height;
        }

        // ── Input box (CodeEditor) ────────────────────────────────────────
        const input_id = clay.ElementId.IDI("ai_chat_input", @truncate(@intFromPtr(&state.input_editor)));

        clay.UI()(.{
            .id = input_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(state.input_height) },
                .direction = .left_to_right,
            },
            .background_color = .{ 28, 28, 34, 255 },
            .border = .{ .width = .all(1), .color = theme.border },
            .corner_radius = .all(4),
        })({
            state.input_editor.render(arena, mouse_pressed);
        });

        // Input-Bounds für Cursor-Detection speichern
        const input_box_data = clay.getElementData(input_id);
        if (input_box_data.found) {
            state.input_bounds_x = input_box_data.bounding_box.x;
            state.input_bounds_y = input_box_data.bounding_box.y;
            state.input_bounds_w = input_box_data.bounding_box.width;
            state.input_bounds_h = input_box_data.bounding_box.height;
            state.input_bounds_valid = true;
            // Der Editor braucht Ursprung und Größe für Mausklicks, sichtbare Zeilen und Word-Wrap
            // (Panes setzen das in renderPane; hier ist die Box das Layout-Element)
            state.input_editor.content_origin_x = input_box_data.bounding_box.x;
            state.input_editor.content_origin_y = input_box_data.bounding_box.y;
            state.input_editor.width = input_box_data.bounding_box.width;
            state.input_editor.height = input_box_data.bounding_box.height;
        }
    });
}
