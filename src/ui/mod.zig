//! UI Modul für zid
//!
//! Verwendet Clay für Layout und migrierte Gooey Components.

const std = @import("std");
const clay = @import("clay");
pub const Theme = @import("theme.zig").Theme;
const animation = @import("animation.zig");
const Animation = animation.Animation;
const AnimationType = animation.AnimationType;
const AnimationManager = animation.AnimationManager;
const PdfHandler = @import("../rendering/pdf_handler.zig").PdfHandler;
const marp_pdf = @import("../rendering/marp_pdf.zig");
const marp = @import("marp");
const PdfViewState = @import("pdf_view.zig").PdfViewState;
const pdf_nav = @import("pdf_nav.zig");
const editor_mod = @import("../editor/mod.zig");
const backup = @import("../editor/backup.zig");
const lsp_client = @import("lsp_client");
const tab_mru = @import("tab_mru.zig");
const lsp_proto = @import("lsp_proto");
const wio = @import("wio");
const tab_bar_mod = @import("tab_bar.zig");
const scrollbar = @import("scrollbar");
const file_explorer_mod = @import("file_explorer.zig");
const image_view_mod = @import("image_view.zig");
const binary_view_mod = @import("binary_view.zig");
const file_types = @import("file_types.zig");
const markdown_view_mod = @import("markdown_view.zig");
const git_worker = @import("git_worker");
const git_diff_view = @import("git_diff_view.zig");
const git_diff = @import("git_diff");
const timeline_view_mod = @import("timeline_view.zig");
const scm_graph_view_mod = @import("scm_graph_view.zig");
const scm_changes_view_mod = @import("scm_changes_view.zig");
const tooltip = @import("components/tooltip.zig");
const line_edit_mod = @import("line_edit.zig");
const git_changes = @import("git_changes");
const git_commit_view_mod = @import("git_commit_view.zig");
const git_scm = @import("git_scm");
const pane_mod = @import("pane.zig");
const dialog_mod = @import("dialog.zig");
const dialog_ops = @import("dialog_ops.zig");
const folder_picker_mod = @import("folder_picker.zig");
const picker_mod = @import("picker.zig");
const user_state = @import("user_state.zig");
const shortcuts = @import("shortcuts");
const ctx_menu = @import("context_menu");
const shortcuts_dialog = @import("shortcuts_dialog.zig");
const ai_tools = @import("ai_tools");
const agent_actions = @import("agent_actions.zig");
const ai_chat_mod = @import("ai_chat.zig");
const agent_mod = @import("agent");
const env = @import("env");

const log = std.log.scoped(.ui);

/// Globaler Measure-Context (thread-local) — wird von CodeEditor.colFromX genutzt
var g_text_renderer: ?*@import("../text/mod.zig").TextRenderer = null;
var g_font_size: f32 = 0;

/// C-kompatibler Callback: misst Text-Breite in px
fn cMeasureText(ptr: [*c]const u8, len: usize) f32 {
    const tr = g_text_renderer orelse return 0;
    return tr.measureTextAtSize(ptr[0..len], g_font_size);
}

/// Public helper: misst Text-Breite bei beliebiger Font-Size.
/// Wird von UI-Komponenten (z.B. tab_bar) benötigt, die explizite Breiten
/// berechnen müssen, weil Clay's .fit Sizing für Text + fixed children unzuverlässig ist.
pub fn measureTextWidth(text: []const u8, font_size: f32) f32 {
    const tr = g_text_renderer orelse return 0;
    return tr.measureTextAtSize(text, font_size);
}

/// UI Konfiguration
pub const UIConfig = struct {
    font_size: f32 = 24.0,
    padding: f32 = 12.0,
    gap: f32 = 8.0,
    ai_disabled: bool = false,
};

/// UI Hauptstruktur
pub const components = @import("components/mod.zig");

pub const UI = struct {
    pub const TabCloseRequest = struct { pane: *pane_mod.Pane, index: usize };
    pub const PdfPageChange = struct { path: []const u8, delta: i16 };
    pub const TabTarget = struct { pane: *pane_mod.Pane, index: usize };
    pub const Toast = struct { text: []u8, until_ms: f32 };
    /// `marp_deck` wird beim Öffnen einmal bestimmt (ggf. Dateikopf lesen), nicht pro Frame.
    pub const TabMenu = struct { pane: *pane_mod.Pane, index: usize, x: f32, y: f32, marp_deck: bool = false };

    pub const ActiveDialog = struct {
        dialog: dialog_mod.Dialog,
        context_usize: usize = 0,
        context_ptr: ?*anyopaque = null,
        callback: *const fn (*UI, dialog_mod.DialogResult, usize, ?*anyopaque) void,
        message_needs_free: bool = false,
        /// Per Tastatur fokussierter Button (Tab wandert, Enter wählt)
        focused: usize = 0,
        /// Per Tastatur gewähltes Ergebnis; wird wie ein Klick nach dem Layout verarbeitet
        key_result: ?dialog_mod.DialogResult = null,
    };

    allocator: std.mem.Allocator,
    config: UIConfig,
    theme: Theme,
    initialized: bool,

    clay_memory: []u8,
    anim_manager: AnimationManager,
    frame_arena: std.heap.ArenaAllocator,

    root_pane: *pane_mod.Pane,
    active_pane: *pane_mod.Pane,

    text_renderer: ?*@import("../text/mod.zig").TextRenderer,
    window: ?*wio.Window,

    file_explorer: file_explorer_mod.FileExplorerState,
    /// Timeline-Abschnitt unter dem Explorer (VS-Code-Stil)
    timeline_view: timeline_view_mod.TimelineView,
    /// Zuletzt an die Timeline gemeldeter Tab-Pfad (nur bei Änderung neu auflösen)
    timeline_follow_key: ?[]u8 = null,
    /// Sidebar zeigt Explorer oder Source Control (VS Code: Ansichten der Aktivitätsleiste)
    sidebar_mode: enum { explorer, scm } = .explorer,
    scm_graph: scm_graph_view_mod.ScmGraphView,
    /// Commit, auf den sich das Graph-Kontextmenü bezieht
    scm_cmd_commit: ?usize = null,
    /// Source Control „Changes“ über dem Graphen: Eingabefeld, Gruppen, Aktionen
    scm_changes: scm_changes_view_mod.ScmChangesView,
    /// Repo-Wurzel aus dem letzten git status (`root:` im Explorer-Teil), owned
    scm_repo_root: ?[]u8 = null,
    /// Nach einer Aktion: main.zig lädt den Status neu (`takeGitStatusRequest`)
    git_status_wanted: bool = false,
    /// Was der offene Rückfrage-Dialog bei „Ja“ ausführt
    scm_pending: ?union(enum) { discard: git_changes.Row, discard_all, commit_all } = null,
    /// Knopftext und Aktionen des Rückfrage-Dialogs (der Dialog hält nur Slices)
    scm_dialog_button: ?[]u8 = null,
    scm_dialog_actions: [2]dialog_mod.DialogAction = undefined,
    /// Multi-File-Diff-Tabs je Tab-Pfad (`git-commit://…`)
    git_commits: std.StringHashMapUnmanaged(*git_commit_view_mod.GitCommitView) = .empty,
    show_file_explorer: bool,

    ai_chat: ai_chat_mod.AIChatState,
    show_ai_chat: bool,

    current_directory: ?[]const u8,
    pending_tab_switch: ?[]const u8,
    pending_pdf_page_change: ?PdfPageChange,
    /// Offene PDFs, die sich auf der Platte geändert haben (Schlüssel aus `open_pdfs`, owned)
    pending_pdf_reloads: std.ArrayListUnmanaged([]u8) = .empty,
    /// Vom Main-Thread beim Rendern gesetzt, damit E2E den Zustand lesen kann,
    /// ohne im Server-Thread über Tabs und Handler-Map zu laufen.
    /// Beschriftung der Blätter-Leiste: gehört der UI, weil Clay den Text erst
    /// beim Zeichnen liest und die Frame-Arena bis dahin zurückgesetzt ist.
    pdf_label_buf: [32]u8 = undefined,
    pdf_view_page: u16 = 0,
    pdf_view_pages: u16 = 0,
    pending_split: ?pane_mod.PaneDirection,

    active_dialog: ?ActiveDialog,
    /// Klick/Enter im Dialog aus dem letzten Layout. Wird erst vor dem nächsten Layout
    /// verarbeitet: Die Render-Commands des aktuellen Frames zeigen noch auf die
    /// Dialog-Nachricht und auf alles, was der Callback freigibt (z. B. Explorer-Knoten
    /// nach `performMove` → `refresh`); der GPU-Renderer liest sie erst nach renderExample.
    pending_dialog_result: ?dialog_mod.DialogResult = null,
    /// Ausgeklapptes Header-Menü (Index in shortcuts.menus), null = keins
    open_menu: ?usize = null,
    /// Help → Keyboard Shortcuts offen
    shortcuts_dialog_open: bool = false,
    /// Agent-Aufruf, der auf die Antwort des Bestätigungsdialogs wartet
    agent_confirm: ?ai_tools.ToolCall = null,
    /// Antwort des Dialogs (true = erlaubt), wird in update() verarbeitet
    agent_confirm_answer: ?bool = null,
    /// Letzter Klick war im Explorer: F2/Entf gelten für den markierten Eintrag
    explorer_focused: bool = false,
    /// Letzter Klick war im Source Control Graph oder in der Timeline: Pfeile/Enter/F5
    /// gehören der Liste, keine Taste erreicht den Editor. Escape gibt den Fokus zurück.
    sidebar_focus: enum { none, scm, timeline, changes, commit_input } = .none,
    /// Zuletzt per setClipboard kopierter Text (owned; für Tests ohne Fenster)
    last_clipboard_text: ?[]u8 = null,
    /// Dauer des letzten Frames (Eingabe bis Ende Layout/Render) und Maximum seit dem letzten Abholen
    last_frame_ms: f32 = 0,
    max_frame_ms: f32 = 0,
    /// Pfade zuletzt geschlossener Datei-Tabs (owned, neueste hinten) für Ctrl+Shift+T
    closed_tabs: std.ArrayListUnmanaged([]u8) = .empty,
    /// Offenes Tab-Kontextmenü (Rechtsklick auf einen Tab-Kopf)
    tab_menu: ?TabMenu = null,
    /// Ziel eines Tab-Kommandos aus dem Kontextmenü; null = aktiver Tab des aktiven Panes
    tab_cmd_target: ?TabTarget = null,
    /// UI-Uhr in ms (für Chords)
    ui_time_ms: f32 = 0,
    /// Ctrl+K gedrückt: der nächste Pfeil wechselt das Pane (bis zu dieser Zeit)
    chord_k_until_ms: f32 = -1,
    /// Pfad, für den der „Datei außerhalb geändert“-Dialog offen ist (owned)
    external_change_path: ?[]u8 = null,
    /// Drag & Drop im Explorer: bestätigungspflichtiges Verschieben
    pending_move: ?file_explorer_mod.PendingMove = null,
    /// Autosave nach 1 s Ruhe (File → Toggle Autosave, gemerkt)
    autosave: bool = false,
    /// Kurze Meldungen unten rechts (Speichern, Papierkorb …), verschwinden nach 3 s
    toasts: std.ArrayListUnmanaged(Toast) = .empty,
    /// Per Tastatur markierter Menüeintrag (Alt+F, Pfeile, Enter)
    menu_highlight: ?usize = null,
    /// Scroll-Versatz im Kürzel-Dialog
    shortcuts_scroll_y: f32 = 0,
    /// Tab-Index vor dem letzten Wechsel ins Terminal (Ctrl+J zurück)
    terminal_return_index: ?usize = null,
    /// "Open Folder…"-Dialog
    folder_picker: folder_picker_mod.FolderPicker,
    /// Schnellöffner (Ctrl+P) und Command Palette (Ctrl+Shift+P)
    picker: picker_mod.Picker,
    /// Vom Dialog bestätigter Projektordner (owned); main.zig holt ihn per takePendingOpenFolder
    pending_open_folder: ?[]u8 = null,
    /// Beenden ist bestätigt (keine ungespeicherten Änderungen oder im Dialog entschieden);
    /// der Main-Loop endet danach.
    quit_confirmed: bool = false,
    pending_tab_closes: std.ArrayListUnmanaged(TabCloseRequest),

    open_buffers: std.StringHashMap(*@import("flow_core").Buffer),
    /// Buffer, die aus open_buffers entfernt wurden, aber noch referenziert sein
    /// können (gelöschte/umbenannte Dateien). Werden erst in deinit freigegeben.
    orphan_buffers: std.ArrayListUnmanaged(*@import("flow_core").Buffer) = .empty,
    open_images: std.StringHashMap(*anyopaque),
    open_pdfs: std.StringHashMap(*anyopaque),
    open_markdown_views: std.StringHashMap(*markdown_view_mod.MarkdownView),
    /// Diff-Editor-Tabs je Tab-Pfad (`git-diff://…`); Schlüssel gehört der Ansicht
    git_diffs: std.StringHashMapUnmanaged(*git_diff_view.GitDiffView) = .empty,
    pending_md_preview: ?[]const u8,

    image_renderer: ?*@import("../clay_renderer/image_renderer.zig").ImageRenderer,

    mouse_pressed_this_frame: bool,
    mouse_x: f32,
    mouse_y: f32,
    is_mouse_down: bool,
    is_ctrl_down: bool,
    is_shift_down: bool,
    is_alt_down: bool,
    /// Language Server (zls) — wird beim ersten Sprung zur Definition in einer .zig-Datei gestartet
    scheduler: ?*@import("scheduler").Scheduler = null,
    /// Ctrl+Tab-Umschalter: Position in der „zuletzt benutzt“-Reihenfolge, solange Ctrl gehalten wird
    tab_switcher: ?usize = null,
    lsp: ?*lsp_client.LspClient = null,
    lsp_failed: bool = false,
    lsp_pending: ?LspPending = null,
    lsp_goto: ?LspGoto = null,

    /// Git-Branch Name (leer = unbekannt)
    git_branch: []const u8,

    const Self = @This();

    /// UI initialisieren
    /// Obergrenze für Clay-Layout-Elemente pro Frame. Großzügig, weil die
    /// Elemente je Frame, zugleich Kapazität von Clays persistenter ID-Hash-Map (die
    /// gepatchte clay.h verdichtet sie, sonst lief sie voll und neue Elemente verloren
    /// Bounds und Hover, siehe AGENTS.md „Clay: gepatchte clay.h“).
    const MAX_CLAY_ELEMENTS: i32 = 16384;

    /// Clay meldet Layout-Fehler hierher statt sie nur auf den Bildschirm zu
    /// malen. Ohne diesen Handler stand die Meldung rot im Fenster und tauchte
    /// in keinem Log auf.
    /// Clay-Fehler seit Start (RPC `ui_state.clay_errors`): E2E prüfen damit, dass nichts still
    /// verloren ging.
    pub var clay_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    fn clayError(data: clay.ErrorData) callconv(.c) void {
        _ = clay_error_count.fetchAdd(1, .monotonic);
        log.err("Clay: {s} ({s})", .{ data.error_text.chars[0..@intCast(data.error_text.length)], @tagName(data.error_type) });
        if (data.error_type == .duplicate_id) logDuplicateParent();
    }

    /// duplicate_id nennt das Element nicht. Zur Eingrenzung einmal je Elternelement dessen
    /// Clay-ID loggen (das doppelte Element ist beim Aufruf noch offen, sein Elternteil steht
    /// darunter im Stapel). Die Zahl lässt sich mit den bekannten ID-Namen zurückrechnen
    /// (`scripts/clay_id_decode.py`).
    fn logDuplicateParent() void {
        const Seen = struct {
            var ids: [16]u32 = undefined;
            var count: usize = 0;
        };
        const parent = clay.cdefs.Clay__GetParentElementId();
        for (Seen.ids[0..Seen.count]) |id| if (id == parent) return;
        if (Seen.count < Seen.ids.len) {
            Seen.ids[Seen.count] = parent;
            Seen.count += 1;
        }
        log.err("Clay: duplicate_id unter Elternelement id={d}", .{parent});
    }

    pub fn init(allocator: std.mem.Allocator, config: UIConfig, default_file_path: ?[]const u8) !Self {
        log.debug("Initializing UI system", .{});

        // Clay Memory allozieren. Die Obergrenze für Layout-Elemente muss vor
        // minMemorySize stehen, weil die Größe daran hängt. Clays Standard sind
        // 8192; die Markdown-Vorschau baut ein ganzes Dokument auf einmal auf
        // (ein Element je Zeile und je Textstück), was bei großen Dateien wie
        // AGENTS.md darüber hinausgeht — Clay meldet dann
        // „Layout elements exceeded Clay__maxElementCount" und bricht ab.
        clay.setMaxElementCount(MAX_CLAY_ELEMENTS);
        const min_memory = clay.minMemorySize();
        const generous_memory = @max(min_memory, 10 * 1024 * 1024);
        const clay_memory = try allocator.alloc(u8, generous_memory);
        log.info("Clay: max {d} Elemente, {d} KiB Arena", .{ MAX_CLAY_ELEMENTS, generous_memory / 1024 });

        // File Explorer initialisieren
        const file_explorer = file_explorer_mod.FileExplorerState.init(allocator);

        var open_buffers = std.StringHashMap(*@import("flow_core").Buffer).init(allocator);
        const initial_buf = try @import("flow_core").Buffer.create(allocator);

        // Content laden
        if (default_file_path) |path| {
            if (std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024)) |file_content| {
                defer allocator.free(file_content);
                initial_buf.root = try initial_buf.load_from_string(file_content, &initial_buf.file_eol_mode, &initial_buf.file_utf8_sanitized);
                initial_buf.set_file_path(path);
                initial_buf.last_save = initial_buf.root;
                log.info("Loaded default file: {s} ({d} bytes)", .{ path, file_content.len });
                try open_buffers.put(try allocator.dupe(u8, path), initial_buf);
            } else |err| {
                log.err("Failed to load default file '{s}': {}. Using fallback.", .{ path, err });
                initial_buf.root = try initial_buf.load_from_string("// Error loading file", &initial_buf.file_eol_mode, &initial_buf.file_utf8_sanitized);
                try open_buffers.put(try allocator.dupe(u8, "error"), initial_buf);
            }
        } else {
            const default_text = "pub fn main() !void {\n    std.log.info(\"Hello World\", .{});\n}\n";
            initial_buf.root = try initial_buf.load_from_string(default_text, &initial_buf.file_eol_mode, &initial_buf.file_utf8_sanitized);
            try open_buffers.put(try allocator.dupe(u8, "scratchpad"), initial_buf);
        }

        const root_pane = try pane_mod.Pane.createLeaf(allocator, initial_buf);
        const active_pane = root_pane;
        if (default_file_path) |path| active_pane.data.leaf.code_editor.setLanguageFromPath(path);

        // AI Chat initialisieren (falls nicht deaktiviert). Standard: Ollama mit
        // gemma4:e2b; LLAMA_SERVER_PATH / LLAMA_MODEL_PATH überschreiben das.
        // Ohne Agent erklärt der Chat beim Senden, warum nichts passiert.
        var ai_chat = ai_chat_mod.AIChatState.init(allocator) catch |err| @panic(@errorName(err));
        if (!config.ai_disabled) {
            // Standard: llama.cpp-Vulkan-Build + gemma4-E2B Q4_0 (llm-bench/: 10/10 Werkzeugwahl,
            // 27,6 tok/s auf der P1000, 18,2 auf CPU), beides im Repo (engines/, models/). Repo-Wurzel
            // aus dem Ort der ausführbaren Datei (<repo>/zig-out/bin), sonst Arbeitsverzeichnis.
            // Fehlt der Build, fällt es auf Ollama mit gemma4:e2b zurück.
            const ai_paths = @import("ai_paths");
            const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
            defer if (exe_dir) |d| allocator.free(d);
            const cwd_root = std.fs.cwd().realpathAlloc(allocator, ".") catch try allocator.dupe(u8, ".");
            defer allocator.free(cwd_root);
            const repo_root = (if (exe_dir) |d| ai_paths.repoRootFromExeDir(d) else null) orelse cwd_root;
            const default_engine = try ai_paths.defaultEngine(allocator, repo_root);
            defer allocator.free(default_engine);
            const engine_available = if (std.fs.cwd().access(default_engine, .{})) |_| true else |_| false;
            const default_model = try ai_paths.defaultModel(allocator, repo_root);
            defer allocator.free(default_model);

            const server_path = std.process.getEnvVarOwned(allocator, "LLAMA_SERVER_PATH") catch |err| blk: {
                if (err == error.EnvironmentVariableNotFound) break :blk try allocator.dupe(u8, if (engine_available) default_engine else "ollama");
                return err;
            };
            defer allocator.free(server_path);
            const use_ollama = std.mem.eql(u8, server_path, "ollama");
            const model_path = std.process.getEnvVarOwned(allocator, "LLAMA_MODEL_PATH") catch |err| blk: {
                if (err == error.EnvironmentVariableNotFound) break :blk try allocator.dupe(u8, if (use_ollama) "gemma4:e2b" else default_model);
                return err;
            };
            defer allocator.free(model_path);
            ai_chat.initAgent(server_path, model_path) catch |err| {
                log.err("AI agent init failed: {}. Chat will explain when used.", .{err});
            };
        }

        return Self{
            .allocator = allocator,
            .config = config,
            .theme = Theme.dark(),
            .initialized = false,
            .clay_memory = clay_memory,
            .anim_manager = AnimationManager.init(allocator),
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .root_pane = root_pane,
            .active_pane = active_pane,
            .text_renderer = null,
            .window = null,
            .file_explorer = file_explorer,
            .timeline_view = timeline_view_mod.TimelineView.init(allocator),
            .scm_graph = scm_graph_view_mod.ScmGraphView.init(allocator),
            .scm_changes = scm_changes_view_mod.ScmChangesView.init(allocator),
            .show_file_explorer = true,
            .ai_chat = ai_chat,
            .show_ai_chat = false,
            .current_directory = null,
            .pending_tab_switch = null,
            .pending_pdf_page_change = null,
            .pdf_label_buf = undefined,
            .pending_split = null,
            .active_dialog = null,
            .folder_picker = folder_picker_mod.FolderPicker.init(allocator),
            .picker = picker_mod.Picker.init(allocator),
            .pending_tab_closes = std.ArrayListUnmanaged(TabCloseRequest).empty,
            .open_buffers = open_buffers,
            .open_images = std.StringHashMap(*anyopaque).init(allocator),
            .open_pdfs = std.StringHashMap(*anyopaque).init(allocator),
            .open_markdown_views = std.StringHashMap(*markdown_view_mod.MarkdownView).init(allocator),
            .pending_md_preview = null,
            .image_renderer = null,
            .mouse_pressed_this_frame = false,
            .mouse_x = 0.0,
            .mouse_y = 0.0,
            .is_mouse_down = false,
            .is_ctrl_down = false,
            .is_shift_down = false,
            .is_alt_down = false,
            .git_branch = "",
        };
    }

    /// UI aufräumen
    pub fn deinit(self: *Self) void {
        log.debug("UI.deinit: start", .{});
        if (self.lsp) |l| l.deinit();
        self.lsp = null;
        if (self.lsp_goto) |g| self.allocator.free(g.path);
        self.lsp_goto = null;

        if (self.active_dialog) |ad| {
            if (ad.message_needs_free) {
                self.allocator.free(ad.dialog.message);
            }
            self.active_dialog = null;
        }

        self.anim_manager.deinit();
        log.debug("UI.deinit: anim_manager done", .{});
        self.frame_arena.deinit();
        log.debug("UI.deinit: frame_arena done", .{});
        self.allocator.free(self.clay_memory);
        log.debug("UI.deinit: clay_memory freed", .{});

        self.root_pane.deinit();
        log.debug("UI.deinit: root_pane done", .{});

        self.file_explorer.deinit();
        log.debug("UI.deinit: file_explorer done", .{});
        self.timeline_view.deinit();
        if (self.timeline_follow_key) |k| self.allocator.free(k);
        self.scm_graph.deinit();
        self.scm_changes.deinit();
        if (self.scm_repo_root) |r| self.allocator.free(r);
        if (self.scm_dialog_button) |b| self.allocator.free(b);
        var gc_iter = self.git_commits.valueIterator();
        while (gc_iter.next()) |v| v.*.destroy();
        self.git_commits.deinit(self.allocator);

        self.ai_chat.deinit();
        log.debug("UI.deinit: ai_chat done", .{});

        // Buffer aufräumen (Zentrales Ownership)
        log.debug("UI.deinit: cleaning buffers", .{});
        var buf_iter = self.open_buffers.iterator();
        while (buf_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.open_buffers.deinit();
        for (self.orphan_buffers.items) |b| b.deinit();
        self.orphan_buffers.deinit(self.allocator);

        // Bilder aufräumen
        var iter = self.open_images.iterator();
        while (iter.next()) |entry| {
            const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;
            const tex_ptr: *ImageTexture = @ptrCast(@alignCast(entry.value_ptr.*));
            tex_ptr.deinit();
            self.allocator.destroy(tex_ptr);
            self.allocator.free(entry.key_ptr.*); // Key freigeben
        }
        self.open_images.deinit();

        // PDFs aufräumen
        var pdf_iter = self.open_pdfs.iterator();
        while (pdf_iter.next()) |entry| {
            const handler: *PdfHandler = @ptrCast(@alignCast(entry.value_ptr.*));
            handler.deinit();
        }
        self.open_pdfs.deinit();
        for (self.pending_pdf_reloads.items) |p| self.allocator.free(p);
        self.pending_pdf_reloads.deinit(self.allocator);

        // Markdown Previews aufräumen
        var md_iter = self.open_markdown_views.iterator();
        while (md_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.open_markdown_views.deinit();

        var gd_iter = self.git_diffs.valueIterator();
        while (gd_iter.next()) |v| v.*.destroy();
        self.git_diffs.deinit(self.allocator);

        if (self.current_directory) |dir| self.allocator.free(dir);
        if (self.pending_open_folder) |p| self.allocator.free(p);
        if (self.agent_confirm) |c| c.deinit(self.allocator);
        if (self.last_clipboard_text) |t| self.allocator.free(t);
        for (self.closed_tabs.items) |p| self.allocator.free(p);
        self.closed_tabs.deinit(self.allocator);
        if (self.external_change_path) |p| self.allocator.free(p);
        if (self.pending_move) |m| m.deinit(self.allocator);
        for (self.toasts.items) |t| self.allocator.free(t.text);
        self.toasts.deinit(self.allocator);
        self.folder_picker.deinit();
        self.picker.deinit();
        if (self.git_branch.len > 0) self.allocator.free(self.git_branch);
        self.pending_tab_closes.deinit(self.allocator);

        log.debug("UI.deinit: finished", .{});
    }

    pub fn setAIScheduler(self: *Self, sched: *@import("scheduler").Scheduler) void {
        self.scheduler = sched;
        self.ai_chat.setScheduler(sched);
    }

    pub fn handleAIReply(self: *Self, payload: []const u8) void {
        self.ai_chat.handleReply(payload);
    }

    pub fn handleAIError(self: *Self, payload: []const u8) void {
        self.ai_chat.handleError(payload);
    }

    pub fn handleAIDelta(self: *Self, payload: []const u8) void {
        self.ai_chat.handleDelta(payload);
    }

    pub fn handleAICancelled(self: *Self, payload: []const u8) void {
        self.ai_chat.handleCancelled(payload);
    }

    pub fn handleAIWarmupDone(self: *Self) void {
        self.ai_chat.handleWarmupDone();
    }

    pub fn handleAIWarmupError(self: *Self, payload: []const u8) void {
        self.ai_chat.handleWarmupError(payload);
    }

    pub fn handleAIDownloadDone(self: *Self) void {
        self.ai_chat.handleDownloadDone();
    }

    pub fn handleAIDownloadError(self: *Self, payload: []const u8) void {
        self.ai_chat.handleDownloadError(payload);
    }

    /// Clay initialisieren (nach Window Creation)
    pub fn setupClay(self: *Self, window: ?*wio.Window, width: u32, height: u32, text_renderer: *@import("../text/mod.zig").TextRenderer) !void {
        log.debug("Setting up Clay layout: {}x{}", .{ width, height });
        self.text_renderer = text_renderer;
        self.window = window;
        self.getActiveEditor().window = window;
        self.ai_chat.setWindow(window);
        self.ai_chat.input_editor.measure_fn = cMeasureText;
        g_font_size = @floatFromInt(self.ai_chat.input_editor.font_size);

        // Globalen Measure-Context setzen (für Maus→Spalte)
        g_text_renderer = text_renderer;
        g_font_size = @floatFromInt(self.getActiveEditor().font_size);
        self.getActiveEditor().measure_fn = cMeasureText;

        const arena = clay.createArenaWithCapacityAndMemory(self.clay_memory);

        _ = clay.initialize(
            arena,
            .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
            .{ .error_handler_function = clayError },
        );

        // Measure Text Function setzen
        clay.setMeasureTextFunction(*Self, self, clayMeasureText);

        self.initialized = true;
        log.debug("Clay initialized", .{});
    }

    /// Clay Measure Text Callback
    fn clayMeasureText(text_str: []const u8, config: *clay.TextElementConfig, user_data: *Self) clay.Dimensions {
        const renderer = user_data.text_renderer orelse return .{ .w = 0, .h = 0 };

        // Text messen (mit korrekter Font-Size)
        // Wir fügen einen kleinen Puffer hinzu (1.0px) um Floating-Point Rundungsfehler
        // und Clipping-Probleme in Clay zu vermeiden.
        // Kleiner Puffer gegen Rundung/Clipping. Vorher 1 px: jedes Highlight-Segment einer Zeile
        // wurde so 1 px breiter als gerendert, die Zeile driftete gegenüber Cursor und Overlays.
        const width = (renderer.ts_ptr.measureTextAtSize(text_str, @floatFromInt(config.font_size)) catch 0) + 0.25;

        var height: f32 = @floatFromInt(config.font_size);
        if (renderer.ts_ptr.getMetrics()) |metrics| {
            const scale = @as(f32, @floatFromInt(config.font_size)) / metrics.point_size;
            height = metrics.line_height * scale;
        }

        return .{
            .w = width,
            .h = height,
        };
    }

    /// Keyboard Input verarbeiten
    pub fn handleKeyPress(self: *Self, key: @import("wio").Button) void {
        // Offener Ordner-Dialog ist modal
        if (self.folder_picker.visible) {
            self.folder_picker.handleKey(key, self.editMods(), self.editClipboard());
            return;
        }
        if (self.picker.visible) {
            self.picker.handleKey(key, self.editMods(), self.editClipboard());
            return;
        }
        if (self.shortcuts_dialog_open) {
            if (key == .escape or key == .f1) self.shortcuts_dialog_open = false;
            if (key == .down) self.scrollShortcuts(-3);
            if (key == .up) self.scrollShortcuts(3);
            return;
        }
        // Offenes Menü per Tastatur: ←/→ wechseln, ↑/↓ markieren, Enter führt aus
        if (self.open_menu) |mi| {
            const n = shortcuts.menus.len;
            const items_len = shortcuts.menus[mi].items.len;
            switch (key) {
                .left => {
                    self.open_menu = (mi + n - 1) % n;
                    self.menu_highlight = 0;
                    return;
                },
                .right => {
                    self.open_menu = (mi + 1) % n;
                    self.menu_highlight = 0;
                    return;
                },
                .down => {
                    self.menu_highlight = if (self.menu_highlight) |h| (h + 1) % items_len else 0;
                    return;
                },
                .up => {
                    self.menu_highlight = if (self.menu_highlight) |h| (h + items_len - 1) % items_len else items_len - 1;
                    return;
                },
                .enter, .kp_enter => {
                    if (self.menu_highlight) |h| {
                        if (h < items_len) self.executeCommand(shortcuts.menus[mi].items[h]);
                    }
                    self.open_menu = null;
                    self.menu_highlight = null;
                    return;
                },
                else => {},
            }
        }
        // Alt+F/E/V/H öffnet das Menü mit diesem Anfangsbuchstaben
        if (self.is_alt_down and !self.is_ctrl_down and self.active_dialog == null) {
            const name = @tagName(key);
            if (name.len == 1) {
                inline for (shortcuts.menus, 0..) |menu, i| {
                    if (std.ascii.toLower(menu.title[0]) == name[0]) {
                        self.open_menu = i;
                        self.menu_highlight = 0;
                        return;
                    }
                }
            }
        }
        // Modaler Dialog: alle Tasten gehen an den Dialog, nichts an Editor/Explorer
        if (self.active_dialog) |*ad| {
            self.handleDialogKey(ad, key);
            return;
        }
        if (self.open_menu != null and key == .escape) {
            self.open_menu = null;
            self.menu_highlight = null;
            return;
        }
        if (self.tab_menu != null and key == .escape) {
            self.tab_menu = null;
            return;
        }
        // Folienvorschau: Pfeile und Bild auf/ab blättern durch die Folien.
        if (self.activeSlideDeckView()) |v| {
            switch (key) {
                .left, .page_up => return v.prevSlide(),
                .right, .page_down => return v.nextSlide(),
                .home => return v.showSlide(0),
                .end => return v.showSlide(v.slideCount() - 1),
                else => {},
            }
        }
        // PDF-Vorschau: Pfeile und Bild auf/ab blättern durch die Seiten.
        if (self.activePdfTabPath()) |pdf_path| {
            if (keyFromButton(key)) |k| {
                if (pdf_nav.deltaForKey(k, self.currentMods())) |delta| {
                    self.pending_pdf_page_change = .{ .path = pdf_path, .delta = delta };
                    return;
                }
            }
        }
        // Kürzel aus der zentralen Tabelle (shortcuts.zig): global überall,
        // Explorer-Scope nur mit Fokus im Explorer und markiertem Eintrag
        // Inline-Umbenennen/Anlegen im Explorer fängt alle Tasten ab
        if (self.show_file_explorer and self.file_explorer.isEditing()) {
            self.file_explorer.handleRenameKey(key, self.editMods(), self.editClipboard());
            return;
        }
        const explorer_has_focus = self.show_file_explorer and self.explorer_focused;
        // Chord Ctrl+K, dann Pfeil: Pane-Fokus wie in Zed/VS Code
        if (self.chord_k_until_ms > self.ui_time_ms) {
            self.chord_k_until_ms = -1;
            switch (key) {
                .left => return self.executeCommand(.focus_pane_left),
                .right => return self.executeCommand(.focus_pane_right),
                .up => return self.executeCommand(.focus_pane_up),
                .down => return self.executeCommand(.focus_pane_down),
                .left_control, .right_control => self.chord_k_until_ms = self.ui_time_ms + 1500,
                else => {},
            }
        }
        if (key == .k and self.is_ctrl_down and !self.is_shift_down and !self.is_alt_down) {
            self.chord_k_until_ms = self.ui_time_ms + 1500;
            return;
        }
        if (keyFromButton(key)) |k| {
            const mods = self.currentMods();
            if (shortcuts.lookup(k, mods, .global)) |cmd| {
                self.executeCommand(cmd);
                return;
            }
            if (explorer_has_focus) {
                if (shortcuts.lookup(k, mods, .explorer)) |cmd| {
                    self.executeCommand(cmd);
                    return;
                }
            }
        }
        // Fokus im Explorer: Navigation dort, keine Taste erreicht den Editor
        // (vorher machte ein „d“ die Datei im Editor dirty). Escape gibt den Fokus zurück.
        if (explorer_has_focus) {
            if (key == .escape) {
                self.explorer_focused = false;
                return;
            }
            _ = self.file_explorer.handleNavKey(key, self.is_shift_down);
            return;
        }

        // Fokus im Source Control Graph oder in der Timeline: Pfeile/Bild/Pos1/Ende wählen,
        // Enter öffnet, F5 lädt neu. Keine Taste erreicht den Editor, Escape gibt den Fokus zurück.
        if (self.show_file_explorer and self.sidebar_focus != .none) {
            if (key == .escape) {
                self.sidebar_focus = .none;
                return;
            }
            // Commit-Eingabefeld: Ctrl+Enter committet, Tab wechselt in die Liste, Rest ist Text
            if (self.sidebar_focus == .commit_input and self.sidebar_mode == .scm) {
                if (key == .tab) {
                    self.sidebar_focus = .changes;
                    return;
                }
                if (!self.is_alt_down) self.runScmAction(self.scm_changes.handleInputKey(key, self.editMods(), self.editClipboard()));
                return;
            }
            if (!self.is_ctrl_down and !self.is_alt_down) {
                switch (self.sidebar_focus) {
                    .changes => if (self.sidebar_mode == .scm) {
                        if (key == .tab) {
                            self.sidebar_focus = .scm; // Reihenfolge wie VS Code: Feld → Changes → Graph
                            return;
                        }
                        const k: ?scm_changes_view_mod.ScmChangesView.Key = switch (key) {
                            .up => .up,
                            .down => .down,
                            .page_up => .page_up,
                            .page_down => .page_down,
                            .home => .home,
                            .end => .end,
                            .enter, .space => .enter,
                            .delete => .delete,
                            .f5 => .reload,
                            else => null,
                        };
                        if (k) |kk| self.runScmAction(self.scm_changes.handleKey(kk));
                    },
                    .commit_input => {},
                    .scm => if (self.sidebar_mode == .scm) {
                        if (key == .tab) {
                            self.sidebar_focus = .commit_input;
                            return;
                        }
                        const k: ?scm_graph_view_mod.ScmGraphView.Key = switch (key) {
                            .up => .up,
                            .down => .down,
                            .page_up => .page_up,
                            .page_down => .page_down,
                            .home => .home,
                            .end => .end,
                            .left => .left,
                            .right => .right,
                            .enter, .space => .enter,
                            .f5 => .reload,
                            else => null,
                        };
                        if (k) |kk| switch (self.scm_graph.handleKey(kk)) {
                            .open_diff => |row| if (self.scm_graph.view.diffSpec(row)) |spec| self.openGitDiff(spec),
                            else => {},
                        };
                    },
                    .timeline => if (self.sidebar_mode == .explorer) {
                        const k: ?timeline_view_mod.TimelineView.Key = switch (key) {
                            .up => .up,
                            .down => .down,
                            .page_up => .page_up,
                            .page_down => .page_down,
                            .home => .home,
                            .end => .end,
                            .enter, .space => .enter,
                            .f5 => .reload,
                            else => null,
                        };
                        if (k) |kk| switch (self.timeline_view.handleKey(kk)) {
                            .open_changes => |i| self.openTimelineChanges(i),
                            else => {},
                        };
                    },
                    .none => {},
                }
            }
            return;
        }

        // Diff-Editor: Pfeile/Bild/Pos1/Ende scrollen (Alt+F5 läuft über die Kürzel-Tabelle)
        if (self.activeTabKind() == .git_diff) {
            const d = self.activeGitDiff() orelse return;
            if (!self.is_ctrl_down and !self.is_alt_down) {
                const k: ?git_diff_view.GitDiffView.Key = switch (key) {
                    .up => .up,
                    .down => .down,
                    .page_up => .page_up,
                    .page_down => .page_down,
                    .home => .home,
                    .end => .end,
                    .left => .left,
                    .right => .right,
                    else => null,
                };
                if (k) |kk| d.view.handleKey(kk, d.salt);
            }
            return;
        }

        // If a chat tab is active, handle chat input. Ctrl+C mit markiertem Bubble-Text
        // kopiert diesen statt aus dem Eingabefeld.
        if (self.isChatTabActive()) {
            if (self.is_ctrl_down and key == .c) {
                if (self.ai_chat.selectedText(self.allocator)) |text| {
                    defer self.allocator.free(text);
                    if (self.window) |win| win.setClipboardText(text);
                    return;
                }
            }
            if (self.ai_chat.handleKeyPress(key)) return;
        }

        log.debug("handleKeyPress: key={} isTerminalActive={}", .{ key, self.isTerminalActive() });

        // If a terminal tab is active, forward input to the terminal
        if (self.getActiveTerminal()) |term| {
            // Convert key to terminal input sequence
            var data: ?[]const u8 = switch (key) {
                .enter => "\r",
                .backspace => "\x7f",
                .tab => "\t",
                .escape => "\x1b",
                .up => "\x1b[A",
                .down => "\x1b[B",
                .right => "\x1b[C",
                .left => "\x1b[D",
                .home => "\x1b[H",
                .end => "\x1b[F",
                .delete => "\x1b[3~",
                .page_up => "\x1b[5~",
                .page_down => "\x1b[6~",
                else => null,
            };

            if (self.getActiveEditor().mods.ctrl) {
                data = switch (key) {
                    .a => "\x01",
                    .b => "\x02",
                    .c => "\x03",
                    .d => "\x04",
                    .e => "\x05",
                    .f => "\x06",
                    .g => "\x07",
                    .h => "\x08",
                    .i => "\x09",
                    .j => "\x0A",
                    .k => "\x0B",
                    .l => "\x0C",
                    .m => "\x0D",
                    .n => "\x0E",
                    .o => "\x0F",
                    .p => "\x10",
                    .q => "\x11",
                    .r => "\x12",
                    .s => "\x13",
                    .t => "\x14",
                    .u => "\x15",
                    .v => "\x16",
                    .w => "\x17",
                    .x => "\x18",
                    .y => "\x19",
                    .z => "\x1A",
                    else => data,
                };
            }

            if (data) |d| {
                term.sendInput(d) catch {};
            }
            return;
        }
        // Markdown-Vorschau: Ctrl+C kopiert die Textauswahl, Escape hebt sie auf. Beides
        // darf nicht im unsichtbaren Editor dahinter landen.
        if (self.activeMarkdownView()) |v| {
            if (self.is_ctrl_down and key == .c) return self.copyPreviewSelection(v);
            if (key == .escape and v.hasSelection()) return v.clearSelection();
        }
        self.getActiveEditor().handleKeyPress(key);
    }

    /// Auswahl der Markdown-Vorschau in die Zwischenablage (Ctrl+C, Kontextmenü Copy).
    pub fn copyPreviewSelection(self: *Self, v: *markdown_view_mod.MarkdownView) void {
        const text = v.selectedText(self.allocator) orelse return;
        defer self.allocator.free(text);
        if (self.window) |win| win.setClipboardText(text);
    }

    fn handleDialogKey(self: *Self, ad: *ActiveDialog, key: wio.Button) void {
        var labels_buf: [8][]const u8 = undefined;
        const actions = ad.dialog.actions;
        const n = @min(actions.len, labels_buf.len);
        for (actions[0..n], 0..) |a, i| labels_buf[i] = a.label;
        const name = @tagName(key);
        const dk: dialog_ops.Key = switch (key) {
            .enter, .kp_enter => .enter,
            .escape => .escape,
            .tab => if (self.is_shift_down) .shift_tab else .tab,
            else => if (name.len == 1) .letter else return,
        };
        switch (dialog_ops.handleKey(labels_buf[0..n], ad.focused, dk, if (name.len == 1) name[0] else 0)) {
            .none => {},
            .focus => |i| ad.focused = i,
            .choose => |i| ad.key_result = actions[i].result,
        }
    }

    /// Text Input verarbeiten
    pub fn handleChar(self: *Self, char_code: u21) void {
        if (self.active_dialog != null) return; // Dialog ist modal, Buchstaben sind Buttons
        if (self.folder_picker.visible) {
            self.folder_picker.handleChar(char_code);
            return;
        }
        if (self.picker.visible) {
            self.picker.handleChar(char_code);
            return;
        }
        if (self.show_file_explorer and self.file_explorer.isEditing()) {
            self.file_explorer.handleRenameChar(char_code);
            return;
        }
        if (self.show_file_explorer and self.explorer_focused) return; // Buchstaben sind Explorer-Kürzel
        if (self.show_file_explorer and self.sidebar_focus == .commit_input and self.sidebar_mode == .scm) {
            self.scm_changes.handleInputChar(char_code);
            return;
        }
        if (self.show_file_explorer and self.sidebar_focus != .none) return; // Fokus in Graph/Timeline/Changes
        // kein Text in den unsichtbaren Editor hinter History- und Diff-Tabs
        if (self.activeTabKind() == .git_diff or self.activeTabKind() == .git_commit) return;

        // Forward to chat tab if active
        if (self.isChatTabActive()) {
            self.ai_chat.handleChar(char_code);
            return;
        }

        // Forward to terminal if active
        if (self.getActiveTerminal()) |term| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(char_code, &buf) catch return;
            term.sendInput(buf[0..len]) catch {};
            return;
        }
        self.getActiveEditor().handleChar(char_code);
    }

    /// Modifier-State aktualisieren
    pub fn setShiftState(self: *Self, pressed: bool) void {
        self.is_shift_down = pressed;
        self.ai_chat.setShiftState(pressed);
        self.getActiveEditor().setShiftState(pressed);
    }

    pub fn setCtrlState(self: *Self, pressed: bool) void {
        self.is_ctrl_down = pressed;
        if (!pressed) self.commitTabSwitcher();
        self.ai_chat.setCtrlState(pressed);
        self.getActiveEditor().setCtrlState(pressed);
    }

    pub fn setAltState(self: *Self, pressed: bool) void {
        self.is_alt_down = pressed;
        self.ai_chat.setAltState(pressed);
        self.getActiveEditor().setAltState(pressed);
    }

    fn findPaneAt(self: *Self, pane: *pane_mod.Pane, x: f32, y: f32) ?*pane_mod.Pane {
        switch (pane.data) {
            .leaf => {
                const id = clay.ElementId.IDI("Pane", @truncate(@intFromPtr(pane)));
                const data = clay.getElementData(id);
                if (data.found) {
                    const bb = data.bounding_box;
                    if (x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height) {
                        return pane;
                    }
                }
            },
            .split => |split| {
                if (self.findPaneAt(split.children[0], x, y)) |p| return p;
                if (self.findPaneAt(split.children[1], x, y)) |p| return p;
            },
        }
        return null;
    }

    /// Maus-Events an Editor oder Terminal weiterleiten
    pub fn handleMouseDown(self: *Self, x: f32, y: f32, button: wio.Button) void {
        log.debug("handleMouseDown: x={} y={} button={}", .{ x, y, button });
        // Nur Linksklicks zählen als "Press" für hover-basierte Klick-Handler im
        // Layout (Explorer-Zeilen, Tab-Leiste, Dialog-Buttons). Rechtsklick öffnet
        // Kontextmenüs und darf z.B. keine Datei öffnen.
        self.mouse_pressed_this_frame = (button == .mouse_left);
        self.is_mouse_down = (button == .mouse_left);

        if (self.shortcuts_dialog_open) {
            if (button == .mouse_left and (clay.pointerOver(clay.ElementId.ID(shortcuts_dialog.CLOSE_ID)) or
                !clay.pointerOver(clay.ElementId.ID(shortcuts_dialog.BOX_ID))))
            {
                self.shortcuts_dialog_open = false;
            }
            return;
        }
        // Ordner-Dialog ist modal: alle Klicks gehören ihm
        if (self.picker.visible) {
            if (button == .mouse_left) self.picker.handleMouseDown(x, self.is_shift_down);
            return;
        }
        if (self.folder_picker.visible) {
            if (button == .mouse_left) self.folder_picker.handleMouseDown(x, self.is_shift_down);
            return;
        }
        // Header-Menü: offen → Eintrag ausführen oder schließen; Klick auf "File" → öffnen
        if (self.open_menu) |mi| {
            self.open_menu = null;
            if (button == .mouse_left) {
                for (shortcuts.menus[mi].items) |cmd| {
                    if (clay.pointerOver(menuItemId(cmd))) {
                        self.executeCommand(cmd);
                        break;
                    }
                }
            }
            return;
        }
        if (button == .mouse_left) {
            inline for (shortcuts.menus, 0..) |menu, i| {
                if (clay.pointerOver(menuTitleId(menu))) {
                    self.open_menu = i;
                    return;
                }
            }
        }

        // Offenes Tab-Kontextmenü: Eintrag ausführen oder schließen
        if (self.tab_menu) |menu| {
            self.tab_menu = null;
            if (ctx_menu.hit("tab_menu", &shortcuts.tab_menu_items, tabMenuHidden(menu))) |cmd| {
                self.tab_cmd_target = .{ .pane = menu.pane, .index = menu.index };
                self.executeCommand(cmd);
                self.tab_cmd_target = null;
            }
            return;
        }
        // Tab-Kopf: Mittelklick schließt, Rechtsklick öffnet das Menü
        if (button == .mouse_middle or button == .mouse_right) {
            if (self.findPaneAt(self.root_pane, x, y)) |pane| {
                if (pane.data == .leaf) {
                    if (pane.data.leaf.tab_bar.tabIndexAt(x, y)) |i| {
                        if (button == .mouse_middle) {
                            self.requestCloseTab(pane, i);
                        } else {
                            self.tab_menu = .{ .pane = pane, .index = i, .x = x, .y = y, .marp_deck = self.tabIsMarpDeck(pane, i) };
                        }
                        return;
                    }
                }
            }
        }

        // Source Control Graph in der Sidebar
        if (self.show_file_explorer and self.sidebar_mode == .scm and (self.scm_graph.menu != null or self.inSidebarBox(x, y))) {
            self.explorer_focused = false;
            self.sidebar_focus = if (self.inSidebarBox(x, y)) .scm else .none;
            // Changes-Bereich über dem Graphen: Eingabefeld, Gruppen, Zeilen, Aktionen
            if (self.scm_graph.menu == null and self.scm_changes.contains(x, y)) {
                const act = self.scm_changes.handleMouseDown(x, y, button == .mouse_right, self.is_shift_down);
                self.sidebar_focus = if (act == .focus_input) .commit_input else .changes;
                self.runScmAction(act);
                return;
            }
            switch (self.scm_graph.handleMouseDown(x, y, button == .mouse_right)) {
                .none, .consumed => {},
                .open_diff => |row| if (self.scm_graph.view.diffSpec(row)) |spec| self.openGitDiff(spec),
                .open_commit => |c| self.openCommitChanges(c),
                .command => |c| {
                    self.scm_cmd_commit = c.commit;
                    self.executeCommand(c.cmd);
                    self.scm_cmd_commit = null;
                },
            }
            if (self.inSidebarBox(x, y)) return;
        }

        // Timeline unter dem Explorer: offenes Menü, Kopf und Einträge vor dem Baum
        if (self.show_file_explorer and self.sidebar_mode == .explorer and (self.timeline_view.menu != null or self.timeline_view.contains(x, y))) {
            self.explorer_focused = false;
            self.sidebar_focus = if (self.timeline_view.contains(x, y)) .timeline else .none;
            switch (self.timeline_view.handleMouseDown(x, y, button == .mouse_right)) {
                .none => {},
                .consumed => return,
                .toggled => {
                    self.saveUserState();
                    return;
                },
                .pin_toggled => {
                    self.resetTimelineFollow();
                    return;
                },
                .open_changes => |i| {
                    self.openTimelineChanges(i);
                    return;
                },
                .command => |c| {
                    self.timeline_view.timeline.selected = c.index;
                    self.executeCommand(c.cmd);
                    return;
                },
            }
        }

        // Tastatur-Fokus folgt dem Klick: Explorer-Kürzel (F2/Entf) nur nach Klick im Explorer
        self.explorer_focused = self.show_file_explorer and self.sidebar_mode == .explorer and self.file_explorer.inSidebar(x);
        self.sidebar_focus = .none;

        if (self.show_file_explorer and self.sidebar_mode == .explorer) {
            if (self.file_explorer.handleMouseDown(x, y, button, self.is_shift_down)) {
                if (self.file_explorer.takePendingCommand()) |cmd| self.executeCommand(cmd);
                return;
            }
        }

        // Priority: If a context menu is open, it must handle the click first (to either trigger an action or close)
        const current_editor = self.getActiveEditor();
        if (!current_editor.show_context_menu) {
            if (self.findPaneAt(self.root_pane, x, y)) |pane| {
                self.active_pane = pane;
            }
        }

        const tab_bar = self.getActiveTabBar();
        const editor = self.getActiveEditor();

        if (tab_bar.getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (tab_bar.terminal_instances.get(tab.path)) |term| {
                    if (button == .mouse_right) {
                        term.showContextMenu(x, y);
                        return;
                    }
                    const char_w = measureTextWidth("W", 16.0);
                    const line_h: f32 = 24.0;
                    if (term.handleMouseDown(x, y, char_w, line_h, term.terminal_content_x, term.terminal_content_y)) return;
                }
                return;
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    if (button == .mouse_right) {
                        v.showContextMenu(x, y);
                        return;
                    }
                    _ = v.handleMouseDown(x, y);
                }
                return;
            } else if (tab.kind == .chat) {
                self.ai_chat.handleMouseDown(x, y, button);
                return;
            } else if (tab.kind == .git_diff) {
                if (self.activeGitDiff()) |d| {
                    if (button == .mouse_left) _ = d.view.handleMouseDown(x, y, d.salt);
                }
                return;
            } else if (tab.kind == .git_commit) {
                if (self.activeGitCommit()) |c| {
                    if (button == .mouse_left) _ = c.view.handleMouseDown(x, y, c.salt);
                }
                return;
            }
        }

        // Rechtsklick auf die Tab-Leiste des aktiven Panes öffnet das Editor-Kontextmenü
        // (MD-Preview, Split …) an der Klickposition, wie im Textbereich selbst.
        if (button == .mouse_right) {
            const tb_id = clay.ElementId.IDI("tab_bar_container", @as(u32, @truncate(@intFromPtr(tab_bar))));
            const tb_data = clay.getElementData(tb_id);
            if (tb_data.found) {
                const tb = tb_data.bounding_box;
                if (x >= tb.x and x < tb.x + tb.width and y >= tb.y and y < tb.y + tb.height) {
                    editor.handleMouseDown(x, y, button);
                    return;
                }
            }
        }

        // Nur an Editor weitergeben wenn Klick innerhalb der code_editor-BBox
        // oder wenn Menü offen ist (damit Klicks auf das Menü ankommen)
        const editor_id = clay.ElementId.IDI("code_editor", @truncate(@intFromPtr(editor)));
        const editor_data = clay.getElementData(editor_id);
        if (editor_data.found) {
            const bb = editor_data.bounding_box;
            if (editor.show_context_menu or (x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height)) {
                editor.handleMouseDown(x, y, button);
            }
        }
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;

        // Modale Dialoge: Auswahl in Such- bzw. Pfadzeile ziehen
        if (self.picker.visible) return self.picker.handleMouseMove(x);
        if (self.folder_picker.visible) return self.folder_picker.handleMouseMove(x);

        if (self.show_file_explorer) {
            switch (self.sidebar_mode) {
                .explorer => {
                    self.file_explorer.handleMouseMove(x, y);
                    self.timeline_view.handleMouseMove(x, y);
                },
                .scm => {
                    self.scm_changes.handleMouseMove(x, y);
                    self.scm_graph.handleMouseMove(x, y);
                },
            }
        }

        if (self.getActiveTabBar().getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.getActiveTabBar().terminal_instances.get(tab.path)) |term| {
                    const char_w = measureTextWidth("W", 16.0);
                    const line_h: f32 = 24.0;
                    term.handleMouseMove(x, y, char_w, line_h, term.terminal_content_x, term.terminal_content_y);
                }
                return;
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    v.handleMouseMove(x, y);
                }
                return;
            } else if (tab.kind == .chat) {
                self.ai_chat.handleMouseMove(x, y);
                return;
            }
        }
        self.getActiveEditor().handleMouseMove(x, y);
        self.getActiveEditor().desired_cursor = if (self.getActiveEditor().last_frame_hovered) .text else .arrow;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.is_mouse_down = false;
        // Ziehen der Auswahl in den Editierfeldern beenden
        self.picker.handleMouseUp();
        self.folder_picker.handleMouseUp();
        self.scm_changes.handleMouseUp();

        if (self.show_file_explorer) {
            self.file_explorer.handleMouseUp();
        }

        if (self.getActiveTabBar().getActiveTab()) |tab| {
            if (tab.kind == .terminal) {
                if (self.getActiveTabBar().terminal_instances.get(tab.path)) |term| {
                    term.handleMouseUp();
                }
                // No return here, might want to clear other states too
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    v.handleMouseUp();
                }
                return;
            } else if (tab.kind == .chat) {
                self.ai_chat.handleMouseUp();
                return;
            }
        }
        self.getActiveEditor().handleMouseUp();
    }

    /// Scroll-Events an Editor oder Terminal weiterleiten
    /// Horizontales Scrollen (Touchpad/Shift+Rad): Editor-Spalten.
    pub fn handleScrollHorizontal(self: *Self, delta: i32) void {
        if (self.active_dialog != null or self.folder_picker.visible) return;
        if (self.getActiveTabBar().getActiveTab()) |tab| {
            if (tab.kind == .git_diff) {
                if (self.activeGitDiff()) |d| d.view.scrollLines(delta, true);
                return;
            }
            if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| v.scrollColumns(delta);
                return;
            }
            if (tab.kind != .text) return;
        }
        self.getActiveEditor().scrollColumns(delta);
    }

    /// Mausrad/Pfeile im Kürzel-Dialog: Versatz an die Inhaltshöhe geklemmt.
    fn scrollShortcuts(self: *Self, delta: i32) void {
        const content = clay.getElementData(clay.ElementId.ID(shortcuts_dialog.CONTENT_ID));
        const max_scroll = if (content.found) @max(0, content.bounding_box.height - shortcuts_dialog.LIST_HEIGHT) else 0;
        self.shortcuts_scroll_y = std.math.clamp(self.shortcuts_scroll_y - @as(f32, @floatFromInt(delta)) * 40, 0, max_scroll);
    }

    pub fn handleScroll(self: *Self, delta: i32) void {
        if (self.shortcuts_dialog_open) return self.scrollShortcuts(delta);
        // PDF-Vorschau blättert seitenweise statt zu scrollen.
        if (self.handlePdfScroll(@floatFromInt(delta))) return;
        if (self.is_shift_down) return self.handleScrollHorizontal(delta);
        if (self.folder_picker.visible) {
            self.folder_picker.handleScroll(delta);
            return;
        }
        if (self.picker.visible) {
            self.picker.handleScroll(delta);
            return;
        }
        if (self.show_file_explorer and self.sidebar_mode == .scm and self.inSidebarBox(self.mouse_x, self.mouse_y)) {
            if (self.scm_changes.inBody(self.mouse_x, self.mouse_y)) self.scm_changes.scrollLines(delta) else self.scm_graph.scrollLines(delta);
            return;
        }
        if (self.show_file_explorer and self.timeline_view.contains(self.mouse_x, self.mouse_y)) {
            self.timeline_view.scrollLines(delta);
            return;
        }
        if (self.show_file_explorer and clay.pointerOver(clay.ElementId.ID("file_explorer"))) {
            self.file_explorer.scrollLines(delta);
            return;
        }

        if (self.getActiveTabBar().getActiveTab()) |tab| {
            if (tab.kind == .chat) {
                self.ai_chat.scrollLines(delta);
                return;
            }
            if (tab.kind == .terminal) {
                if (self.getActiveTabBar().terminal_instances.get(tab.path)) |term| {
                    term.scrollLines(delta);
                }
                return;
            } else if (tab.kind == .markdown_preview) {
                if (self.open_markdown_views.get(tab.path)) |v| {
                    v.scrollLines(delta);
                }
                return;
            } else if (tab.kind == .git_diff) {
                if (self.activeGitDiff()) |d| d.view.scrollLines(delta, false);
                return;
            } else if (tab.kind == .git_commit) {
                if (self.activeGitCommit()) |c| c.view.scrollLines(delta);
                return;
            }
        }
        self.getActiveEditor().scrollLines(delta);
    }

    /// UI updaten (pro Frame)
    pub fn update(self: *Self, delta_ms: f32) void {
        self.ensureEditorHooks();
        self.applyLspGoto();
        self.driveGitDiffs();
        self.timeline_view.update(delta_ms);
        // „File History“ aus dem Editor-Menü: vor dem Layout, nie im Render-Pfad
        {
            var leaves_buf: [32]*pane_mod.Pane = undefined;
            var n: usize = 0;
            collectLeaves(self.root_pane, &leaves_buf, &n);
            for (leaves_buf[0..n]) |leaf| {
                const ed = leaf.data.leaf.code_editor;
                if (ed.pending_file_history) {
                    ed.pending_file_history = false;
                    self.openFileHistory(ed.buffer.get_file_path());
                }
            }
        }
        self.followActiveFileForTimeline();
        self.driveTimeline();
        self.scm_graph.update(delta_ms);
        self.driveScm();
        // Bestätigtes Löschen im Explorer: vor dem Layout, nie im Dialog-Callback
        self.file_explorer.processPending();
        while (self.file_explorer.takeFsChange()) |change| {
            defer change.deinit(self.allocator);
            self.applyFsChange(change);
        }
        if (self.file_explorer.takeError()) |msg| {
            if (self.active_dialog == null) self.showErrorDialog(msg) else self.allocator.free(msg);
        }
        if (self.file_explorer.takePendingMove()) |mv| {
            if (self.active_dialog != null or self.pending_move != null) {
                mv.deinit(self.allocator);
            } else {
                self.showMoveDialog(mv);
            }
        }
        if (self.getActiveEditor().takeError()) |msg| {
            if (self.active_dialog == null) self.showErrorDialog(msg) else self.allocator.free(msg);
        }
        if (self.file_explorer.takeInfo()) |msg| {
            defer self.allocator.free(msg);
            self.showToast("{s}", .{msg});
        }
        {
            const ed = self.getActiveEditor();
            if (ed.takeSaved()) {
                self.showToast("Saved {s}", .{std.fs.path.basename(ed.buffer.get_file_path())});
                self.reloadMarkdownPreview(ed.buffer.get_file_path());
            }
            // Autosave: 1 s nach der letzten Änderung, nur für Dateien mit Pfad
            if (self.autosave and ed.is_modified and ed.buffer.get_file_path().len > 0 and (ed.time_ms - ed.last_edit_ms) > 1000) {
                if (self.getActiveTabBar().getActiveTab()) |tab| {
                    if (tab.kind == .text) ed.dispatchAction(.Save);
                }
            }
        }
        // Abgelaufene Toasts entfernen
        var ti: usize = 0;
        while (ti < self.toasts.items.len) {
            if (self.toasts.items[ti].until_ms <= self.ui_time_ms) {
                self.allocator.free(self.toasts.orderedRemove(ti).text);
            } else ti += 1;
        }
        self.picker.poll();
        if (self.picker.takeFile()) |rel| {
            defer self.allocator.free(rel);
            if (self.picker.root) |root| {
                const abs = std.fs.path.join(self.allocator, &.{ root, rel }) catch null;
                if (abs) |a| {
                    defer self.allocator.free(a);
                    self.getActiveTabBar().openFile(a) catch |err| log.warn("quick open '{s}' failed: {}", .{ a, err });
                }
            }
        }
        if (self.picker.takeTab()) |picked_tab| self.getActiveTabBar().setActive(picked_tab);
        if (self.picker.takeCommand()) |cmd| self.executeCommand(cmd);
        if (self.folder_picker.takeResult()) |path| {
            if (self.pending_open_folder) |old| self.allocator.free(old);
            self.pending_open_folder = path;
        }
        self.driveAgentTools();
        self.anim_manager.update(delta_ms);
        self.getActiveEditor().time_ms += delta_ms;
        self.file_explorer.now_ms += delta_ms;
        self.ui_time_ms += delta_ms;
        self.ai_chat.updateTimeMs(delta_ms);
    }

    /// Werkzeugaufrufe des Agenten auf dem Main-Thread ausführen. Bestätigungs-
    /// pflichtige Aufrufe halten die Runde an, bis der Dialog beantwortet ist.
    fn driveAgentTools(self: *Self) void {
        if (self.agent_confirm) |*call| {
            const answer = self.agent_confirm_answer orelse return; // Dialog offen
            self.agent_confirm_answer = null;
            if (answer) {
                switch (agent_actions.execute(self, self.allocator, call, true)) {
                    .done => |res| {
                        defer self.allocator.free(res);
                        self.ai_chat.pushToolResult(call, res);
                    },
                    .needs_confirm => |msg| {
                        self.allocator.free(msg);
                        self.ai_chat.pushToolResult(call, "{\"error\":\"still requires confirmation\"}");
                    },
                }
            } else {
                self.ai_chat.pushToolResult(call, "{\"error\":\"the user denied this action\"}");
            }
            call.deinit(self.allocator);
            self.agent_confirm = null;
        }
        while (self.ai_chat.takePendingToolCall()) |call| {
            switch (agent_actions.execute(self, self.allocator, &call, false)) {
                .done => |res| {
                    defer self.allocator.free(res);
                    self.ai_chat.pushToolResult(&call, res);
                    call.deinit(self.allocator);
                },
                .needs_confirm => |msg| {
                    self.agent_confirm = call;
                    self.agent_confirm_answer = null;
                    self.active_dialog = .{
                        .dialog = .{
                            .title = "AI agent",
                            .message = msg,
                            .actions = &.{
                                .{ .label = "Allow", .result = .yes },
                                .{ .label = "Deny", .result = .cancel },
                            },
                        },
                        .callback = handleAgentConfirm,
                        .message_needs_free = true,
                    };
                    return;
                },
            }
        }
    }

    fn handleAgentConfirm(ui: *UI, res: dialog_mod.DialogResult, _: usize, _: ?*anyopaque) void {
        // Nicht hier ausführen (Render-Commands dieses Frames leben noch): update() macht weiter
        ui.agent_confirm_answer = (res == .yes);
    }

    pub fn handleAIToolCalls(self: *Self, payload: []const u8) void {
        self.ai_chat.handleToolCalls(payload);
    }

    /// Alle Leaf-Panes mit ausstehendem Tab-Wechsel (pending_switch_path). main.zig
    /// lädt deren Buffer, egal welches Pane aktiv ist.
    pub fn leavesWithPendingSwitch(self: *Self, buf: []*pane_mod.Pane) []*pane_mod.Pane {
        var n: usize = 0;
        collectPendingSwitch(self.root_pane, buf, &n);
        return buf[0..n];
    }

    fn collectPendingSwitch(pane: *pane_mod.Pane, buf: []*pane_mod.Pane, n: *usize) void {
        switch (pane.data) {
            .leaf => |leaf| {
                if (leaf.tab_bar.pending_switch_path != null and n.* < buf.len) {
                    buf[n.*] = pane;
                    n.* += 1;
                }
            },
            .split => |s| {
                collectPendingSwitch(s.children[0], buf, n);
                collectPendingSwitch(s.children[1], buf, n);
            },
        }
    }

    /// Datei wurde außerhalb des Editors neu geschrieben (Agent): offenen Buffer und
    /// alle Editoren darauf mit `content` neu laden, Tabs gelten als gespeichert.
    /// false, wenn die Datei nicht offen ist.
    pub fn reloadFileFromDisk(self: *Self, path: []const u8, content: []const u8) bool {
        const buf = self.open_buffers.get(path) orelse return false;
        var via_editor = false;
        self.reloadInPane(self.root_pane, buf, path, content, &via_editor);
        if (!via_editor) {
            buf.root = buf.load_from_string(content, &buf.file_eol_mode, &buf.file_utf8_sanitized) catch return true;
        }
        buf.last_save = buf.root;
        return true;
    }

    fn reloadInPane(self: *Self, pane: *pane_mod.Pane, buf: *@import("flow_core").Buffer, path: []const u8, content: []const u8, via_editor: *bool) void {
        switch (pane.data) {
            .leaf => |*leaf| {
                if (leaf.code_editor.buffer == buf) {
                    leaf.code_editor.setText(content);
                    leaf.code_editor.setLanguageFromPath(path);
                    leaf.code_editor.is_modified = false;
                    via_editor.* = true;
                }
                for (leaf.tab_bar.tabs.items) |*tab| {
                    if (std.mem.eql(u8, tab.path, path)) tab.modified = false;
                }
            },
            .split => |s| {
                self.reloadInPane(s.children[0], buf, path, content, via_editor);
                self.reloadInPane(s.children[1], buf, path, content, via_editor);
            },
        }
    }

    fn currentMods(self: *const Self) shortcuts.Mods {
        return .{ .ctrl = self.is_ctrl_down, .shift = self.is_shift_down, .alt = self.is_alt_down };
    }

    /// wio-Taste auf die Kürzel-Tabelle abbilden; null = Taste hat dort keine Rolle.
    fn keyFromButton(btn: wio.Button) ?shortcuts.Key {
        return switch (btn) {
            .a => .a,
            .b => .b,
            .c => .c,
            .d => .d,
            .e => .e,
            .f => .f,
            .g => .g,
            .h => .h,
            .j => .j,
            .k => .k,
            .n => .n,
            .o => .o,
            .p => .p,
            .r => .r,
            .s => .s,
            .t => .t,
            .v => .v,
            .w => .w,
            .x => .x,
            .y => .y,
            .z => .z,
            .@"0" => .n0,
            .equals => .equals,
            .minus => .minus,
            .kp_0 => .kp_0,
            .kp_plus => .kp_plus,
            .kp_minus => .kp_minus,
            .@"1" => .n1,
            .@"2" => .n2,
            .@"3" => .n3,
            .@"4" => .n4,
            .@"5" => .n5,
            .@"6" => .n6,
            .@"7" => .n7,
            .@"8" => .n8,
            .@"9" => .n9,
            .tab => .tab,
            .grave => .grave,
            .backslash => .backslash,
            .slash => .slash,
            .dot => .dot,
            .f1 => .f1,
            .f2 => .f2,
            .f5 => .f5,
            .f12 => .f12,
            .delete => .delete,
            .escape => .escape,
            .enter, .kp_enter => .enter,
            .page_up => .page_up,
            .page_down => .page_down,
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
            else => null,
        };
    }

    /// Ein Command aus Menü oder Tastenkürzel ausführen.
    pub fn executeCommand(self: *Self, cmd: shortcuts.Command) void {
        self.open_menu = null;
        switch (cmd) {
            .open_folder => self.openFolderPicker(),
            .show_shortcuts => self.shortcuts_dialog_open = true,
            .new_file => self.getActiveTabBar().openFile("New File.txt") catch |err| log.warn("new file failed: {}", .{err}),
            .close_tab => self.requestCloseActiveTab(),
            .next_tab => self.cycleTab(1),
            .prev_tab => self.cycleTab(-1),
            .recent_tab_next => self.recentTabSwitch(1),
            .recent_tab_prev => self.recentTabSwitch(-1),
            .open_tab_picker => self.openTabPicker(),
            .toggle_explorer => {
                self.show_file_explorer = !self.show_file_explorer;
                if (!self.show_file_explorer) {
                    self.explorer_focused = false;
                    self.sidebar_focus = .none;
                }
            },
            .new_terminal => self.getActiveTabBar().openTerminal(),
            // Editor-Commands: dieselben Actions wie die Tastenkürzel im Editor-Keymap
            .save => self.getActiveEditor().dispatchAction(.Save),
            .undo => self.getActiveEditor().dispatchAction(.Undo),
            .redo => self.getActiveEditor().dispatchAction(.Redo),
            .cut => self.getActiveEditor().dispatchAction(.Cut),
            .copy => self.getActiveEditor().dispatchAction(.Copy),
            .paste => self.getActiveEditor().dispatchAction(.Paste),
            .select_all => self.getActiveEditor().dispatchAction(.SelectAll),
            .delete_line => self.getActiveEditor().dispatchAction(.DeleteLine),
            .split_vertical => self.getActiveEditor().dispatchAction(.SplitVertical),
            .split_horizontal => self.getActiveEditor().dispatchAction(.SplitHorizontal),
            // Aus dem Tab-Menü: Vorschau des angeklickten Tabs, sonst des aktiven Editors
            .md_preview => if (self.tab_cmd_target) |t| self.requestMarkdownPreview(t.pane.data.leaf.tab_bar.tabs.items[t.index].path) else self.getActiveEditor().dispatchAction(.MdPreview),
            .md_export_pdf => if (self.tab_cmd_target) |t| self.exportMarpPdf(t.pane.data.leaf.tab_bar.tabs.items[t.index].path) else self.getActiveEditor().dispatchAction(.MdExportPdf),
            .terminal_copy => if (self.getActiveTerminal()) |term| term.copyToClipboard() catch |err| log.err("terminal copy failed: {}", .{err}),
            .terminal_paste => if (self.getActiveTerminal()) |term| term.pasteFromClipboard() catch |err| log.err("terminal paste failed: {}", .{err}),
            .find => self.getActiveEditor().dispatchAction(.Search),
            .rename_entry => {
                if (self.file_explorer.selectedNodeIndex()) |node| self.file_explorer.startRename(node);
            },
            .delete_entry => {
                if (self.file_explorer.selectedNodeIndex()) |node| {
                    self.file_explorer.requestDelete(node);
                    if (self.file_explorer.takePendingDelete()) |n| self.showDeleteConfirmationDialog(n);
                }
            },
            .new_file_entry => self.file_explorer.startCreate(false),
            .new_folder_entry => self.file_explorer.startCreate(true),
            .cut_entry => self.file_explorer.copySelection(true),
            .copy_entry => self.file_explorer.copySelection(false),
            .paste_entry => self.file_explorer.paste(),
            .duplicate_entry => self.file_explorer.duplicateSelection(),
            .copy_path => {
                if (self.file_explorer.selectedNodeIndex()) |node| self.setClipboard(self.file_explorer.nodes.items[node].path);
            },
            .copy_relative_path => {
                if (self.file_explorer.selectedNodeIndex()) |node| {
                    const abs = self.file_explorer.nodes.items[node].path;
                    const root = self.file_explorer.nodes.items[0].path;
                    const rel = if (std.mem.startsWith(u8, abs, root) and abs.len > root.len + 1) abs[root.len + 1 ..] else abs;
                    self.setClipboard(rel);
                }
            },
            .reveal_in_file_manager => {
                const node = self.file_explorer.targetFolder();
                const dir = self.file_explorer.nodes.items[node].path;
                var child = std.process.Child.init(&.{ "xdg-open", dir }, self.allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;
                child.spawn() catch |err| log.warn("xdg-open '{s}' failed: {}", .{ dir, err });
            },
            .open_in_terminal => {
                const node = self.file_explorer.targetFolder();
                self.getActiveTabBar().openTerminalIn(self.file_explorer.nodes.items[node].path);
            },
            .collapse_all => self.file_explorer.collapseAll(),
            .refresh_explorer => self.file_explorer.refreshKeepSelection(),
            .select_all_entries => self.file_explorer.selectAll(),
            .toggle_hidden_files => {
                self.file_explorer.toggleHidden();
                self.saveUserState();
            },
            .filter_explorer => {
                self.show_file_explorer = true;
                self.explorer_focused = true;
                self.sidebar_focus = .none;
                self.file_explorer.startFilter();
            },
            .close_other_tabs => if (self.tabTarget()) |t| self.closeTabsWhere(t.pane, t.index, false, false),
            .close_tabs_right => if (self.tabTarget()) |t| self.closeTabsWhere(t.pane, t.index, true, false),
            .close_all_tabs => if (self.tabTarget()) |t| self.closeTabsWhere(t.pane, null, false, false),
            .close_saved_tabs => if (self.tabTarget()) |t| self.closeTabsWhere(t.pane, null, false, true),
            .pin_tab => if (self.tabTarget()) |t| t.pane.data.leaf.tab_bar.togglePin(t.index),
            .copy_tab_path => if (self.tabTarget()) |t| self.setClipboard(t.pane.data.leaf.tab_bar.tabs.items[t.index].path),
            .reveal_in_explorer => if (self.tabTarget()) |t| {
                self.show_file_explorer = true;
                self.file_explorer.revealPath(t.pane.data.leaf.tab_bar.tabs.items[t.index].path);
            },
            .reopen_closed_tab => self.reopenClosedTab(),
            .goto_tab_1 => self.gotoTab(0),
            .goto_tab_2 => self.gotoTab(1),
            .goto_tab_3 => self.gotoTab(2),
            .goto_tab_4 => self.gotoTab(3),
            .goto_tab_5 => self.gotoTab(4),
            .goto_tab_6 => self.gotoTab(5),
            .goto_tab_7 => self.gotoTab(6),
            .goto_tab_8 => self.gotoTab(7),
            .goto_tab_9 => self.gotoTab(8),
            .toggle_comment => self.getActiveEditor().dispatchAction(.ToggleComment),
            .move_line_up => self.getActiveEditor().dispatchAction(.MoveLineUp),
            .move_line_down => self.getActiveEditor().dispatchAction(.MoveLineDown),
            .duplicate_line => self.getActiveEditor().dispatchAction(.DuplicateLine),
            .goto_line => self.getActiveEditor().dispatchAction(.GotoLine),
            .replace => self.getActiveEditor().dispatchAction(.Replace),
            .outdent_lines => self.getActiveEditor().dispatchAction(.OutdentLines),
            .goto_definition => self.getActiveEditor().dispatchAction(.GotoDefinition),
            .select_next_occurrence => self.getActiveEditor().dispatchAction(.SelectNextOccurrence),
            .add_cursor_above => self.getActiveEditor().dispatchAction(.AddCursorAbove),
            .add_cursor_below => self.getActiveEditor().dispatchAction(.AddCursorBelow),
            .focus_pane_left => self.focusPane(.left),
            .focus_pane_right => self.focusPane(.right),
            .focus_pane_up => self.focusPane(.up),
            .focus_pane_down => self.focusPane(.down),
            .focus_explorer => {
                self.show_file_explorer = true;
                self.sidebar_mode = .explorer; // wie VS Code Ctrl+Shift+E: zurück zum Explorer
                self.explorer_focused = true;
                self.sidebar_focus = .none;
                if (self.file_explorer.selected_index == null and self.file_explorer.visible_entries.items.len > 0) self.file_explorer.selectEntry(0);
            },
            .toggle_terminal => self.toggleTerminal(),
            .quick_open => {
                const root = if (self.file_explorer.nodes.items.len > 0) self.file_explorer.nodes.items[0].path else (self.current_directory orelse ".");
                self.picker.openFiles(root);
            },
            .command_palette => self.picker.openCommands(),
            .toggle_theme => {
                self.theme = if (self.theme.bg[0] > 128) Theme.dark() else Theme.light();
                self.applyThemeToEditors();
                self.saveUserState();
            },
            .zoom_in => self.setFontSizeAll(self.getActiveEditor().font_size + 2),
            .zoom_out => self.setFontSizeAll(self.getActiveEditor().font_size -| 2),
            .zoom_reset => self.setFontSizeAll(24),
            .toggle_autosave => {
                self.autosave = !self.autosave;
                self.showToast("Autosave {s}", .{if (self.autosave) "on" else "off"});
                self.saveUserState();
            },
            .toggle_minimap => self.toggleEditorOption(.minimap),
            .toggle_whitespace => self.toggleEditorOption(.whitespace),
            .toggle_word_wrap => self.toggleEditorOption(.word_wrap),
            .toggle_indent_guides => self.toggleEditorOption(.indent_guides),
            .file_history => if (self.tab_cmd_target) |t|
                self.openFileHistory(t.pane.data.leaf.tab_bar.tabs.items[t.index].path)
            else
                self.openFileHistory(self.getActiveEditor().buffer.get_file_path()),
            .file_history_entry => if (self.file_explorer.selectedNodeIndex()) |node| {
                self.openFileHistory(self.file_explorer.nodes.items[node].path);
            },
            .diff_next_change => if (self.activeGitDiff()) |d| d.view.nextChange(d.salt),
            .diff_prev_change => if (self.activeGitDiff()) |d| d.view.prevChange(d.salt),
            .diff_toggle_collapse => if (self.activeGitDiff()) |d| d.view.state.toggleCollapse(),
            .diff_toggle_inline => if (self.activeGitDiff()) |d| d.view.toggleInline(),
            .timeline_open_changes => if (self.timeline_view.timeline.selected) |i| self.openTimelineChanges(i),
            .timeline_copy_commit_id => if (self.selectedTimelineItem()) |it| self.setClipboard(it.hash),
            .timeline_copy_commit_message => if (self.selectedTimelineItem()) |it| self.setClipboard(it.message),
            .timeline_refresh => self.timeline_view.timeline.refresh(),
            .timeline_toggle_pin => {
                self.timeline_view.timeline.togglePin();
                self.resetTimelineFollow();
            },
            .timeline_open_commit => if (self.selectedTimelineItem()) |it| {
                const t = &self.timeline_view.timeline;
                if (it.kind == .commit) self.openCommitTab(.{ .hash = it.hash, .parent = it.parent, .repo = t.repo, .subject = it.label });
            },
            .view_source_control => {
                self.show_file_explorer = true;
                self.sidebar_mode = .scm;
                self.explorer_focused = false;
                self.sidebar_focus = .commit_input; // wie VS Code Ctrl+Shift+G: Fokus im Eingabefeld
            },
            .graph_open_changes => if (self.scm_cmd_commit) |c| self.openCommitChanges(c),
            .graph_copy_commit_hash => if (self.graphCommit()) |c| self.setClipboard(c.hash),
            .graph_copy_commit_message => if (self.graphCommit()) |c| self.setClipboard(c.message),
            .graph_refresh => self.scm_graph.refresh(),
        }
    }

    // ───────────────────────── Source Control Graph ─────────────────────────

    fn inSidebarBox(self: *Self, x: f32, y: f32) bool {
        _ = self;
        const d = clay.getElementData(clay.ElementId.ID("sidebar"));
        if (!d.found) return false;
        const b = d.bounding_box;
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    fn graphCommit(self: *Self) ?git_scm.Commit {
        const i = self.scm_cmd_commit orelse (if (self.scm_graph.view.selected) |r| (if (r < self.scm_graph.view.rows.items.len) self.scm_graph.view.rows.items[r].commit else null) else null) orelse return null;
        const all = self.scm_graph.view.commits();
        return if (i < all.len) all[i] else null;
    }

    /// „Open Changes“ eines Graph-Commits: Multi-File-Diff wie VS Code git.viewCommit.
    fn openCommitChanges(self: *Self, commit_index: usize) void {
        const spec = self.scm_graph.view.commitSpec(commit_index) orelse return;
        self.openCommitTab(spec);
    }

    fn openCommitTab(self: *Self, spec: git_scm.CommitSpec) void {
        const tab_path = git_scm.commitTabPath(self.allocator, spec) catch return;
        if (self.pending_tab_switch) |old| self.allocator.free(old);
        self.pending_tab_switch = tab_path;
        self.explorer_focused = false;
        self.sidebar_focus = .none;
    }

    fn gitCommitFor(self: *Self, tab_path: []const u8) ?*git_commit_view_mod.GitCommitView {
        if (self.git_commits.get(tab_path)) |v| return v;
        const v = git_commit_view_mod.GitCommitView.create(self.allocator, tab_path) catch return null;
        self.git_commits.put(self.allocator, v.tab_path, v) catch {
            v.destroy();
            return null;
        };
        return v;
    }

    pub const ActiveCommit = struct { view: *git_commit_view_mod.GitCommitView, salt: u32 };

    pub fn activeGitCommit(self: *Self) ?ActiveCommit {
        const tab = self.getActiveTabBar().getActiveTab() orelse return null;
        if (tab.kind != .git_commit) return null;
        const v = self.git_commits.get(tab.path) orelse return null;
        return .{ .view = v, .salt = paneSalt(self.active_pane) };
    }

    const graph_key = "graph";

    /// Graph-Seiten, aufgeklappte Commits, Multi-File-Diffs und deren sichtbare Dateien anfordern.
    fn driveScm(self: *Self) void {
        const sched = self.scheduler orelse return;
        if (self.sidebar_mode == .scm and self.show_file_explorer) {
            const v = &self.scm_graph.view;
            if (v.want_log != null) blk: {
                const root = if (self.file_explorer.nodes.items.len > 0) self.file_explorer.nodes.items[0].path else (self.current_directory orelse ".");
                var key_buf: [32]u8 = undefined;
                var skip_buf: [24]u8 = undefined;
                var size_buf: [24]u8 = undefined;
                const skip = v.want_log.?;
                const key = std.fmt.bufPrint(&key_buf, graph_key ++ "{d}\x1f{d}", .{ self.scm_graph.generation, skip }) catch break :blk;
                const params = git_worker.FieldsParam.init(self.allocator, &.{
                    key,
                    root,
                    std.fmt.bufPrint(&skip_buf, "{d}", .{skip}) catch break :blk,
                    std.fmt.bufPrint(&size_buf, "{d}", .{git_scm.page_size}) catch break :blk,
                }) catch break :blk;
                if (sched.submit(.{ .func = git_worker.taskGitGraphLog, .data = params })) {
                    _ = v.takeLogRequest();
                } else params.deinit();
            }
            while (v.takeChangesRequest()) |hash| {
                const c = for (v.commits()) |c| {
                    if (std.mem.eql(u8, c.hash, hash)) break c;
                } else continue;
                var key_buf: [96]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, graph_key ++ "{d}\x1f{s}", .{ self.scm_graph.generation, hash }) catch continue;
                const params = git_worker.FieldsParam.init(self.allocator, &.{ key, v.repo, c.hash, c.firstParent() }) catch continue;
                if (!sched.submit(.{ .func = git_worker.taskGitCommitChanges, .data = params })) params.deinit();
            }
        }
        var it = self.git_commits.valueIterator();
        while (it.next()) |vp| {
            const cv = vp.*;
            if (cv.takeChangesRequest()) {
                const params = git_worker.FieldsParam.init(self.allocator, &.{ cv.tab_path, cv.spec.repo, cv.spec.hash, cv.spec.parent }) catch continue;
                if (!sched.submit(.{ .func = git_worker.taskGitCommitChanges, .data = params })) {
                    params.deinit();
                    cv.want_changes = true;
                    cv.loading = false;
                }
            }
            for (cv.sections.items) |*s| {
                if (!s.needed or s.view.state.loaded or s.view.state.loading or s.view.state.error_text != null) continue;
                s.view.state.want_load = true;
                if (!s.view.state.takeRequest()) continue;
                const param = git_worker.TextParam.init(self.allocator, s.view.state.tab_path) catch continue;
                if (!sched.submit(.{ .func = git_worker.taskGitFileDiff, .data = param })) {
                    param.deinit();
                    s.view.state.loading = false;
                }
            }
        }
    }

    /// Ergebnis einer Graph-Seite; Schlüssel `graph<generation>\x1f<skip>`, veraltete verworfen.
    pub fn handleGitGraphLog(self: *Self, ok: bool, payload: []const u8) void {
        const u = git_worker.unframe(payload) orelse return;
        const k = git_worker.splitKey(u.key);
        var buf: [32]u8 = undefined;
        const current = std.fmt.bufPrint(&buf, graph_key ++ "{d}", .{self.scm_graph.generation}) catch return;
        if (!std.mem.eql(u8, k.tab_path, current)) return;
        self.scm_graph.view.applyLog(ok, u.body, git_scm.page_size) catch |err| log.warn("graph: {}", .{err});
    }

    /// Dateien eines Commits: für den Graphen (`graph<gen>\x1f<hash>`) oder einen Multi-File-Diff-Tab.
    pub fn handleGitCommitChanges(self: *Self, ok: bool, payload: []const u8) void {
        const u = git_worker.unframe(payload) orelse return;
        if (self.git_commits.get(u.key)) |cv| {
            cv.applyChanges(ok, u.body) catch |err| log.warn("commit changes: {}", .{err});
            return;
        }
        const k = git_worker.splitKey(u.key);
        var buf: [32]u8 = undefined;
        const current = std.fmt.bufPrint(&buf, graph_key ++ "{d}", .{self.scm_graph.generation}) catch return;
        if (!std.mem.eql(u8, k.tab_path, current)) return;
        self.scm_graph.view.applyChanges(k.hash, ok, u.body) catch |err| log.warn("graph changes: {}", .{err});
    }

    fn dropUnusedGitCommit(self: *Self, tab_path: []const u8) void {
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| {
            for (p.data.leaf.tab_bar.tabs.items) |tab| {
                if (std.mem.eql(u8, tab.path, tab_path)) return;
            }
        }
        const kv = self.git_commits.fetchRemove(tab_path) orelse return;
        kv.value.destroy();
    }

    // ───────────────────────── Timeline ─────────────────────────

    fn selectedTimelineItem(self: *Self) ?@import("git_timeline").Item {
        const t = &self.timeline_view.timeline;
        const i = t.selected orelse return null;
        return if (i < t.items().len) t.items()[i] else null;
    }

    /// Klick auf einen Timeline-Eintrag: Diff-Editor wie VS Code `Open Comparison`.
    fn openTimelineChanges(self: *Self, index: usize) void {
        const spec = self.timeline_view.timeline.diffSpec(index) orelse return;
        self.openGitDiff(spec);
    }

    /// Timeline folgt der Datei des aktiven Tabs (Datei-Tabs, Vorschau-Quelle, Diff-Editor-Datei).
    /// Nur bei geändertem Tab-Pfad wird neu aufgelöst (realpath).
    /// Nächster Frame löst die Datei des aktiven Tabs neu auf (nach Lösen des Pins).
    fn resetTimelineFollow(self: *Self) void {
        if (self.timeline_follow_key) |k| self.allocator.free(k);
        self.timeline_follow_key = null;
    }

    fn followActiveFileForTimeline(self: *Self) void {
        const tab = self.getActiveTabBar().getActiveTab();
        const key: []const u8 = if (tab) |t| t.path else "";
        if (self.timeline_follow_key) |k| if (std.mem.eql(u8, k, key)) return;
        if (self.timeline_follow_key) |k| self.allocator.free(k);
        self.timeline_follow_key = self.allocator.dupe(u8, key) catch null;

        const t = tab orelse return self.timeline_view.timeline.follow(null);
        switch (t.kind) {
            .text, .image, .pdf, .binary, .markdown_preview => {
                const src = if (t.kind == .markdown_preview and std.mem.startsWith(u8, t.path, "preview://")) t.path["preview://".len..] else t.path;
                const abs = std.fs.cwd().realpathAlloc(self.allocator, src) catch return self.timeline_view.timeline.follow(null);
                defer self.allocator.free(abs);
                self.timeline_view.timeline.follow(abs);
            },
            // Diff-Editor: Timeline bleibt stehen. VS Code behält die Datei-URI (app.zig), auch wenn
            // der Commit die Datei noch unter altem Namen (lib.zig) zeigt; der Pfad im Diff-Tab
            // ist der historische und würde die Liste auf die alte Datei umschalten.
            .git_diff => {},
            else => self.timeline_view.timeline.follow(null),
        }
    }

    fn driveTimeline(self: *Self) void {
        const sched = self.scheduler orelse return;
        const t = &self.timeline_view.timeline;
        if (!t.takeRequest()) return;
        const param = git_worker.TextParam.init(self.allocator, t.file.?) catch return;
        if (!sched.submit(.{ .func = git_worker.taskGitTimeline, .data = param })) {
            param.deinit();
            t.loading = false;
            t.want_load = true;
        }
    }

    /// Ergebnis von `taskGitTimeline` (ok = Tag `git_timeline`).
    pub fn handleGitTimeline(self: *Self, ok: bool, payload: []const u8) void {
        const u = git_worker.unframe(payload) orelse return;
        self.timeline_view.timeline.apply(u.key, ok, u.body) catch |err| log.warn("timeline: {}", .{err});
    }

    fn activeTabKind(self: *Self) ?file_types.FileKind {
        const tab = self.getActiveTabBar().getActiveTab() orelse return null;
        return tab.kind;
    }

    pub const ActiveDiff = struct { view: *git_diff_view.GitDiffView, salt: u32 };

    /// Diff-Editor des aktiven Tabs im aktiven Pane.
    pub fn activeGitDiff(self: *Self) ?ActiveDiff {
        const tab = self.getActiveTabBar().getActiveTab() orelse return null;
        if (tab.kind != .git_diff) return null;
        const v = self.git_diffs.get(tab.path) orelse return null;
        return .{ .view = v, .salt = paneSalt(self.active_pane) };
    }

    fn gitDiffFor(self: *Self, tab_path: []const u8) ?*git_diff_view.GitDiffView {
        if (self.git_diffs.get(tab_path)) |v| return v;
        const v = git_diff_view.GitDiffView.create(self.allocator, tab_path) catch return null;
        self.git_diffs.put(self.allocator, v.state.tab_path, v) catch {
            v.destroy();
            return null;
        };
        return v;
    }

    /// Diff-Tab öffnen bzw. aktivieren (main.zig öffnet `pending_tab_switch` im nächsten Frame).
    pub fn openGitDiff(self: *Self, spec: git_diff.Spec) void {
        const tab_path = git_diff.tabPath(self.allocator, spec) catch return;
        if (self.pending_tab_switch) |old| self.allocator.free(old);
        self.pending_tab_switch = tab_path;
        self.explorer_focused = false;
        self.sidebar_focus = .none;
    }

    fn driveGitDiffs(self: *Self) void {
        const sched = self.scheduler orelse return;
        var it = self.git_diffs.valueIterator();
        while (it.next()) |vp| {
            const s = &vp.*.state;
            if (!s.takeRequest()) continue;
            const param = git_worker.TextParam.init(self.allocator, s.tab_path) catch return;
            if (!sched.submit(.{ .func = git_worker.taskGitFileDiff, .data = param })) {
                param.deinit();
                s.want_load = true; // Queue voll: nächster Frame
                s.loading = false;
                return;
            }
        }
    }

    /// Ergebnis von `taskGitFileDiff` (ok = Tag `git_file_diff`).
    pub fn handleGitFileDiff(self: *Self, ok: bool, payload: []const u8) void {
        const u = git_worker.unframe(payload) orelse return;
        if (self.git_diffs.get(u.key)) |v| {
            v.apply(ok, u.body) catch |err| log.warn("git diff: {}", .{err});
            return;
        }
        // Datei eines Multi-File-Diffs
        var it = self.git_commits.valueIterator();
        while (it.next()) |cv| if (cv.*.applyFileDiff(u.key, ok, u.body)) return;
    }

    fn dropUnusedGitDiff(self: *Self, tab_path: []const u8) void {
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| {
            for (p.data.leaf.tab_bar.tabs.items) |tab| {
                if (std.mem.eql(u8, tab.path, tab_path)) return;
            }
        }
        const kv = self.git_diffs.fetchRemove(tab_path) orelse return;
        kv.value.destroy();
    }

    // ───────────────────────── File History (Timeline) ─────────────────────────

    /// „File History“: Timeline auf die Datei stellen. Ordner und Dateien außerhalb eines
    /// Repos bekommen einen Hinweis.
    fn openFileHistory(self: *Self, path: []const u8) void {
        if (path.len == 0) return;
        const abs = std.fs.cwd().realpathAlloc(self.allocator, path) catch |err| {
            self.showToast("File History: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(abs);
        if (@import("explorer_ops.zig").isDirectory(abs)) {
            self.showToast("File History works on files, not folders", .{});
            return;
        }
        if (!git_worker.isInsideRepo(std.fs.path.dirname(abs) orelse abs)) {
            self.showToast("Not in a git repository: {s}", .{std.fs.path.basename(abs)});
            return;
        }
        // Wie VS Code `files.openTimeline`: Timeline im Explorer auf die Datei stellen
        self.show_file_explorer = true;
        self.sidebar_mode = .explorer;
        self.explorer_focused = false;
        self.timeline_view.timeline.show(abs);
        self.saveUserState();
    }

    fn paneSalt(pane: *pane_mod.Pane) u32 {
        return @truncate(@intFromPtr(pane));
    }

    pub const EditorOption = enum { minimap, whitespace, indent_guides, word_wrap };

    /// Anzeigeoption in allen Editoren umschalten (gemerkt).
    fn toggleEditorOption(self: *Self, opt: EditorOption) void {
        const ed = self.getActiveEditor();
        const new_value = switch (opt) {
            .minimap => !ed.show_minimap,
            .whitespace => !ed.show_whitespace,
            .indent_guides => !ed.show_indent_guides,
            .word_wrap => !ed.word_wrap,
        };
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| {
            const e = p.data.leaf.code_editor;
            switch (opt) {
                .minimap => e.show_minimap = new_value,
                .whitespace => e.show_whitespace = new_value,
                .indent_guides => e.show_indent_guides = new_value,
                .word_wrap => {
                    e.word_wrap = new_value;
                    e.ensureCursorVisible();
                },
            }
        }
        self.showToast("{s} {s}", .{ @tagName(opt), if (new_value) "on" else "off" });
        self.saveUserState();
    }

    pub fn isLightTheme(self: *const Self) bool {
        return self.theme.bg[0] > 128;
    }

    // ───────────────────────── LSP (zls): Sprung zur Definition ─────────────────────────

    const LspPending = struct { editor: *editor_mod.CodeEditor, row: usize, col: usize };
    const LspGoto = struct { path: []u8, row: usize, col: usize, frames_left: u32 };

    /// Jeder Editor bekommt den Definition-Hook (UI-Zeiger ist erst nach init stabil, deshalb hier).
    fn ensureEditorHooks(self: *Self) void {
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| {
            const e = p.data.leaf.code_editor;
            if (e.definition_hook == null) e.definition_hook = .{ .ctx = self, .func = lspDefinitionHookFn };
        }
    }

    fn lspDefinitionHookFn(ctx: *anyopaque, editor: *editor_mod.CodeEditor, row: usize, col: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.lspGotoDefinition(editor, row, col);
    }

    pub fn lspStatus(self: *const Self) []const u8 {
        const l = self.lsp orelse return if (self.lsp_failed) "failed" else "off";
        return if (l.isReady()) "ready" else "starting";
    }

    /// zls starten, falls möglich: `ZLS_PATH`, sonst `~/.local/bin/zls`, sonst `zls` im PATH.
    /// `ZID_LSP=off` schaltet ab.
    fn ensureLsp(self: *Self) ?*lsp_client.LspClient {
        if (self.lsp) |l| return l;
        if (self.lsp_failed) return null;
        if (env.get("ZID_LSP")) |v| {
            if (std.mem.eql(u8, v, "off")) {
                self.lsp_failed = true;
                return null;
            }
        }
        const sched = self.scheduler orelse {
            self.lsp_failed = true;
            return null;
        };
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const zls: []const u8 = env.get("ZLS_PATH") orelse blk: {
            if (env.home()) |home| {
                const candidate = std.fmt.bufPrint(&path_buf, "{s}/.local/bin/zls", .{home}) catch break :blk "zls";
                std.fs.accessAbsolute(candidate, .{}) catch break :blk "zls";
                break :blk candidate;
            }
            break :blk "zls";
        };
        const root = self.current_directory orelse ".";
        const abs_root = std.fs.cwd().realpathAlloc(self.allocator, root) catch {
            self.lsp_failed = true;
            return null;
        };
        defer self.allocator.free(abs_root);
        const client = lsp_client.LspClient.start(self.allocator, sched, &.{zls}, abs_root) catch |err| {
            log.warn("LSP: zls konnte nicht gestartet werden ({s}): {}", .{ zls, err });
            self.lsp_failed = true;
            return null;
        };
        log.info("LSP: zls gestartet ({s}) für {s}", .{ zls, abs_root });
        self.lsp = client;
        return client;
    }

    /// true = Anfrage an zls unterwegs; false = Editor sucht selbst per Textmuster.
    fn lspGotoDefinition(self: *Self, editor: *editor_mod.CodeEditor, row: usize, col: usize) bool {
        const rel = editor.buffer.get_file_path();
        if (!std.mem.endsWith(u8, rel, ".zig")) return false;
        const client = self.ensureLsp() orelse return false;
        if (!client.isReady()) return false;
        const path = std.fs.cwd().realpathAlloc(self.allocator, rel) catch return false;
        defer self.allocator.free(path);
        const text = editor.allTextAlloc() catch return false;
        defer self.allocator.free(text);
        client.syncDocument(path, "zig", text) catch return false;
        client.definition(path, @intCast(row), editor.charIndexAt(row, col)) catch return false;
        self.lsp_pending = .{ .editor = editor, .row = row, .col = col };
        return true;
    }

    /// Antwort auf `textDocument/definition`: gleiche Datei → Cursor setzen, andere Datei →
    /// Tab öffnen und den Sprung nachholen, sobald der Buffer geladen ist. Nichts gefunden →
    /// lokale Textmuster-Suche als Rückfall.
    pub fn handleLspDefinition(self: *Self, payload: []const u8) void {
        const pending = self.lsp_pending orelse return;
        self.lsp_pending = null;
        const loc = (lsp_proto.firstLocation(self.allocator, payload) catch null) orelse {
            pending.editor.gotoDefinitionLocal(pending.row, pending.col);
            return;
        };
        defer loc.deinit(self.allocator);
        const target = (lsp_proto.uriToPath(self.allocator, loc.uri) catch null) orelse {
            pending.editor.gotoDefinitionLocal(pending.row, pending.col);
            return;
        };
        defer self.allocator.free(target);
        const current = std.fs.cwd().realpathAlloc(self.allocator, pending.editor.buffer.get_file_path()) catch null;
        defer if (current) |c| self.allocator.free(c);
        if (current != null and std.mem.eql(u8, current.?, target)) {
            pending.editor.jumpTo(loc.line, loc.character);
            return;
        }
        const tab_bar = self.getActiveTabBar();
        tab_bar.openFile(target) catch {
            pending.editor.gotoDefinitionLocal(pending.row, pending.col);
            return;
        };
        if (self.lsp_goto) |g| self.allocator.free(g.path);
        self.lsp_goto = .{ .path = self.allocator.dupe(u8, target) catch return, .row = loc.line, .col = loc.character, .frames_left = 240 };
    }

    fn applyLspGoto(self: *Self) void {
        const g = &(self.lsp_goto orelse return);
        const tab_bar = self.getActiveTabBar();
        const loaded = tab_bar.pending_switch_path == null and blk: {
            const idx = tab_bar.active_index orelse break :blk false;
            if (idx >= tab_bar.tabs.items.len) break :blk false;
            break :blk std.mem.eql(u8, tab_bar.tabs.items[idx].path, g.path);
        };
        if (loaded) {
            self.getActiveEditor().jumpTo(g.row, g.col);
        } else if (g.frames_left > 0) {
            g.frames_left -= 1;
            return;
        }
        self.allocator.free(g.path);
        self.lsp_goto = null;
    }

    // ───────────────────────── Ctrl+Tab (zuletzt benutzt) und Tab-Picker ─────────────────────────

    /// Ctrl+Tab / Ctrl+Shift+Tab: eine Position weiter in der „zuletzt benutzt“-Reihenfolge; die
    /// Auswahl gilt, sobald Ctrl losgelassen wird (`commitTabSwitcher`). Wie VS Code und Zed.
    fn recentTabSwitch(self: *Self, dir: i32) void {
        const n = self.getActiveTabBar().tabs.items.len;
        if (n < 2) return;
        self.tab_switcher = tab_mru.cyclePos(self.tab_switcher, dir, n);
    }

    fn commitTabSwitcher(self: *Self) void {
        const pos = self.tab_switcher orelse return;
        self.tab_switcher = null;
        const tab_bar = self.getActiveTabBar();
        const order = tab_bar.mruIndices(self.allocator) catch return;
        defer self.allocator.free(order);
        if (pos < order.len) tab_bar.setActive(order[pos]);
    }

    /// Ctrl+E: Picker über die offenen Tabs der aktiven Leiste, jüngster zuerst.
    fn openTabPicker(self: *Self) void {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.tabs.items.len == 0) return;
        const order = tab_bar.mruIndices(self.allocator) catch return;
        defer self.allocator.free(order);
        const arena_alloc = self.frame_arena.allocator();
        var labels: std.ArrayListUnmanaged([]const u8) = .empty;
        var details: std.ArrayListUnmanaged([]const u8) = .empty;
        for (order) |i| {
            labels.append(arena_alloc, tab_bar_mod.tabLabel(arena_alloc, tab_bar, i)) catch return;
            const dir = std.fs.path.dirname(tab_bar.tabs.items[i].path) orelse "";
            details.append(arena_alloc, dir) catch return;
        }
        self.picker.openTabs(labels.items, details.items, order);
    }

    /// Umschalter-Overlay: offene Tabs in „zuletzt benutzt“-Reihenfolge, Auswahl hervorgehoben.
    fn renderTabSwitcher(self: *Self, t: Theme) void {
        const pos = self.tab_switcher orelse return;
        const tab_bar = self.getActiveTabBar();
        const arena_alloc = self.frame_arena.allocator();
        const order = tab_bar.mruIndices(arena_alloc) catch return;
        clay.UI()(.{
            .id = clay.ElementId.ID("tab_switcher_backdrop"),
            .floating = .{ .attach_to = .to_root, .z_index = 2000 },
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .child_alignment = .{ .x = .center, .y = .top }, .padding = .{ .top = 120 } },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("tab_switcher"),
                .layout = .{ .sizing = .{ .w = .fixed(420) }, .padding = .all(8), .direction = .top_to_bottom, .child_gap = 2 },
                .background_color = t.surface,
                .border = .{ .width = .all(1), .color = t.border },
                .corner_radius = .all(8),
            })({
                for (order, 0..) |tab_index, k| {
                    const active = k == pos;
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("tab_switcher_row", @intCast(k)),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(30) }, .padding = .axes(0, 10), .child_alignment = .{ .x = .left, .y = .center } },
                        .background_color = if (active) t.primary else .{ 0, 0, 0, 0 },
                        .corner_radius = .all(4),
                    })({
                        clay.text(tab_bar_mod.tabLabel(arena_alloc, tab_bar, tab_index), .{ .font_size = 18, .color = if (active) t.text_on_primary else t.text, .wrap_mode = .none });
                    });
                }
            });
        });
    }

    /// Neue Editoren (Split) übernehmen Anzeigeoptionen, Schriftgröße und Theme des Ausgangs-Editors;
    /// vorher startete ein gesplitteter Pane mit den Standardwerten (Minimap an, kein Wrap …).
    fn copyEditorOptions(dst: *editor_mod.CodeEditor, src: *const editor_mod.CodeEditor, theme: Theme) void {
        dst.show_minimap = src.show_minimap;
        dst.show_whitespace = src.show_whitespace;
        dst.show_indent_guides = src.show_indent_guides;
        dst.word_wrap = src.word_wrap;
        dst.setFontSize(src.font_size);
        dst.applyTheme(theme);
    }

    pub fn applyThemeToEditors(self: *Self) void {
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| p.data.leaf.code_editor.applyTheme(self.theme);
        self.ai_chat.input_editor.applyTheme(self.theme);
    }

    fn setFontSizeAll(self: *Self, size: u16) void {
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| p.data.leaf.code_editor.setFontSize(size);
        const preview = self.previewFontSize();
        var it = self.open_markdown_views.valueIterator();
        while (it.next()) |v| v.*.font_size = preview;
        self.showToast("Font size {d}", .{self.getActiveEditor().font_size});
        self.saveUserState();
    }

    /// Kurze Meldung unten rechts, 3 s sichtbar.
    pub fn showToast(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.toasts.append(self.allocator, .{ .text = text, .until_ms = self.ui_time_ms + 3000 }) catch self.allocator.free(text);
        if (self.toasts.items.len > 4) self.allocator.free(self.toasts.orderedRemove(0).text);
    }

    /// Text des jüngsten Toasts (Tests).
    pub fn lastToast(self: *const Self) []const u8 {
        if (self.toasts.items.len == 0) return "";
        return self.toasts.items[self.toasts.items.len - 1].text;
    }

    fn renderToasts(self: *Self, t: Theme) void {
        if (self.toasts.items.len == 0) return;
        clay.UI()(.{
            .id = clay.ElementId.ID("toasts"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_bottom },
                .offset = .{ .x = -16, .y = -16 },
                .z_index = 1800,
            },
            .layout = .{ .direction = .top_to_bottom, .child_gap = 6, .child_alignment = .{ .x = .right } },
        })({
            for (self.toasts.items) |toast| {
                clay.UI()(.{
                    .layout = .{ .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 } },
                    .background_color = t.overlay,
                    .border = .{ .width = .all(1), .color = t.border },
                    .corner_radius = .all(4),
                })({
                    clay.text(toast.text, .{ .font_size = 16, .color = t.text, .wrap_mode = .none });
                });
            }
        });
    }

    pub const Direction = enum { left, right, up, down };

    fn collectLeaves(pane: *pane_mod.Pane, buf: []*pane_mod.Pane, n: *usize) void {
        switch (pane.data) {
            .leaf => {
                if (n.* < buf.len) {
                    buf[n.*] = pane;
                    n.* += 1;
                }
            },
            .split => |s| {
                collectLeaves(s.children[0], buf, n);
                collectLeaves(s.children[1], buf, n);
            },
        }
    }

    fn paneCenter(pane: *pane_mod.Pane) ?struct { x: f32, y: f32 } {
        const data = clay.getElementData(clay.ElementId.IDI("Pane", @truncate(@intFromPtr(pane))));
        if (!data.found) return null;
        const bb = data.bounding_box;
        return .{ .x = bb.x + bb.width / 2, .y = bb.y + bb.height / 2 };
    }

    /// Nächstes Leaf-Pane in Richtung `dir` (nach den Layout-Bounds des letzten Frames) fokussieren.
    pub fn focusPane(self: *Self, dir: Direction) void {
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        const from = paneCenter(self.active_pane) orelse return;
        var best: ?*pane_mod.Pane = null;
        var best_dist: f32 = std.math.floatMax(f32);
        for (buf[0..n]) |p| {
            if (p == self.active_pane) continue;
            const c = paneCenter(p) orelse continue;
            const dx = c.x - from.x;
            const dy = c.y - from.y;
            const ok = switch (dir) {
                .left => dx < -1 and @abs(dy) <= @abs(dx) * 2,
                .right => dx > 1 and @abs(dy) <= @abs(dx) * 2,
                .up => dy < -1 and @abs(dx) <= @abs(dy) * 2,
                .down => dy > 1 and @abs(dx) <= @abs(dy) * 2,
            };
            if (!ok) continue;
            const d = dx * dx + dy * dy;
            if (d < best_dist) {
                best_dist = d;
                best = p;
            }
        }
        if (best) |p| {
            self.active_pane = p;
            self.explorer_focused = false;
            self.sidebar_focus = .none;
        }
    }

    /// Ctrl+J: Terminal-Tab im aktiven Pane aktivieren (anlegen, wenn keiner da ist);
    /// vom Terminal aus zurück zum vorherigen Tab.
    fn toggleTerminal(self: *Self) void {
        const tb = self.getActiveTabBar();
        if (self.isTerminalActive()) {
            if (self.terminal_return_index) |i| {
                if (i < tb.tabs.items.len and tb.tabs.items[i].kind != .terminal) tb.setActive(i);
            }
            return;
        }
        self.terminal_return_index = tb.active_index;
        for (tb.tabs.items, 0..) |tab, i| {
            if (tab.kind == .terminal) {
                tb.setActive(i);
                return;
            }
        }
        tb.openTerminal();
    }

    /// Text der Statusleiste für den aktiven Editor (Zeile/Spalte, Auswahl, EOL, Encoding, Sprache, Einrückung).
    pub fn statusText(self: *Self, arena: std.mem.Allocator) []const u8 {
        const tb = self.getActiveTabBar();
        const tab = tb.getActiveTab() orelse return "";
        if (tab.kind != .text) return "";
        const ed = self.getActiveEditor();
        const edit_ops = @import("../editor/edit_ops.zig");
        var sel_buf: [48]u8 = undefined;
        var sel_text: []const u8 = "";
        if (ed.selectionRange()) |r| {
            if (r.begin.row == r.end.row) {
                sel_text = std.fmt.bufPrint(&sel_buf, "  ({d} selected)", .{r.end.col - r.begin.col}) catch "";
            } else {
                sel_text = std.fmt.bufPrint(&sel_buf, "  ({d} lines selected)", .{r.end.row - r.begin.row + 1}) catch "";
            }
        }
        const eol: []const u8 = if (ed.buffer.file_eol_mode == .crlf) "CRLF" else "LF";
        return std.fmt.allocPrint(arena, "Ln {d}, Col {d}{s}    {s}    UTF-8    {s}    Spaces: 4", .{
            ed.cursor.row + 1, ed.cursor.col + 1, sel_text, eol, edit_ops.languageNameForPath(tab.path),
        }) catch "";
    }

    /// Datei auf der Platte geändert (Watcher): ungeänderte Buffer still neu laden, geänderte fragen.
    pub fn handleExternalChange(self: *Self, event_path: []const u8) void {
        // Offenes PDF (z. B. erneuter Marp-Export): im Main-Loop neu öffnen
        if (self.keyForPath(*anyopaque, &self.open_pdfs, event_path)) |pdf_key| {
            self.requestPdfReload(pdf_key);
            return;
        }
        // Der Watcher meldet den Pfad, unter dem er das Verzeichnis registriert hat; der
        // Buffer ist unter dem Pfad geschlüsselt, mit dem die Datei geöffnet wurde. Bei
        // Symlink-Ordnern (Link im Projekt, Ziel woanders) sind das zwei Schreibweisen
        // derselben Datei, deshalb notfalls über realpath vergleichen.
        const path = self.bufferKeyForPath(event_path) orelse return;
        const buf = self.open_buffers.get(path) orelse return;
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024 * 1024) catch return;
        defer self.allocator.free(content);
        const current = buf.store_to_string_cached(buf.root, buf.file_eol_mode);
        if (std.mem.eql(u8, content, current)) return; // eigener Save oder gleicher Inhalt
        if (!self.anyTabModified(path)) {
            _ = self.reloadFileFromDisk(path, content);
            return;
        }
        if (self.active_dialog != null or self.external_change_path != null) return;
        const msg = std.fmt.allocPrint(self.allocator, "'{s}' changed on disk. Reload and lose your edits?", .{std.fs.path.basename(path)}) catch return;
        self.external_change_path = self.allocator.dupe(u8, path) catch {
            self.allocator.free(msg);
            return;
        };
        self.active_dialog = .{
            .dialog = .{
                .title = "File Changed",
                .message = msg,
                .actions = &.{
                    .{ .label = "Reload", .result = .yes },
                    .{ .label = "Keep Mine", .result = .cancel },
                },
            },
            .callback = handleExternalChangeDialog,
            .message_needs_free = true,
        };
    }

    /// Schlüssel in `open_buffers` für einen Pfad: direkt, sonst der Buffer mit demselben
    /// realpath (Symlink-Ordner). null, wenn die Datei nicht offen ist.
    /// PDF neu laden lassen (Main-Loop, `takeDuePdfReload`). `key` ist der Schlüssel in `open_pdfs`.
    pub fn requestPdfReload(self: *Self, key: []const u8) void {
        for (self.pending_pdf_reloads.items) |p| if (std.mem.eql(u8, p, key)) return;
        const owned = self.allocator.dupe(u8, key) catch return;
        self.pending_pdf_reloads.append(self.allocator, owned) catch self.allocator.free(owned);
    }

    /// Ruhezeit vor dem Neuladen. mupdf (System-Bibliothek 1.27.2) stürzt beim Reparieren
    /// mancher halb geschriebener PDFs ab (`mutool draw` segfaultet auf derselben Datei), und der
    /// Watcher meldet von einer Schreibfolge nur das erste Ereignis je 100 ms.
    pub const pdf_reload_quiet_ns: i128 = 150 * std.time.ns_per_ms;

    /// Nächster fälliger PDF-Reload: die Datei wurde seit `pdf_reload_quiet_ns` nicht mehr
    /// geändert (mtime). Eigentum geht an den Aufrufer; nicht fällige bleiben in der Liste.
    pub fn takeDuePdfReload(self: *Self) ?[]u8 {
        const now = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < self.pending_pdf_reloads.items.len) : (i += 1) {
            const key = self.pending_pdf_reloads.items[i];
            const st = std.fs.cwd().statFile(key) catch {
                // Gerade ersetzt oder gelöscht: beim nächsten Frame erneut schauen, gelöscht
                // bleibt es stehen, bis der Tab geschlossen wird
                if (std.fs.cwd().access(key, .{})) |_| {} else |_| {
                    return self.pending_pdf_reloads.orderedRemove(i);
                }
                continue;
            };
            if (now - st.mtime < pdf_reload_quiet_ns) continue;
            return self.pending_pdf_reloads.orderedRemove(i);
        }
        return null;
    }

    fn bufferKeyForPath(self: *Self, path: []const u8) ?[]const u8 {
        return self.keyForPath(*@import("flow_core").Buffer, &self.open_buffers, path);
    }

    /// Schlüssel in `map` für `path`: direkt oder über realpath (Symlink-Ordner, siehe
    /// handleExternalChange).
    fn keyForPath(self: *Self, comptime V: type, map: *std.StringHashMap(V), path: []const u8) ?[]const u8 {
        if (map.getKey(path)) |k| return k;
        const real = std.fs.cwd().realpathAlloc(self.allocator, path) catch return null;
        defer self.allocator.free(real);
        var it = map.keyIterator();
        while (it.next()) |key| {
            if (!std.fs.path.isAbsolute(key.*)) continue; // "scratchpad", "error"
            const key_real = std.fs.cwd().realpathAlloc(self.allocator, key.*) catch continue;
            defer self.allocator.free(key_real);
            if (std.mem.eql(u8, key_real, real)) return key.*;
        }
        return null;
    }

    fn showMoveDialog(self: *Self, mv: file_explorer_mod.PendingMove) void {
        const msg = std.fmt.allocPrint(self.allocator, "Move '{s}' into '{s}'?", .{
            std.fs.path.basename(mv.src), std.fs.path.basename(mv.dst_dir),
        }) catch {
            mv.deinit(self.allocator);
            return;
        };
        self.pending_move = mv;
        self.active_dialog = .{
            .dialog = .{
                .title = "Move",
                .message = msg,
                .actions = &.{
                    .{ .label = "Move", .result = .yes },
                    .{ .label = "Cancel", .result = .cancel },
                },
            },
            .callback = handleMoveDialog,
            .message_needs_free = true,
        };
    }

    fn handleMoveDialog(ui: *UI, res: dialog_mod.DialogResult, _: usize, _: ?*anyopaque) void {
        const mv = ui.pending_move orelse return;
        defer {
            mv.deinit(ui.allocator);
            ui.pending_move = null;
        }
        if (res == .yes) ui.file_explorer.performMove(mv.src, mv.dst_dir);
    }

    fn handleExternalChangeDialog(ui: *UI, res: dialog_mod.DialogResult, _: usize, _: ?*anyopaque) void {
        const path = ui.external_change_path orelse return;
        defer {
            ui.allocator.free(path);
            ui.external_change_path = null;
        }
        if (res != .yes) return;
        const content = std.fs.cwd().readFileAlloc(ui.allocator, path, 64 * 1024 * 1024) catch return;
        defer ui.allocator.free(content);
        _ = ui.reloadFileFromDisk(path, content);
    }

    fn anyTabModified(self: *Self, path: []const u8) bool {
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| {
            for (p.data.leaf.tab_bar.tabs.items) |tab| {
                if (std.mem.eql(u8, tab.path, path) and tab.modified) return true;
            }
        }
        return false;
    }

    /// Text-Tab mit .md-Pfad, dessen Inhalt `marp: true` im Front-Matter trägt.
    /// Quelle ist der Buffer (aktiver Tab: Editor, sonst Tab-Cache), damit ungespeichertes
    /// Front-Matter zählt; ohne Buffer entscheidet der Dateikopf auf der Platte.
    fn tabIsMarpDeck(self: *UI, pane: *pane_mod.Pane, index: usize) bool {
        _ = self;
        const leaf = &pane.data.leaf;
        const tabs = leaf.tab_bar.tabs.items;
        if (index >= tabs.len or tabs[index].kind != .text or !std.mem.endsWith(u8, tabs[index].path, ".md")) return false;
        const buf: ?*@import("flow_core").Buffer = if (leaf.tab_bar.active_index == index) leaf.code_editor.buffer else tabs[index].buffer;
        if (buf) |b| return marp.isMarpDeck(b.store_to_string_cached(b.root, b.file_eol_mode));
        return marp.isMarpDeckFile(tabs[index].path);
    }

    /// Markdown Preview nur für Text-Tabs mit .md-Pfad, Export to PDF nur für
    /// Marp-Decks; die Vorschau selbst und Terminal/Chat/Bild bekommen beides nicht.
    fn tabMenuHidden(menu: TabMenu) ctx_menu.Hidden {
        var hidden = ctx_menu.none;
        const tabs = menu.pane.data.leaf.tab_bar.tabs.items;
        const is_md = menu.index < tabs.len and tabs[menu.index].kind == .text and std.mem.endsWith(u8, tabs[menu.index].path, ".md");
        if (!is_md) hidden.insert(.md_preview);
        if (!is_md or !menu.marp_deck) hidden.insert(.md_export_pdf);
        const has_file = menu.index < tabs.len and switch (tabs[menu.index].kind) {
            .text, .image, .pdf, .binary => true,
            else => false,
        };
        if (!has_file) hidden.insert(.file_history);
        return hidden;
    }

    /// Kontextmenü eines Tabs (`shortcuts.tab_menu_items`, IDs `tab_menu_<command>`), schwebend an der Klickposition.
    fn renderTabMenu(self: *Self, menu: TabMenu, t: Theme) void {
        _ = self;
        _ = ctx_menu.render("tab_menu", &shortcuts.tab_menu_items, menu.x, menu.y, tabMenuHidden(menu), ctx_menu.Colors.fromTheme(t));
    }

    pub fn recordFrameTime(self: *Self, ms: f32) void {
        self.last_frame_ms = ms;
        if (ms > self.max_frame_ms) self.max_frame_ms = ms;
    }

    /// Maximale Frame-Dauer seit dem letzten Aufruf (RPC ui_state setzt zurück).
    pub fn takeMaxFrameMs(self: *Self) f32 {
        const m = self.max_frame_ms;
        self.max_frame_ms = 0;
        return m;
    }

    /// Sidebar-Breite und Hidden-Flag in ~/.config/zid/state schreiben.
    pub fn saveUserState(self: *Self) void {
        const path = user_state.defaultPath(self.allocator) catch return;
        defer self.allocator.free(path);
        user_state.saveTo(self.allocator, path, .{
            .sidebar_width = self.file_explorer.width,
            .show_hidden = self.file_explorer.show_hidden,
            .light_theme = self.isLightTheme(),
            .font_size = self.getActiveEditor().font_size,
            .autosave = self.autosave,
            .minimap = self.getActiveEditor().show_minimap,
            .whitespace = self.getActiveEditor().show_whitespace,
            .indent_guides = self.getActiveEditor().show_indent_guides,
            .word_wrap = self.getActiveEditor().word_wrap,
            .timeline_expanded = self.timeline_view.timeline.expanded,
        }) catch |err| log.warn("state save '{s}' failed: {}", .{ path, err });
    }

    /// Gemerkten Zustand anwenden (beim Start).
    pub fn loadUserState(self: *Self) void {
        const path = user_state.defaultPath(self.allocator) catch return;
        defer self.allocator.free(path);
        const st = user_state.loadFrom(self.allocator, path);
        self.file_explorer.width = st.sidebar_width;
        self.file_explorer.show_hidden = st.show_hidden;
        self.timeline_view.timeline.setExpanded(st.timeline_expanded);
        self.autosave = st.autosave;
        self.theme = if (st.light_theme) Theme.light() else Theme.dark();
        self.applyThemeToEditors();
        var buf: [32]*pane_mod.Pane = undefined;
        var n: usize = 0;
        collectLeaves(self.root_pane, &buf, &n);
        for (buf[0..n]) |p| {
            const e = p.data.leaf.code_editor;
            e.setFontSize(st.font_size);
            e.show_minimap = st.minimap;
            e.show_whitespace = st.whitespace;
            e.show_indent_guides = st.indent_guides;
            e.word_wrap = st.word_wrap;
        }
    }

    /// Text in die System-Zwischenablage (Fenster) legen; headless nur merken (RPC ui_state).
    pub fn setClipboard(self: *Self, text: []const u8) void {
        if (self.window) |win| win.setClipboardText(text);
        if (self.last_clipboard_text) |old| self.allocator.free(old);
        self.last_clipboard_text = self.allocator.dupe(u8, text) catch null;
    }

    /// Inhalt der Zwischenablage als Kopie (Fenster; headless der zuletzt gesetzte Text,
    /// damit Ausschneiden/Einfügen in den Feldern per RPC prüfbar ist). Aufrufer gibt frei.
    pub fn getClipboard(self: *Self, allocator: std.mem.Allocator) ?[]u8 {
        if (self.window) |win| return win.getClipboardText(allocator);
        const t = self.last_clipboard_text orelse return null;
        return allocator.dupe(u8, t) catch null;
    }

    /// Gehaltene Modifier für die Editierfelder (line_edit).
    pub fn editMods(self: *const Self) line_edit_mod.Mods {
        return .{ .ctrl = self.is_ctrl_down, .shift = self.is_shift_down };
    }

    /// Zwischenablage-Schnittstelle der Editierfelder (Ctrl+C/X/V in Umbenennen, Filter,
    /// Picker, Ordner-Dialog, Commit-Nachricht).
    pub fn editClipboard(self: *Self) line_edit_mod.Clipboard {
        return .{ .ctx = @ptrCast(self), .allocator = self.allocator, .copyFn = clipCopy, .pasteFn = clipPaste };
    }

    fn clipCopy(ctx: *anyopaque, text: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.setClipboard(text);
    }

    fn clipPaste(ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.getClipboard(allocator);
    }

    /// Aktiven Tab schließen wie über das × in der Tab-Leiste: geänderte Tabs
    /// fragen nach, alle anderen werden nach dem Layout geschlossen.
    fn requestCloseActiveTab(self: *Self) void {
        const target = self.tabTarget() orelse return;
        self.requestCloseTab(target.pane, target.index);
    }

    /// Tab schließen wie über das ×: geänderte Tabs fragen nach.
    pub fn requestCloseTab(self: *Self, pane: *pane_mod.Pane, index: usize) void {
        if (pane.data != .leaf) return;
        const tb = &pane.data.leaf.tab_bar;
        if (index >= tb.tabs.items.len) return;
        if (tb.tabs.items[index].modified) {
            self.showSaveConfirmationDialog(pane, index);
        } else {
            self.pending_tab_closes.append(self.allocator, .{ .pane = pane, .index = index }) catch {};
        }
    }

    /// Markdown-Vorschau von `path` anfordern: main.zig öffnet `preview://<path>` im nächsten
    /// Frame und gibt den String frei.
    fn requestMarkdownPreview(self: *Self, path: []const u8) void {
        if (path.len == 0) return;
        const preview_path = std.fmt.allocPrint(self.allocator, "preview://{s}", .{path}) catch |err| {
            log.err("markdown preview for '{s}' failed: {}", .{ path, err });
            return;
        };
        if (self.pending_tab_switch) |old| self.allocator.free(old);
        self.pending_tab_switch = preview_path;
    }

    /// Nach dem Speichern von `source_path` (Ctrl+S oder Autosave) die offene Vorschau derselben
    /// Datei neu aufbauen, damit ein Split „Editor links, Vorschau rechts“ ohne Neuöffnen
    /// nachzieht. Scroll-Position, Folie und Schriftgröße bleiben erhalten.
    pub fn reloadMarkdownPreview(self: *Self, source_path: []const u8) void {
        var key_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "preview://{s}", .{source_path}) catch return;
        const entry = self.open_markdown_views.getEntry(key) orelse return;
        const old = entry.value_ptr.*;
        const content = std.fs.cwd().readFileAlloc(self.allocator, source_path, 1024 * 1024) catch |err| {
            log.warn("preview reload: {s}: {s}", .{ source_path, @errorName(err) });
            return;
        };
        defer self.allocator.free(content);
        const new_v = self.allocator.create(markdown_view_mod.MarkdownView) catch return;
        new_v.* = markdown_view_mod.MarkdownView.init(self.allocator, content, source_path);
        new_v.scroll_offset_y = old.scroll_offset_y;
        if (new_v.slideCount() > 0) new_v.current_slide = @min(old.current_slide, new_v.slideCount() - 1);
        new_v.font_size = old.font_size;
        old.deinit();
        self.allocator.destroy(old);
        entry.value_ptr.* = new_v;
    }

    /// Die Vorschau rendert vier Punkt kleiner als der Editor (Standard 24 → 20).
    /// Zoom-Befehle wirken auf beides, sonst blieb die Vorschau auf ihrer Startgröße.
    pub fn previewFontSize(self: *Self) u16 {
        return @max(10, @min(48, self.getActiveEditor().font_size -| 4));
    }

    /// Die Markdown-Vorschau des aktiven Tabs, sonst null.
    pub fn activeMarkdownView(self: *Self) ?*markdown_view_mod.MarkdownView {
        const tb = self.getActiveTabBar();
        const tab = tb.getActiveTab() orelse return null;
        if (tab.kind != .markdown_preview) return null;
        return self.open_markdown_views.get(tab.path);
    }

    /// Die Markdown-Vorschau des aktiven Tabs, falls sie ein Marp-Deck zeigt.
    pub fn activeSlideDeckView(self: *Self) ?*markdown_view_mod.MarkdownView {
        const v = self.activeMarkdownView() orelse return null;
        if (v.slideCount() == 0) return null;
        return v;
    }

    /// Pfad des aktiven PDF-Tabs, sonst null.
    pub fn activePdfTabPath(self: *Self) ?[]const u8 {
        const tb = self.getActiveTabBar();
        const tab = tb.getActiveTab() orelse return null;
        if (tab.kind != .pdf) return null;
        if (!self.open_pdfs.contains(tab.path)) return null;
        return tab.path;
    }

    /// Mausrad im PDF-Tab blättert seitenweise.
    pub fn handlePdfScroll(self: *Self, delta_y: f32) bool {
        const path = self.activePdfTabPath() orelse return false;
        const delta = pdf_nav.deltaForScroll(delta_y) orelse return false;
        self.pending_pdf_page_change = .{ .path = path, .delta = delta };
        return true;
    }

    /// Exportiert `path` als Marp-Deck nach PDF und öffnet das Ergebnis als Tab.
    /// Nicht-Decks (kein `marp: true` im Front-Matter) melden das als Dialog.
    fn exportMarpPdf(self: *Self, path: []const u8) void {
        if (path.len == 0) return;
        const stripped = if (std.mem.startsWith(u8, path, "preview://")) path["preview://".len..] else path;

        const out_path = marp_pdf.defaultOutputPath(self.allocator, stripped) catch |err| {
            self.reportError("PDF-Export fehlgeschlagen: {t}", .{err});
            return;
        };
        defer self.allocator.free(out_path);

        marp_pdf.exportFile(self.allocator, stripped, out_path) catch |err| {
            if (err == error.NotAMarpDeck) {
                self.reportError("Kein Marp-Deck: im Front-Matter fehlt 'marp: true'", .{});
            } else {
                self.reportError("PDF-Export fehlgeschlagen: {t}", .{err});
            }
            return;
        };
        log.info("Marp-PDF geschrieben: {s}", .{out_path});
        // Schon offen: neu laden, sonst zeigt der Tab den alten Export
        if (self.keyForPath(*anyopaque, &self.open_pdfs, out_path)) |key| self.requestPdfReload(key);

        // Ergebnis im PDF-Tab zeigen — die Vorschau ist damit das, was rauskommt.
        const owned = self.allocator.dupe(u8, out_path) catch return;
        if (self.pending_tab_switch) |old| self.allocator.free(old);
        self.pending_tab_switch = owned;
    }

    /// Ziel eines Tab-Kommandos: Kontextmenü-Tab oder aktiver Tab des aktiven Panes.
    fn tabTarget(self: *Self) ?TabTarget {
        if (self.tab_cmd_target) |t| return t;
        const tb = self.getActiveTabBar();
        const idx = tb.active_index orelse return null;
        if (idx >= tb.tabs.items.len) return null;
        return .{ .pane = self.active_pane, .index = idx };
    }

    /// Mehrere Tabs eines Panes schließen: `keep` = Index, der bleibt; `only_right` = nur rechts davon;
    /// `only_saved` = nur ungeänderte. Geänderte und angepinnte Tabs bleiben immer.
    fn closeTabsWhere(self: *Self, pane: *pane_mod.Pane, keep: ?usize, only_right: bool, only_saved: bool) void {
        if (pane.data != .leaf) return;
        const tb = &pane.data.leaf.tab_bar;
        // Absteigend einreihen: pending_tab_closes ist ein Stack, höchste Indizes zuerst
        var i: usize = 0;
        while (i < tb.tabs.items.len) : (i += 1) {
            const tab = tb.tabs.items[i];
            if (keep != null and i == keep.?) continue;
            if (only_right and (keep == null or i < keep.?)) continue;
            if (tab.pinned or tab.modified) continue;
            _ = only_saved;
            self.pending_tab_closes.append(self.allocator, .{ .pane = pane, .index = i }) catch {};
        }
    }

    /// Ctrl+Shift+T: zuletzt geschlossene Datei wieder öffnen (übersprungen, wenn sie nicht mehr existiert).
    fn reopenClosedTab(self: *Self) void {
        while (self.closed_tabs.pop()) |path| {
            defer self.allocator.free(path);
            std.fs.cwd().access(path, .{}) catch continue;
            self.getActiveTabBar().openFile(path) catch continue;
            return;
        }
    }

    fn gotoTab(self: *Self, n: usize) void {
        const tb = self.getActiveTabBar();
        if (n < tb.tabs.items.len) tb.setActive(n);
    }

    /// Nächsten (+1) oder vorherigen (-1) Tab im aktiven Pane aktivieren, zyklisch.
    fn cycleTab(self: *Self, direction: i32) void {
        const tb = self.getActiveTabBar();
        const n = tb.tabs.items.len;
        if (n < 2) return;
        const cur: i32 = @intCast(tb.active_index orelse 0);
        const next: usize = @intCast(@mod(cur + direction, @as(i32, @intCast(n))));
        tb.setActive(next);
    }

    /// "Open Folder…"-Dialog im aktuellen Projektordner öffnen (Menü, Ctrl+O).
    pub fn openFolderPicker(self: *Self) void {
        self.open_menu = null;
        self.folder_picker.open(self.current_directory orelse "/");
    }

    /// Vom Dialog bestätigten Projektordner abholen (owned, Aufrufer gibt frei).
    pub fn takePendingOpenFolder(self: *Self) ?[]u8 {
        const p = self.pending_open_folder orelse return null;
        self.pending_open_folder = null;
        return p;
    }

    /// Aktionen, die während des Layouts angefordert wurden (Split, Tab-Schließen, leere
    /// Panes), vor dem nächsten Layout ausführen. Nach `endLayout` wäre es zu früh: die
    /// Render-Commands des Frames zeigen noch auf Tab-Namen (`closeTab`, `TabBarState.deinit`
    /// geben sie frei) und werden erst nach `renderExample` gezeichnet.
    fn applyDeferredLayoutActions(self: *Self) void {
        self.applyPendingDialogResult();
        // Handle global split requests
        if (self.pending_split) |dir| {
            self.splitActivePane(dir) catch |err| {
                log.err("Failed to split pane: {}", .{err});
            };
            self.pending_split = null;
        }

        // Process deferred tab closes
        while (self.pending_tab_closes.pop()) |req| {
            log.debug("pending_tab_closes: processing close for pane={*} index={d}", .{ req.pane, req.index });
            // Verify pane is still valid and has tabs
            switch (req.pane.data) {
                .leaf => |*leaf| {
                    log.debug("pending_tab_closes: leaf has {d} tabs, closing index={d}", .{ leaf.tab_bar.tabs.items.len, req.index });
                    if (req.index < leaf.tab_bar.tabs.items.len) {
                        const closing = leaf.tab_bar.tabs.items[req.index];
                        if (closing.kind == .text or closing.kind == .image or closing.kind == .pdf or closing.kind == .binary) {
                            if (self.allocator.dupe(u8, closing.path)) |dup| {
                                self.closed_tabs.append(self.allocator, dup) catch self.allocator.free(dup);
                                if (self.closed_tabs.items.len > 20) self.allocator.free(self.closed_tabs.orderedRemove(0));
                            } else |_| {}
                        }
                        // Pfad vor closeTab kopieren (gibt ihn frei); die Ansicht erst danach prüfen
                        const view_path: ?[]u8 = if (closing.kind == .git_diff or closing.kind == .git_commit) self.allocator.dupe(u8, closing.path) catch null else null;
                        const closing_kind = closing.kind;
                        defer if (view_path) |p| self.allocator.free(p);
                        leaf.tab_bar.closeTab(req.index);
                        if (view_path) |p| switch (closing_kind) {
                            .git_diff => self.dropUnusedGitDiff(p),
                            .git_commit => self.dropUnusedGitCommit(p),
                            else => {},
                        };
                        // Don't call cancelWait here - causes recursive render with destroyed pane!
                    } else {
                        log.warn("pending_tab_closes: index {d} out of range (len={d}), skipping", .{ req.index, leaf.tab_bar.tabs.items.len });
                    }
                },
                else => {
                    log.warn("pending_tab_closes: pane is not a leaf, skipping", .{});
                },
            }
        }

        // Cleanup empty panes (close split if a pane becomes empty)
        _ = self.cleanupEmptyPanes(null, self.root_pane);
    }

    /// Dialog-Ergebnis des vorigen Frames anwenden, bevor ein neues Layout beginnt.
    /// Erst jetzt sind die alten Render-Commands garantiert gezeichnet, der Callback darf
    /// Speicher freigeben, auf den sie zeigten.
    fn applyPendingDialogResult(self: *Self) void {
        const res = self.pending_dialog_result orelse return;
        self.pending_dialog_result = null;
        const ad = self.active_dialog orelse return;
        ad.callback(self, res, ad.context_usize, ad.context_ptr);
        if (ad.message_needs_free) self.allocator.free(ad.dialog.message);
        self.active_dialog = null;
    }

    /// Layout beginnen
    pub fn beginLayout(self: *Self) void {
        _ = self.frame_arena.reset(.retain_capacity);
        clay.beginLayout();
        if (self.mouse_pressed_this_frame) {
            const hovered = clay.getPointerOverIds();
            log.debug("beginLayout click: mouse=({d:.0},{d:.0}) hovered_count={d}", .{ self.mouse_x, self.mouse_y, hovered.len });
        }
    }

    /// Layout beenden und Render Commands holen
    pub fn endLayout(self: *Self) []clay.RenderCommand {
        const commands = clay.endLayout();
        self.mouse_pressed_this_frame = false;
        return commands;
    }

    /// Window Resize behandeln
    pub fn resize(self: *Self, width: u32, height: u32) void {
        clay.setLayoutDimensions(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) });
        // Editor-Höhe aktualisieren für korrekte visibleLineCount-Berechnung
        self.getActiveEditor().height = @floatFromInt(height);
    }

    /// Maus-Position und Button-Status an Clay weiterleiten
    pub fn setPointerState(self: *Self, x: f32, y: f32, is_down: bool) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.is_mouse_down = is_down;
        if (is_down) log.debug("setPointerState click: ({d:.0}, {d:.0})", .{ x, y });
        clay.setPointerState(.{ .x = x, .y = y }, is_down);
    }

    /// Scroll-Events an Clay weiterleiten. Clays eigene Scroll-Positionen benutzt zid nicht
    /// (jede Ansicht scrollt über `child_offset`), aber jedes Element mit `.clip` legt dort
    /// einen Eintrag an, und nur dieser Aufruf räumt die Liste auf (sie fasst 10 Einträge).
    /// Das Aufräumen selbst ist in `libs/clay-zig/vendor/clay.h` korrigiert („zid:“).
    pub fn updateScroll(self: *Self, delta_x: f32, delta_y: f32, delta_time_ms: f32) void {
        _ = self;
        // Clay erwartet Scroll-Delta als Vector2 und delta_time in Sekunden
        clay.updateScrollContainers(false, .{ .x = delta_x, .y = delta_y }, delta_time_ms / 1000.0);
    }

    pub fn getOrCreateTexture(self: *Self, path: []const u8) ?*anyopaque {
        if (self.open_images.get(path)) |tex| return tex;
        const ir = self.image_renderer orelse return null;
        const tex = ir.createTextureFromPath(self.allocator, path) catch return null;
        const tex_ptr = self.allocator.create(@import("../clay_renderer/image_renderer.zig").ImageTexture) catch return null;
        tex_ptr.* = tex;
        const path_copy = self.allocator.dupe(u8, path) catch path;
        self.open_images.put(path_copy, tex_ptr) catch {};
        wio.cancelWait();
        return tex_ptr;
    }

    /// UI Beispiel rendern
    fn lowerAscii(comptime text: []const u8) []const u8 {
        comptime {
            var out: [text.len]u8 = undefined;
            for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
            const frozen = out;
            return &frozen;
        }
    }

    /// Clay-ID des Menütitels, z.B. "menu_file" (stabil für Tests).
    fn menuTitleId(comptime menu: shortcuts.Menu) clay.ElementId {
        return clay.ElementId.ID(comptime "menu_" ++ lowerAscii(menu.title));
    }

    /// Clay-ID eines Menüeintrags, z.B. "menu_item_open_folder".
    fn menuItemId(cmd: shortcuts.Command) clay.ElementId {
        switch (cmd) {
            inline else => |c| return clay.ElementId.ID("menu_item_" ++ @tagName(c)),
        }
    }

    /// Clay-ID des Häkchens vor einem aktiven Umschalt-Eintrag (E2E: element_bounds)
    fn menuCheckId(cmd: shortcuts.Command) []const u8 {
        switch (cmd) {
            inline else => |c| return "menu_check_" ++ @tagName(c),
        }
    }

    /// Aktueller Zustand eines Umschalt-Befehls (Häkchen im Menü), null für alle anderen.
    fn toggleState(self: *Self, cmd: shortcuts.Command) ?bool {
        const ed = self.getActiveEditor();
        return switch (cmd) {
            .toggle_autosave => self.autosave,
            .toggle_explorer => self.show_file_explorer,
            .toggle_terminal => self.isTerminalActive(),
            .toggle_theme => self.isLightTheme(),
            .toggle_hidden_files => self.file_explorer.show_hidden,
            .toggle_minimap => ed.show_minimap,
            .toggle_whitespace => ed.show_whitespace,
            .toggle_indent_guides => ed.show_indent_guides,
            .toggle_word_wrap => ed.word_wrap,
            else => null,
        };
    }

    /// Menüleiste im Header aus shortcuts.menus: Titel nebeneinander, das offene
    /// Menü als Dropdown mit Label links und Kürzel rechts. Bei offenem Menü
    /// wechselt Hover über einen anderen Titel das Menü (wie in Zed/VS Code).
    fn renderMenuBar(self: *Self, t: Theme) void {
        inline for (shortcuts.menus, 0..) |menu, i| {
            const title_id = menuTitleId(menu);
            const hover = clay.pointerOver(title_id);
            if (hover and self.open_menu != null and self.open_menu.? != i) self.open_menu = i;
            const active = self.open_menu != null and self.open_menu.? == i;
            clay.UI()(.{
                .id = title_id,
                .layout = .{
                    .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
                    .child_alignment = .{ .y = .center },
                },
                .background_color = if (active) t.primary else if (hover) t.overlay else .{ 0, 0, 0, 0 },
                .corner_radius = .all(4),
            })({
                clay.text(menu.title, .{ .font_size = 20, .wrap_mode = .none, .color = if (active) t.text_on_primary else t.text });
            });
            if (active) self.renderMenuDropdown(menu, title_id, t);
        }
    }

    fn renderMenuDropdown(self: *Self, menu: shortcuts.Menu, title_id: clay.ElementId, t: Theme) void {
        clay.UI()(.{
            .id = clay.ElementId.ID("menu_dropdown"),
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = title_id.id,
                .attach_points = .{ .element = .left_top, .parent = .left_bottom },
                .offset = .{ .x = 0, .y = 4 },
                .z_index = 1500,
            },
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .top_to_bottom,
                .padding = .all(4),
                .child_gap = 2,
            },
            .background_color = t.overlay,
            .border = .{ .width = .all(1), .color = t.border },
            .corner_radius = .all(4),
        })({
            for (menu.items, 0..) |cmd, idx| {
                const item_id = menuItemId(cmd);
                const item_hover = clay.pointerOver(item_id) or (self.menu_highlight != null and self.menu_highlight.? == idx);
                const fg = if (item_hover) t.text_on_primary else t.text;
                clay.UI()(.{
                    .id = item_id,
                    .layout = .{
                        // Der Rahmen ist `.fit`, die Einträge `.grow`: Clay misst den
                        // breitesten Eintrag und zieht alle anderen darauf. Damit
                        // stehen die Kürzel rechtsbündig, ohne selbst zu messen.
                        .sizing = .{ .w = .grow, .h = .fit },
                        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
                        .child_gap = 32,
                        .direction = .left_to_right,
                        .child_alignment = .{ .y = .center },
                    },
                    .background_color = if (item_hover) t.primary else .{ 0, 0, 0, 0 },
                    .corner_radius = .all(3),
                })({
                    // Feste Spalte für das Häkchen, damit alle Labels bündig stehen
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(18), .h = .fixed(18) }, .child_alignment = .{ .x = .center, .y = .center } } })({
                        if (self.toggleState(cmd) == true) {
                            const svg = @import("components/svg.zig");
                            svg.Svg(self.frame_arena.allocator(), menuCheckId(cmd), svg.Lucide.check, 18, fg);
                        }
                    });
                    clay.text(shortcuts.label(cmd), .{ .font_size = 20, .wrap_mode = .none, .color = fg });
                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                    const sc = shortcuts.shortcutText(cmd);
                    if (sc.len > 0) clay.text(sc, .{ .font_size = 16, .wrap_mode = .none, .color = if (item_hover) t.text_on_primary else t.muted });
                });
            }
        });
    }

    pub fn renderExample(self: *Self, image_data: ?*const anyopaque) []clay.RenderCommand {
        self.applyDeferredLayoutActions();
        self.beginLayout();
        tooltip.beginFrame(self.ui_time_ms);

        const t = self.theme;

        // Root Container
        clay.UI()(.{
            .id = clay.ElementId.ID("Root"),
            .layout = .{
                .sizing = .grow,
                .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
                .child_gap = 0,
                .direction = .top_to_bottom,
            },
            .background_color = t.bg,
        })({
            // Header mit Logo und Titel
            clay.UI()(.{
                .id = clay.ElementId.ID("Header"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(56) },
                    .child_gap = 16,
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 16, .right = 16 },
                },
                .background_color = t.surface,
                .border = .{ .width = .{ .bottom = 1 }, .color = t.border },
            })({
                // Logo Image (falls vorhanden)
                if (image_data) |ptr| {
                    clay.UI()(.{
                        .id = clay.ElementId.ID("Logo"),
                        .layout = .{
                            .sizing = .{ .w = .fixed(32), .h = .fixed(32) },
                        },
                        .image = .{ .image_data = ptr },
                        .background_color = .{ 0, 0, 0, 0 },
                    })({});
                }

                clay.text("ZID", .{ .font_size = 24, .color = t.text });
                self.renderMenuBar(t);
            });

            // Status Bar (Git Branch + Info)
            clay.UI()(.{
                .id = clay.ElementId.ID("StatusBar"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(28) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .x = .left, .y = .center },
                    .padding = .{ .left = 12, .right = 12 },
                    .child_gap = 16,
                },
                .background_color = t.overlay,
                .border = .{ .width = .{ .top = 1 }, .color = t.border },
            })({
                const svg = @import("components/svg.zig");
                const arena = self.frame_arena.allocator();
                const branch_text = if (self.git_branch.len > 0) self.git_branch else "—";
                const branch_id = clay.ElementId.ID("status_branch");
                clay.UI()(.{ .id = branch_id, .layout = .{ .child_gap = 4, .child_alignment = .{ .y = .center } } })({
                    svg.Svg(arena, "status_git_icon", svg.Lucide.git_branch, 18, t.success);
                    clay.text(branch_text, .{ .font_size = 18, .color = t.subtext });
                    tooltip.attach(t, branch_id, if (self.git_branch.len > 0) "Current Git Branch" else "No Git Repository");
                });
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                const status = self.statusText(arena);
                if (status.len > 0) clay.text(status, .{ .font_size = 16, .color = t.subtext, .wrap_mode = .none });
                // Autosave-Zustand, jederzeit sichtbar (File → Toggle Autosave)
                clay.UI()(.{
                    .id = clay.ElementId.ID("status_autosave"),
                    .layout = .{ .child_gap = 4, .child_alignment = .{ .y = .center } },
                })({
                    svg.Svg(arena, "status_autosave_icon", svg.Lucide.save, 16, if (self.autosave) t.success else t.muted);
                    clay.text(if (self.autosave) "Autosave: on" else "Autosave: off", .{ .font_size = 16, .color = if (self.autosave) t.subtext else t.muted, .wrap_mode = .none });
                    tooltip.attach(t, clay.ElementId.ID("status_autosave"), "Toggle Autosave (File menu)");
                });
            });

            // Main Content Area (Sidebar + Editor)
            clay.UI()(.{
                .id = clay.ElementId.ID("MainContent"),
                .layout = .{
                    .sizing = .grow,
                    .direction = .left_to_right,
                    .child_gap = 0,
                },
                .background_color = t.bg,
            })({
                // Phase 15: Splitter Logic
                const splitter_id = clay.ElementId.ID("ExplorerSplitter");
                if (self.show_file_explorer) {
                    if (self.file_explorer.is_resizing) {
                        if (!self.is_mouse_down) {
                            self.file_explorer.is_resizing = false;
                            log.debug("splitter: end width={d:.0}", .{self.file_explorer.width});
                            self.saveUserState();
                        } else {
                            const before = self.file_explorer.width;
                            self.file_explorer.width = @min(600, @max(100, self.mouse_x));
                            // Zittern (ZID_DEBUG=1): jede Änderung mit Vorher/Nachher und Maus-X,
                            // Rückwärtsschritt gegen die Zugrichtung markiert „<<“.
                            if (self.file_explorer.width != before) {
                                const dw = self.file_explorer.width - before;
                                log.debug("splitter: width {d:.0} -> {d:.0} (mouse_x={d:.0}, dw={d:.0}){s}", .{ before, self.file_explorer.width, self.mouse_x, dw, if (dw < 0) " <<" else "" });
                            }
                        }
                    } else if (clay.pointerOver(splitter_id) and self.mouse_pressed_this_frame) {
                        self.file_explorer.is_resizing = true;
                        log.debug("splitter: start width={d:.0} mouse_x={d:.0}", .{ self.file_explorer.width, self.mouse_x });
                    }
                }

                // File Explorer Sidebar, darunter der Timeline-Abschnitt wie in VS Code
                if (self.show_file_explorer) {
                    clay.UI()(.{
                        .id = clay.ElementId.ID("sidebar"),
                        .layout = .{ .sizing = .{ .w = .fixed(self.file_explorer.width), .h = .grow }, .direction = .top_to_bottom },
                    })({
                        switch (self.sidebar_mode) {
                            .explorer => {
                                file_explorer_mod.renderFileExplorer(
                                    self.frame_arena.allocator(),
                                    &self.file_explorer,
                                    t,
                                    // Klicks in der Timeline gehören nicht dem Baum
                                    self.mouse_pressed_this_frame and !self.timeline_view.contains(self.mouse_x, self.mouse_y),
                                    self.explorer_focused,
                                    .{ .ctrl = self.is_ctrl_down, .shift = self.is_shift_down },
                                    .{ .x = self.mouse_x, .y = self.mouse_y, .down = self.is_mouse_down },
                                );
                                self.timeline_view.render(self.frame_arena.allocator(), t, self.file_explorer.width, self.mouse_x, self.mouse_y);
                            },
                            .scm => {
                                self.scm_changes.render(self.frame_arena.allocator(), t, self.file_explorer.width, self.mouse_x, self.mouse_y, self.sidebar_focus == .commit_input);
                                self.scm_graph.render(self.frame_arena.allocator(), t, self.file_explorer.width, self.mouse_x, self.mouse_y);
                            },
                        }
                    });
                    // Deferred Toggle ausführen (nach Rendering, vor endLayout)
                    self.file_explorer.processPendingToggle();

                    // Splitter
                    clay.UI()(.{
                        .id = splitter_id,
                        .layout = .{
                            .sizing = .{ .w = .fixed(4), .h = .grow },
                        },
                        .background_color = if (self.file_explorer.is_resizing) t.primary else if (clay.pointerOver(splitter_id)) t.secondary else t.border,
                    })({});
                }

                // Recursive Pane Rendering
                self.renderPane(self.root_pane, t);
            });
        });

        // "Open Folder…"-Dialog (floating, z_index=2000), modal wie der Dialog unten
        self.folder_picker.render(self.frame_arena.allocator(), t);
        self.picker.render(self.frame_arena.allocator(), t);
        self.renderTabSwitcher(t);
        if (self.shortcuts_dialog_open) shortcuts_dialog.render(t, self.shortcuts_scroll_y);
        self.renderToasts(t);

        // Dialog INSIDE Clay layout (floating, z_index=2000 → overlays everything)
        // Must be here so Clay can register element bounds and mouse_pressed_this_frame is still true
        if (self.tab_menu) |menu| self.renderTabMenu(menu, t);
        if (self.active_dialog) |*ad| {
            const res = ad.dialog.render(t, self.mouse_pressed_this_frame, ad.focused) orelse ad.key_result;
            // Nicht hier verarbeiten: siehe pending_dialog_result / applyPendingDialogResult
            if (self.pending_dialog_result == null) self.pending_dialog_result = res;
            // Erst nach dem Übernehmen leeren: `res` kann auf ad.key_result verweisen (Zig-
            // Aliasing bei `orelse` auf ein Feld). Vorher geleert, kam unter Windows null an
            // und Escape/Enter/Buchstaben schlossen keinen Dialog.
            ad.key_result = null;
        }

        tooltip.endFrame();
        const commands = self.endLayout();
        // Nachlauf (Split, Tab-Schließen, leere Panes) läuft NICHT hier: die Commands zeigen
        // noch auf Tab-Namen und Panes, siehe applyDeferredLayoutActions.
        return commands;
    }

    fn cleanupEmptyPanes(self: *Self, parent: ?*pane_mod.Pane, pane: *pane_mod.Pane) bool {
        switch (pane.data) {
            .leaf => |*leaf| {
                if (leaf.tab_bar.tabs.items.len == 0) {
                    if (parent) |p| {
                        log.debug("cleanupEmptyPanes: found empty leaf, collapsing split. Parent: {*}, Leaf: {*}", .{ p, pane });
                        // Find other child
                        const split = &p.data.split;
                        const other_idx: usize = if (split.children[0] == pane) 1 else 0;
                        const other_child = split.children[other_idx];

                        // Keep other child's data
                        const other_data = other_child.data;
                        const other_allocator = other_child.allocator;

                        // Focus redirection: If either the closed pane or the parent was active,
                        // redirection focus to the parent (which now becomes the sibling).
                        if (self.active_pane == pane or self.active_pane == p or self.active_pane == other_child) {
                            self.active_pane = p;
                        }

                        // Destroy current empty pane and the other child's wrapper
                        pane.deinit();
                        p.data = other_data;
                        other_allocator.destroy(other_child);

                        return true;
                    }
                }
            },
            .split => |*split| {
                if (self.cleanupEmptyPanes(pane, split.children[0])) return true;
                if (self.cleanupEmptyPanes(pane, split.children[1])) return true;
            },
        }
        return false;
    }

    fn renderPane(self: *Self, pane: *pane_mod.Pane, t: Theme) void {
        const allocator = self.frame_arena.allocator();
        switch (pane.data) {
            .leaf => |*leaf| {
                const pane_id = clay.ElementId.IDI("Pane", @truncate(@intFromPtr(pane)));

                // Editor Area (Tabs + Editor)
                clay.UI()(.{
                    .id = pane_id,
                    .layout = .{
                        .sizing = .grow,
                        .direction = .top_to_bottom,
                        .child_gap = 0,
                    },
                    .background_color = t.bg,
                })({
                    // Focus handling
                    if (clay.pointerOver(pane_id) and self.mouse_pressed_this_frame) {
                        self.active_pane = pane;
                    }

                    const is_active = (self.active_pane == pane);

                    // Tab-Leiste
                    if (tab_bar_mod.renderTabBar(
                        allocator,
                        &leaf.tab_bar,
                        t,
                        self.mouse_pressed_this_frame,
                        self.is_mouse_down,
                        self.mouse_x,
                        self.mouse_y,
                    )) |req| {
                        if (req.close) {
                            log.debug("renderPane: tab close requested for index {d}", .{req.index});
                            const tab = &leaf.tab_bar.tabs.items[req.index];
                            if (tab.modified) {
                                self.showSaveConfirmationDialog(pane, req.index);
                            } else {
                                // Defer the closure to after the layout cycle
                                self.pending_tab_closes.append(self.allocator, .{ .pane = pane, .index = req.index }) catch {};
                            }
                        } else if (req.do_switch) {
                            leaf.tab_bar.setActive(req.index);
                        }
                    }

                    if (leaf.code_editor.pending_md_preview) {
                        leaf.code_editor.pending_md_preview = false;
                        self.requestMarkdownPreview(leaf.code_editor.buffer.get_file_path());
                    }
                    if (leaf.code_editor.pending_md_export_pdf) {
                        leaf.code_editor.pending_md_export_pdf = false;
                        self.exportMarpPdf(leaf.code_editor.buffer.get_file_path());
                    }
                    // pending_file_history wird in update() abgeholt: die Timeline gibt dabei ihren
                    // Log frei, auf den Clay-Texte dieses Frames noch zeigen würden.

                    // Aktiven Tab prüfen
                    var special_active = false;
                    const tab_bar = &leaf.tab_bar;
                    if (tab_bar.active_index) |idx| {
                        if (idx < tab_bar.tabs.items.len) {
                            const tab = &tab_bar.tabs.items[idx];
                            if (tab.kind == .image) {
                                image_view_mod.ImageViewState.render(allocator, tab.path, t, &self.open_images);
                                special_active = true;
                            } else if (tab.kind == .pdf) {
                                const maybe_handler = self.open_pdfs.get(tab.path);
                                const maybe_texture = self.open_images.get(tab.path);
                                if (maybe_handler) |handler_ptr| {
                                    const handler: *PdfHandler = @ptrCast(@alignCast(handler_ptr));
                                    if (PdfViewState.render(&self.pdf_label_buf, handler, maybe_texture, t, self.mouse_pressed_this_frame, self.mouse_x, self.mouse_y)) |delta| {
                                        self.pending_pdf_page_change = .{ .path = tab.path, .delta = delta };
                                    }
                                }
                                special_active = true;
                            } else if (tab.kind == .binary) {
                                binary_view_mod.render(allocator, tab.path, t);
                                special_active = true;
                            } else if (tab.kind == .git_commit) {
                                if (self.gitCommitFor(tab.path)) |v| {
                                    v.render(allocator, t, paneSalt(pane), @intCast(@min(leaf.code_editor.font_size, 48)), self.mouse_x, self.mouse_y);
                                }
                                special_active = true;
                            } else if (tab.kind == .git_diff) {
                                if (self.gitDiffFor(tab.path)) |v| {
                                    // Schrift wie im Editor dieses Panes (Zoom gilt mit)
                                    v.render(allocator, t, paneSalt(pane), @intCast(@min(leaf.code_editor.font_size, 48)), self.mouse_x, self.mouse_y);
                                }
                                special_active = true;
                            } else if (tab.kind == .terminal) {
                                self.renderTerminalContentInPane(pane, tab.path, t);
                                special_active = true;
                            } else if (tab.kind == .chat) {
                                ai_chat_mod.renderAIChat(
                                    allocator,
                                    &self.ai_chat,
                                    t,
                                    self.mouse_pressed_this_frame,
                                    self.window,
                                    self,
                                );
                                special_active = true;
                            } else if (tab.kind == .markdown_preview) {
                                var md_view = self.open_markdown_views.get(tab.path);
                                if (md_view == null) {
                                    const source_path = tab.path["preview://".len..];
                                    const content = std.fs.cwd().readFileAlloc(self.allocator, source_path, 1024 * 1024) catch |err| blk: {
                                        std.log.err("Failed to load markdown: {any}", .{err});
                                        break :blk self.allocator.dupe(u8, "# Error") catch "# Error";
                                    };
                                    defer self.allocator.free(content);
                                    const new_v = self.allocator.create(markdown_view_mod.MarkdownView) catch unreachable;
                                    new_v.* = markdown_view_mod.MarkdownView.init(self.allocator, content, source_path);
                                    new_v.font_size = self.previewFontSize();
                                    self.open_markdown_views.put(self.allocator.dupe(u8, tab.path) catch tab.path, new_v) catch {};
                                    md_view = new_v;
                                }
                                if (md_view) |v| {
                                    // Dieselbe Vorschau kann in zwei Panes stehen (Split kopiert die
                                    // Tabs, Views hängen am Pfad): IDs zusätzlich je Pane salzen.
                                    v.pane_salt = @truncate(@intFromPtr(pane));
                                    v.render(allocator, t, self);
                                    if (v.pending_split_v) {
                                        v.pending_split_v = false;
                                        self.pending_split = .vertical;
                                    }
                                    if (v.pending_split_h) {
                                        v.pending_split_h = false;
                                        self.pending_split = .horizontal;
                                    }
                                    if (v.pending_export_pdf) {
                                        v.pending_export_pdf = false;
                                        self.exportMarpPdf(tab.path["preview://".len..]);
                                    }
                                    if (v.pending_copy) {
                                        v.pending_copy = false;
                                        self.copyPreviewSelection(v);
                                    }
                                    special_active = true;
                                }
                            }
                        }
                    }

                    if (!special_active and tab_bar.tabs.items.len > 0) {
                        if (tab_bar.getActiveTab()) |tab| {
                            if (tab.kind == .text) {
                                tab.modified = leaf.code_editor.is_modified;
                            }
                        }
                        // Jeder Editor misst mit dem echten Font (auch Panes, die nach dem Start
                        // entstanden sind) und in seiner Schriftgröße (Zoom); vorher hatte nur der
                        // erste Editor eine Messfunktion, die anderen rechneten 0,6 × Schriftgröße.
                        if (leaf.code_editor.measure_fn == null) leaf.code_editor.measure_fn = cMeasureText;
                        g_font_size = @floatFromInt(leaf.code_editor.font_size);
                        leaf.code_editor.render(allocator, self.mouse_pressed_this_frame);
                    }

                    if (leaf.code_editor.pending_split_v) {
                        leaf.code_editor.pending_split_v = false;
                        self.pending_split = .vertical;
                    }
                    if (leaf.code_editor.pending_split_h) {
                        leaf.code_editor.pending_split_h = false;
                        self.pending_split = .horizontal;
                    }

                    if (is_active) {
                        clay.UI()(.{
                            .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top } },
                            .layout = .{ .sizing = .grow },
                            .border = .{ .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 }, .color = t.primary },
                        })({});
                    }
                });

                // Update bounds
                const editor_id = clay.ElementId.IDI("code_editor", @truncate(@intFromPtr(leaf.code_editor)));
                const editor_data = clay.getElementData(editor_id);
                if (editor_data.found) {
                    leaf.code_editor.content_origin_y = editor_data.bounding_box.y;
                    leaf.code_editor.content_origin_x = editor_data.bounding_box.x;
                    leaf.code_editor.height = editor_data.bounding_box.height;
                    leaf.code_editor.width = editor_data.bounding_box.width;
                    // Store bounds for cursor detection
                    leaf.code_editor.editor_bounds_x = editor_data.bounding_box.x;
                    leaf.code_editor.editor_bounds_y = editor_data.bounding_box.y;
                    leaf.code_editor.editor_bounds_width = editor_data.bounding_box.width;
                    leaf.code_editor.editor_bounds_height = editor_data.bounding_box.height;
                    leaf.code_editor.editor_bounds_valid = true;
                }
            },
            .split => |*split| {
                const direction = if (split.direction == .horizontal) clay.LayoutDirection.left_to_right else clay.LayoutDirection.top_to_bottom;
                clay.UI()(.{
                    .id = clay.ElementId.IDI("Split", @truncate(@intFromPtr(pane))),
                    .layout = .{ .sizing = .grow, .direction = direction },
                })({
                    clay.UI()(.{
                        .layout = .{
                            .sizing = if (split.direction == .horizontal)
                                .{ .w = .percent(split.ratio), .h = .grow }
                            else
                                .{ .w = .grow, .h = .percent(split.ratio) },
                        },
                    })({
                        self.renderPane(split.children[0], t);
                    });

                    const splitter_id = clay.ElementId.IDI("Splitter", @truncate(@intFromPtr(pane)));
                    clay.UI()(.{
                        .id = splitter_id,
                        .layout = .{
                            .sizing = if (split.direction == .horizontal)
                                .{ .w = .fixed(4), .h = .grow }
                            else
                                .{ .w = .grow, .h = .fixed(4) },
                        },
                        .background_color = if (split.is_resizing) t.primary else if (clay.pointerOver(splitter_id)) t.secondary else t.border,
                    })({});

                    clay.UI()(.{ .layout = .{ .sizing = .grow } })({
                        self.renderPane(split.children[1], t);
                    });

                    if (clay.pointerOver(splitter_id) and self.mouse_pressed_this_frame) split.is_resizing = true;
                    if (split.is_resizing) {
                        if (!self.is_mouse_down) {
                            split.is_resizing = false;
                        } else {
                            const data = clay.getElementData(clay.ElementId.IDI("Split", @truncate(@intFromPtr(pane))));
                            if (data.found) {
                                if (split.direction == .horizontal) {
                                    split.ratio = (self.mouse_x - data.bounding_box.x) / data.bounding_box.width;
                                } else {
                                    split.ratio = (self.mouse_y - data.bounding_box.y) / data.bounding_box.height;
                                }
                                split.ratio = std.math.clamp(split.ratio, 0.05, 0.95);
                            }
                        }
                    }
                });
            },
        }
    }

    /// Berechnet den gewünschten Cursor für diesen Frame
    pub fn getDesiredCursor(self: *Self) wio.Cursor {
        // PDF-Leiste: Hand über den Schaltflächen (Bounds-Check, clay.pointerOver
        // meldet in dieser Ansicht nichts).
        if (self.activePdfTabPath() != null and PdfViewState.overPagerButton(self.mouse_x, self.mouse_y)) {
            return .hand;
        }

        if (self.file_explorer.is_resizing or clay.pointerOver(clay.ElementId.ID("ExplorerSplitter"))) {
            return .size_ew;
        }

        // Chat-Input → I-Beam (Bounds-Check wie Editor, nicht clay.pointerOver)
        if (self.isChatTabActive() and self.ai_chat.input_bounds_valid) {
            const c = &self.ai_chat;
            if (self.mouse_x >= c.input_bounds_x and self.mouse_x < c.input_bounds_x + c.input_bounds_w and
                self.mouse_y >= c.input_bounds_y and self.mouse_y < c.input_bounds_y + c.input_bounds_h)
            {
                return c.input_editor.desired_cursor;
            }
        }

        // Explorer-Balken wird gezogen: Pfeil, auch wenn die Maus dabei über dem Editor steht
        if (self.file_explorer.scrollbar_drag != null) return .arrow;
        // Markdown-Vorschau: Pfeil über den Balken, I-Beam über dem Text. Vor dem Editor-Test,
        // der hält für die Pane noch die Editor-Bounds und meldete über der Vorschau immer I-Beam.
        if (self.activeMarkdownView()) |v| {
            if (v.cursorAt(self.mouse_x, self.mouse_y)) |c| return c;
        }

        // Mit Mausposition + Bounds prüfen ob wir über einem Editor sind
        if (self.isMouseOverEditor()) {
            return .text;
        }

        return .arrow;
    }

    fn isMouseOverEditor(self: *Self) bool {
        return self.checkEditorBounds(self.root_pane);
    }

    fn checkEditorBounds(self: *Self, pane: *pane_mod.Pane) bool {
        switch (pane.data) {
            .leaf => |*leaf| {
                if (leaf.code_editor.editor_bounds_valid) {
                    const bx = leaf.code_editor.editor_bounds_x;
                    const by = leaf.code_editor.editor_bounds_y;
                    const bw = leaf.code_editor.editor_bounds_width;
                    const bh = leaf.code_editor.editor_bounds_height;
                    if (self.mouse_x >= bx and self.mouse_x < bx + bw and
                        self.mouse_y >= by and self.mouse_y < by + bh)
                    {
                        // Über Editor, aber Scrollbalken ausschließen
                        if (leaf.code_editor.isMouseOverScrollbar(self.mouse_x, self.mouse_y)) {
                            return false;
                        }
                        return true;
                    }
                }
            },
            .split => |*split| {
                if (self.checkEditorBounds(split.children[0])) return true;
                if (self.checkEditorBounds(split.children[1])) return true;
            },
        }
        return false;
    }

    pub fn getOrCreateBuffer(self: *Self, path: []const u8) !*@import("flow_core").Buffer {
        if (self.open_buffers.get(path)) |buf| return buf;

        // Try to load existing file
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024 * 1024) catch |not_found| {
            if (not_found == error.FileNotFound) {
                // New file - create empty buffer with initialized root
                const new_buf = try @import("flow_core").Buffer.create(self.allocator);
                new_buf.root = try new_buf.load_from_string("", &new_buf.file_eol_mode, &new_buf.file_utf8_sanitized);
                new_buf.set_file_path(path);
                new_buf.last_save = new_buf.root;
                try self.open_buffers.put(try self.allocator.dupe(u8, path), new_buf);
                return new_buf;
            }
            return not_found;
        };
        defer self.allocator.free(content);
        const new_buf = try @import("flow_core").Buffer.create(self.allocator);
        new_buf.root = try new_buf.load_from_string(content, &new_buf.file_eol_mode, &new_buf.file_utf8_sanitized);
        new_buf.set_file_path(path);
        new_buf.last_save = new_buf.root;
        try self.open_buffers.put(try self.allocator.dupe(u8, path), new_buf);
        return new_buf;
    }

    pub fn isTerminalActive(self: *Self) bool {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) return tab_bar.tabs.items[idx].kind == .terminal;
        }
        return false;
    }

    pub fn getActiveEditor(self: *Self) *editor_mod.CodeEditor {
        var p = self.active_pane;
        while (p.data == .split) {
            p = p.data.split.children[0];
        }
        return p.data.leaf.code_editor;
    }

    pub fn getActiveTabBar(self: *Self) *tab_bar_mod.TabBarState {
        var p = self.active_pane;
        while (p.data == .split) {
            p = p.data.split.children[0];
        }
        return &p.data.leaf.tab_bar;
    }

    pub fn splitActivePane(self: *Self, direction: pane_mod.PaneDirection) !void {
        const pane = self.active_pane;
        if (pane.data != .leaf) return;

        // 1. Get current state
        const current_leaf = pane.data.leaf;
        const current_buffer = current_leaf.code_editor.buffer;

        // 2. Create TWO brand new independent leaves
        const old_content_leaf = try pane_mod.Pane.createLeaf(self.allocator, current_buffer);
        const new_split_leaf = try pane_mod.Pane.createLeaf(self.allocator, current_buffer);

        // 3. Die neue Hälfte bekommt eine Kopie der Tabs (ohne Chat und Terminal, siehe
        // cloneFrom). Die bisherige Hälfte übernimmt die Tab-Leiste selbst: Chat-Tabs und
        // Terminal-Instanzen gibt es nur einmal, eine zweite Kopie ließe sie verschwinden.
        try new_split_leaf.data.leaf.tab_bar.cloneFrom(&current_leaf.tab_bar);
        old_content_leaf.data.leaf.tab_bar.deinit();
        old_content_leaf.data.leaf.tab_bar = current_leaf.tab_bar;
        copyEditorOptions(old_content_leaf.data.leaf.code_editor, current_leaf.code_editor, self.theme);
        copyEditorOptions(new_split_leaf.data.leaf.code_editor, current_leaf.code_editor, self.theme);

        // 4. Den alten Editor sichern, bevor die Union überschrieben wird
        var old_editor = current_leaf.code_editor;

        // 5. Transform original pane into a split node
        pane.data = .{ .split = .{ .direction = direction, .ratio = 0.5, .children = .{ old_content_leaf, new_split_leaf } } };

        // 6. Now it's safe to deinit old resources (die Tab-Leiste gehört jetzt old_content_leaf)
        old_editor.deinit();
        self.allocator.destroy(old_editor);

        // 7. Update focus
        self.active_pane = new_split_leaf;

        wio.cancelWait();
    }

    /// Umbenennen/Löschen aus dem Explorer auf offene Tabs und Buffer anwenden.
    /// Umbenennen: Tab-Pfad, Titel, Buffer-Pfad und Map-Schlüssel folgen (auch unter
    /// umbenannten Ordnern). Löschen: Tabs ohne ungespeicherte Änderungen schließen,
    /// geänderte bleiben offen (Inhalt lässt sich per Speichern wiederherstellen).
    fn applyFsChange(self: *Self, change: file_explorer_mod.FsChange) void {
        const explorer_ops = @import("explorer_ops.zig");
        self.applyFsChangeToPane(self.root_pane, change);

        // Buffer-Map nach Pfad umschlüsseln bzw. verwaiste Buffer aus der Map nehmen
        var keys_to_fix: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys_to_fix.deinit(self.allocator);
        var it = self.open_buffers.keyIterator();
        while (it.next()) |k| {
            if (explorer_ops.isPathOrUnder(k.*, change.old_path)) keys_to_fix.append(self.allocator, k.*) catch {};
        }
        for (keys_to_fix.items) |old_key| {
            const kv = self.open_buffers.fetchRemove(old_key) orelse continue;
            switch (change.kind) {
                .renamed => {
                    const new_key = explorer_ops.pathAfterRename(self.allocator, kv.key, change.old_path, change.new_path.?) catch null;
                    self.allocator.free(kv.key);
                    if (new_key) |nk| {
                        kv.value.set_file_path(nk);
                        self.open_buffers.put(nk, kv.value) catch {
                            self.allocator.free(nk);
                            self.orphan_buffers.append(self.allocator, kv.value) catch {};
                        };
                    } else {
                        self.orphan_buffers.append(self.allocator, kv.value) catch {};
                    }
                },
                .deleted => {
                    // Nicht deinit: der aktive Editor kann den Buffer bis zum nächsten
                    // Tab-Wechsel noch zeigen. Bleibt bis zum Programmende erhalten.
                    self.allocator.free(kv.key);
                    self.orphan_buffers.append(self.allocator, kv.value) catch {};
                },
            }
        }
    }

    fn applyFsChangeToPane(self: *Self, pane: *pane_mod.Pane, change: file_explorer_mod.FsChange) void {
        const explorer_ops = @import("explorer_ops.zig");
        switch (pane.data) {
            .split => |*sp| {
                self.applyFsChangeToPane(sp.children[0], change);
                self.applyFsChangeToPane(sp.children[1], change);
            },
            .leaf => |*leaf| {
                const tabs = leaf.tab_bar.tabs.items;
                var i: usize = 0;
                while (i < tabs.len) : (i += 1) {
                    const tab = &tabs[i];
                    const prefix: []const u8 = if (std.mem.startsWith(u8, tab.path, "preview://")) "preview://" else "";
                    const base = tab.path[prefix.len..];
                    if (!explorer_ops.isPathOrUnder(base, change.old_path)) continue;
                    switch (change.kind) {
                        .renamed => {
                            const new_base = (explorer_ops.pathAfterRename(self.allocator, base, change.old_path, change.new_path.?) catch null) orelse continue;
                            defer self.allocator.free(new_base);
                            const new_path = std.mem.concat(self.allocator, u8, &.{ prefix, new_base }) catch continue;
                            const new_name = self.allocator.dupe(u8, std.fs.path.basename(new_base)) catch {
                                self.allocator.free(new_path);
                                continue;
                            };
                            self.allocator.free(tab.path);
                            self.allocator.free(tab.display_name);
                            tab.path = new_path;
                            tab.display_name = new_name;
                            if (tab.buffer) |b| b.set_file_path(new_base);
                        },
                        .deleted => {
                            const dirty = if (tab.buffer) |b| (b.last_save != null and b.root != b.last_save.?) else tab.modified;
                            if (dirty) {
                                tab.modified = true;
                                continue;
                            }
                            // Aufsteigend einreihen: pending_tab_closes wird als Stack
                            // abgearbeitet, höchste Indizes zuerst → Indizes bleiben gültig.
                            self.pending_tab_closes.append(self.allocator, .{ .pane = pane, .index = i }) catch {};
                        },
                    }
                }
            },
        }
    }

    fn showDeleteConfirmationDialog(self: *Self, node_index: u32) void {
        if (node_index >= self.file_explorer.nodes.items.len) return;
        const node = self.file_explorer.nodes.items[node_index];
        const count = self.file_explorer.deleteCount();
        const msg = if (count > 1)
            std.fmt.allocPrint(self.allocator, "Move {d} items to the trash?", .{count}) catch return
        else
            std.fmt.allocPrint(self.allocator, "Move '{s}'{s} to the trash?", .{
                node.name,
                if (node.is_folder) " and everything inside it" else "",
            }) catch return;
        self.active_dialog = .{
            .dialog = .{
                .title = "Move to Trash",
                .message = msg,
                .actions = &.{
                    .{ .label = "Delete", .result = .yes },
                    .{ .label = "Cancel", .result = .cancel },
                },
            },
            .context_usize = node_index,
            .context_ptr = null,
            .callback = handleDeleteConfirmation,
            .message_needs_free = true,
        };
    }

    /// Fehler formatiert als Dialog zeigen (Laden, Speichern …); bei offenem Dialog nur loggen.
    pub fn reportError(self: *Self, comptime fmt: []const u8, args: anytype) void {
        log.err(fmt, args);
        if (self.active_dialog != null) return;
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.showErrorDialog(msg);
    }

    /// Fehler einer Explorer-Aktion (Papierkorb, Anlegen, Einfügen) als Dialog statt nur im Log.
    fn showErrorDialog(self: *Self, msg: []u8) void {
        self.active_dialog = .{
            .dialog = .{
                .title = "Error",
                .message = msg,
                .actions = &.{.{ .label = "OK", .result = .cancel }},
            },
            .callback = handleErrorDialog,
            .message_needs_free = true,
        };
    }

    fn handleErrorDialog(_: *UI, _: dialog_mod.DialogResult, _: usize, _: ?*anyopaque) void {}

    fn handleDeleteConfirmation(ui: *UI, res: dialog_mod.DialogResult, idx: usize, _: ?*anyopaque) void {
        // Nicht hier löschen: Render-Commands dieses Frames zeigen noch auf Knotennamen.
        if (res == .yes) ui.file_explorer.confirmDelete(@intCast(idx));
    }

    /// Fenster schließen (wio `.close`, RPC `request_quit`): ohne ungespeicherte Buffer sofort
    /// beenden, sonst nachfragen. Vorher beendete die Plattform ohne Nachfrage, Autosave ist aus.
    pub fn requestQuit(self: *Self) void {
        if (self.active_dialog != null) return; // erst den offenen Dialog beantworten
        var names: std.ArrayListUnmanaged(u8) = .empty;
        defer names.deinit(self.allocator);
        var count: usize = 0;
        var it = self.open_buffers.valueIterator();
        while (it.next()) |buf| {
            if (!buf.*.is_dirty()) continue;
            count += 1;
            if (count <= 3) {
                if (names.items.len > 0) names.appendSlice(self.allocator, ", ") catch {};
                names.appendSlice(self.allocator, std.fs.path.basename(buf.*.get_file_path())) catch {};
            }
        }
        if (count == 0) {
            self.quit_confirmed = true;
            return;
        }
        var more_buf: [32]u8 = undefined;
        const more = if (count > 3) std.fmt.bufPrint(&more_buf, " and {d} more", .{count - 3}) catch "" else "";
        const msg = std.fmt.allocPrint(self.allocator, "{d} file{s} with unsaved changes: {s}{s}. Save before closing?", .{
            count, if (count == 1) "" else "s", names.items, more,
        }) catch {
            self.quit_confirmed = false;
            return;
        };
        self.active_dialog = .{
            .dialog = .{
                .title = "Unsaved Changes",
                .message = msg,
                .actions = &.{
                    .{ .label = "Save All", .result = .yes },
                    .{ .label = "Don't Save", .result = .no },
                    .{ .label = "Cancel", .result = .cancel },
                },
            },
            .callback = handleQuitConfirmation,
            .message_needs_free = true,
        };
    }

    fn handleQuitConfirmation(ui: *UI, res: dialog_mod.DialogResult, _: usize, _: ?*anyopaque) void {
        switch (res) {
            .yes => {
                var it = ui.open_buffers.valueIterator();
                while (it.next()) |buf| {
                    if (!buf.*.is_dirty()) continue;
                    const path = buf.*.get_file_path();
                    backup.backup(ui.allocator, path) catch |err| log.warn("backup for '{s}' failed: {}", .{ path, err });
                    buf.*.store_to_file_and_clean(path) catch |err| {
                        // Nicht beenden: sonst ginge genau die Änderung verloren
                        ui.reportError("Could not save '{s}': {s}", .{ path, @errorName(err) });
                        return;
                    };
                }
                ui.quit_confirmed = true;
            },
            .no => ui.quit_confirmed = true,
            .cancel => {},
        }
    }

    fn showSaveConfirmationDialog(self: *Self, pane: *pane_mod.Pane, tab_index: usize) void {
        const tab = &pane.data.leaf.tab_bar.tabs.items[tab_index];
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Do you want to save changes to '{s}'?", .{tab.display_name}) catch "Save?";

        const duped_msg = self.allocator.dupe(u8, msg) catch msg;
        const needs_free = (duped_msg.ptr != msg.ptr);

        self.active_dialog = .{
            .dialog = .{
                .title = "Unsaved Changes",
                .message = duped_msg,
                .actions = &.{
                    .{ .label = "Save", .result = .yes },
                    .{ .label = "Don't Save", .result = .no },
                    .{ .label = "Cancel", .result = .cancel },
                },
            },
            .context_usize = tab_index,
            .context_ptr = pane,
            .callback = handleSaveConfirmation,
            .message_needs_free = needs_free,
        };
    }

    fn handleSaveConfirmation(ui: *UI, res: dialog_mod.DialogResult, idx: usize, ptr: ?*anyopaque) void {
        const p: *pane_mod.Pane = @ptrCast(@alignCast(ptr.?));
        const leaf = &p.data.leaf;
        switch (res) {
            .yes => {
                leaf.code_editor.save() catch |err| {
                    log.err("Failed to save during close: {}", .{err});
                };
                ui.pending_tab_closes.append(ui.allocator, .{ .pane = p, .index = idx }) catch {};
            },
            .no => {
                // Verworfene Änderungen auch im Buffer verwerfen (Buffer überleben das Schließen)
                const path = leaf.tab_bar.tabs.items[idx].path;
                if (std.fs.cwd().readFileAlloc(ui.allocator, path, 64 * 1024 * 1024)) |content| {
                    defer ui.allocator.free(content);
                    _ = ui.reloadFileFromDisk(path, content);
                } else |_| {}
                ui.pending_tab_closes.append(ui.allocator, .{ .pane = p, .index = idx }) catch {};
            },
            .cancel => {},
        }
    }

    /// Branch-Name aus git_branch TaskResult übernehmen
    pub fn updateBranch(self: *Self, payload: []const u8) void {
        if (self.git_branch.len > 0) self.allocator.free(self.git_branch);
        self.git_branch = self.allocator.dupe(u8, payload) catch "";
    }

    /// Git-Status aus git_status TaskResult an den File Explorer weitergeben
    pub fn updateGitStatus(self: *Self, payload: []const u8) void {
        const repo_root = self.current_directory orelse return;
        const parts = git_worker.splitStatusPayload(payload);
        self.file_explorer.updateGitStatus(parts.explorer, repo_root);
        // Repo-Wurzel für Source-Control-Aktionen (Pfade im Status sind relativ dazu)
        if (self.scm_repo_root) |r| self.allocator.free(r);
        self.scm_repo_root = null;
        if (std.mem.startsWith(u8, parts.explorer, "root:")) {
            const end = std.mem.indexOfScalar(u8, parts.explorer, '\n') orelse parts.explorer.len;
            self.scm_repo_root = self.allocator.dupe(u8, parts.explorer["root:".len..end]) catch null;
        }
        self.scm_changes.view.apply(parts.raw) catch |err| log.warn("scm changes: {}", .{err});
    }

    /// main.zig: weiter rendern statt auf ein Ereignis zu warten, solange ein Hover-Tooltip
    /// (Icon-Knopf, Explorer-Pfad, Timeline- oder Graph-Commit) noch auf seine 700 ms wartet.
    pub fn wantsFrameSoon(self: *Self) bool {
        if (tooltip.pending()) return true;
        if (self.pending_pdf_reloads.items.len > 0) return true; // wartet, bis die Datei ruht
        const fx = &self.file_explorer;
        if (fx.hover_index != null and fx.now_ms - fx.hover_since_ms <= 700) return true;
        const tl = &self.timeline_view;
        if (tl.hover_index != null and tl.now_ms - tl.hover_since_ms <= 700) return true;
        const sg = &self.scm_graph;
        if (sg.hover_row != null and sg.now_ms - sg.hover_since_ms <= 700) return true;
        return false;
    }

    /// main.zig: Status nach einer Source-Control-Aktion neu laden (über den Debounce).
    pub fn takeGitStatusRequest(self: *Self) bool {
        const v = self.git_status_wanted;
        self.git_status_wanted = false;
        return v;
    }

    // ───────────────────────── Source Control: Changes ─────────────────────────

    fn scmRepo(self: *Self) ?[]const u8 {
        return self.scm_repo_root orelse self.current_directory;
    }

    /// Aktion des Changes-Bereichs ausführen (Klick oder Taste).
    fn runScmAction(self: *Self, action: scm_changes_view_mod.Action) void {
        const sc = &self.scm_changes;
        switch (action) {
            .none, .consumed => {},
            .focus_input => self.sidebar_focus = .commit_input,
            .refresh => self.git_status_wanted = true,
            .open_diff => |row| if (self.scmRepo()) |repo| {
                if (sc.view.diffSpec(row, repo)) |spec| self.openGitDiff(spec);
            },
            .open_file => |row| if (self.scmRepo()) |repo| {
                const e = sc.view.entry(row) orelse return;
                const abs = std.fs.path.join(self.allocator, &.{ repo, e.path }) catch return;
                defer self.allocator.free(abs);
                self.getActiveTabBar().openFile(abs) catch |err| log.warn("open '{s}': {}", .{ abs, err });
            },
            .stage => |row| if (sc.view.entry(row)) |e| self.submitScm("stage", &.{e.path}, null),
            .unstage => |row| if (sc.view.entry(row)) |e| self.submitScm("unstage", &.{e.path}, null),
            .stage_all => {
                const paths = self.scmGroupPaths(&.{ .changes, .merge }) orelse return;
                defer self.allocator.free(paths);
                if (paths.len > 0) self.submitScm("stage", paths, null);
            },
            .unstage_all => {
                const paths = self.scmGroupPaths(&.{.staged}) orelse return;
                defer self.allocator.free(paths);
                if (paths.len > 0) self.submitScm("unstage", paths, null);
            },
            .discard => |row| {
                var buf: [512]u8 = undefined;
                const q = sc.view.discardQuestion(&buf, row) catch return;
                self.scm_pending = .{ .discard = row };
                self.showScmDialog("Discard Changes", q, sc.view.discardButton(row));
            },
            .discard_all => {
                const n = sc.view.count(.changes) + sc.view.count(.merge);
                if (n == 0) return;
                var buf: [256]u8 = undefined;
                var btn: [64]u8 = undefined;
                const q = std.fmt.bufPrint(&buf, "Are you sure you want to discard ALL changes in {d} files?\nThis is IRREVERSIBLE!\nYour current working set will be FOREVER LOST if you proceed.", .{n}) catch return;
                const b = std.fmt.bufPrint(&btn, "Discard All {d} Files", .{n}) catch "Discard All";
                self.scm_pending = .discard_all;
                self.showScmDialog("Discard All Changes", q, b);
            },
            .commit => self.scmCommit(),
            .sync => self.scmSync(),
            .generate_message => self.scmGenerateMessage(),
        }
    }

    /// „Generate Commit Message“ wie VS Code Copilot / Zed: Diff holen (gestagt, sonst Arbeitskopie),
    /// dann als Prompt ans Modell; die Antwort landet im Feld (`handleAICommitMessage`).
    fn scmGenerateMessage(self: *Self) void {
        const sc = &self.scm_changes;
        if (sc.generating) return;
        if (self.ai_chat.agent == null or self.ai_chat.agent_status != .ready) {
            self.showToast("AI is not available: start zid without --ai=off", .{});
            return;
        }
        if (sc.view.isClean()) {
            self.showToast("There are no changes to describe.", .{});
            return;
        }
        sc.generating = true;
        self.submitScm("commit_diff", &.{}, null);
    }

    /// Diff da: Prompt bauen und blockierend ans Modell schicken (eigene Ergebnis-Tags).
    fn scmSubmitCommitPrompt(self: *Self, diff: []const u8) void {
        const sched = self.scheduler orelse return self.scmGenerateFailed("no scheduler");
        const agent = self.ai_chat.agent orelse return self.scmGenerateFailed("AI is not available");
        if (std.mem.trim(u8, diff, " \r\n").len == 0) return self.scmGenerateFailed("no diff");
        const prompt = git_changes.commitPrompt(self.allocator, diff, 24 * 1024) catch return self.scmGenerateFailed("out of memory");
        defer self.allocator.free(prompt);
        const ai_worker = @import("ai_worker");
        const messages = [_]@import("agent").LlamaAgent.ChatMessage{.{ .role = "user", .content = prompt }};
        const params = ai_worker.ChatParams.initWithStop(self.allocator, agent, &messages, &sched.should_stop) catch return self.scmGenerateFailed("out of memory");
        params.reply_tag = .ai_commit_message;
        params.error_tag = .ai_commit_message_error;
        if (!sched.submit(.{ .func = ai_worker.taskChatCompletion, .data = params })) {
            params.deinit();
            self.scmGenerateFailed("worker busy");
        }
    }

    fn scmGenerateFailed(self: *Self, why: []const u8) void {
        self.scm_changes.generating = false;
        self.showToast("Generate commit message: {s}", .{why});
    }

    /// Antwort des Modells: bereinigt ins Feld, Fokus ins Feld.
    pub fn handleAICommitMessage(self: *Self, ok: bool, payload: []const u8) void {
        const sc = &self.scm_changes;
        sc.generating = false;
        if (!ok) {
            self.showToast("Generate commit message: {s}", .{payload});
            return;
        }
        const text = git_changes.cleanGeneratedMessage(payload);
        if (text.len == 0) {
            self.showToast("Generate commit message: empty reply", .{});
            return;
        }
        sc.message.set(text);
        sc.validation = null;
        self.sidebar_focus = .commit_input;
    }

    /// Wie VS Code: ohne Upstream „Publish Branch“ (`push -u origin <branch>`), sonst `git.sync`
    /// (`pull`, dann `push`).
    fn scmSync(self: *Self) void {
        const sc = &self.scm_changes;
        if (sc.busy) return;
        const branch = sc.view.branch();
        if (branch.len == 0) {
            self.showToast("Sync: no branch", .{});
            return;
        }
        if (sc.view.upstream().len == 0) {
            self.submitScm("push", &.{ "-u", "origin", branch }, null);
        } else {
            self.submitScm("sync", &.{}, null);
        }
        sc.busy = true;
    }

    /// Pfade der Gruppen als eine Liste (owned Slice, Strings gehören dem Status).
    fn scmGroupPaths(self: *Self, groups: []const git_changes.Group) ?[]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        for (groups) |g| {
            const paths = self.scm_changes.view.groupPaths(self.allocator, g) catch return null;
            defer self.allocator.free(paths);
            out.appendSlice(self.allocator, paths) catch return null;
        }
        return out.toOwnedSlice(self.allocator) catch null;
    }

    /// Commit wie VS Code `smartCommit`: leere Nachricht → Hinweis; ohne Staged Changes → Rückfrage
    /// „stage all and commit“; ohne jede Änderung → Hinweis.
    fn scmCommit(self: *Self) void {
        const sc = &self.scm_changes;
        if (sc.busy) return;
        if (sc.message.len == 0) {
            sc.validation = "Please provide a commit message";
            self.sidebar_focus = .commit_input;
            return;
        }
        if (sc.view.count(.staged) > 0) {
            self.submitScm("commit", &.{}, sc.message.text());
        } else if (sc.view.count(.changes) + sc.view.count(.merge) > 0) {
            self.scm_pending = .commit_all;
            self.showScmDialog("Commit", "There are no staged changes to commit.\n\nWould you like to stage all your changes and commit them directly?", "Yes");
        } else {
            self.showToast("There are no changes to commit.", .{});
        }
    }

    fn showScmDialog(self: *Self, title: []const u8, msg: []const u8, button: []const u8) void {
        const duped = self.allocator.dupe(u8, msg) catch return;
        const btn = self.allocator.dupe(u8, button) catch {
            self.allocator.free(duped);
            return;
        };
        // Knopftext und Aktionen leben bis zum nächsten Dialog (der Dialog hält nur Slices)
        if (self.scm_dialog_button) |b| self.allocator.free(b);
        self.scm_dialog_button = btn;
        self.scm_dialog_actions = .{ .{ .label = btn, .result = .yes }, .{ .label = "Cancel", .result = .cancel } };
        self.active_dialog = .{
            .dialog = .{ .title = title, .message = duped, .actions = &self.scm_dialog_actions },
            .callback = handleScmDialog,
            .message_needs_free = true,
        };
    }

    fn handleScmDialog(ui: *UI, res: dialog_mod.DialogResult, _: usize, _: ?*anyopaque) void {
        const pending = ui.scm_pending orelse return;
        ui.scm_pending = null;
        if (res != .yes) return;
        const sc = &ui.scm_changes;
        switch (pending) {
            .discard => |row| if (sc.view.entry(row)) |e| {
                const untracked = e.kind == .untracked or e.kind == .intent_to_add;
                ui.submitScm(if (untracked) "discard_untracked" else "discard_tracked", &.{e.path}, null);
            },
            .discard_all => {
                // tracked und untracked getrennt (checkout bzw. clean), wie VS Code cleanAll
                var tracked: std.ArrayListUnmanaged([]const u8) = .empty;
                defer tracked.deinit(ui.allocator);
                var untracked: std.ArrayListUnmanaged([]const u8) = .empty;
                defer untracked.deinit(ui.allocator);
                for ([_]git_changes.Group{ .changes, .merge }) |g| {
                    const s = &(sc.view.status orelse continue);
                    for (s.entries(g)) |e| {
                        if (e.kind == .untracked or e.kind == .intent_to_add) untracked.append(ui.allocator, e.path) catch {} else tracked.append(ui.allocator, e.path) catch {};
                    }
                }
                if (tracked.items.len > 0) ui.submitScm("discard_tracked", tracked.items, null);
                if (untracked.items.len > 0) ui.submitScm("discard_untracked", untracked.items, null);
            },
            .commit_all => ui.submitScm("commit_all", &.{}, sc.message.text()),
        }
    }

    /// Worker-Aufruf `taskGitAction`: Felder Aktion, Repo, dann Pfade bzw. die Nachricht.
    fn submitScm(self: *Self, action: []const u8, paths: []const []const u8, message: ?[]const u8) void {
        const sched = self.scheduler orelse return;
        const repo = self.scmRepo() orelse return;
        var fields: std.ArrayListUnmanaged([]const u8) = .empty;
        defer fields.deinit(self.allocator);
        fields.appendSlice(self.allocator, &.{ action, repo }) catch return;
        if (message) |m| fields.append(self.allocator, m) catch return;
        fields.appendSlice(self.allocator, paths) catch return;
        const params = git_worker.FieldsParam.init(self.allocator, fields.items) catch return;
        if (!sched.submit(.{ .func = git_worker.taskGitAction, .data = params })) {
            params.deinit();
            self.showToast("git {s}: worker busy", .{action});
            return;
        }
        if (message != null) self.scm_changes.busy = true;
    }

    /// Ergebnis von `taskGitAction`: Fehler als Toast, danach Status (und nach Commit Graph
    /// und Timeline) neu laden.
    pub fn handleGitAction(self: *Self, ok: bool, payload: []const u8) void {
        const u = git_worker.unframe(payload) orelse return;
        const sc = &self.scm_changes;
        // Diff für die Commit-Nachricht: kein Status-Refresh, weiter ans Modell
        if (std.mem.eql(u8, u.key, "commit_diff")) {
            if (ok) self.scmSubmitCommitPrompt(u.body) else self.scmGenerateFailed(u.body[0 .. std.mem.indexOfScalar(u8, u.body, '\n') orelse u.body.len]);
            return;
        }
        const is_commit = std.mem.startsWith(u8, u.key, "commit");
        const is_push = std.mem.eql(u8, u.key, "push");
        const is_sync = std.mem.eql(u8, u.key, "sync");
        if (is_commit or is_push or is_sync) sc.busy = false;
        self.git_status_wanted = true;
        if (!ok) {
            const first = u.body[0 .. std.mem.indexOfScalar(u8, u.body, '\n') orelse u.body.len];
            self.showToast("git {s}: {s}", .{ u.key, first });
            return;
        }
        if (is_push) {
            self.showToast("Published branch to origin", .{});
            self.scm_graph.refresh();
        }
        if (is_sync) {
            self.showToast("Synced with {s}", .{sc.view.upstream()});
            self.scm_graph.refresh();
            self.timeline_view.timeline.refresh();
        }
        if (is_commit) {
            sc.message.set("");
            sc.validation = null;
            self.scm_graph.refresh();
            self.timeline_view.timeline.refresh();
        }
    }

    pub fn getActiveTerminal(self: *Self) ?*@import("../terminal/terminal_instance.zig").TerminalInstance {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) {
                const tab = tab_bar.tabs.items[idx];
                if (tab.kind == .terminal) return tab_bar.terminal_instances.get(tab.path);
            }
        }
        return null;
    }

    pub fn isChatTabActive(self: *Self) bool {
        const tab_bar = self.getActiveTabBar();
        if (tab_bar.active_index) |idx| {
            if (idx < tab_bar.tabs.items.len) {
                return tab_bar.tabs.items[idx].kind == .chat;
            }
        }
        return false;
    }

    fn renderTerminalContentInPane(self: *Self, pane: *pane_mod.Pane, path: []const u8, t: Theme) void {
        const leaf = &pane.data.leaf;
        const term_instance = leaf.tab_bar.terminal_instances.get(path) orelse return;
        term_instance.window = self.window;
        const arena_alloc = self.frame_arena.allocator();
        const cursor = term_instance.getCursor();
        const total_rows = term_instance.*.totalRows();
        const line_height: f32 = 24.0;
        const clip_id = clay.ElementId.IDI("terminal_content_clip", @truncate(@intFromPtr(pane)));
        const outer_id = clay.ElementId.IDI("terminal_outer", @truncate(@intFromPtr(pane)));
        const outer_data = clay.getElementData(outer_id);
        if (outer_data.found) {
            const ob = outer_data.bounding_box;
            term_instance.scrollbar_track_x = ob.x + ob.width - term_instance.scrollbar_width;
            term_instance.scrollbar_track_y = ob.y;
            term_instance.scrollbar_track_len = ob.height;
        }
        const term_data = clay.getElementData(clip_id);
        if (term_data.found) {
            const bb = term_data.bounding_box;
            term_instance.height = bb.height;
            term_instance.terminal_content_x = bb.x;
            term_instance.terminal_content_y = bb.y;
            const char_w = measureTextWidth("W", 16.0);
            if (char_w > 0) {
                const cols: u16 = @intFromFloat(bb.width / char_w);
                const rows: u16 = @intFromFloat(bb.height / line_height);
                if (cols != term_instance.cols or rows != term_instance.rows) {
                    if (cols > 0 and rows > 0) term_instance.resize(cols, rows) catch {};
                }
            }
        }
        const visible_rows = term_instance.visibleLineCount();
        const history_count = if (total_rows > term_instance.rows) total_rows - term_instance.rows else 0;
        const cursor_abs_row = history_count + cursor.y;
        clay.UI()(.{
            .id = outer_id,
            .layout = .{ .sizing = .grow, .direction = .left_to_right, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } },
            .background_color = .{ 30, 30, 30, 255 },
        })({
            clay.UI()(.{ .id = clip_id, .layout = .{ .sizing = .grow }, .clip = .{ .vertical = true, .horizontal = true } })({
                clay.UI()(.{ .id = clay.ElementId.IDI("terminal_content", @truncate(@intFromPtr(pane))), .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom } })({
                    const start_line = @min(term_instance.view_row, total_rows);
                    const end_line = @min(start_line + visible_rows + 1, total_rows);
                    var i: usize = start_line;
                    while (i < end_line) : (i += 1) {
                        const line_text = term_instance.getLine(i, arena_alloc) catch "";
                        clay.UI()(.{ .id = clay.ElementId.IDI("term_row", @truncate(i ^ @intFromPtr(pane))), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(line_height) }, .direction = .left_to_right, .child_alignment = .{ .x = .left, .y = .center } } })({
                            var pos: usize = 0;
                            var current_fg: clay.Color = .{ 204, 204, 204, 255 };
                            var current_bg: ?clay.Color = null;
                            var text_start: usize = 0;
                            const default_fg: clay.Color = .{ 204, 204, 204, 255 };
                            while (pos < line_text.len) {
                                if (line_text[pos] == '\x1B' and pos + 1 < line_text.len and line_text[pos + 1] == '[') {
                                    if (pos > text_start) {
                                        const seg = line_text[text_start..pos];
                                        if (current_bg) |bg| {
                                            clay.UI()(.{ .background_color = bg })({
                                                clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                            });
                                        } else {
                                            clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                        }
                                    }
                                    pos += 2;
                                    var args: [16]u8 = undefined;
                                    var arg_count: usize = 0;
                                    var num: u8 = 0;
                                    var has_num = false;
                                    while (pos < line_text.len) {
                                        const c = line_text[pos];
                                        if (c >= '0' and c <= '9') {
                                            num = num * 10 + (c - '0');
                                            has_num = true;
                                            pos += 1;
                                        } else if (c == ';') {
                                            if (arg_count < args.len) {
                                                args[arg_count] = num;
                                                arg_count += 1;
                                            }
                                            num = 0;
                                            has_num = false;
                                            pos += 1;
                                        } else if (c == 'm') {
                                            if (has_num and arg_count < args.len) {
                                                args[arg_count] = num;
                                                arg_count += 1;
                                            }
                                            pos += 1;
                                            break;
                                        } else {
                                            pos += 1;
                                            break;
                                        }
                                    }
                                    var arg_idx: usize = 0;
                                    if (arg_count == 0) {
                                        current_fg = default_fg;
                                        current_bg = null;
                                    }
                                    while (arg_idx < arg_count) {
                                        const code = args[arg_idx];
                                        arg_idx += 1;
                                        switch (code) {
                                            0 => {
                                                current_fg = default_fg;
                                                current_bg = null;
                                            },
                                            30...37 => {
                                                current_fg = switch (code - 30) {
                                                    0 => .{ 0, 0, 0, 255 },
                                                    1 => .{ 205, 49, 49, 255 },
                                                    2 => .{ 13, 188, 121, 255 },
                                                    3 => .{ 229, 229, 16, 255 },
                                                    4 => .{ 36, 114, 200, 255 },
                                                    5 => .{ 188, 63, 188, 255 },
                                                    6 => .{ 17, 168, 205, 255 },
                                                    7 => .{ 229, 229, 229, 255 },
                                                    else => default_fg,
                                                };
                                            },
                                            38 => {
                                                if (arg_idx + 1 < arg_count and args[arg_idx] == 5) {
                                                    arg_idx += 2;
                                                } else if (arg_idx + 3 < arg_count and args[arg_idx] == 2) {
                                                    current_fg = .{ @floatFromInt(args[arg_idx + 1]), @floatFromInt(args[arg_idx + 2]), @floatFromInt(args[arg_idx + 3]), 255 };
                                                    arg_idx += 4;
                                                }
                                            },
                                            39 => current_fg = default_fg,
                                            40...47 => {
                                                current_bg = switch (code - 40) {
                                                    0 => .{ 0, 0, 0, 255 },
                                                    1 => .{ 205, 49, 49, 255 },
                                                    2 => .{ 13, 188, 121, 255 },
                                                    3 => .{ 229, 229, 16, 255 },
                                                    4 => .{ 36, 114, 200, 255 },
                                                    5 => .{ 188, 63, 188, 255 },
                                                    6 => .{ 17, 168, 205, 255 },
                                                    7 => .{ 229, 229, 229, 255 },
                                                    else => null,
                                                };
                                            },
                                            48 => {
                                                if (arg_idx + 1 < arg_count and args[arg_idx] == 5) {
                                                    arg_idx += 2;
                                                } else if (arg_idx + 3 < arg_count and args[arg_idx] == 2) {
                                                    current_bg = .{ @floatFromInt(args[arg_idx + 1]), @floatFromInt(args[arg_idx + 2]), @floatFromInt(args[arg_idx + 3]), 255 };
                                                    arg_idx += 4;
                                                }
                                            },
                                            49 => current_bg = null,
                                            90...97 => {
                                                current_fg = switch (code - 90) {
                                                    0 => .{ 102, 102, 102, 255 },
                                                    1 => .{ 241, 76, 76, 255 },
                                                    2 => .{ 35, 209, 139, 255 },
                                                    3 => .{ 245, 245, 67, 255 },
                                                    4 => .{ 59, 142, 234, 255 },
                                                    5 => .{ 214, 112, 214, 255 },
                                                    6 => .{ 41, 184, 219, 255 },
                                                    7 => .{ 255, 255, 255, 255 },
                                                    else => default_fg,
                                                };
                                            },
                                            else => {},
                                        }
                                    }
                                    text_start = pos;
                                } else pos += 1;
                            }
                            if (pos > text_start) {
                                const seg = line_text[text_start..pos];
                                if (current_bg) |bg| {
                                    clay.UI()(.{ .background_color = bg })({
                                        clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                    });
                                } else {
                                    clay.text(arena_alloc.dupe(u8, seg) catch " ", .{ .font_size = 16, .color = current_fg });
                                }
                            }
                            if (i == cursor_abs_row) {
                                const char_w = measureTextWidth("W", 16.0);
                                const exact_x = @as(f32, @floatFromInt(cursor.x)) * char_w;
                                clay.UI()(.{ .id = clay.ElementId.IDI("terminal_cursor", @truncate(@intFromPtr(pane))), .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = exact_x, .y = 0 } }, .layout = .{ .sizing = .{ .w = .fixed(char_w), .h = .fixed(line_height) } }, .background_color = .{ 200, 200, 200, 180 } })({});
                            }
                            {
                                var col: u16 = 0;
                                var selection_start_col: ?u16 = null;
                                const char_w = measureTextWidth("W", 16.0);
                                while (col < term_instance.cols) {
                                    if (term_instance.isSelected(col, i)) {
                                        if (selection_start_col == null) selection_start_col = col;
                                    } else {
                                        if (selection_start_col) |start| {
                                            const width = @as(f32, @floatFromInt(col - start)) * char_w;
                                            clay.UI()(.{ .id = clay.ElementId.IDI("term_sel", @truncate(i * 1000 + start ^ @intFromPtr(pane))), .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = @as(f32, @floatFromInt(start)) * char_w, .y = 0 } }, .layout = .{ .sizing = .{ .w = .fixed(width), .h = .fixed(line_height) } }, .background_color = .{ 100, 100, 255, 60 } })({});
                                            selection_start_col = null;
                                        }
                                    }
                                    col += 1;
                                }
                                if (selection_start_col) |start| {
                                    const width = @as(f32, @floatFromInt(col - start)) * char_w;
                                    clay.UI()(.{ .id = clay.ElementId.IDI("term_sel", @truncate(i * 1000 + start ^ @intFromPtr(pane))), .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = @as(f32, @floatFromInt(start)) * char_w, .y = 0 } }, .layout = .{ .sizing = .{ .w = .fixed(width), .h = .fixed(line_height) } }, .background_color = .{ 100, 100, 255, 60 } })({});
                                }
                            }
                        });
                    }
                });
            });
            // Balken über die volle Höhe am rechten Rand (Lage aus dem Vorframe). Hover braucht
            // keine Auswertung: über dem Terminal gilt ohnehin der Pfeil.
            if (term_instance.scrollModel()) |m| {
                _ = scrollbar.render(m, .{
                    .track = clay.ElementId.IDI("terminal_scrollbar_track", @truncate(@intFromPtr(pane))),
                    .thumb = clay.ElementId.IDI("terminal_scrollbar_thumb", @truncate(@intFromPtr(pane))),
                });
            }
        });
        term_instance.renderContextMenu(ctx_menu.Colors.fromTheme(t));
    }

    fn renderChatContentInPane(self: *Self, pane: *pane_mod.Pane, t: Theme) void {
        const chat = &self.ai_chat;
        const line_height: f32 = 24.0;
        const input_height: f32 = 80.0;
        const padding: f32 = 12.0;

        // Messages viewport
        const viewport_id = clay.ElementId.IDI("chat_viewport", @truncate(@intFromPtr(pane)));
        const clip_id = clay.ElementId.IDI("chat_clip", @truncate(@intFromPtr(pane)));

        clay.UI()(.{
            .id = clay.ElementId.IDI("chat_outer", @truncate(@intFromPtr(pane))),
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .padding = .{ .left = padding, .right = padding, .top = padding, .bottom = 0 },
            },
            .background_color = t.surface,
        })({
            // Header
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(40) },
                    .direction = .left_to_right,
                    .child_alignment = .{ .y = .center },
                    .child_gap = 8,
                },
            })({
                clay.text("Chat", .{ .font_size = 18, .color = t.text });
                if (chat.is_loading) {
                    clay.text("...", .{ .font_size = 14, .color = t.muted });
                }
            });

            // Messages area
            clay.UI()(.{
                .id = viewport_id,
                .layout = .{ .sizing = .{ .w = .grow, .h = .grow } },
                .clip = .{ .vertical = true },
            })({
                clay.UI()(.{
                    .id = clip_id,
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = 8,
                    },
                }({
                    chat.mutex.lock();
                    defer chat.mutex.unlock();
                    for (chat.messages.items, 0..) |msg, idx| {
                        const is_user = std.mem.eql(u8, msg.role, "user");
                        const msg_id = clay.ElementId.IDI("chat_msg", @truncate(idx ^ @intFromPtr(pane)));

                        const role_label = if (is_user) "You:" else "Gemma:";
                        const role_color: clay.Color = if (is_user) .{ 200, 200, 255, 255 } else .{ 200, 255, 200, 255 };

                        clay.UI()(.{
                            .id = msg_id,
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fit },
                                .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
                                .direction = .top_to_bottom,
                            },
                            .background_color = if (is_user) .{ 40, 40, 60, 255 } else .{ 35, 35, 45, 255 },
                            .corner_radius = .all(4),
                        })({
                            clay.text(role_label, .{ .font_size = 12, .color = role_color });
                            clay.text(msg.content, .{ .font_size = 14, .color = t.text });
                        });
                    }
                    if (chat.is_loading) {
                        clay.text("Thinking...", .{ .font_size = 14, .color = t.muted });
                    }
                }));
            });

            // Update viewport heights for scrolling
            const vp_data = clay.getElementData(viewport_id);
            const content_data = clay.getElementData(clip_id);
            if (vp_data.found) chat.viewport_height = vp_data.bounding_box.height;
            if (content_data.found) chat.content_height = content_data.bounding_box.height;
            const max_scroll = @max(0, chat.content_height - chat.viewport_height);
            if (chat.scroll_offset_y > max_scroll) chat.scroll_offset_y = max_scroll;

            // Input area at bottom
            clay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(input_height) },
                    .direction = .top_to_bottom,
                    .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
                },
                .background_color = .{ 25, 25, 30, 255 },
                .border = .{ .width = .{ .top = 1 }, .color = t.border },
            })({
                const input_text = if (chat.input_buffer.items.len == 0) "> " else chat.input_buffer.items;
                clay.text(input_text, .{ .font_size = 16, .color = t.text });

                // Blinking cursor
                {
                    const blink_ms: f32 = 530.0;
                    const visible = @mod(chat.ui_time_ms, blink_ms * 2.0) < blink_ms;
                    if (visible) {
                        const char_w: f32 = 9.0;
                        const text_w = @as(f32, @floatFromInt(chat.input_buffer.items.len)) * char_w;
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(line_height) } },
                            .floating = .{
                                .attach_to = .to_parent,
                                .attach_points = .{ .element = .left_top, .parent = .left_top },
                                .offset = .{ .x = text_w + 8, .y = 8 },
                            },
                            .background_color = .{ 200, 200, 200, 255 },
                        })({});
                    }
                }
            });
        });

        // Handle scroll
        if (self.active_tab_bar) |tab_bar| {
            if (tab_bar.getActiveTab()) |tab| {
                _ = tab;
                // Scroll handled by scroll wheel events
            }
        }
    }
};
