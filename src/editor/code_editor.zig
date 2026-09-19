//! Code Editor Component für zid
//!
//! Code Editor mit Line Numbers, Syntax Highlighting, Cursor und Text Input.
//! Verwendet flow_core.Buffer für Text-Speicherung.

const std = @import("std");
const clay = @import("clay");
const flow_core = @import("flow_core");
const syntax = @import("syntax");
const wio = @import("wio");
const shortcuts = @import("shortcuts");
const ctx_menu = @import("context_menu");
const scrollbar = @import("scrollbar");
const marp = @import("marp");
const find_ops = @import("find_ops.zig");

const actions = @import("actions.zig");
const keymap = @import("keymap.zig");
const edit_ops = @import("edit_ops.zig");
const wrap_ops = @import("wrap_ops.zig");
const backup = @import("backup.zig");

/// Bis zu dieser Zeilenzahl zählt `totalVisualRows` exakt, darüber per Stichprobe.
pub const visual_rows_sample_max: usize = 2048;
const VisualRowsCache = struct { root: flow_core.Buffer.Root, cols: usize, total: usize };

/// Measurement function type: returns width of text in pixels.
pub const MeasureFn = *const fn (ptr: [*c]const u8, len: usize) f32;

/// Writer adapter: writes into ArrayListUnmanaged(u8), compatible with write_range
pub fn ArrayListWriter(comptime WriterError: type) type {
    return struct {
        allocator: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(u8),

        const AWriter = @This();
        pub const Error = WriterError;

        pub fn init(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8)) AWriter {
            return .{ .allocator = allocator, .list = list };
        }

        pub fn write(self: *AWriter, data: []const u8) Error!usize {
            self.list.appendSlice(self.allocator, data) catch return Error.OutOfMemory;
            return data.len;
        }

        pub fn writeAll(self: *AWriter, data: []const u8) Error!void {
            try self.write(data);
        }
    };
}

fn colorFromTag(fg: u32) clay.Color {
    return .{
        @floatFromInt((fg >> 16) & 0xff),
        @floatFromInt((fg >> 8) & 0xff),
        @floatFromInt(fg & 0xff),
        255,
    };
}

fn lessThanTag(_: void, a: flow_core.highlight.ColorTag, b: flow_core.highlight.ColorTag) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end; // längere zuerst bei gleichem Start (Container-Prinzip)
}

/// `line` ist der sichtbare Ausschnitt der Zeile ab Byte `offset` (horizontales Scrollen);
/// die Highlight-Tags beziehen sich auf die ganze Zeile (`full_len` Bytes).
fn renderHighlightedLine(
    arena: std.mem.Allocator,
    hl: *flow_core.highlight.SyntaxHighlighter,
    line_idx: usize,
    line: []const u8,
    offset: usize,
    full_len: usize,
    font_size: u16,
    plain_color: clay.Color,
) void {
    const tags = hl.tagsForLine(line_idx, full_len, arena) catch {
        const persistent = arena.dupe(u8, line) catch "";
        clay.text(persistent, .{ .font_size = font_size, .color = plain_color, .wrap_mode = .none });
        return;
    };
    std.sort.insertion(flow_core.highlight.ColorTag, tags, {}, lessThanTag);

    var pos: usize = 0;
    for (tags) |tag| {
        if (tag.end > full_len) continue;
        if (tag.start >= tag.end) continue;
        // In den Ausschnitt verschieben und beschneiden
        const tag_start = @min(tag.start -| offset, line.len);
        const tag_end = @min(tag.end -| offset, line.len);
        if (tag_start >= tag_end) continue;

        // Robust gegen Überlappungen: nur den Teil rendern, der noch nicht gezeichnet wurde
        const actual_start = @max(tag_start, pos);
        if (actual_start >= tag_end) continue;

        if (actual_start > pos) {
            const seg = arena.dupe(u8, line[pos..actual_start]) catch "";
            clay.text(seg, .{ .font_size = font_size, .color = plain_color, .wrap_mode = .none });
        }
        const seg = arena.dupe(u8, line[actual_start..tag_end]) catch "";
        clay.text(seg, .{ .font_size = font_size, .color = colorFromTag(tag.fg), .wrap_mode = .none });
        pos = tag_end;
    }
    if (pos < line.len) {
        const seg = arena.dupe(u8, line[pos..]) catch "";
        clay.text(seg, .{ .font_size = font_size, .color = plain_color, .wrap_mode = .none });
    }
}

pub const ExtraCursor = struct { cursor: flow_core.Cursor, anchor: ?flow_core.Cursor };

pub const CodeEditor = struct {
    allocator: std.mem.Allocator,

    /// flow-core Buffer for text storage
    buffer: *flow_core.Buffer,

    /// Aktuelle Zeile (1-based, für Highlight)
    current_line: usize = 1,

    /// Cursor Position (flow_core.Cursor: row/col in display columns)
    cursor: flow_core.Cursor,

    /// Selection Anchor, null = keine Selektion
    selection_anchor: ?flow_core.Cursor = null,

    /// Modifier-State (Bitmaske)
    mods: actions.Mods = .{},

    /// Keymap für Command-Dispatching
    keymap: ?keymap.Keymap = null,

    /// Maus-State für Drag-Selektion
    mouse_down: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    /// Double-Click Erkennung
    last_mouse_click_ms: f32 = 0,
    last_mouse_click_line: usize = 0,
    last_mouse_click_col: usize = 0,
    /// Klicks in Folge (1 = einfach, 2 = doppelt, 3 = dreifach)
    click_count: u32 = 0,

    /// View for scrolling
    view: flow_core.View,

    /// Laufendes Ziehen an der senkrechten bzw. waagrechten Leiste (Modul `scrollbar`)
    vscroll_drag: ?scrollbar.Drag = null,
    hscroll_drag: ?scrollbar.Drag = null,

    /// Längste Zeile in Spalten (waagrechte Leiste): gecacht, nach einer Änderung wird nur
    /// der betroffene Bereich neu gemessen (`maxLineWidth`).
    longest_line_width: usize = 0,
    longest_line_idx: usize = 0,
    longest_valid: bool = false,
    longest_pending: ?LineChange = null,
    /// Sichtbare Reihen des ganzen Buffers mit Word-Wrap, gültig für genau diesen
    /// Root und diese Spaltenzahl (siehe `totalVisualRows`).
    visual_rows_cache: ?VisualRowsCache = null,

    pending_split_v: bool = false,
    pending_split_h: bool = false,

    typing_in_progress: bool = false,
    /// Cursor nach dem zuletzt getippten Zeichen. Steht der Cursor beim nächsten Zeichen woanders
    /// (Klick, Pfeil, Sprung), beginnt ein neuer Undo-Schritt.
    typing_end: struct { row: usize, col: usize } = .{ .row = 0, .col = 0 },

    pending_md_preview: bool = false,
    pending_md_export_pdf: bool = false,
    /// Kontextmenü „File History“: UI öffnet den Verlauf der Datei dieses Buffers
    pending_file_history: bool = false,
    /// Suchleiste (Ctrl+F)
    find: FindState = .{},
    /// Gehe zu Zeile (Ctrl+G)
    goto: GotoState = .{},

    /// Zeitpunkt der letzten Cursor-Bewegung (für Blink-Delay)
    last_cursor_movement_ms: f32 = 0,

    /// Layout (Breite/Höhe des Editor-Elements aus dem letzten Layout)
    width: f32 = 800,
    height: f32 = 400,
    gutter_width: f32 = 50,
    scrollbar_width: f32 = 10,

    /// Content-Offset vom Fenster-Top
    content_origin_y: f32 = 0,
    content_origin_x: f32 = 0,

    /// Bounds des Editors für Cursor-Detection (gültig nach render)
    editor_bounds_valid: bool = false,
    editor_bounds_x: f32 = 0,
    editor_bounds_y: f32 = 0,
    editor_bounds_width: f32 = 0,
    editor_bounds_height: f32 = 0,

    /// Letzter Fehler (z. B. Speichern), von der UI per takeError abgeholt (owned)
    last_error: ?[]u8 = null,

    /// Text-Messung
    measure_fn: ?MeasureFn = null,

    font_size: u16 = 24,
    time_ms: f32 = 0,

    /// Farben
    bg_color: clay.Color = .{ 30, 30, 46, 255 },
    gutter_color: clay.Color = .{ 24, 24, 37, 255 },
    line_number_color: clay.Color = .{ 108, 112, 134, 255 },
    current_line_number_color: clay.Color = .{ 138, 173, 244, 255 },
    current_line_highlight: clay.Color = .{ 60, 70, 100, 200 },
    cursor_color: clay.Color = .{ 249, 226, 175, 255 },
    selection_color: clay.Color = .{ 100, 120, 200, 160 },
    text_color: clay.Color = .{ 202, 211, 245, 255 },
    /// Zeitpunkt der letzten Änderung (Autosave nach Ruhe) und Zähler gespeicherter Dateien (Toast)
    last_edit_ms: f32 = 0,
    saved_event: bool = false,
    /// Anzeigeoptionen (View-Menü, gemerkt)
    show_indent_guides: bool = true,
    show_whitespace: bool = false,
    show_minimap: bool = true,
    /// Soft-Wrap: lange Zeilen werden in Segmente von `visibleColCount()` Spalten umgebrochen
    /// (Alt+Z). Cursor-Bewegung bleibt zeilenweise (Buffer-Zeilen), gescrollt wird nach Buffer-Zeilen.
    word_wrap: bool = false,
    /// Sprung zur Definition über einen Language Server (gesetzt vom UI); liefert true,
    /// wenn die Anfrage unterwegs ist — dann kein lokaler Textmuster-Sprung.
    definition_hook: ?DefinitionHook = null,
    /// Zeilennummernspalte (aus für Eingabefelder wie den KI-Chat)
    show_gutter: bool = true,
    /// Kontextmenü nur Cut/Copy/Paste (Eingabefeld: kein MD-Preview, kein Split)
    compact_menu: bool = false,
    /// Klammerpaar am Cursor (pro Frame berechnet): Position der Klammer am Cursor und ihres Partners
    bracket_pair: ?[2]flow_core.Cursor = null,
    /// Breite der Minimap-Spalte
    minimap_width: f32 = 84,
    /// Zusätzliche Cursor (Ctrl+D, Ctrl+Alt+↑/↓); der Hauptcursor ist `cursor`
    extra_cursors: std.ArrayListUnmanaged(ExtraCursor) = .empty,
    /// Während einer Mehrfach-Cursor-Operation: Einzelschritte legen keinen eigenen Undo-Punkt an
    in_multi: bool = false,

    /// Referenz auf das Fenster
    window: ?*wio.Window = null,

    /// Kontextmenü-State
    show_context_menu: bool = false,
    context_menu_x: f32 = 0,
    context_menu_y: f32 = 0,
    /// Menüfarben aus dem UI-Theme (applyTheme), bis dahin Dark
    menu_colors: ctx_menu.Colors = ctx_menu.Colors.dark,

    last_frame_hovered: bool = false,
    desired_cursor: wio.Cursor = .arrow,

    /// Reusable line buffer for getLine — contents valid only until next getLine call.
    line_scratch: std.Io.Writer.Allocating,

    /// Syntax-Highlighter (flow-syntax / tree-sitter). null = kein Highlighting
    /// (z.B. unbekannte Dateiendung oder leerer Editor).
    highlighter: ?*flow_core.highlight.SyntaxHighlighter = null,

    /// Background parsing state
    bg_parse_thread: ?std.Thread = null,
    bg_mutex: std.Thread.Mutex = .{},
    bg_highlighter: ?*flow_core.highlight.SyntaxHighlighter = null,
    bg_queued_edits: std.ArrayListUnmanaged(syntax.Edit) = .empty,
    bg_parsing: bool = false,
    bg_snapshot_root: ?flow_core.Buffer.Root = null,
    bg_parse_error: ?anyerror = null,

    /// Rope-Root der letzten Parser-Run — wird pro Render verglichen,
    /// um nur bei Buffer-Änderungen neu zu parsen.
    last_parsed_root: ?flow_core.Buffer.Root = null,

    /// Trackt ob seit dem letzten Reparse Edits korrekt via pushEdit gemeldet wurden.
    /// true = alle Edits wurden gemeldet, inkrementeller Parse ist sicher.
    /// false = Edits fehlen, resetTree() muß vor dem nächsten Reparse aufgerufen werden.
    edits_fully_tracked: bool = true,

    /// Zeilen-Bereich der seit dem letzten Reparse geändert wurde (inclusive).
    /// Wird für Dirty-Region-Tracking beim Rendering verwendet.
    /// Nur relevant wenn edits_fully_tracked == true.
    dirty_line_start: usize = 0,
    dirty_line_end: usize = 0,
    has_dirty_lines: bool = false,
    is_modified: bool = false,

    const Self = @This();

    pub fn isModified(self: *const Self) bool {
        return self.is_modified;
    }

    pub fn getBuffer(self: *Self) *flow_core.Buffer {
        return self.buffer;
    }

    pub fn setBuffer(self: *Self, new_buf: *flow_core.Buffer, path: []const u8) void {
        self.destroyHighlighter();
        self.buffer = new_buf;
        self.setLanguageFromPath(path);
        self.is_modified = new_buf.last_save != null and new_buf.root != new_buf.last_save.?; // Rough check
        // Cursor, Auswahl und Mehrfach-Cursor gehören zur alten Datei: alles zurücksetzen,
        // sonst bleibt der alte Anker stehen und markiert ab Zeile 0 bis dorthin.
        self.cursor = .{};
        self.selection_anchor = null;
        self.clearExtraCursors();
        self.mouse_down = false;
        self.view.row = 0;
        self.view.col = 0;
        self.edits_fully_tracked = false;
        self.has_dirty_lines = true;
        self.dirty_line_start = 0;
        self.dirty_line_end = self.lineCount();
    }

    pub fn save(self: *Self) !void {
        const path = self.buffer.get_file_path();
        if (path.len == 0) return error.NoFilePath;

        // Sicherung der alten Version (eine je Datei unter ~/.local/share/zid/backup)
        backup.backup(self.allocator, path) catch |err| std.log.scoped(.editor).warn("backup for '{s}' failed: {}", .{ path, err });
        try self.buffer.store_to_file_and_clean(path);

        self.markSaved();
        self.saved_event = true;
        std.log.scoped(.editor).info("Saved file: {s}", .{path});
    }

    /// Stand nach erfolgreichem Speichern (Buffer hat `last_save` schon gesetzt).
    pub fn markSaved(self: *Self) void {
        self.is_modified = false;
        // Nächstes Zeichen legt einen neuen Undo-Stand an: dessen root ist `last_save`, Undo
        // dorthin macht den Tab wieder sauber
        self.typing_in_progress = false;
    }

    /// true genau einmal nach jedem erfolgreichen Speichern (Toast in der UI).
    pub fn takeSaved(self: *Self) bool {
        const v = self.saved_event;
        self.saved_event = false;
        return v;
    }

    /// Farben aus dem UI-Theme übernehmen (Light/Dark).
    pub fn applyTheme(self: *Self, t: anytype) void {
        self.bg_color = t.bg;
        self.gutter_color = t.surface;
        self.line_number_color = t.muted;
        self.current_line_number_color = t.primary;
        self.current_line_highlight = .{ t.overlay[0], t.overlay[1], t.overlay[2], 140 };
        self.cursor_color = t.accent;
        self.selection_color = .{ t.primary[0], t.primary[1], t.primary[2], 110 };
        self.text_color = t.text;
        self.menu_colors = ctx_menu.Colors.fromTheme(t);
    }

    /// Schriftgröße setzen (Zoom), 10–48.
    pub fn setFontSize(self: *Self, size: u16) void {
        self.font_size = @max(10, @min(48, size));
        self.ensureCursorVisible();
    }

    fn setError(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (self.last_error) |e| self.allocator.free(e);
        self.last_error = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    /// Letzten Fehler abholen (owned, Aufrufer gibt frei).
    pub fn takeError(self: *Self) ?[]u8 {
        const e = self.last_error;
        self.last_error = null;
        return e;
    }

    /// Setzt Dirty-Flag für Highlighting — OHNE sofortigen Reparse.
    /// MUSS nach Edit-Operationen aufgerufen werden.
    fn markDirty(self: *Self, start_line: usize, end_line: usize) void {
        std.log.scoped(.highlight).debug("markDirty lines {d}..{d}", .{ start_line, end_line });
        self.edits_fully_tracked = true;
        if (!self.has_dirty_lines) {
            self.dirty_line_start = start_line;
            self.dirty_line_end = end_line;
            self.has_dirty_lines = true;
        } else {
            self.dirty_line_start = @min(self.dirty_line_start, start_line);
            self.dirty_line_end = @max(self.dirty_line_end, end_line);
        }
    }

    /// Metrics for flow_core - uses monospace assumption
    fn metrics(_: *const Self) flow_core.Buffer.Metrics {
        const Ctx = struct {
            fn egc_length(_: flow_core.Buffer.Metrics, egcs: []const u8, colcount: *usize, _: usize) usize {
                if (egcs.len == 0) return 0;
                if (egcs[0] == '\n') {
                    colcount.* = 1;
                    return 1;
                }
                if (egcs[0] == '\t') {
                    colcount.* = 4;
                    return 1;
                }
                // Ein Codepoint = eine Spalte. Vorher zählte jedes Byte als Spalte: ←/→ liefen in
                // zwei Schritten durch ein „ü“, Tippen dazwischen zerschnitt die UTF-8-Sequenz.
                colcount.* = 1;
                const len = std.unicode.utf8ByteSequenceLength(egcs[0]) catch 1;
                return @min(len, egcs.len);
            }
            /// Breite eines ganzen Chunks: insert_chars addiert sie zur Cursor-Spalte. Vorher
            /// war das pauschal 1, der Cursor stand nach Einfügen/Autoclose eine Spalte zu weit links.
            fn egc_chunk_width(_: flow_core.Buffer.Metrics, chunk_: []const u8, _: usize) usize {
                var w: usize = 0;
                for (chunk_) |b| {
                    if ((b & 0xC0) == 0x80) continue; // UTF-8-Folgebyte
                    w += if (b == '\t') 4 else 1;
                }
                return w;
            }
            fn egc_last(_: flow_core.Buffer.Metrics, egcs: []const u8) []const u8 {
                return egcs;
            }
        };
        return .{
            .ctx = undefined,
            .egc_length = Ctx.egc_length,
            .egc_chunk_width = Ctx.egc_chunk_width,
            .egc_last = Ctx.egc_last,
            .tab_width = 4,
        };
    }

    pub fn init(allocator: std.mem.Allocator, buffer: *flow_core.Buffer) Self {
        const view: flow_core.View = .{
            .rows = 20,
            .cols = 80,
            .row = 0,
            .col = 0,
        };

        const cursor: flow_core.Cursor = .{
            .row = 0,
            .col = 0,
            .target = 0,
        };

        return Self{
            .allocator = allocator,
            .buffer = buffer,
            .cursor = cursor,
            .view = view,
            .keymap = keymap.Keymap.initDefault(allocator) catch null,
            .desired_cursor = .arrow,
            .line_scratch = .init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_error) |e| self.allocator.free(e);
        self.extra_cursors.deinit(self.allocator);
        if (self.bg_parse_thread) |thread| thread.join();
        if (self.highlighter) |hl| hl.destroy();
        if (self.bg_highlighter) |hl| hl.destroy();
        self.bg_queued_edits.deinit(self.allocator);
        // self.buffer.deinit(); // Buffer is managed by UI/TabBar to prevent double-free
        if (self.keymap) |*km| km.deinit();
        self.line_scratch.deinit();
    }

    fn destroyHighlighter(self: *Self) void {
        if (self.bg_parse_thread) |thread| {
            thread.join();
            self.bg_parse_thread = null;
        }
        if (self.highlighter) |hl| {
            hl.destroy();
            self.highlighter = null;
        }
        if (self.bg_highlighter) |hl| {
            hl.destroy();
            self.bg_highlighter = null;
        }
        self.bg_queued_edits.clearRetainingCapacity();
        self.last_parsed_root = null;
        self.visual_rows_cache = null;
    }

    /// Sprache anhand Dateipfad (Extension / Shebang) wählen.
    /// Erkennt nichts → Highlighter bleibt null, Fallback = Plain-Color.
    pub fn setLanguageFromPath(self: *Self, file_path: []const u8) void {
        const log = std.log.scoped(.highlight);
        self.destroyHighlighter();
        self.buffer.set_file_path(file_path);
        const content = self.buffer.store_to_string_cached(self.buffer.root, self.buffer.file_eol_mode);

        // Create primary highlighter
        self.highlighter = flow_core.highlight.SyntaxHighlighter.createByPath(
            self.allocator,
            file_path,
            content,
        ) catch |err| {
            log.warn("no highlighter for '{s}': {s}", .{ file_path, @errorName(err) });
            return;
        };

        // Create secondary highlighter for background parsing
        self.bg_highlighter = flow_core.highlight.SyntaxHighlighter.createByPath(
            self.allocator,
            file_path,
            content,
        ) catch null; // If first succeeded, this usually succeeds too

        self.last_parsed_root = null;
        self.visual_rows_cache = null;

        // Dirty-Flag setzen statt sofort zu parsen.
        // highlightChunked wird im Main-Loop aufgerufen.
        self.edits_fully_tracked = false;
        self.has_dirty_lines = true;
        self.dirty_line_start = 0;
        self.dirty_line_end = self.lineCount();
        // Damit der Background-Parse sofort startet und nicht erst nach 100ms Debounce
        self.last_cursor_movement_ms = -1000.0;

        log.info("highlighter active for '{s}' (background parsing started)", .{file_path});
    }

    /// Re-parse Highlighter, wenn der Rope-Root seit letztem Parse getauscht
    /// wurde. Pro Render-Frame am Anfang aufrufen. tree-sitter liest über
    /// Rope-Callback (`refresh_from_buffer`) — keine Volltext-Kopie.
    ///
    /// Inkrementeller Pfad:
    /// - Wenn alle Edits via `pushEditForChange` gemeldet wurden, wird der
    ///   bestehende Tree inkrementell aktualisiert (schnell).
    /// - Wenn Edits fehlen (z.B. setText, Undo/Redo), wird der Tree verworfen
    ///   und vollständig neu geparst (langsam, aber korrekt).
    pub fn ensureHighlightFresh(self: *Self) void {
        const hl = self.highlighter orelse return;
        if (self.last_parsed_root) |lpr| {
            if (lpr == self.buffer.root) return;
        }

        const was_tracked = self.edits_fully_tracked;
        const dirty_start = self.dirty_line_start;
        const dirty_end = self.dirty_line_end;

        // Wenn Edits nicht vollständig getrackt wurden, muss der Tree verworfen
        // werden (z.B. nach setText oder Undo/Redo ohne korrekte Edit-Events).
        if (!was_tracked) {
            if (self.last_parsed_root != null) {
                std.log.scoped(.highlight).debug("resetTree: edits not fully tracked", .{});
                hl.resetTree();
            }
        } else {
            std.log.scoped(.highlight).debug("incremental reparse: edits tracked", .{});
        }

        const start = std.time.nanoTimestamp();
        hl.reparseFromBuffer(self.buffer.root, self.metrics()) catch |err| {
            std.log.scoped(.highlight).err("reparse failed: {s}", .{@errorName(err)});
            return;
        };
        const end = std.time.nanoTimestamp();
        std.log.scoped(.highlight).debug("synchronous reparse took {d:.3} ms", .{@as(f64, @floatFromInt(end - start)) / 1_000_000.0});
        self.last_parsed_root = self.buffer.root;

        // Cache invalidieren: komplett bei Full-Reparse, sonst nur Dirty-Range.
        if (!was_tracked) {
            hl.invalidateAllLines();
        } else if (self.has_dirty_lines) {
            hl.invalidateLineRange(dirty_start, dirty_end + 1);
        }

        // Nach erfolgreichem Reparse: Dirty-Flags zurücksetzen
        self.edits_fully_tracked = true;
        self.has_dirty_lines = false;
        self.dirty_line_start = 0;
        self.dirty_line_end = 0;
    }

    fn runBackgroundParse(self: *Self, root: flow_core.Buffer.Root, metrics_val: flow_core.Buffer.Metrics) void {
        const bg_hl = self.bg_highlighter orelse return;
        const start = std.time.nanoTimestamp();
        bg_hl.reparseFromBuffer(root, metrics_val) catch |err| {
            self.bg_mutex.lock();
            self.bg_parse_error = err;
            self.bg_mutex.unlock();
        };
        const end = std.time.nanoTimestamp();
        std.log.scoped(.highlight).debug("background reparse took {d:.3} ms", .{@as(f64, @floatFromInt(end - start)) / 1_000_000.0});

        self.bg_mutex.lock();
        self.bg_parsing = false;
        self.bg_mutex.unlock();
    }

    /// Chunked Reparse — jetzt asynchron via Background-Thread.
    /// Gibt `true` zurück wenn noch Arbeit (Parsing) läuft.
    pub fn highlightChunked(self: *Self, max_ms: u64, time_ms: f32) bool {
        _ = max_ms; // Budget wird im Background-Thread ignoriert (da kein UI-Block)

        // 1. Prüfen ob Background-Parse fertig ist
        self.bg_mutex.lock();
        if (self.bg_parse_thread != null and !self.bg_parsing) {
            self.bg_mutex.unlock();

            const swap_start = std.time.nanoTimestamp();
            if (self.bg_parse_thread) |thread| {
                thread.join();
                self.bg_parse_thread = null;
            }

            // Swap highlighters
            if (self.highlighter != null and self.bg_highlighter != null) {
                // ... (rest of swap logic)
                const old_hl = self.highlighter.?;
                self.highlighter = self.bg_highlighter.?;
                self.bg_highlighter = old_hl;

                // Neuer primary hat frischen Tree vom Snapshot-Zeitpunkt,
                // aber ihm fehlen die Edits, die WÄHREND des Parsens passiert sind.
                // -> Catch up!
                self.bg_mutex.lock();
                for (self.bg_queued_edits.items) |ed| {
                    self.highlighter.?.pushEdit(ed);
                }
                self.bg_queued_edits.clearRetainingCapacity();

                // Cache für alle Zeilen invalidieren, da der Tree nun ein anderer ist
                self.highlighter.?.invalidateAllLines();

                self.last_parsed_root = self.bg_snapshot_root;
                self.has_dirty_lines = (self.last_parsed_root != self.buffer.root);
                if (self.has_dirty_lines) {
                    std.log.scoped(.highlight).debug("STILL DIRTY after swap (more edits arrived): last={*} current={*}", .{ self.last_parsed_root, self.buffer.root });
                }
                self.bg_mutex.unlock();

                const swap_end = std.time.nanoTimestamp();
                std.log.scoped(.highlight).debug("background reparse swapped in {d:.3} ms", .{@as(f64, @floatFromInt(swap_end - swap_start)) / 1_000_000.0});
            } else {
                self.bg_mutex.lock();
                self.bg_queued_edits.clearRetainingCapacity();
                self.bg_mutex.unlock();
            }
            return self.has_dirty_lines;
        }
        self.bg_mutex.unlock();

        // Wenn gerade ein Parse läuft: Main-Loop informieren (für wio.wait Timeout)
        if (self.bg_parsing) return true;
        if (!self.has_dirty_lines) return false;

        // 2. Debounce: Nur parsen wenn seit 100ms keine Edits mehr kamen.
        // Wichtig: `true` zurueckgeben damit main-loop in 16ms-Poll bleibt,
        // sonst schlaeft `wio.wait(.{})` bis zum naechsten Input-Event und
        // der Parse startet erst beim naechsten Tastendruck (→ 600ms Delay).
        const idle_ms = time_ms - self.last_cursor_movement_ms;
        if (idle_ms < 100 and !self.edits_fully_tracked) {
            return true;
        }

        // 3. Prüfen ob Reparse nötig
        if (self.last_parsed_root) |lpr| {
            if (lpr == self.buffer.root) {
                self.has_dirty_lines = false;
                return false;
            }
        }

        // 4. Background-Parse starten
        const hl = self.highlighter orelse return false;
        std.log.scoped(.highlight).debug("starting background parse: has_dirty={any} tracked={any} root={*} last={*}", .{ self.has_dirty_lines, self.edits_fully_tracked, self.buffer.root, self.last_parsed_root });

        // Wenn Edits fehlen: resetTree() nötig
        if (!self.edits_fully_tracked) {
            hl.resetTree();
            if (self.bg_highlighter) |bg| bg.resetTree();
            self.edits_fully_tracked = true;
        }

        self.bg_mutex.lock();
        self.bg_parsing = true;
        self.bg_snapshot_root = self.buffer.root;
        self.bg_parse_error = null;
        self.bg_mutex.unlock();

        self.bg_parse_thread = std.Thread.spawn(.{}, runBackgroundParse, .{ self, self.bg_snapshot_root.?, self.metrics() }) catch |err| {
            std.log.scoped(.highlight).err("failed to spawn bg parse thread: {s}", .{@errorName(err)});
            self.bg_mutex.lock();
            self.bg_parsing = false;
            self.bg_mutex.unlock();
            return false;
        };

        return true;
    }

    /// Get a single line via rope. Returned slice points into `line_scratch`
    /// and is invalidated by the next getLine call. Dupe into arena if needed.
    fn getLine(self: *Self, line_idx: usize) []const u8 {
        self.line_scratch.clearRetainingCapacity();
        self.buffer.root.get_line(line_idx, &self.line_scratch.writer, self.metrics()) catch {};
        return self.line_scratch.written();
    }

    /// Total number of lines
    pub fn lineCount(self: *const Self) usize {
        return self.buffer.root.lines();
    }

    /// Get line width in display columns
    fn lineWidth(self: *const Self, line_idx: usize) usize {
        return self.buffer.root.line_width(line_idx, self.metrics()) catch 0;
    }

    pub fn setText(self: *Self, text: []const u8) void {
        std.log.scoped(.editor).info("setText called (len={d})", .{text.len});
        self.longest_valid = false;
        // Alten Highlighter wegwerfen — setLanguageFromPath setzt danach neu.
        self.destroyHighlighter();
        var eol_mode: flow_core.Buffer.EolMode = .lf;
        var utf8_sanitized: bool = false;
        const new_root = self.buffer.load_from_string(text, &eol_mode, &utf8_sanitized) catch {
            // Fallback: empty buffer
            self.buffer.root = self.buffer.load_from_string("", &self.buffer.file_eol_mode, &self.buffer.file_utf8_sanitized) catch @panic("OOM");
            self.cursor = .{};
            self.selection_anchor = null;
            self.edits_fully_tracked = false;
            return;
        };
        self.buffer.root = new_root;
        self.buffer.file_eol_mode = eol_mode;
        self.buffer.file_utf8_sanitized = utf8_sanitized;
        // flow-core gibt beim Laden die Leaf-Puffer des alten Baums frei; alle Undo-/Redo-Einträge
        // zeigen noch dorthin und wären nach einem Undo "switch on corrupt value". Verlauf verwerfen
        // und die laufende Tipp-Gruppe beenden, damit der nächste Tastendruck wieder einen Snapshot legt.
        self.buffer.undo_head = null;
        self.buffer.redo_head = null;
        self.typing_in_progress = false;
        self.clearExtraCursors();

        self.cursor = .{};
        self.selection_anchor = null;

        // setText ersetzt den gesamten Inhalt -> Edits können nicht getrackt werden
        // -> ensureHighlightFresh muss resetTree() aufrufen
        self.edits_fully_tracked = false;
        self.has_dirty_lines = true;
        self.dirty_line_start = 0;
        self.dirty_line_end = self.lineCount();
    }

    fn recordCursorMovement(self: *Self) void {
        self.last_cursor_movement_ms = self.time_ms;
        self.ensureCursorVisible();
    }

    // =========================================================================
    // tree-sitter inkrementelles Edit-Tracking
    // =========================================================================

    /// Melde eine Änderung an den Syntax-Highlighter für inkrementelles Reparse.
    /// MUSS vor der eigentlichen Buffer-Änderung aufgerufen werden.
    ///
    /// `row`, `col` = Position VOR der Änderung (Beginn der Änderung).
    /// `old_text` = Text der gelöscht wird ("" bei reinem Insert).
    /// `new_text` = Text der eingefügt wird ("" bei reinem Delete).
    fn pushEditForChange(self: *Self, row: usize, col: usize, old_text: []const u8, new_text: []const u8) void {
        self.is_modified = true;
        self.last_edit_ms = self.time_ms;
        const old_line_count = std.mem.count(u8, old_text, "\n");
        const new_line_count = std.mem.count(u8, new_text, "\n");
        self.noteLineChange(row, old_line_count, new_line_count);
        const hl = self.highlighter orelse return;
        const m = self.metrics();
        const line_start = self.buffer.root.line_start_byte(row, m);
        const col_byte: usize = self.buffer.root.get_line_width_to_pos(row, col, m) catch return;

        const start_byte = line_start + col_byte;
        const old_end_byte = start_byte + old_text.len;
        const new_end_byte = start_byte + new_text.len;

        const old_end_row: u32 = @intCast(row + old_line_count);
        const new_end_row: u32 = @intCast(row + new_line_count);

        // tree-sitter-Punkte sind Byte-Spalten, `col` ist eine Zeichenspalte
        const old_end_col: u32 = if (old_line_count == 0)
            @intCast(col_byte + old_text.len)
        else
            @intCast(old_text.len - std.mem.lastIndexOf(u8, old_text, "\n").? - 1);

        const new_end_col: u32 = if (new_line_count == 0)
            @intCast(col_byte + new_text.len)
        else
            @intCast(new_text.len - std.mem.lastIndexOf(u8, new_text, "\n").? - 1);

        const ed: syntax.Edit = .{
            .start_byte = @intCast(start_byte),
            .old_end_byte = @intCast(old_end_byte),
            .new_end_byte = @intCast(new_end_byte),
            .start_point = .{ .row = @intCast(row), .column = @intCast(col_byte) },
            .old_end_point = .{ .row = old_end_row, .column = old_end_col },
            .new_end_point = .{ .row = new_end_row, .column = new_end_col },
        };

        // Always apply to primary highlighter
        hl.pushEdit(ed);

        // Apply to background highlighter or queue if busy
        self.bg_mutex.lock();
        defer self.bg_mutex.unlock();

        if (self.bg_parsing) {
            self.bg_queued_edits.append(self.allocator, ed) catch {};
        } else if (self.bg_highlighter) |bg_hl| {
            bg_hl.pushEdit(ed);
        }

        const affected_start = row;
        const affected_end = row + @max(old_line_count, new_line_count);
        self.markDirty(affected_start, affected_end);
    }

    // =========================================================================
    // UTF-8 Navigation Helpers (adapted for buffer text)
    // =========================================================================

    fn prevCharBoundary(text: []const u8, pos_: usize) usize {
        const pos = @min(pos_, text.len);
        if (pos == 0) return 0;
        var i = pos - 1;
        while (i > 0 and (text[i] & 0xC0) == 0x80) {
            i -= 1;
        }
        return i;
    }

    fn nextCharBoundary(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var i = pos + 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) {
            i += 1;
        }
        return i;
    }

    fn snapToCharBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        if (pos >= text.len) return text.len;
        if ((text[pos] & 0xC0) != 0x80) return pos;
        return prevCharBoundary(text, pos);
    }

    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn prevWordBoundary(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos;
        while (i > 0) {
            const prev = prevCharBoundary(text, i);
            if (!std.ascii.isWhitespace(text[prev])) break;
            i = prev;
        }
        if (i == 0) return 0;
        const start_is_word = isWordChar(text[prevCharBoundary(text, i)]);
        while (i > 0) {
            const prev = prevCharBoundary(text, i);
            if (isWordChar(text[prev]) != start_is_word or std.ascii.isWhitespace(text[prev])) break;
            i = prev;
        }
        return i;
    }

    fn nextWordBoundary(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        var i = pos;
        if (std.ascii.isWhitespace(text[i])) {
            while (i < text.len and std.ascii.isWhitespace(text[i])) {
                i = nextCharBoundary(text, i);
            }
        } else {
            const start_is_word = isWordChar(text[i]);
            while (i < text.len) {
                if (isWordChar(text[i]) != start_is_word or std.ascii.isWhitespace(text[i])) break;
                i = nextCharBoundary(text, i);
            }
        }
        return i;
    }

    // =========================================================================
    // Selection Helpers
    // =========================================================================

    pub fn hasSelection(self: *const Self) bool {
        if (self.selection_anchor) |anchor| {
            return !anchor.eql(self.cursor);
        }
        return false;
    }

    fn clearSelection(self: *Self) void {
        self.selection_anchor = null;
    }

    fn startSelection(self: *Self) void {
        self.selection_anchor = self.cursor;
    }

    pub fn selectionRange(self: *const Self) ?flow_core.Selection {
        if (!self.hasSelection()) return null;
        const anchor = self.selection_anchor.?;
        return .{ .begin = if (anchor.row < self.cursor.row or (anchor.row == self.cursor.row and anchor.col < self.cursor.col)) anchor else self.cursor, .end = if (anchor.row < self.cursor.row or (anchor.row == self.cursor.row and anchor.col < self.cursor.col)) self.cursor else anchor };
    }

    pub fn getSelectedText(self: *const Self, alloc: std.mem.Allocator) !?[]u8 {
        _ = alloc;
        const range = self.selectionRange() orelse return null;
        const text = try self.getTextInRange(range);
        if (text.len == 0) {
            self.allocator.free(text);
            return null;
        }
        return text;
    }

    pub fn getTextInRange(self: *const Self, range: flow_core.Selection) ![]u8 {
        var sel_list = std.ArrayListUnmanaged(u8){};
        errdefer sel_list.deinit(self.allocator);

        var writer = ArrayListWriter(std.mem.Allocator.Error).init(self.allocator, &sel_list);
        self.buffer.root.write_range(range, &writer, null, self.metrics()) catch return error.WriteFailed;

        if (sel_list.items.len == 0) {
            sel_list.deinit(self.allocator);
            return "";
        }
        const owned = try sel_list.toOwnedSlice(self.allocator);
        return owned;
    }

    /// Insert a string at the current cursor position.
    pub fn insertString(self: *Self, text: []const u8) !void {
        if (text.len == 0) return;

        // Delete selection first
        if (self.hasSelection()) {
            const range = self.selectionRange().?;
            const m = self.metrics();
            // pushEdit für Delete der Selection
            const sel_text = self.getTextInRange(range) catch "";
            defer if (sel_text.len > 0 and sel_text.ptr != "".ptr) self.allocator.free(sel_text);

            self.pushEditForChange(range.begin.row, range.begin.col, sel_text, "");
            const new_root = self.buffer.root.delete_range(range, self.buffer.allocator, null, m) catch return error.Stop;
            self.buffer.root = new_root;
            self.cursor = range.begin;
            self.clearSelection();
        }

        // pushEdit für Insert
        const insert_row = self.cursor.row;
        const insert_col = self.cursor.col;
        self.pushEditForChange(insert_row, insert_col, "", text);

        // Insert chars at cursor
        const m = self.metrics();
        const result = self.buffer.root.insert_chars(
            self.cursor.row,
            self.cursor.col,
            text,
            self.buffer.allocator,
            m,
        ) catch return error.Stop;
        self.buffer.root = result[2];
        self.cursor.row = result[0];
        self.cursor.col = result[1];
        self.cursor.target = result[1];

        // Re-tokenize affected lines
        // self.retokenizeAround(self.cursor.row);

        self.last_cursor_movement_ms = self.time_ms;
    }

    /// Aktionen, die mit mehreren Cursorn je Cursor ausgeführt werden (kein Zeilenumbruch,
    /// keine Zeilenoperationen: die würden die Positionen der anderen Cursor verschieben).
    fn multiSafe(action: actions.Action) bool {
        return switch (action) {
            .MoveLeft, .MoveRight, .MoveUp, .MoveDown, .MoveWordLeft, .MoveWordRight, .MoveLineStart, .MoveLineEnd, .SelectLeft, .SelectRight, .SelectUp, .SelectDown, .SelectWordLeft, .SelectWordRight, .SelectLineStart, .SelectLineEnd, .DeleteBack, .DeleteForward, .DeleteWordBack, .DeleteWordForward, .InsertTab => true,
            else => false,
        };
    }

    pub fn dispatchAction(self: *Self, action: actions.Action) void {
        switch (action) {
            .SelectNextOccurrence => return self.selectNextOccurrence(),
            .AddCursorAbove => return self.addCursorVertical(false),
            .AddCursorBelow => return self.addCursorVertical(true),
            else => {},
        }
        if (self.extra_cursors.items.len == 0) return self.dispatchSingle(action);
        if (!multiSafe(action)) {
            self.clearExtraCursors();
            return self.dispatchSingle(action);
        }
        switch (action) {
            .DeleteBack, .DeleteForward, .DeleteWordBack, .DeleteWordForward, .InsertTab => {
                self.typing_in_progress = false;
                self.snapshotForUndo();
            },
            else => {},
        }
        self.in_multi = true;
        defer self.in_multi = false;
        self.forEachCursor(action, null);
    }

    pub fn clearExtraCursors(self: *Self) void {
        self.extra_cursors.clearRetainingCapacity();
    }

    fn cursorLess(_: void, a: ExtraCursor, b: ExtraCursor) bool {
        if (a.cursor.row != b.cursor.row) return a.cursor.row > b.cursor.row;
        return a.cursor.col > b.cursor.col;
    }

    /// Aktion (oder Zeichen) je Cursor von unten nach oben ausführen, damit Änderungen die
    /// Positionen der noch nicht bearbeiteten Cursor nicht verschieben. Cursor, die danach
    /// zusammenfallen, werden verschmolzen.
    fn forEachCursor(self: *Self, action: ?actions.Action, char_code: ?u21) void {
        var all: std.ArrayListUnmanaged(ExtraCursor) = .empty;
        defer all.deinit(self.allocator);
        all.append(self.allocator, .{ .cursor = self.cursor, .anchor = self.selection_anchor }) catch return;
        all.appendSlice(self.allocator, self.extra_cursors.items) catch return;
        std.sort.pdq(ExtraCursor, all.items, {}, cursorLess);
        for (all.items, 0..) |*c, idx| {
            self.cursor = c.cursor;
            self.selection_anchor = c.anchor;
            const row0 = self.cursor.row;
            const w0: isize = @intCast(self.lineWidth(row0));
            const n0: isize = @intCast(self.lineCount());
            if (action) |a| self.dispatchSingle(a);
            if (char_code) |cp| self.handleCharSingle(cp);
            c.cursor = self.cursor;
            c.anchor = self.selection_anchor;
            // Schon bearbeitete Cursor (rechts bzw. unterhalb) an die Änderung anpassen:
            // gleiche Zeile → Spalten um die Breitenänderung, Zeilen verschmolzen/geteilt → Zeilen
            const dw: isize = @as(isize, @intCast(self.lineWidth(@min(row0, self.lineCount() - 1)))) - w0;
            const dn: isize = @as(isize, @intCast(self.lineCount())) - n0;
            for (all.items[0..idx]) |*done| {
                if (done.cursor.row == row0 and dn == 0) {
                    done.cursor.col = @intCast(@max(0, @as(isize, @intCast(done.cursor.col)) + dw));
                    done.cursor.target = done.cursor.col;
                    if (done.anchor) |*a| {
                        if (a.row == row0) a.col = @intCast(@max(0, @as(isize, @intCast(a.col)) + dw));
                    }
                } else if (done.cursor.row > row0 and dn != 0) {
                    done.cursor.row = @intCast(@max(0, @as(isize, @intCast(done.cursor.row)) + dn));
                    if (done.anchor) |*a| a.row = @intCast(@max(0, @as(isize, @intCast(a.row)) + dn));
                }
            }
        }
        // Erster Eintrag (unterster) wird Hauptcursor, Rest extra; Duplikate verschmelzen
        self.extra_cursors.clearRetainingCapacity();
        self.cursor = all.items[0].cursor;
        self.selection_anchor = all.items[0].anchor;
        var i: usize = 1;
        while (i < all.items.len) : (i += 1) {
            const c = all.items[i];
            const prev = all.items[i - 1];
            if (c.cursor.row == prev.cursor.row and c.cursor.col == prev.cursor.col) continue;
            self.extra_cursors.append(self.allocator, c) catch {};
        }
    }

    /// Ctrl+D: ohne Auswahl das Wort am Cursor markieren; mit Auswahl das nächste Vorkommen
    /// (Groß/Klein exakt) als weiteren Cursor mit Auswahl hinzufügen.
    pub fn selectNextOccurrence(self: *Self) void {
        const m = self.metrics();
        if (!self.hasSelection()) {
            const line = self.getLine(self.cursor.row);
            const byte = @min(self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch line.len, line.len);
            var ws = byte;
            while (ws > 0 and isWordChar(line[ws - 1])) : (ws -= 1) {}
            var we = byte;
            while (we < line.len and isWordChar(line[we])) : (we += 1) {}
            if (ws == we) return;
            const c0 = self.buffer.root.pos_to_width(self.cursor.row, ws, m) catch return;
            const c1 = self.buffer.root.pos_to_width(self.cursor.row, we, m) catch return;
            self.selection_anchor = .{ .row = self.cursor.row, .col = c0, .target = c0 };
            self.cursor = .{ .row = self.cursor.row, .col = c1, .target = c1 };
            return;
        }
        const range = self.selectionRange() orelse return;
        if (range.begin.row != range.end.row) return;
        const needle = self.getTextInRange(range) catch return;
        defer if (needle.len > 0) self.allocator.free(needle);
        if (needle.len == 0) return;
        // Ab dem untersten Cursor weitersuchen
        var from: find_ops.Pos = .{ .row = self.cursor.row, .col = self.cursor.col };
        for (self.extra_cursors.items) |ec| {
            if (ec.cursor.row > from.row or (ec.cursor.row == from.row and ec.cursor.col > from.col)) from = .{ .row = ec.cursor.row, .col = ec.cursor.col };
        }
        const Finder = find_ops.Finder(LineSource);
        var tries: usize = 0;
        while (tries < 4) : (tries += 1) {
            const mm = Finder.findOpts(.{ .ed = self }, needle, from, true, .{ .case_sensitive = true }) orelse return;
            var taken = (mm.begin.row == range.begin.row and mm.begin.col == range.begin.col);
            for (self.extra_cursors.items) |ec| {
                if (ec.anchor) |a| {
                    if (a.row == mm.begin.row and a.col == mm.begin.col) taken = true;
                }
            }
            if (!taken) {
                self.extra_cursors.append(self.allocator, .{
                    .cursor = .{ .row = mm.end.row, .col = mm.end.col, .target = mm.end.col },
                    .anchor = .{ .row = mm.begin.row, .col = mm.begin.col, .target = mm.begin.col },
                }) catch {};
                return;
            }
            from = .{ .row = mm.begin.row, .col = mm.begin.col };
        }
    }

    /// Ctrl+Alt+↑/↓: Cursor in der Zeile über dem obersten / unter dem untersten Cursor.
    pub fn addCursorVertical(self: *Self, down: bool) void {
        var base = self.cursor;
        for (self.extra_cursors.items) |ec| {
            if (down and ec.cursor.row > base.row) base = ec.cursor;
            if (!down and ec.cursor.row < base.row) base = ec.cursor;
        }
        if (down and base.row + 1 >= self.lineCount()) return;
        if (!down and base.row == 0) return;
        const row = if (down) base.row + 1 else base.row - 1;
        const col = @min(base.target, self.lineWidth(row));
        self.extra_cursors.append(self.allocator, .{ .cursor = .{ .row = row, .col = col, .target = base.target }, .anchor = null }) catch {};
    }

    fn dispatchSingle(self: *Self, action: actions.Action) void {
        if (!self.in_multi) switch (action) {
            .InsertNewline, .InsertTab, .DeleteBack, .DeleteForward, .DeleteWordBack, .DeleteWordForward, .DeleteLine, .Cut, .Paste, .IndentLines, .OutdentLines, .ToggleComment, .MoveLineUp, .MoveLineDown, .DuplicateLine => {
                self.typing_in_progress = false;
                self.snapshotForUndo();
            },
            else => {},
        };

        const m = self.metrics();
        const line_count = self.lineCount();

        switch (action) {
            .MoveLeft => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.begin;
                    self.clearSelection();
                } else {
                    self.cursor.move_left(self.buffer.root, m) catch {};
                }
            },
            .MoveRight => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.end;
                    self.clearSelection();
                } else {
                    self.cursor.move_right(self.buffer.root, m) catch {};
                }
            },
            .MoveUp => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.begin;
                    self.clearSelection();
                } else {
                    self.cursor.move_up(self.buffer.root, m) catch {};
                }
            },
            .MoveDown => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.end;
                    self.clearSelection();
                } else {
                    self.cursor.move_down(self.buffer.root, m) catch {};
                }
            },
            .MoveWordLeft => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.begin;
                    self.clearSelection();
                } else {
                    // Manual word-left using line text
                    const line_text = self.getLine(self.cursor.row);
                    if (self.cursor.col > 0) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = prevWordBoundary(line_text, byte_pos);
                        self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch 0;
                    } else if (self.cursor.row > 0) {
                        self.cursor.row -= 1;
                        self.cursor.col = self.lineWidth(self.cursor.row);
                    }
                }
            },
            .MoveWordRight => {
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    self.cursor = range.end;
                    self.clearSelection();
                } else {
                    const line_text = self.getLine(self.cursor.row);
                    const line_w = self.lineWidth(self.cursor.row);
                    if (self.cursor.col < line_w) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = nextWordBoundary(line_text, byte_pos);
                        self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch line_w;
                    } else if (self.cursor.row + 1 < line_count) {
                        self.cursor.row += 1;
                        self.cursor.col = 0;
                    }
                }
            },
            .SelectLeft => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_left(self.buffer.root, m) catch {};
            },
            .SelectRight => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_right(self.buffer.root, m) catch {};
            },
            .SelectUp => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_up(self.buffer.root, m) catch {};
            },
            .SelectDown => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_down(self.buffer.root, m) catch {};
            },
            .SelectWordLeft => {
                if (!self.hasSelection()) self.startSelection();
                const line_text = self.getLine(self.cursor.row);
                if (self.cursor.col > 0) {
                    const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                    const new_byte_pos = prevWordBoundary(line_text, byte_pos);
                    self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch 0;
                } else if (self.cursor.row > 0) {
                    self.cursor.row -= 1;
                    self.cursor.col = self.lineWidth(self.cursor.row);
                }
            },
            .SelectWordRight => {
                if (!self.hasSelection()) self.startSelection();
                const line_text = self.getLine(self.cursor.row);
                const line_w = self.lineWidth(self.cursor.row);
                if (self.cursor.col < line_w) {
                    const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                    const new_byte_pos = nextWordBoundary(line_text, byte_pos);
                    self.cursor.col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch line_w;
                } else if (self.cursor.row + 1 < line_count) {
                    self.cursor.row += 1;
                    self.cursor.col = 0;
                }
            },
            .MoveLineStart => {
                self.cursor.move_begin();
            },
            .MoveLineEnd => {
                self.cursor.move_end(self.buffer.root, m);
            },
            .SelectLineStart => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_begin();
            },
            .SelectLineEnd => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_end(self.buffer.root, m);
            },
            .MoveFileStart => {
                self.clearSelection();
                self.cursor.move_buffer_begin();
            },
            .MoveFileEnd => {
                self.clearSelection();
                self.cursor.move_buffer_end(self.buffer.root, m);
            },
            .SelectFileStart => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_buffer_begin();
            },
            .SelectFileEnd => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_buffer_end(self.buffer.root, m);
            },
            .MovePageUp => {
                if (self.hasSelection()) {
                    self.cursor.move_page_up(self.buffer.root, &self.view, m);
                    self.clearSelection();
                } else {
                    self.cursor.move_page_up(self.buffer.root, &self.view, m);
                }
            },
            .MovePageDown => {
                if (self.hasSelection()) {
                    self.cursor.move_page_down(self.buffer.root, &self.view, m);
                    self.clearSelection();
                } else {
                    self.cursor.move_page_down(self.buffer.root, &self.view, m);
                }
            },
            .SelectPageUp => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_page_up(self.buffer.root, &self.view, m);
            },
            .SelectPageDown => {
                if (!self.hasSelection()) self.startSelection();
                self.cursor.move_page_down(self.buffer.root, &self.view, m);
            },
            .DeleteBack => {
                if (!self.deleteSelection()) {
                    if (self.cursor.col == 0 and self.cursor.row > 0) {
                        const prev_row = self.cursor.row - 1;
                        const prev_len = self.lineWidth(prev_row);
                        self.pushEditForChange(prev_row, prev_len, "\n", "");
                        const sel: flow_core.Selection = .{
                            .begin = .{ .row = prev_row, .col = prev_len },
                            .end = .{ .row = self.cursor.row, .col = 0 },
                        };
                        const result = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                        self.buffer.root = result;
                        self.cursor.row = prev_row;
                        self.cursor.col = prev_len;
                    } else if (self.cursor.col > 0) {
                        const line_text = self.getLine(self.cursor.row);
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const char_start = prevCharBoundary(line_text, byte_pos);
                        const char_bytes = byte_pos - char_start;
                        // Backspace zwischen () [] {} "" '' `` löscht das Paar
                        const prev_b: ?u8 = if (byte_pos > 0) line_text[byte_pos - 1] else null;
                        const next_b: ?u8 = if (byte_pos < line_text.len) line_text[byte_pos] else null;
                        if (char_bytes == 1 and edit_ops.deletesPair(prev_b, next_b)) {
                            const pair_text = self.allocator.dupe(u8, line_text[byte_pos - 1 .. byte_pos + 1]) catch return;
                            defer self.allocator.free(pair_text);
                            self.pushEditForChange(self.cursor.row, self.cursor.col - 1, pair_text, "");
                            const sel: flow_core.Selection = .{
                                .begin = .{ .row = self.cursor.row, .col = self.cursor.col - 1 },
                                .end = .{ .row = self.cursor.row, .col = self.cursor.col + 1 },
                            };
                            const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                            self.buffer.root = result2;
                            self.cursor.col -= 1;
                            self.cursor.target = self.cursor.col;
                        } else if (char_bytes > 0) {
                            const del_text = self.allocator.dupe(u8, line_text[char_start..byte_pos]) catch return;
                            defer self.allocator.free(del_text);
                            const del_row = self.cursor.row;
                            const del_col = self.cursor.col - 1;
                            self.pushEditForChange(del_row, del_col, del_text, "");
                            const sel: flow_core.Selection = .{
                                .begin = .{ .row = self.cursor.row, .col = self.cursor.col - 1 },
                                .end = self.cursor,
                            };
                            const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                            self.buffer.root = result2;
                            self.cursor.col -= 1;
                            self.cursor.target = self.cursor.col;
                        }
                    }
                }
            },
            .DeleteForward => {
                if (!self.deleteSelection()) {
                    const line_w = self.lineWidth(self.cursor.row);
                    if (self.cursor.col < line_w) {
                        const sel: flow_core.Selection = .{
                            .begin = self.cursor,
                            .end = .{ .row = self.cursor.row, .col = self.cursor.col + 1 },
                        };
                        const del_text = self.getTextInRange(sel) catch "";
                        defer if (del_text.len > 0) self.allocator.free(del_text);
                        self.pushEditForChange(self.cursor.row, self.cursor.col, del_text, "");
                        const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                        self.buffer.root = result2;
                    } else if (self.cursor.row + 1 < line_count) {
                        self.pushEditForChange(self.cursor.row, self.cursor.col, "\n", "");
                        const sel: flow_core.Selection = .{
                            .begin = self.cursor,
                            .end = .{ .row = self.cursor.row + 1, .col = 0 },
                        };
                        const result = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                        self.buffer.root = result;
                    }
                }
            },
            .DeleteWordBack => {
                if (!self.deleteSelection()) {
                    const line_text = self.getLine(self.cursor.row);
                    if (self.cursor.col > 0) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = prevWordBoundary(line_text, byte_pos);
                        const new_col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch 0;
                        if (new_col < self.cursor.col) {
                            const sel: flow_core.Selection = .{
                                .begin = .{ .row = self.cursor.row, .col = new_col },
                                .end = self.cursor,
                            };
                            const del_text = self.getTextInRange(sel) catch "";
                            defer if (del_text.len > 0) self.allocator.free(del_text);
                            self.pushEditForChange(self.cursor.row, new_col, del_text, "");
                            const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                            self.buffer.root = result2;
                            self.cursor.col = new_col;
                            self.cursor.target = new_col;
                        }
                    } else if (self.cursor.row > 0) {
                        self.dispatchAction(.DeleteBack);
                        return;
                    }
                }
            },
            .DeleteWordForward => {
                if (!self.deleteSelection()) {
                    const line_text = self.getLine(self.cursor.row);
                    const line_w = self.lineWidth(self.cursor.row);
                    if (self.cursor.col < line_w) {
                        const byte_pos = self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch 0;
                        const new_byte_pos = nextWordBoundary(line_text, byte_pos);
                        const new_col = self.buffer.root.pos_to_width(self.cursor.row, new_byte_pos, m) catch line_w;
                        if (new_col > self.cursor.col) {
                            const sel: flow_core.Selection = .{
                                .begin = self.cursor,
                                .end = .{ .row = self.cursor.row, .col = new_col },
                            };
                            const del_text = self.getTextInRange(sel) catch "";
                            defer if (del_text.len > 0) self.allocator.free(del_text);
                            self.pushEditForChange(self.cursor.row, self.cursor.col, del_text, "");
                            const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                            self.buffer.root = result2;
                        }
                    } else if (self.cursor.row + 1 < line_count) {
                        self.dispatchAction(.DeleteForward);
                        return;
                    }
                }
            },
            .DeleteLine => {
                // Letzte Zeile hat keinen eigenen Umbruch: dann den davor mitnehmen,
                // sonst bliebe eine leere Zeile stehen (VS-Code-Verhalten).
                const row = self.cursor.row;
                const joins_previous = row + 1 >= line_count and row > 0;
                const sel: flow_core.Selection = if (joins_previous) .{
                    .begin = .{ .row = row - 1, .col = self.lineWidth(row - 1) },
                    .end = .{ .row = row, .col = self.lineWidth(row) },
                } else .{
                    .begin = .{ .row = row, .col = 0 },
                    .end = .{ .row = row, .col = self.lineWidth(row) + 1 },
                };
                const del_text = self.getTextInRange(sel) catch "";
                defer if (del_text.len > 0) self.allocator.free(del_text);
                self.pushEditForChange(sel.begin.row, sel.begin.col, del_text, "");
                const result2 = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
                self.buffer.root = result2;
                if (joins_previous) self.cursor.row = row - 1;
                self.cursor.col = 0;
                self.cursor.target = 0;
            },
            .InsertNewline => {
                if (self.deleteSelection()) {}
                // Auto-Indent: Einrückung der Zeile, nach { ( [ eine Stufe mehr, Klammerpaar aufspannen
                const line_text = self.getLine(self.cursor.row);
                const cursor_byte = @min(self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch line_text.len, line_text.len);
                const ins = edit_ops.newlineInsertion(self.allocator, line_text, cursor_byte) catch return;
                defer self.allocator.free(ins.text);
                self.insertString(ins.text) catch return;
                if (ins.rows_back > 0) {
                    self.cursor.row -= ins.rows_back;
                    self.cursor.col = self.lineWidth(self.cursor.row);
                    self.cursor.target = self.cursor.col;
                }
            },
            .IndentLines => self.indentSelection(false),
            .OutdentLines => self.indentSelection(true),
            .ToggleComment => self.toggleComment(),
            .MoveLineUp => self.moveLines(false),
            .MoveLineDown => self.moveLines(true),
            .DuplicateLine => self.duplicateLines(),
            .GotoLine => self.openGoto(),
            .Replace => self.openReplace(),
            .GotoDefinition => self.gotoDefinition(self.cursor.row, self.cursor.col),
            .SelectNextOccurrence, .AddCursorAbove, .AddCursorBelow => {}, // im Wrapper dispatchAction behandelt
            .InsertTab => {
                // Mehrzeilige Auswahl: Zeilen einrücken statt Text ersetzen
                if (self.selectionRange()) |r| {
                    if (r.end.row > r.begin.row) {
                        self.indentSelection(false);
                        return;
                    }
                }
                if (self.deleteSelection()) {}
                const ins_row = self.cursor.row;
                const ins_col = self.cursor.col;
                self.pushEditForChange(ins_row, ins_col, "", "    ");
                const result = self.buffer.root.insert_chars(
                    self.cursor.row,
                    self.cursor.col,
                    "    ",
                    self.buffer.allocator,
                    m,
                ) catch return;
                self.buffer.root = result[2];
                self.cursor.col += 4;
                self.cursor.target = self.cursor.col;
            },
            .SelectAll => {
                self.selection_anchor = .{ .row = 0, .col = 0 };
                self.cursor.row = line_count - 1;
                self.cursor.col = self.lineWidth(self.cursor.row);
                self.cursor.target = self.cursor.col;
            },
            .ScrollUp => {
                self.scrollLines(1);
            },
            .ScrollDown => {
                self.scrollLines(-1);
            },
            .Copy => {
                if (self.getSelectedText(self.allocator)) |text_opt| {
                    if (text_opt) |text| {
                        defer self.allocator.free(text);
                        if (self.window) |win| {
                            win.setClipboardText(text);
                        }
                    }
                } else |err| {
                    std.log.err("Failed to copy text: {}", .{err});
                }
            },
            .Cut => {
                if (self.getSelectedText(self.allocator)) |text_opt| {
                    if (text_opt) |text| {
                        defer self.allocator.free(text);
                        if (self.window) |win| {
                            win.setClipboardText(text);
                        }
                        _ = self.deleteSelection();
                    } else {
                        // Ohne Auswahl schneidet Ctrl+X die ganze Zeile aus (VS Code, Zed).
                        const row = self.cursor.row;
                        const line_text = self.getTextInRange(.{
                            .begin = .{ .row = row, .col = 0 },
                            .end = .{ .row = row, .col = self.lineWidth(row) },
                        }) catch "";
                        defer if (line_text.len > 0) self.allocator.free(line_text);
                        if (self.window) |win| {
                            const with_eol = std.mem.concat(self.allocator, u8, &.{ line_text, "\n" }) catch line_text;
                            defer if (with_eol.ptr != line_text.ptr) self.allocator.free(with_eol);
                            win.setClipboardText(with_eol);
                        }
                        self.dispatchAction(.DeleteLine);
                    }
                } else |err| {
                    std.log.err("Failed to cut text: {}", .{err});
                }
            },
            .Paste => {
                // Try window clipboard first
                if (self.window) |win| {
                    if (win.getClipboardText(self.allocator)) |text| {
                        defer self.allocator.free(text);
                        self.insertString(text) catch |err| {
                            std.log.err("Failed to paste text: {}", .{err});
                        };
                    }
                }
            },
            .ShowContextMenu => {
                self.show_context_menu = true;
                self.context_menu_x = self.mouse_x;
                self.context_menu_y = self.mouse_y;
            },
            .Undo => {
                std.log.info("Undo: attempting buffer.undo()", .{});
                const meta = self.buffer.undo() catch |err| {
                    std.log.debug("Undo: nichts mehr rückgängig zu machen ({})", .{err});
                    return;
                };
                self.afterUndoRedo(meta);
                return;
            },
            .Redo => {
                const meta = self.buffer.redo() catch return;
                self.afterUndoRedo(meta);
                return;
            },
            .MdPreview => {
                self.pending_md_preview = true;
            },
            .MdExportPdf => {
                self.pending_md_export_pdf = true;
            },
            .FileHistory => {
                self.pending_file_history = true;
            },
            .Search => self.openFind(),
            .SplitVertical => {
                self.pending_split_v = true;
            },
            .SplitHorizontal => {
                self.pending_split_h = true;
            },
            .Save => {
                self.save() catch |err| {
                    std.log.scoped(.editor).err("Failed to save file: {}", .{err});
                    self.setError("Cannot save '{s}': {s}", .{ std.fs.path.basename(self.buffer.get_file_path()), @errorName(err) });
                };
            },
        }
        self.recordCursorMovement();
        self.current_line = self.cursor.row + 1;
    }

    /// Delete selected text. Returns true if text was deleted.
    fn deleteSelection(self: *Self) bool {
        // Jede Eingabe hebt den Anker auf. Ein Klick setzt Anker = Cursor; blieb er
        // stehen, "markierte" das erste getippte Zeichen sich selbst und das zweite
        // ersetzte es ("abc" wurde "bc").
        defer self.selection_anchor = null;
        if (!self.hasSelection()) return false;
        const range = self.selectionRange() orelse return false;
        const del_text = self.getTextInRange(range) catch return false;
        defer self.allocator.free(del_text);

        self.pushEditForChange(range.begin.row, range.begin.col, del_text, "");
        const m = self.metrics();
        const new_root = self.buffer.root.delete_range(range, self.buffer.allocator, null, m) catch return false;
        self.buffer.root = new_root;
        self.cursor = range.begin;
        self.clearSelection();
        return true;
    }

    /// Snapshot for undo - saves current buffer state before edits
    /// Die Metadaten tragen die Cursor-Position vor der Änderung (`zeile:spalte`); Undo/Redo
    /// setzen den Cursor dorthin statt an den Dateianfang.
    fn snapshotForUndo(self: *Self) void {
        var buf: [48]u8 = undefined;
        const meta = std.fmt.bufPrint(&buf, "{d}:{d}", .{ self.cursor.row, self.cursor.col }) catch "";
        self.buffer.store_undo(meta) catch {
            std.log.err("Failed to store undo snapshot", .{});
        };
    }

    /// Nach Undo/Redo: Cursor aus den Metadaten (sonst der alte, begrenzt), Geändert-Status aus
    /// dem Vergleich mit dem gespeicherten Stand.
    fn afterUndoRedo(self: *Self, meta: []const u8) void {
        self.longest_valid = false;
        self.selection_anchor = null;
        if (std.mem.indexOfScalar(u8, meta, ':')) |sep| {
            const row = std.fmt.parseInt(usize, meta[0..sep], 10) catch self.cursor.row;
            const col = std.fmt.parseInt(usize, meta[sep + 1 ..], 10) catch self.cursor.col;
            self.cursor.row = row;
            self.cursor.col = col;
        }
        const last_row = self.lineCount() -| 1;
        if (self.cursor.row > last_row) self.cursor.row = last_row;
        const line_cols = self.buffer.root.line_width(self.cursor.row, self.metrics()) catch 0;
        if (self.cursor.col > line_cols) self.cursor.col = line_cols;
        self.cursor.target = self.cursor.col;
        self.is_modified = self.buffer.is_dirty();
        self.recordCursorMovement();
    }

    pub const FindState = struct {
        active: bool = false,
        query: [256]u8 = undefined,
        len: usize = 0,
        /// Letzter Treffer; Ausgangspunkt für weiter/zurück
        last_match: ?find_ops.Match = null,
        not_found: bool = false,
        /// Ersetzen-Zeile sichtbar (Ctrl+H); Tab wechselt das Feld
        replace_mode: bool = false,
        focus_replace: bool = false,
        replacement: [256]u8 = undefined,
        replacement_len: usize = 0,
        /// Letzte Ersetzen-alle-Anzahl für die Anzeige
        replaced_count: ?usize = null,
        /// Nach dem Öffnen ersetzt das erste getippte Zeichen den alten Begriff (wie VS Code)
        replace_on_type: bool = false,
        /// Optionen (Alt+C, Alt+W, Alt+R)
        case_sensitive: bool = false,
        whole_word: bool = false,
        use_regex: bool = false,

        pub fn text(self: *const FindState) []const u8 {
            return self.query[0..self.len];
        }

        pub fn replacementText(self: *const FindState) []const u8 {
            return self.replacement[0..self.replacement_len];
        }
    };

    /// Gehe zu Zeile (Ctrl+G): Ziffern tippen, Enter springt
    pub const GotoState = struct {
        active: bool = false,
        digits: [12]u8 = undefined,
        len: usize = 0,
    };

    pub fn openGoto(self: *Self) void {
        self.goto = .{ .active = true };
    }

    fn findOptions(self: *const Self) find_ops.Options {
        return .{ .case_sensitive = self.find.case_sensitive, .whole_word = self.find.whole_word, .regex = self.find.use_regex };
    }

    /// Ctrl+H: Suchleiste mit Ersetzen-Zeile öffnen
    pub fn openReplace(self: *Self) void {
        self.openFind();
        self.find.replace_mode = true;
        self.find.focus_replace = self.find.len > 0;
        self.find.replaced_count = null;
    }

    /// Aktuellen Treffer (= Auswahl) ersetzen und zum nächsten springen.
    pub fn replaceCurrent(self: *Self) void {
        const m = self.find.last_match orelse {
            self.findStep(true, true);
            return;
        };
        const r = self.selectionRange() orelse {
            self.findStep(true, true);
            return;
        };
        if (r.begin.row != m.begin.row or r.begin.col != m.begin.col) {
            self.findStep(true, true);
            return;
        }
        self.typing_in_progress = false;
        self.snapshotForUndo();
        self.insertString(self.find.replacementText()) catch return;
        self.find.last_match = null;
        self.findStep(true, true);
    }

    /// Alle Treffer im Buffer ersetzen; liefert die Anzahl.
    pub fn replaceAll(self: *Self) usize {
        if (self.find.len == 0) return 0;
        const Finder = find_ops.Finder(LineSource);
        self.typing_in_progress = false;
        self.snapshotForUndo();
        var from: find_ops.Pos = .{ .row = 0, .col = 0 };
        var first = true;
        var count: usize = 0;
        while (count < 100_000) {
            var start = from;
            if (first) {
                // Finder sucht exklusiv ab `from`: vor den Anfang zurücksetzen
                first = false;
                start = .{ .row = self.lineCount() -| 1, .col = std.math.maxInt(u32) };
                const mm = Finder.findOpts(.{ .ed = self }, self.find.text(), start, true, self.findOptions()) orelse break;
                if (mm.begin.row != 0 or mm.begin.col != 0) {
                    // Erster Treffer liegt nicht am Anfang: normal ab (0,0) exklusiv weitersuchen,
                    // aber den Treffer an (0,0) nicht verpassen
                    start = .{ .row = 0, .col = 0 };
                    if (!(mm.begin.row == 0 and mm.begin.col == 0)) {
                        self.selection_anchor = .{ .row = mm.begin.row, .col = mm.begin.col, .target = mm.begin.col };
                        self.cursor = .{ .row = mm.end.row, .col = mm.end.col, .target = mm.end.col };
                        self.insertString(self.find.replacementText()) catch break;
                        count += 1;
                        from = .{ .row = self.cursor.row, .col = self.cursor.col };
                        continue;
                    }
                }
                self.selection_anchor = .{ .row = mm.begin.row, .col = mm.begin.col, .target = mm.begin.col };
                self.cursor = .{ .row = mm.end.row, .col = mm.end.col, .target = mm.end.col };
                self.insertString(self.find.replacementText()) catch break;
                count += 1;
                from = .{ .row = self.cursor.row, .col = self.cursor.col };
                continue;
            }
            const mm = Finder.findOpts(.{ .ed = self }, self.find.text(), start, true, self.findOptions()) orelse break;
            // Umbruch am Dateiende: Treffer vor `from` bedeutet, wir sind einmal durch
            if (mm.begin.row < from.row or (mm.begin.row == from.row and mm.begin.col < from.col)) break;
            self.selection_anchor = .{ .row = mm.begin.row, .col = mm.begin.col, .target = mm.begin.col };
            self.cursor = .{ .row = mm.end.row, .col = mm.end.col, .target = mm.end.col };
            self.insertString(self.find.replacementText()) catch break;
            count += 1;
            from = .{ .row = self.cursor.row, .col = self.cursor.col };
        }
        self.find.last_match = null;
        self.find.replaced_count = count;
        self.selection_anchor = null;
        self.ensureCursorVisible();
        return count;
    }

    const LineSource = struct {
        ed: *CodeEditor,
        pub fn lineCount(self: LineSource) usize {
            return self.ed.lineCount();
        }
        pub fn line(self: LineSource, i: usize) []const u8 {
            return self.ed.getLine(i);
        }
    };

    pub fn openFind(self: *Self) void {
        self.find.active = true;
        self.find.not_found = false;
        self.find.replace_on_type = true;
        // Markierten Text als Suchbegriff übernehmen (einzeilig)
        if (self.selectionRange()) |r| {
            if (r.begin.row == r.end.row) {
                const t = self.getTextInRange(r) catch "";
                defer if (t.len > 0) self.allocator.free(t);
                const n = @min(t.len, self.find.query.len);
                @memcpy(self.find.query[0..n], t[0..n]);
                self.find.len = n;
            }
        }
    }

    pub fn closeFind(self: *Self) void {
        self.find.active = false;
        self.find.replace_mode = false;
        self.find.focus_replace = false;
    }

    /// Nächsten/vorherigen Treffer markieren. `inclusive`: ein Treffer an der
    /// aktuellen Stelle zählt (beim Tippen), sonst wird weitergesprungen.
    fn findStep(self: *Self, forward: bool, inclusive: bool) void {
        const Finder = find_ops.Finder(LineSource);
        const anchor: find_ops.Pos = if (self.find.last_match) |m| m.begin else .{ .row = self.cursor.row, .col = self.cursor.col };
        var from = anchor;
        if (inclusive and forward) {
            if (from.col > 0) from.col -= 1 else if (from.row > 0) {
                from.row -= 1;
                from.col = std.math.maxInt(u32);
            } else {
                from = .{ .row = self.lineCount() -| 1, .col = std.math.maxInt(u32) };
            }
        }
        const m = Finder.findOpts(.{ .ed = self }, self.find.text(), from, forward, .{
            .case_sensitive = self.find.case_sensitive,
            .whole_word = self.find.whole_word,
            .regex = self.find.use_regex,
        }) orelse {
            self.find.not_found = self.find.len > 0;
            return;
        };
        self.find.not_found = false;
        self.find.last_match = m;
        self.selection_anchor = .{ .row = m.begin.row, .col = m.begin.col, .target = m.begin.col };
        self.cursor = .{ .row = m.end.row, .col = m.end.col, .target = m.end.col };
        self.ensureCursorVisible();
    }

    pub fn findNext(self: *Self, forward: bool) void {
        self.findStep(forward, false);
    }

    /// Suchleiste mit vorgegebenem Begriff öffnen und zum ersten Treffer springen
    /// (Agent-Werkzeug find_in_editor).
    pub fn findText(self: *Self, query: []const u8) void {
        self.openFind();
        const n = @min(query.len, self.find.query.len);
        @memcpy(self.find.query[0..n], query[0..n]);
        self.find.len = n;
        self.find.last_match = null;
        self.find.not_found = false;
        if (n > 0) self.findStep(true, true);
    }

    fn handleFindKey(self: *Self, key: wio.Button) void {
        // Alt+C Groß/Klein, Alt+W Ganzwort, Alt+R Regex (wie VS Code)
        if (self.mods.alt and (key == .c or key == .w or key == .r)) {
            switch (key) {
                .c => self.find.case_sensitive = !self.find.case_sensitive,
                .w => self.find.whole_word = !self.find.whole_word,
                else => self.find.use_regex = !self.find.use_regex,
            }
            self.find.last_match = null;
            self.find.not_found = false;
            if (self.find.len > 0) self.findStep(true, true);
            return;
        }
        switch (key) {
            .escape => self.closeFind(),
            .tab => if (self.find.replace_mode) {
                self.find.focus_replace = !self.find.focus_replace;
            },
            .enter, .kp_enter => {
                if (self.find.replace_mode and self.mods.alt) {
                    _ = self.replaceAll();
                } else if (self.find.replace_mode and self.find.focus_replace) {
                    self.replaceCurrent();
                } else {
                    self.findNext(!self.mods.shift);
                }
            },
            .backspace => {
                if (self.find.replace_mode and self.find.focus_replace) {
                    if (self.find.replacement_len > 0) {
                        var i = self.find.replacement_len - 1;
                        while (i > 0 and (self.find.replacement[i] & 0xC0) == 0x80) i -= 1;
                        self.find.replacement_len = i;
                    }
                    return;
                }
                if (self.find.len > 0) {
                    var i = self.find.len - 1;
                    while (i > 0 and (self.find.query[i] & 0xC0) == 0x80) i -= 1;
                    self.find.len = i;
                }
                self.find.last_match = null;
                self.find.not_found = false;
                if (self.find.len > 0) self.findStep(true, true);
            },
            else => {},
        }
    }

    fn handleFindChar(self: *Self, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.find.replace_mode and self.find.focus_replace) {
            if (self.find.replacement_len + n > self.find.replacement.len) return;
            @memcpy(self.find.replacement[self.find.replacement_len .. self.find.replacement_len + n], tmp[0..n]);
            self.find.replacement_len += n;
            return;
        }
        if (self.find.replace_on_type) {
            self.find.len = 0;
            self.find.last_match = null;
            self.find.replace_on_type = false;
        }
        if (self.find.len + n > self.find.query.len) return;
        @memcpy(self.find.query[self.find.len .. self.find.len + n], tmp[0..n]);
        self.find.len += n;
        self.findStep(true, true);
    }

    fn renderFindWidget(self: *Self, arena: std.mem.Allocator, editor_id: clay.ElementId) void {
        clay.UI()(.{
            .id = clay.ElementId.ID("find_widget"),
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = editor_id.id,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .offset = .{ .x = -24, .y = 8 },
                .z_index = 500,
            },
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .left_to_right,
                .padding = .all(8),
                .child_gap = 10,
                .child_alignment = .{ .y = .center },
            },
            .background_color = .{ 45, 45, 60, 255 },
            .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
            .corner_radius = .all(4),
        })({
            clay.text("Find", .{ .font_size = 18, .color = .{ 150, 150, 170, 255 }, .wrap_mode = .none });
            clay.UI()(.{
                .id = clay.ElementId.ID("find_input"),
                .layout = .{
                    .sizing = .{ .w = .fixed(260), .h = .fixed(30) },
                    .padding = .axes(0, 8),
                    .child_alignment = .{ .y = .center },
                },
                .clip = .{ .horizontal = true },
                .background_color = .{ 30, 30, 46, 255 },
                .border = .{ .width = .all(1), .color = if (self.find.not_found) .{ 220, 90, 90, 255 } else .{ 120, 140, 220, 255 } },
                .corner_radius = .all(3),
            })({
                const shown = std.fmt.allocPrint(arena, "{s}|", .{self.find.text()}) catch self.find.text();
                clay.text(shown, .{ .font_size = 18, .color = .{ 220, 220, 240, 255 }, .wrap_mode = .none });
            });
            const status: []const u8 = if (self.find.not_found) "No results" else if (self.find.last_match) |m|
                std.fmt.allocPrint(arena, "Line {d}", .{m.begin.row + 1}) catch ""
            else
                "";
            if (status.len > 0) clay.text(status, .{ .font_size = 16, .color = if (self.find.not_found) .{ 220, 90, 90, 255 } else .{ 150, 150, 170, 255 }, .wrap_mode = .none });
            renderFindToggle("Aa", self.find.case_sensitive);
            renderFindToggle("W", self.find.whole_word);
            renderFindToggle(".*", self.find.use_regex);
            clay.text("Enter ↓  Shift+Enter ↑  Alt+C/W/R  Esc", .{ .font_size = 14, .color = .{ 120, 120, 140, 255 }, .wrap_mode = .none });
        });
        if (self.find.replace_mode) self.renderReplaceRow(arena, editor_id);
    }

    fn renderFindToggle(label: []const u8, on: bool) void {
        clay.UI()(.{
            .layout = .{ .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 } },
            .background_color = if (on) .{ 120, 140, 220, 255 } else .{ 60, 60, 80, 255 },
            .corner_radius = .all(3),
        })({
            clay.text(label, .{ .font_size = 14, .color = if (on) .{ 20, 20, 30, 255 } else .{ 170, 170, 190, 255 }, .wrap_mode = .none });
        });
    }

    fn renderReplaceRow(self: *Self, arena: std.mem.Allocator, editor_id: clay.ElementId) void {
        clay.UI()(.{
            .id = clay.ElementId.ID("replace_widget"),
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = editor_id.id,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .offset = .{ .x = -24, .y = 60 },
                .z_index = 500,
            },
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .left_to_right,
                .padding = .all(8),
                .child_gap = 10,
                .child_alignment = .{ .y = .center },
            },
            .background_color = .{ 45, 45, 60, 255 },
            .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
            .corner_radius = .all(4),
        })({
            clay.text("Replace", .{ .font_size = 18, .color = .{ 150, 150, 170, 255 }, .wrap_mode = .none });
            clay.UI()(.{
                .id = clay.ElementId.ID("replace_input"),
                .layout = .{
                    .sizing = .{ .w = .fixed(260), .h = .fixed(30) },
                    .padding = .axes(0, 8),
                    .child_alignment = .{ .y = .center },
                },
                .clip = .{ .horizontal = true },
                .background_color = .{ 30, 30, 46, 255 },
                .border = .{ .width = .all(1), .color = if (self.find.focus_replace) .{ 120, 140, 220, 255 } else .{ 80, 80, 100, 255 } },
                .corner_radius = .all(3),
            })({
                const shown = if (self.find.focus_replace)
                    std.fmt.allocPrint(arena, "{s}|", .{self.find.replacementText()}) catch self.find.replacementText()
                else
                    self.find.replacementText();
                clay.text(shown, .{ .font_size = 18, .color = .{ 220, 220, 240, 255 }, .wrap_mode = .none });
            });
            if (self.find.replaced_count) |n| {
                const t = std.fmt.allocPrint(arena, "{d} replaced", .{n}) catch "";
                clay.text(t, .{ .font_size = 16, .color = .{ 150, 150, 170, 255 }, .wrap_mode = .none });
            }
            clay.text("Tab wechselt  Enter ersetzt  Alt+Enter alle", .{ .font_size = 14, .color = .{ 120, 120, 140, 255 }, .wrap_mode = .none });
        });
    }

    fn renderGotoWidget(self: *Self, arena: std.mem.Allocator, editor_id: clay.ElementId) void {
        clay.UI()(.{
            .id = clay.ElementId.ID("goto_widget"),
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = editor_id.id,
                .attach_points = .{ .element = .center_top, .parent = .center_top },
                .offset = .{ .x = 0, .y = 8 },
                .z_index = 500,
            },
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fit },
                .direction = .left_to_right,
                .padding = .all(8),
                .child_gap = 10,
                .child_alignment = .{ .y = .center },
            },
            .background_color = .{ 45, 45, 60, 255 },
            .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
            .corner_radius = .all(4),
        })({
            clay.text("Go to line", .{ .font_size = 18, .color = .{ 150, 150, 170, 255 }, .wrap_mode = .none });
            clay.UI()(.{
                .id = clay.ElementId.ID("goto_input"),
                .layout = .{ .sizing = .{ .w = .fixed(120), .h = .fixed(30) }, .padding = .axes(0, 8), .child_alignment = .{ .y = .center } },
                .background_color = .{ 30, 30, 46, 255 },
                .border = .{ .width = .all(1), .color = .{ 120, 140, 220, 255 } },
                .corner_radius = .all(3),
            })({
                const shown = std.fmt.allocPrint(arena, "{s}|", .{self.goto.digits[0..self.goto.len]}) catch "";
                clay.text(shown, .{ .font_size = 18, .color = .{ 220, 220, 240, 255 }, .wrap_mode = .none });
            });
            const hint = std.fmt.allocPrint(arena, "1–{d}  Enter  Esc", .{self.lineCount()}) catch "";
            clay.text(hint, .{ .font_size = 14, .color = .{ 120, 120, 140, 255 }, .wrap_mode = .none });
        });
    }

    pub fn handleKeyPress(self: *Self, key: wio.Button) void {
        std.log.debug("handleKeyPress: key={} mods={}", .{ key, self.mods });
        if (self.find.active) {
            self.handleFindKey(key);
            return;
        }
        if (self.goto.active) {
            switch (key) {
                .escape => self.goto.active = false,
                .backspace => self.goto.len -|= 1,
                .enter, .kp_enter => {
                    const n = std.fmt.parseInt(usize, self.goto.digits[0..self.goto.len], 10) catch 0;
                    self.goto.active = false;
                    if (n > 0) {
                        self.cursor = .{ .row = @min(n - 1, self.lineCount() -| 1), .col = 0, .target = 0 };
                        self.selection_anchor = null;
                        self.ensureCursorVisible();
                        self.recordCursorMovement();
                    }
                },
                else => {},
            }
            return;
        }
        if (key == .escape and self.extra_cursors.items.len > 0) {
            self.clearExtraCursors();
            return;
        }
        if (self.keymap) |km| {
            std.log.debug("keymap lookup key={} mods={}", .{ key, self.mods });
            if (km.lookup(key, self.mods)) |action| {
                std.log.debug("keymap action={}", .{action});
                self.dispatchAction(action);
                return;
            }
        }
    }

    pub fn setShiftState(self: *Self, pressed: bool) void {
        self.mods.shift = pressed;
    }

    pub fn setCtrlState(self: *Self, pressed: bool) void {
        self.mods.ctrl = pressed;
    }

    pub fn setAltState(self: *Self, pressed: bool) void {
        self.mods.alt = pressed;
    }

    // =========================================================================
    // Mouse Handling
    // =========================================================================

    pub fn updateMousePosition(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, button: @import("wio").Button) void {
        self.mouse_x = x;
        self.mouse_y = y;
        // mouse_down erst im Linksklick-Pfad setzen: Rechtsklick öffnet nur das
        // Kontextmenü und darf beim Ziehen keine Selektion vom alten Anker erweitern.

        if (self.show_context_menu) {
            self.show_context_menu = false;
            if (ctx_menu.hit("editor_menu", &shortcuts.editor_menu_items, self.menuHidden())) |cmd| {
                switch (cmd) {
                    .cut => self.dispatchAction(.Cut),
                    .copy => self.dispatchAction(.Copy),
                    .paste => self.dispatchAction(.Paste),
                    .md_preview => self.dispatchAction(.MdPreview),
                    .md_export_pdf => self.dispatchAction(.MdExportPdf),
                    .file_history => self.dispatchAction(.FileHistory),
                    .split_vertical => self.dispatchAction(.SplitVertical),
                    .split_horizontal => self.dispatchAction(.SplitHorizontal),
                    else => {},
                }
                return;
            }
        }

        if (button == .mouse_right) {
            self.show_context_menu = true;
            self.context_menu_x = x;
            self.context_menu_y = y;
            return;
        }

        if (self.handleScrollbarMouseDown(x, y)) return;
        if (self.handleHScrollbarMouseDown(x, y)) return;

        const hit = self.hitFromY(y);
        const line_idx = hit.line;
        const col = self.colFromX(x, line_idx, hit.first_byte);
        self.clearExtraCursors();

        // Ctrl+Klick: zur Definition im Text springen
        if (self.mods.ctrl) {
            self.gotoDefinition(line_idx, col);
            self.mouse_down = false;
            return;
        }
        // Shift+Klick: Auswahl vom Anker (oder alten Cursor) bis zum Klick erweitern
        if (self.mods.shift) {
            if (self.selection_anchor == null) self.selection_anchor = self.cursor;
            self.cursor.row = line_idx;
            self.cursor.col = col;
            self.cursor.target = col;
            self.mouse_down = true;
            self.last_mouse_click_ms = self.time_ms;
            self.recordCursorMovement();
            self.current_line = self.cursor.row + 1;
            return;
        }

        const quick = (self.time_ms - self.last_mouse_click_ms < 500.0) and self.last_mouse_click_line == line_idx;
        const is_double_click = quick and self.last_mouse_click_col == col and self.click_count == 1;
        const is_triple_click = quick and self.click_count >= 2;
        self.click_count = if (quick) self.click_count + 1 else 1;

        if (is_triple_click) {
            // Ganze Zeile markieren (mit Umbruch, wie VS Code)
            self.selection_anchor = .{ .row = line_idx, .col = 0, .target = 0 };
            if (line_idx + 1 < self.lineCount()) {
                self.cursor = .{ .row = line_idx + 1, .col = 0, .target = 0 };
            } else {
                const w = self.lineWidth(line_idx);
                self.cursor = .{ .row = line_idx, .col = w, .target = w };
            }
        } else if (is_double_click) {
            const line_text = self.getLine(line_idx);
            const line_w = self.lineWidth(line_idx);
            const m = self.metrics();
            const byte_pos = if (col < line_w)
                self.buffer.root.get_line_width_to_pos(line_idx, col, m) catch 0
            else
                line_text.len;

            var ws: usize = byte_pos;
            while (ws > 0 and isWordChar(line_text[ws - 1])) : (ws -= 1) {}
            var we: usize = byte_pos;
            while (we < line_text.len and isWordChar(line_text[we])) : (we += 1) {}

            const word_start_col = self.buffer.root.pos_to_width(line_idx, ws, m) catch 0;
            const word_end_col = self.buffer.root.pos_to_width(line_idx, we, m) catch line_w;

            self.cursor.row = line_idx;
            self.cursor.col = word_start_col;
            self.selection_anchor = .{ .row = line_idx, .col = word_end_col };
        } else {
            self.cursor.row = line_idx;
            self.cursor.col = col;
            self.cursor.target = col;
            self.selection_anchor = .{ .row = line_idx, .col = col };
        }

        self.mouse_down = true;
        self.last_mouse_click_ms = self.time_ms;
        self.last_mouse_click_line = line_idx;
        self.last_mouse_click_col = col;
        self.recordCursorMovement();
        self.current_line = self.cursor.row + 1;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;

        if (self.vscroll_drag) |d| {
            self.view.row = scrollbar.dragOffset(self.vscrollModel(), d, x, y);
            return;
        }
        if (self.hscroll_drag) |d| {
            if (self.hscrollModel()) |m| self.view.col = scrollbar.dragOffset(m, d, x, y);
            return;
        }

        if (!self.mouse_down) return;
        const hit = self.hitFromY(y);
        const line_idx = hit.line;
        const col = self.colFromX(x, line_idx, hit.first_byte);
        self.cursor.row = line_idx;
        self.cursor.col = col;
        self.ensureCursorVisible();
        self.current_line = self.cursor.row + 1;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.mouse_down = false;
        self.vscroll_drag = null;
        self.hscroll_drag = null;
    }

    /// Beim Ziehen über den oberen/unteren Rand pro Frame eine Zeile scrollen und den Cursor mitziehen.
    fn autoScrollWhileDragging(self: *Self) void {
        if (!self.mouse_down or self.vscroll_drag != null or self.hscroll_drag != null) return;
        const top = self.content_origin_y;
        const bottom = self.content_origin_y + self.height;
        if (self.mouse_y < top) {
            self.scrollLines(1);
        } else if (self.mouse_y > bottom) {
            self.scrollLines(-1);
        } else return;
        const hit = self.hitFromY(@max(top, @min(self.mouse_y, bottom - 1)));
        self.cursor.row = hit.line;
        self.cursor.col = self.colFromX(self.mouse_x, hit.line, hit.first_byte);
        self.current_line = self.cursor.row + 1;
    }

    fn bracketPartner(c: u8) ?u8 {
        return switch (c) {
            '(' => ')',
            '[' => ']',
            '{' => '}',
            ')' => '(',
            ']' => '[',
            '}' => '{',
            else => null,
        };
    }

    fn isOpenBracket(c: u8) bool {
        return c == '(' or c == '[' or c == '{';
    }

    /// Klammer direkt am Cursor (davor oder danach) und ihr Partner; höchstens 2000 Zeilen weit.
    pub fn findBracketPair(self: *Self) ?[2]flow_core.Cursor {
        const m = self.metrics();
        const row = self.cursor.row;
        const line = self.getLine(row);
        const byte = @min(self.buffer.root.get_line_width_to_pos(row, self.cursor.col, m) catch line.len, line.len);
        var at: ?usize = null;
        if (byte < line.len and bracketPartner(line[byte]) != null) at = byte;
        if (at == null and byte > 0 and bracketPartner(line[byte - 1]) != null) at = byte - 1;
        const here = at orelse return null;
        const ch = line[here];
        const partner = bracketPartner(ch).?;
        const forward = isOpenBracket(ch);
        const here_col = self.buffer.root.pos_to_width(row, here, m) catch return null;

        var depth: usize = 0;
        var r = row;
        var scanned: usize = 0;
        var b: isize = @intCast(here);
        while (scanned < 2000) : (scanned += 1) {
            const l = self.getLine(r);
            while (true) {
                if (forward) {
                    b += 1;
                    if (b >= @as(isize, @intCast(l.len))) break;
                } else {
                    b -= 1;
                    if (b < 0) break;
                }
                const c = l[@intCast(b)];
                if (c == ch) depth += 1;
                if (c == partner) {
                    if (depth == 0) {
                        const col = self.buffer.root.pos_to_width(r, @intCast(b), m) catch return null;
                        return .{ .{ .row = row, .col = here_col, .target = here_col }, .{ .row = r, .col = col, .target = col } };
                    }
                    depth -= 1;
                }
            }
            if (forward) {
                r += 1;
                if (r >= self.lineCount()) break;
                b = -1;
            } else {
                if (r == 0) break;
                r -= 1;
                b = @intCast(self.getLine(r).len);
            }
        }
        return null;
    }

    /// Einrück-Guides, Whitespace-Punkte und Klammer-Rahmen einer Zeile (über den Text gelegt).
    fn renderRowOverlays(self: *Self, arena: std.mem.Allocator, line_idx: usize, slice: []const u8, full_line: []const u8, first_col: usize) void {
        _ = arena;
        const cw = self.charWidth();
        const row_h: f32 = @floatFromInt(self.font_size + 16);
        const seg_cols = blk: {
            var n: usize = 0;
            for (slice) |c| {
                if ((c & 0xC0) == 0x80) continue;
                n += if (c == '\t') 4 else 1;
            }
            break :blk n;
        };
        const last_col = first_col + seg_cols;

        // Einrück-Guides: eine Linie je 4 Spalten führenden Whitespace (Tabs zählen 4)
        if (self.show_indent_guides) {
            var indent_cols: usize = 0;
            for (full_line) |c| {
                if (c == ' ') indent_cols += 1 else if (c == '\t') indent_cols += 4 else break;
            }
            var level: usize = 4;
            while (level <= indent_cols and level < 400) : (level += 4) {
                if (level < first_col or level >= last_col + 1) continue;
                const x = @as(f32, @floatFromInt(level - first_col)) * cw;
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fixed(1), .h = .fixed(row_h) } },
                    .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = x, .y = 0 } },
                    .background_color = .{ self.line_number_color[0], self.line_number_color[1], self.line_number_color[2], 70 },
                })({});
            }
        }

        // Whitespace: Punkt je Leerzeichen, Pfeil je Tab im sichtbaren Ausschnitt
        if (self.show_whitespace) {
            var col: usize = 0;
            var i: usize = 0;
            while (i < slice.len and col < 400) : (i += 1) {
                const c = slice[i];
                if ((c & 0xC0) == 0x80) continue;
                if (c == ' ' or c == '\t') {
                    const x = @as(f32, @floatFromInt(col)) * cw + (if (c == ' ') cw / 2 - 1.5 else 2);
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fixed(if (c == ' ') 3 else cw * 4 - 6), .h = .fixed(if (c == ' ') 3 else 1) } },
                        .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = x, .y = row_h / 2 - 1.5 } },
                        .background_color = .{ self.line_number_color[0], self.line_number_color[1], self.line_number_color[2], 160 },
                    })({});
                }
                col += if (c == '\t') 4 else 1;
            }
        }

        // Klammerpaar: Rahmen um beide Klammern
        if (self.bracket_pair) |pair| {
            for (pair) |p| {
                if (p.row != line_idx or p.col < first_col or p.col >= last_col) continue;
                const x = @as(f32, @floatFromInt(p.col - first_col)) * cw;
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fixed(cw), .h = .fixed(row_h - 8) } },
                    .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = x, .y = 4 } },
                    .border = .{ .width = .all(1), .color = self.current_line_number_color },
                    .corner_radius = .all(2),
                })({});
            }
        }
    }

    /// Minimap rechts: je Zeile ein Balken (Länge ∝ Zeilenlänge), Fenster um den Viewport,
    /// sichtbarer Bereich hinterlegt. Klick springt dorthin.
    /// Clay-ID mit Editor-Salz: Zeilen-, Gutter-, Scroll-Elemente sind je Pane eindeutig.
    /// Ohne Salz meldete Clay bei zwei Panes ~80 `duplicate_id` pro Frame, und `getElementData`
    /// der zweiten Pane bekam die Boxen der ersten. E2E: `element_bounds(_i)` löst den Namen
    /// zuerst global, dann über den aktiven Editor auf (`E2E: elementBounds*`).
    /// Von einer Änderung betroffene Zeilen: `start..old_end` vorher, `start..new_end` nachher.
    pub const LineChange = struct { start: usize, old_end: usize, new_end: usize };

    pub fn idi(self: *const Self, name: []const u8, index: u32) clay.ElementId {
        return clay.ElementId.IDI(name, index +% self.idSalt());
    }

    pub fn idSalt(self: *const Self) u32 {
        return @truncate(@intFromPtr(self));
    }

    /// Höhe eines Minimap-Balkens und Innenabstand oben des Minimap-Elements.
    pub const minimap_line_px: f32 = 2;
    pub const minimap_pad_top: u16 = 2;

    pub const MinimapWindow = struct { rows: usize, start: usize, end: usize };

    /// Zeilenfenster der Minimap: `rows` Balken passen samt Innenabstand in die Editor-Höhe,
    /// der Viewport liegt möglichst mittig, `start..end` sind die gezeichneten Buffer-Zeilen.
    pub fn minimapWindow(self: *Self) MinimapWindow {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        const usable = @max(0, self.height - @as(f32, @floatFromInt(minimap_pad_top)));
        const rows: usize = @max(1, @as(usize, @intFromFloat(usable / minimap_line_px)));
        const half = rows / 2;
        var start: usize = if (self.view.row + visible / 2 > half) self.view.row + visible / 2 - half else 0;
        if (start + rows > total) start = if (total > rows) total - rows else 0;
        return .{ .rows = rows, .start = start, .end = @min(start + rows, total) };
    }

    fn renderMinimap(self: *Self, mouse_pressed: bool) void {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        const line_px = minimap_line_px;
        const window = self.minimapWindow();
        const start = window.start;
        const end = window.end;
        const mm_id = clay.ElementId.IDI("minimap", @truncate(@intFromPtr(self)));
        const data = clay.getElementData(mm_id);
        if (data.found and mouse_pressed and clay.pointerOver(mm_id)) {
            const rel = (self.mouse_y - data.bounding_box.y) / line_px;
            const target = start + @as(usize, @intFromFloat(@max(0, rel)));
            const max_off = if (total > visible) total - visible else 0;
            self.view.row = @min(target -| visible / 2, max_off);
        }
        clay.UI()(.{
            .id = mm_id,
            .layout = .{ .sizing = .{ .w = .fixed(self.minimap_width), .h = .grow }, .direction = .top_to_bottom, .padding = .{ .left = 4, .top = minimap_pad_top } },
            // Clip: Kinder dürfen die Mindesthöhe nicht nach oben durchreichen. Ohne Clip war die
            // Minimap 2 px höher als der Editor, die Wurzel wuchs jeden zweiten Frame um 2 px und
            // der Editor zeichnete nach Minuten hunderte Zeilen (extrem langsam, besonders klein gezoomt).
            .clip = .{ .vertical = true },
            .background_color = self.gutter_color,
            .border = .{ .width = .{ .left = 1 }, .color = .{ self.line_number_color[0], self.line_number_color[1], self.line_number_color[2], 60 } },
        })({
            var i = start;
            while (i < end) : (i += 1) {
                const len = self.getLine(i).len;
                const in_view = i >= self.view.row and i < self.view.row + visible;
                const w: f32 = @min(self.minimap_width - 10, @as(f32, @floatFromInt(len)) * 0.6);
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(line_px) } },
                    .background_color = if (in_view) .{ self.current_line_highlight[0], self.current_line_highlight[1], self.current_line_highlight[2], 120 } else .{ 0, 0, 0, 0 },
                })({
                    if (w > 0) clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fixed(w), .h = .fixed(1) } },
                        .background_color = .{ self.text_color[0], self.text_color[1], self.text_color[2], if (i == self.cursor.row) 255 else 110 },
                    })({});
                });
            }
        });
    }

    /// Waagrechte Leiste unten (Modul `scrollbar`); Klick und Ziehen laufen über handleMouseDown/-Move.
    fn renderHScrollbar(self: *Self) void {
        const m = self.hscrollModel() orelse return;
        if (scrollbar.render(m, .{ .track = self.idi("hscroll", 0), .thumb = self.idi("hscroll_thumb", 0) })) self.desired_cursor = .arrow;
    }

    /// Wort unter (row, col) im Text suchen: erste Zeile, die wie eine Definition aussieht.
    pub const DefinitionHook = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, editor: *CodeEditor, row: usize, col: usize) bool,
    };

    pub fn gotoDefinition(self: *Self, row: usize, col: usize) void {
        if (self.definition_hook) |h| {
            if (h.func(h.ctx, self, row, col)) return;
        }
        self.gotoDefinitionLocal(row, col);
    }

    /// Cursor setzen und sichtbar machen (Zeile/Spalte werden geklemmt).
    pub fn jumpTo(self: *Self, row: usize, col: usize) void {
        const r = @min(row, self.lineCount() -| 1);
        const c = @min(col, self.lineWidth(r));
        self.selection_anchor = null;
        self.clearExtraCursors();
        self.cursor = .{ .row = r, .col = c, .target = c };
        self.ensureCursorVisible();
        self.recordCursorMovement();
        self.current_line = r + 1;
    }

    /// Gesamter Text des Buffers (owned).
    pub fn allTextAlloc(self: *const Self) ![]u8 {
        const last = self.lineCount() -| 1;
        return self.getTextInRange(.{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = last, .col = self.lineWidth(last) } });
    }

    /// Byte-Position in der Zeile → Zeichenindex (Codepoints; für LSP-Positionen).
    pub fn charIndexAt(self: *Self, row: usize, col: usize) u32 {
        const line_text = self.getLine(row);
        const byte = @min(self.buffer.root.get_line_width_to_pos(row, col, self.metrics()) catch line_text.len, line_text.len);
        var n: u32 = 0;
        for (line_text[0..byte]) |c| {
            if ((c & 0xC0) != 0x80) n += 1;
        }
        return n;
    }

    /// Sprung per Textmuster innerhalb der Datei (ohne Language Server).
    pub fn gotoDefinitionLocal(self: *Self, row: usize, col: usize) void {
        const m = self.metrics();
        const line_text = self.getLine(row);
        const byte = @min(self.buffer.root.get_line_width_to_pos(row, col, m) catch line_text.len, line_text.len);
        const word_src = edit_ops.wordAt(line_text, byte);
        if (word_src.len == 0) return;
        const word = self.allocator.dupe(u8, word_src) catch return;
        defer self.allocator.free(word);
        const total = self.lineCount();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (i == row) continue;
            const l = self.getLine(i);
            if (edit_ops.looksLikeDefinition(l, word)) {
                const pos = std.mem.indexOf(u8, l, word) orelse 0;
                const c = self.buffer.root.pos_to_width(i, pos, m) catch 0;
                self.selection_anchor = null;
                self.cursor = .{ .row = i, .col = c, .target = c };
                self.ensureCursorVisible();
                self.recordCursorMovement();
                self.current_line = i + 1;
                return;
            }
        }
    }

    // ───────────────────────── Zeilen-Operationen ─────────────────────────

    /// Zeilenbereich der Auswahl (oder Cursorzeile); eine Auswahl, die in Spalte 0 endet,
    /// nimmt diese letzte Zeile nicht mit (wie VS Code).
    fn selectedLineSpan(self: *const Self) struct { first: usize, last: usize } {
        if (self.selectionRange()) |r| {
            var last = r.end.row;
            if (last > r.begin.row and r.end.col == 0) last -= 1;
            return .{ .first = r.begin.row, .last = last };
        }
        return .{ .first = self.cursor.row, .last = self.cursor.row };
    }

    /// Text der Zeilen first..last (ohne Umbruch am Ende) ersetzen; Cursor/Anker bleiben in ihren Zeilen.
    fn replaceLineSpan(self: *Self, first: usize, last: usize, new_text: []const u8) void {
        const m = self.metrics();
        const sel: flow_core.Selection = .{
            .begin = .{ .row = first, .col = 0 },
            .end = .{ .row = last, .col = self.lineWidth(last) },
        };
        const old = self.getTextInRange(sel) catch return;
        defer if (old.len > 0) self.allocator.free(old);
        self.pushEditForChange(first, 0, old, new_text);
        const deleted = self.buffer.root.delete_range(sel, self.buffer.allocator, null, m) catch return;
        self.buffer.root = deleted;
        const result = self.buffer.root.insert_chars(first, 0, new_text, self.buffer.allocator, m) catch return;
        self.buffer.root = result[2];
        self.markDirty(first, last + 1);
    }

    /// Zeilen der Auswahl als Slices sammeln (owned Kopien, weil getLine einen Scratch nutzt).
    fn collectLines(self: *Self, first: usize, last: usize) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |l| self.allocator.free(l);
            out.deinit(self.allocator);
        }
        var i = first;
        while (i <= last) : (i += 1) try out.append(self.allocator, try self.allocator.dupe(u8, self.getLine(i)));
        return out.toOwnedSlice(self.allocator);
    }

    fn freeLines(self: *Self, lines: [][]u8) void {
        for (lines) |l| self.allocator.free(l);
        self.allocator.free(lines);
    }

    fn clampCols(self: *Self) void {
        self.cursor.col = @min(self.cursor.col, self.lineWidth(self.cursor.row));
        self.cursor.target = self.cursor.col;
        if (self.selection_anchor) |*a| a.col = @min(a.col, self.lineWidth(a.row));
    }

    /// Tab/Shift+Tab: markierte Zeilen (oder Cursorzeile) ein-/ausrücken.
    pub fn indentSelection(self: *Self, outdent: bool) void {
        const span = self.selectedLineSpan();
        const lines = self.collectLines(span.first, span.last) catch return;
        defer self.freeLines(lines);
        const consts: [][]const u8 = @ptrCast(lines);
        const new_text = edit_ops.indentLines(self.allocator, consts, outdent) catch return;
        defer self.allocator.free(new_text);
        self.replaceLineSpan(span.first, span.last, new_text);
        // Cursor/Anker um die Einrückung verschieben
        const delta: usize = edit_ops.indent_unit.len;
        if (outdent) {
            self.cursor.col -|= delta;
            if (self.selection_anchor) |*a| a.col -|= delta;
        } else {
            if (self.lineWidth(self.cursor.row) > 0) self.cursor.col += delta;
            if (self.selection_anchor) |*a| {
                if (self.lineWidth(a.row) > 0) a.col += delta;
            }
        }
        self.clampCols();
    }

    /// Ctrl+/: Zeilenkommentar der markierten Zeilen umschalten (Präfix je Endung).
    pub fn toggleComment(self: *Self) void {
        const prefix = edit_ops.commentPrefixForPath(self.buffer.get_file_path()) orelse return;
        const span = self.selectedLineSpan();
        const lines = self.collectLines(span.first, span.last) catch return;
        defer self.freeLines(lines);
        const consts: [][]const u8 = @ptrCast(lines);
        const new_text = edit_ops.toggleCommentLines(self.allocator, consts, prefix) catch return;
        defer self.allocator.free(new_text);
        self.replaceLineSpan(span.first, span.last, new_text);
        self.clampCols();
    }

    /// Alt+↑/↓: markierte Zeilen um eine Zeile verschieben.
    pub fn moveLines(self: *Self, down: bool) void {
        const span = self.selectedLineSpan();
        const total = self.lineCount();
        if (down and span.last + 1 >= total) return;
        if (!down and span.first == 0) return;
        const lines = self.collectLines(span.first, span.last) catch return;
        defer self.freeLines(lines);
        const other_row = if (down) span.last + 1 else span.first - 1;
        const other = self.allocator.dupe(u8, self.getLine(other_row)) catch return;
        defer self.allocator.free(other);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        if (down) buf.appendSlice(self.allocator, other) catch return;
        for (lines, 0..) |l, i| {
            if (down or i > 0) buf.append(self.allocator, '\n') catch return;
            buf.appendSlice(self.allocator, l) catch return;
        }
        if (!down) {
            buf.append(self.allocator, '\n') catch return;
            buf.appendSlice(self.allocator, other) catch return;
        }
        const first = if (down) span.first else span.first - 1;
        const last = if (down) span.last + 1 else span.last;
        self.replaceLineSpan(first, last, buf.items);
        if (down) {
            self.cursor.row += 1;
            if (self.selection_anchor) |*a| a.row += 1;
        } else {
            self.cursor.row -= 1;
            if (self.selection_anchor) |*a| a.row -= 1;
        }
        self.clampCols();
        self.ensureCursorVisible();
    }

    /// Ctrl+Shift+D: markierte Zeilen (oder Cursorzeile) darunter duplizieren.
    pub fn duplicateLines(self: *Self) void {
        const span = self.selectedLineSpan();
        const m = self.metrics();
        const sel: flow_core.Selection = .{
            .begin = .{ .row = span.first, .col = 0 },
            .end = .{ .row = span.last, .col = self.lineWidth(span.last) },
        };
        const text = self.getTextInRange(sel) catch return;
        defer if (text.len > 0) self.allocator.free(text);
        const ins = std.mem.concat(self.allocator, u8, &.{ "\n", text }) catch return;
        defer self.allocator.free(ins);
        const at_col = self.lineWidth(span.last);
        self.pushEditForChange(span.last, at_col, "", ins);
        const result = self.buffer.root.insert_chars(span.last, at_col, ins, self.buffer.allocator, m) catch return;
        self.buffer.root = result[2];
        self.markDirty(span.first, span.last + 1 + (span.last - span.first));
        const n = span.last - span.first + 1;
        self.cursor.row += n;
        if (self.selection_anchor) |*a| a.row += n;
        self.clampCols();
        self.ensureCursorVisible();
    }

    fn lineFromY(self: *Self, y: f32) usize {
        return self.hitFromY(y).line;
    }

    /// Sichtbare Reihe unter y → Buffer-Zeile und Segmentanfang (Word-Wrap).
    fn hitFromY(self: *Self, y: f32) Hit {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return .{ .line = 0, .first_byte = 0 };
        const rel_y = y - self.content_origin_y;
        if (rel_y < 0) return .{ .line = @min(self.view.row, self.lineCount() -| 1), .first_byte = 0 };
        const row: usize = @intFromFloat(@floor(rel_y / line_height));
        return self.hitRow(row);
    }

    fn colFromX(self: *Self, x: f32, line_idx: usize, seg_first_byte: usize) usize {
        const rel_x = x - self.content_origin_x - self.gutter_width - 12;
        const line_text = self.getLine(line_idx);
        if (rel_x <= 0 or line_text.len == 0) {
            return if (seg_first_byte > 0) (self.buffer.root.pos_to_width(line_idx, @min(seg_first_byte, line_text.len), self.metrics()) catch 0) else 0;
        }
        // Horizontal gescrollt bzw. umgebrochen: Messung beginnt beim ersten sichtbaren Byte
        const first_visible = if (self.word_wrap)
            @min(seg_first_byte, line_text.len)
        else
            @min(self.buffer.root.get_line_width_to_pos(line_idx, self.view.col, self.metrics()) catch 0, line_text.len);

        if (self.measure_fn) |measure| {
            var x_accum: f32 = 0.0;
            var byte_offset: usize = first_visible;
            while (byte_offset < line_text.len) {
                var next_offset = byte_offset + 1;
                while (next_offset < line_text.len and (line_text[next_offset] & 0xC0) == 0x80) {
                    next_offset += 1;
                }
                const char_w = measure(@ptrCast(line_text.ptr + byte_offset), next_offset - byte_offset);
                if (rel_x < x_accum + char_w) {
                    return self.buffer.root.pos_to_width(line_idx, byte_offset, self.metrics()) catch 0;
                }
                x_accum += char_w;
                byte_offset = next_offset;
            }
            return self.lineWidth(line_idx);
        }

        const char_width: f32 = @as(f32, @floatFromInt(self.font_size)) * 0.6;
        if (char_width <= 0) return 0;
        const col_f = @as(isize, @intFromFloat(@floor(rel_x / char_width)));
        if (col_f < 0) return 0;
        const base_col = self.buffer.root.pos_to_width(line_idx, first_visible, self.metrics()) catch self.view.col;
        return @min(@as(usize, @intCast(col_f)) + base_col, self.lineWidth(line_idx));
    }

    /// Breite eines Zeichens der Monospace-Schrift (Messung, sonst Faustformel).
    fn charWidth(self: *const Self) f32 {
        if (self.measure_fn) |measure| {
            const w = measure("M", 1);
            if (w > 0) return w;
        }
        return @as(f32, @floatFromInt(self.font_size)) * 0.6;
    }

    /// Spalten, die neben Gutter und Padding in den Editor passen.
    pub fn visibleColCount(self: *const Self) usize {
        const avail = self.width - self.gutter_width - 12 - self.scrollbar_width;
        if (avail <= 0) return 10;
        return @max(10, @as(usize, @intFromFloat(@floor(avail / self.charWidth()))));
    }

    pub const VisibleSlice = struct { text: []const u8, start_byte: usize };

    /// Sichtbarer Ausschnitt einer Zeile ab `view.col`, höchstens `view.cols + 2` Spalten.
    /// Nur dieser Teil geht an Clay: Riesenzeilen kosten so weder Shaper noch Renderer, und
    /// Zeilen über 2048 Bytes (Shaper-Grenze) bleiben sichtbar. Spalten sind Codepoints
    /// (`metrics`), der Schnitt liegt also immer auf einer Zeichengrenze.
    pub fn visibleSliceOf(self: *Self, line_idx: usize, line: []const u8) VisibleSlice {
        const m = self.metrics();
        const cols = if (self.view.cols > 0) self.view.cols else self.visibleColCount();
        const start = @min(self.buffer.root.get_line_width_to_pos(line_idx, self.view.col, m) catch 0, line.len);
        const end = @min(self.buffer.root.get_line_width_to_pos(line_idx, self.view.col + cols + 2, m) catch line.len, line.len);
        if (start >= end) return .{ .text = line[line.len..], .start_byte = line.len };
        return .{ .text = line[start..end], .start_byte = start };
    }

    /// Wie visibleSliceOf, holt die Zeile selbst (Slice zeigt in line_scratch).
    pub fn visibleSlice(self: *Self, line_idx: usize) VisibleSlice {
        const line = self.getLine(line_idx);
        return self.visibleSliceOf(line_idx, line);
    }

    /// Spalten je Segment beim Word-Wrap: sichtbare Spalten abzüglich Minimap und einer
    /// Reservespalte, damit das Segmentende nicht unter der Minimap verschwindet.
    pub fn wrapCols(self: *const Self) usize {
        var cols = self.visibleColCount();
        if (self.show_minimap) cols -|= @as(usize, @intFromFloat(@ceil(self.minimap_width / self.charWidth())));
        return @max(cols -| 1, 10);
    }

    /// Sichtbare Reihen einer Buffer-Zeile (1 ohne Word-Wrap).
    pub fn visualRowsOf(self: *Self, line_idx: usize) usize {
        if (!self.word_wrap) return 1;
        return wrap_ops.segmentCount(self.getLine(line_idx), self.wrapCols());
    }

    /// Sichtbare Reihen der Buffer-Zeilen from..=to (beide einschließlich).
    pub fn visualRowsBetween(self: *Self, from: usize, to: usize) usize {
        if (to < from) return 0;
        var n: usize = 0;
        var i = from;
        while (i <= to and i < self.lineCount()) : (i += 1) n += self.visualRowsOf(i);
        return n;
    }

    pub const Hit = struct { line: usize, first_byte: usize };

    /// Buffer-Zeile und erstes Byte des Segments unter der sichtbaren Reihe `row` (ab view.row).
    pub fn hitRow(self: *Self, row: usize) Hit {
        const total = self.lineCount();
        if (total == 0) return .{ .line = 0, .first_byte = 0 };
        if (!self.word_wrap) return .{ .line = @min(self.view.row + row, total - 1), .first_byte = 0 };
        const cols = self.wrapCols();
        var line = self.view.row;
        var remaining = row;
        while (line < total) : (line += 1) {
            const text = self.getLine(line);
            const n = wrap_ops.segmentCount(text, cols);
            if (remaining < n) {
                var start: usize = 0;
                var k: usize = 0;
                while (k < remaining) : (k += 1) {
                    const seg = wrap_ops.nextSegment(text, cols, start, 0) orelse break;
                    start = seg.end;
                }
                return .{ .line = line, .first_byte = start };
            }
            remaining -= n;
        }
        return .{ .line = total - 1, .first_byte = 0 };
    }

    /// Änderung vormerken (vor dem Buffer-Edit, aus pushEditForChange). Zwei Änderungen
    /// vor der nächsten Messung: voller Neuaufbau statt Bereichsrechnung.
    fn noteLineChange(self: *Self, row: usize, old_lines: usize, new_lines: usize) void {
        if (self.longest_pending != null) {
            self.longest_valid = false;
            return;
        }
        self.longest_pending = .{ .start = row, .old_end = row + old_lines + 1, .new_end = row + new_lines + 1 };
    }

    /// Breite der längsten Zeile der Datei in Spalten, Grundlage der waagrechten Leiste.
    /// Anders als der Ausschnitt bleibt sie beim senkrechten Scrollen stabil.
    pub fn maxLineWidth(self: *Self) usize {
        if (!self.longest_valid) {
            self.longest_pending = null;
            self.measureLongest(0, self.lineCount());
            self.longest_valid = true;
        } else if (self.longest_pending) |p| {
            self.longest_pending = null;
            self.applyLineChange(p);
        }
        return self.longest_line_width;
    }

    fn measureLongest(self: *Self, start: usize, end: usize) void {
        self.longest_line_width = 0;
        self.longest_line_idx = start;
        var i = start;
        while (i < end) : (i += 1) {
            const w = self.lineWidth(i);
            if (w > self.longest_line_width) {
                self.longest_line_width = w;
                self.longest_line_idx = i;
            }
        }
    }

    /// Nur den geänderten Bereich messen. Lag die bisher längste Zeile davor, bleibt sie;
    /// lag sie dahinter, rückt ihr Index um die Zeilendifferenz; lag sie im Bereich und
    /// ist jetzt kürzer, wird die ganze Datei neu gemessen.
    fn applyLineChange(self: *Self, p: LineChange) void {
        const total = self.lineCount();
        const end = @min(p.new_end, total);
        const prev_width = self.longest_line_width;
        const prev_idx = self.longest_line_idx;
        var range_width: usize = 0;
        var range_idx = p.start;
        var i = p.start;
        while (i < end) : (i += 1) {
            const w = self.lineWidth(i);
            if (w > range_width) {
                range_width = w;
                range_idx = i;
            }
        }
        if (range_width >= prev_width) {
            self.longest_line_width = range_width;
            self.longest_line_idx = range_idx;
        } else if (prev_idx < p.start) {
            // unverändert
        } else if (prev_idx >= p.old_end) {
            self.longest_line_idx = prev_idx + p.new_end - p.old_end;
        } else {
            self.measureLongest(0, total);
        }
    }

    /// Senkrechte Leiste am rechten Rand: Offset in Zeilen, Inhalt in Reihen (Word-Wrap).
    fn vscrollModel(self: *Self) scrollbar.Model {
        return .{
            .axis = .vertical,
            .x = self.content_origin_x + self.width - self.scrollbar_width,
            .y = self.content_origin_y,
            .len = self.height,
            .thickness = self.scrollbar_width,
            .total = self.totalVisualRows(),
            .visible = self.visibleLineCount(),
            .offset = self.view.row,
            .max_offset = self.maxViewRow(),
        };
    }

    /// Waagrechte Leiste am unteren Rand über die volle Breite (auch über dem Gutter),
    /// null wenn alles passt oder Word-Wrap an ist.
    pub fn hscrollModel(self: *Self) ?scrollbar.Model {
        if (self.word_wrap) return null;
        const cols = if (self.view.cols > 0) self.view.cols else self.visibleColCount();
        const max_w = self.maxLineWidth();
        if (max_w <= cols) return null;
        const total = max_w + 4;
        return .{
            .axis = .horizontal,
            .x = self.content_origin_x,
            .y = self.content_origin_y + self.height - self.scrollbar_width,
            .len = @max(0, self.width - self.scrollbar_width),
            .thickness = self.scrollbar_width,
            .total = total,
            .visible = cols,
            .offset = self.view.col,
            .max_offset = total - cols,
            .min_thumb = 30,
        };
    }

    fn handleHScrollbarMouseDown(self: *Self, x: f32, y: f32) bool {
        const m = self.hscrollModel() orelse return false;
        const hit = scrollbar.hitTest(m, x, y);
        switch (hit) {
            .none => return false,
            .thumb => |d| self.hscroll_drag = d,
            .page_back, .page_forward => self.view.col = scrollbar.pageOffset(m, hit),
        }
        return true;
    }

    /// Horizontal scrollen (Shift+Mausrad): positiv = nach links wie scrollLines nach oben.
    pub fn scrollColumns(self: *Self, delta: i32) void {
        if (self.word_wrap) return;
        if (delta > 0) {
            self.view.col = self.view.col -| @as(usize, @intCast(delta));
        } else if (delta < 0) {
            self.view.col += @as(usize, @intCast(-delta));
        }
    }

    // =========================================================================
    // Scrolling
    // =========================================================================

    pub fn scrollLines(self: *Self, delta: i32) void {
        if (delta > 0) {
            const amount = @as(usize, @intCast(delta));
            self.view.row = if (amount > self.view.row) 0 else self.view.row - amount;
        } else if (delta < 0) {
            const amount = @as(usize, @intCast(-delta));
            self.view.row = @min(self.view.row + amount, self.maxViewRow());
        }
    }

    pub fn visibleLineCount(self: *const Self) usize {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return 10;
        const available = self.height;
        if (available <= 0) return 10;
        return @max(1, @as(usize, @intFromFloat(@floor(available / line_height))));
    }

    /// Höchste Buffer-Zeile, die oben stehen darf, damit der Schirm bis zum Dateiende
    /// gefüllt ist. Mit Word-Wrap zählen die sichtbaren Reihen, nicht die Zeilen: von
    /// hinten aufsummieren, bis der Schirm voll ist.
    pub fn maxViewRow(self: *Self) usize {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total == 0) return 0;
        if (!self.word_wrap) return if (total > visible) total - visible else 0;
        var rows: usize = 0;
        var line = total;
        while (line > 0) {
            const next = rows + self.visualRowsOf(line - 1);
            if (next > visible) break;
            rows = next;
            line -= 1;
        }
        return line;
    }

    /// Sichtbare Reihen des ganzen Buffers (Zeilen ohne Word-Wrap). Mit Word-Wrap
    /// je Root und Spaltenzahl gecacht, ab `visual_rows_sample_max` Zeilen aus einer
    /// Stichprobe geschätzt: der Wert bestimmt nur die Thumb-Größe der Scrollbar, und
    /// ein Durchlauf über 40k Zeilen kostet sonst 300 ms pro Frame.
    pub fn totalVisualRows(self: *Self) usize {
        const total = self.lineCount();
        if (!self.word_wrap or total == 0) return total;
        const cols = self.wrapCols();
        if (self.visual_rows_cache) |c| {
            if (c.root == self.buffer.root and c.cols == cols) return c.total;
        }
        const rows = if (total <= visual_rows_sample_max) self.visualRowsBetween(0, total - 1) else self.estimateVisualRows(total);
        self.visual_rows_cache = .{ .root = self.buffer.root, .cols = cols, .total = rows };
        return rows;
    }

    /// Schätzung aus `visual_rows_sample_max` Zeilen: gleichmäßige Schritte, innerhalb
    /// jedes Schritts ein deterministisch gestreuter Versatz, damit periodische Inhalte
    /// (jede zweite Zeile lang) die Stichprobe nicht verzerren. Nie unter `total`.
    fn estimateVisualRows(self: *Self, total: usize) usize {
        const stride = (total + visual_rows_sample_max - 1) / visual_rows_sample_max;
        var sum: usize = 0;
        var count: usize = 0;
        var start: usize = 0;
        var seed: u64 = 0x9E3779B97F4A7C15;
        while (start < total) : (start += stride) {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            const offset: usize = @intCast((seed >> 33) % stride);
            const line = @min(start + offset, total - 1);
            sum += self.visualRowsOf(line);
            count += 1;
        }
        if (count == 0) return total;
        return @max(total, sum * total / count);
    }

    pub fn ensureCursorVisible(self: *Self) void {
        self.view.rows = self.visibleLineCount();
        if (self.word_wrap) {
            // Nie horizontal scrollen; umgebrochene Zeilen brauchen mehr Reihen als Buffer-Zeilen
            self.view.col = 0;
            self.view.cols = 1_000_000;
            self.view.clamp(&self.cursor, true);
            while (self.view.row < self.cursor.row and self.visualRowsBetween(self.view.row, self.cursor.row) > self.view.rows) self.view.row += 1;
            return;
        }
        self.view.cols = self.visibleColCount();
        self.view.clamp(&self.cursor, true);
    }

    pub fn handleChar(self: *Self, char_code: u21) void {
        if (self.extra_cursors.items.len == 0 or self.find.active or self.goto.active) return self.handleCharSingle(char_code);
        if (char_code < 32 or char_code == 127) return;
        if (!self.typing_in_progress) {
            self.snapshotForUndo();
            self.typing_in_progress = true;
        }
        self.in_multi = true;
        defer self.in_multi = false;
        self.forEachCursor(null, char_code);
    }

    fn handleCharSingle(self: *Self, char_code: u21) void {
        if (char_code < 128) {
            std.log.scoped(.editor).debug("handleChar: '{c}'", .{@as(u8, @intCast(char_code))});
        } else {
            std.log.scoped(.editor).debug("handleChar: U+{X}", .{char_code});
        }
        if (char_code < 32 or char_code == 127) return;
        if (self.mods.ctrl and !self.mods.alt) return;
        if (self.find.active) {
            self.handleFindChar(char_code);
            return;
        }
        if (self.goto.active) {
            if (char_code >= '0' and char_code <= '9' and self.goto.len < self.goto.digits.len) {
                self.goto.digits[self.goto.len] = @intCast(char_code);
                self.goto.len += 1;
            }
            return;
        }

        const moved = self.cursor.row != self.typing_end.row or self.cursor.col != self.typing_end.col;
        if (!self.in_multi and (!self.typing_in_progress or moved)) {
            self.snapshotForUndo();
            self.typing_in_progress = true;
        }
        defer self.typing_end = .{ .row = self.cursor.row, .col = self.cursor.col };

        // Autoclose: Klammern und Anführungszeichen als Paar, Schließen springt drüber
        if (edit_ops.closerFor(char_code)) |closer| {
            if (!self.hasSelection()) {
                const line_text = self.getLine(self.cursor.row);
                const byte_pos = @min(self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, self.metrics()) catch line_text.len, line_text.len);
                const prev_b: ?u8 = if (byte_pos > 0) line_text[byte_pos - 1] else null;
                const next_b: ?u8 = if (byte_pos < line_text.len) line_text[byte_pos] else null;
                switch (edit_ops.autoclosePolicy(char_code, prev_b, next_b)) {
                    .skip_over => {
                        self.cursor.col += 1;
                        self.cursor.target = self.cursor.col;
                        self.recordCursorMovement();
                        return;
                    },
                    .insert_pair => {
                        const pair = [_]u8{ @intCast(char_code), closer };
                        self.insertString(&pair) catch return;
                        self.cursor.col -= 1;
                        self.cursor.target = self.cursor.col;
                        self.recordCursorMovement();
                        return;
                    },
                    .plain => {},
                }
            }
        } else if (char_code == ')' or char_code == ']' or char_code == '}') {
            if (!self.hasSelection()) {
                const line_text = self.getLine(self.cursor.row);
                const byte_pos = @min(self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, self.metrics()) catch line_text.len, line_text.len);
                const next_b: ?u8 = if (byte_pos < line_text.len) line_text[byte_pos] else null;
                if (edit_ops.autoclosePolicy(char_code, null, next_b) == .skip_over) {
                    self.cursor.col += 1;
                    self.cursor.target = self.cursor.col;
                    self.recordCursorMovement();
                    return;
                }
            }
        }

        if (self.deleteSelection()) {}

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char_code, &buf) catch return;

        // pushEdit für Insert des Zeichens
        const ins_row = self.cursor.row;
        const ins_col = self.cursor.col;
        self.pushEditForChange(ins_row, ins_col, "", buf[0..len]);

        const m = self.metrics();
        std.log.debug("INSERT: row={} col={} char=U+{X}", .{ self.cursor.row, self.cursor.col, char_code });
        const result = self.buffer.root.insert_chars(
            self.cursor.row,
            self.cursor.col,
            buf[0..len],
            self.buffer.allocator,
            m,
        ) catch |err| {
            std.log.err("INSERT FAILED: {} row={} col={} err={}", .{ char_code, self.cursor.row, self.cursor.col, err });
            return;
        };
        std.log.debug("INSERT OK: row={} col={}", .{ self.cursor.row, self.cursor.col });
        self.buffer.root = result[2];
        // Neue Spalte aus insert_chars (Anzeigebreite), nicht die Byte-Länge: ein Umlaut ist
        // 2 Bytes, aber 1 Spalte
        self.cursor.col = result[1];
        self.cursor.target = self.cursor.col;
        self.recordCursorMovement();
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    pub fn render(self: *Self, arena: std.mem.Allocator, mouse_pressed: bool) void {
        self.desired_cursor = .arrow;
        self.last_frame_hovered = false; // Reset each frame
        // Sichtbare Spalten aus der aktuellen Breite. Vorher stand view.cols nur nach einer
        // Cursorbewegung (ensureCursorVisible) auf dem Wert der Breite; nach dem Öffnen einer
        // Datei galt die Vorgabe von 800 px (50 Spalten): Zeilen endeten in breiten Fenstern
        // bei Spalte 50 und die horizontale Leiste erschien, obwohl alles Platz hatte.
        if (!self.word_wrap) self.view.cols = self.visibleColCount();

        const editor_id = clay.ElementId.IDI("code_editor", @truncate(@intFromPtr(self)));

        clay.UI()(.{
            .id = editor_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right,
            },
            .background_color = self.bg_color,
        })({
            if (self.find.active) self.renderFindWidget(arena, editor_id);
            if (self.goto.active) self.renderGotoWidget(arena, editor_id);
            self.autoScrollWhileDragging();
            self.bracket_pair = self.findBracketPair();
            // pointerOver must be called INSIDE clay.UI where Clay's internal state is valid
            if (clay.pointerOver(editor_id)) {
                self.last_frame_hovered = true;
                self.desired_cursor = .text;
            }

            // Phase 5: Progress Indicator
            if (self.bg_parsing) {
                clay.UI()(.{
                    .id = self.idi("parsing_indicator", 0),
                    .layout = .{
                        .sizing = .fit,
                        .padding = .axes(6, 12),
                        .child_alignment = .center,
                    },
                    .background_color = .{ 45, 45, 70, 220 },
                    .corner_radius = .all(6),
                    .floating = .{
                        .attach_to = .to_parent,
                        .attach_points = .{
                            .element = .right_top,
                            .parent = .right_top,
                        },
                        .offset = .{ .x = -40, .y = 20 },
                        .z_index = 100,
                    },
                })({
                    clay.text("Parsing...", .{ .font_size = 16, .color = .{ 200, 200, 255, 255 } });
                });
            }

            clay.UI()(.{
                .id = self.idi("editor_scroll", 0),
                .layout = .{ .sizing = .grow },
                .background_color = self.bg_color,
                .clip = .{ .vertical = true, .horizontal = true },
            })({
                clay.UI()(.{
                    .id = self.idi("editor_content", 0),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                    },
                })({
                    const total = self.lineCount();

                    // Dynamische Gutter-Breite basierend auf maximaler Zeilennummer
                    if (!self.show_gutter) {
                        self.gutter_width = 0;
                    } else if (self.measure_fn) |measure| {
                        var buf: [16]u8 = undefined;
                        const sample = std.fmt.bufPrint(&buf, "{d}", .{total}) catch "000";
                        // Padding: 8 (links) + 16 (rechts) = 24
                        const needed = measure(sample.ptr, sample.len) + 24;
                        // Nur vergrößern (oder sanft schrumpfen), um Flackern zu vermeiden
                        self.gutter_width = @max(50, needed);
                    }

                    const visible_count = self.visibleLineCount();
                    const start_line = @min(self.view.row, total);
                    const wrap_cols = self.wrapCols();
                    var rows_used: usize = 0;

                    var i: usize = start_line;
                    while (i < total and rows_used < visible_count + 1) : (i += 1) {
                        const line_text = arena.dupe(u8, self.getLine(i)) catch "";
                        const is_current = (i == self.cursor.row);

                        const is_selected = if (self.hasSelection()) blk: {
                            const range = self.selectionRange().?;
                            break :blk i >= range.begin.row and i <= range.end.row;
                        } else false;

                        // Ohne Word-Wrap ein Segment = sichtbarer Ausschnitt; mit Wrap je Segment eine Reihe
                        const one: [1]wrap_ops.Segment = blk: {
                            const vis = self.visibleSliceOf(i, line_text);
                            break :blk .{.{ .start = vis.start_byte, .end = vis.start_byte + vis.text.len, .col = self.view.col }};
                        };
                        const segs: []const wrap_ops.Segment = if (self.word_wrap) (wrap_ops.segments(arena, line_text, wrap_cols) catch &one) else &one;
                        for (segs, 0..) |seg, k| {
                            const vrow = rows_used;
                            rows_used += 1;
                            const is_last_seg = k + 1 == segs.len;

                            clay.UI()(.{
                                // Erstes Segment behält die ID je Buffer-Zeile (E2E: element_bounds_i("code", zeile)),
                                // Fortsetzungsreihen bekommen eigene IDs je sichtbarer Reihe
                                .id = if (k == 0) self.idi("row", @intCast(i)) else self.idi("roww", @intCast(vrow)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                    .direction = .left_to_right,
                                    .child_alignment = .{ .x = .left, .y = .center },
                                },
                            })({
                                if (self.show_gutter) clay.UI()(.{
                                    .id = if (k == 0) self.idi("gutter", @intCast(i)) else self.idi("gutterw", @intCast(vrow)),
                                    .layout = .{
                                        .sizing = .{ .w = .fixed(self.gutter_width), .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                        .padding = .{ .left = 8, .right = 16 },
                                        .child_alignment = .{ .x = .right, .y = .center },
                                    },
                                    .background_color = if (is_selected) self.selection_color else if (is_current) self.current_line_highlight else self.gutter_color,
                                })({
                                    const color = if (is_current)
                                        self.current_line_number_color
                                    else
                                        self.line_number_color;

                                    var buf: [16]u8 = undefined;
                                    // Fortsetzungsreihen einer umgebrochenen Zeile bleiben ohne Nummer
                                    const line_num_str = if (k == 0) (std.fmt.bufPrint(&buf, "{d}", .{i + 1}) catch "?") else "";
                                    const persistent_str = arena.dupe(u8, line_num_str) catch "";
                                    clay.text(persistent_str, .{ .font_size = self.font_size, .color = color });
                                });

                                clay.UI()(.{
                                    .id = if (k == 0) self.idi("code", @intCast(i)) else self.idi("codew", @intCast(vrow)),
                                    .layout = .{
                                        .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                        .padding = .{ .left = 12 },
                                        .child_alignment = .{ .x = .left, .y = .center },
                                    },
                                    .background_color = if (is_current) self.current_line_highlight else .{ 0, 0, 0, 0 },
                                })({
                                    self.renderLine(arena, i, line_text[seg.start..seg.end], seg.start, line_text.len, seg.col, is_last_seg);
                                });
                            });
                        }
                    }
                });
            });

            if (self.lineCount() > self.visibleLineCount()) {
                self.renderScrollbar();
            }
            self.renderHScrollbar();
            if (self.show_minimap) self.renderMinimap(mouse_pressed);
        });

        if (self.show_context_menu) self.renderContextMenu();
    }

    /// `line` ist das sichtbare Stück (ab Byte `offset`, Anzeigespalte `first_col`) der Zeile
    /// `line_idx` mit `full_len` Bytes; `is_last` = letztes Segment (Cursor am Zeilenende, Auswahl bis Zeilenende).
    fn renderLine(self: *Self, arena: std.mem.Allocator, line_idx: usize, line: []const u8, offset: usize, full_len: usize, first_col: usize, is_last: bool) void {
        const seg: VisibleSlice = .{ .text = line, .start_byte = offset };
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .grow }, .direction = .left_to_right, .child_alignment = .{ .x = .left, .y = .center } },
        })({
            if (self.hasSelection()) {
                self.renderSelection(arena, line_idx, seg, is_last);
            }

            const plain_color: clay.Color = self.text_color;
            if (self.highlighter != null) {
                renderHighlightedLine(arena, self.highlighter.?, line_idx, line, offset, full_len, self.font_size, plain_color);
            } else {
                const persistent = arena.dupe(u8, line) catch "";
                clay.text(persistent, .{ .font_size = self.font_size, .color = plain_color, .wrap_mode = .none });
            }

            if (line_idx == self.cursor.row) {
                self.renderCursor(arena, seg, is_last);
            }
            // Zusätzliche Cursor (mit Auswahl) auf dieser Zeile: kurz einwechseln und wie den Hauptcursor zeichnen
            if (self.extra_cursors.items.len > 0) {
                const saved_cursor = self.cursor;
                const saved_anchor = self.selection_anchor;
                for (self.extra_cursors.items) |ec| {
                    self.cursor = ec.cursor;
                    self.selection_anchor = ec.anchor;
                    if (self.hasSelection()) self.renderSelection(arena, line_idx, seg, is_last);
                    if (ec.cursor.row == line_idx) self.renderCursor(arena, seg, is_last);
                }
                self.cursor = saved_cursor;
                self.selection_anchor = saved_anchor;
            }
            self.renderRowOverlays(arena, line_idx, line, self.getLine(line_idx), first_col);
        });
    }

    fn renderSelection(self: *Self, arena: std.mem.Allocator, line_idx: usize, vis: VisibleSlice, is_last: bool) void {
        const range = self.selectionRange() orelse return;
        if (line_idx < range.begin.row or line_idx > range.end.row) return;

        const full_line = self.getLine(line_idx);

        const start_col = if (line_idx == range.begin.row) range.begin.col else 0;
        const end_col = if (line_idx == range.end.row) range.end.col else self.lineWidth(line_idx);

        const start_byte = self.buffer.root.get_line_width_to_pos(line_idx, start_col, self.metrics()) catch 0;
        const end_byte = self.buffer.root.get_line_width_to_pos(line_idx, end_col, self.metrics()) catch full_line.len;

        // In den sichtbaren Ausschnitt bzw. das Segment verschieben
        const line = vis.text;
        // Auswahl beginnt erst hinter diesem Segment
        if (start_byte > vis.start_byte + line.len or (start_byte == vis.start_byte + line.len and !is_last)) return;
        const start_clamped = @min(start_byte -| vis.start_byte, line.len);
        const end_clamped = @min(end_byte -| vis.start_byte, line.len);

        if (start_clamped >= end_clamped and line_idx < range.end.row and is_last) {
            // Selection extends to end of line
            const prefix = line[0..start_clamped];
            const selected_text = line[start_clamped..];

            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(@floatFromInt(self.font_size + 16)) } },
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                    .offset = .{ .x = 0, .y = 0 },
                },
            })({
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fit, .h = .grow }, .direction = .left_to_right },
                })({
                    const p = arena.dupe(u8, prefix) catch "";
                    clay.text(p, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });

                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fit, .h = .grow } },
                        .background_color = self.selection_color,
                    })({
                        const s = arena.dupe(u8, selected_text) catch "";
                        clay.text(s, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(10), .h = .grow } } })({});
                    });
                });
            });
        } else if (start_clamped < end_clamped) {
            const prefix = line[0..start_clamped];
            const selected_text = line[start_clamped..end_clamped];

            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(@floatFromInt(self.font_size + 16)) } },
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                    .offset = .{ .x = 0, .y = 0 },
                },
            })({
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fit, .h = .grow }, .direction = .left_to_right },
                })({
                    const p = arena.dupe(u8, prefix) catch "";
                    clay.text(p, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });

                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fit, .h = .grow } },
                        .background_color = self.selection_color,
                    })({
                        const s = arena.dupe(u8, selected_text) catch "";
                        clay.text(s, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });
                        if (line_idx < range.end.row) {
                            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(10), .h = .grow } } })({});
                        }
                    });
                });
            });
        }
    }

    fn renderCursor(self: *Self, arena: std.mem.Allocator, seg: VisibleSlice, is_last: bool) void {
        const offset = seg.start_byte;
        const blink_ms: f32 = 500.0;
        const blink_delay_ms: f32 = 400.0;

        const time_since_movement = self.time_ms - self.last_cursor_movement_ms;
        const is_moving = time_since_movement < blink_delay_ms;
        const visible = is_moving or (@mod(self.time_ms, blink_ms * 2.0) < blink_ms);
        if (!visible) return;

        const line = self.getLine(self.cursor.row);
        const m = self.metrics();
        const byte_pos = @min(self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch line.len, line.len);
        // Cursor nur im Segment zeichnen, in dem er liegt (Segmentende gehört zum nächsten Segment)
        if (byte_pos < offset) return;
        const seg_end = offset + seg.text.len;
        if (byte_pos > seg_end or (byte_pos == seg_end and !is_last)) return;
        const text_before_cursor = if (byte_pos > offset) line[offset..byte_pos] else line[0..0];

        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(@floatFromInt(self.font_size + 16)) } },
            .floating = .{
                .attach_to = .to_parent,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = .{ .x = 0, .y = 0 },
            },
        })({
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fit, .h = .grow }, .direction = .left_to_right },
            })({
                const persistent = arena.dupe(u8, text_before_cursor) catch "";
                clay.text(persistent, .{ .font_size = self.font_size, .color = .{ 0, 0, 0, 0 } });

                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fixed(2), .h = .grow } },
                    .background_color = self.cursor_color,
                })({});
            });
        });
    }

    /// Senkrechte Leiste rechts (Modul `scrollbar`).
    fn renderScrollbar(self: *Self) void {
        if (scrollbar.render(self.vscrollModel(), .{ .track = self.idi("scrollbar_track", 0), .thumb = self.idi("scrollbar_thumb", 0) })) self.desired_cursor = .arrow;
    }

    /// Senkrechte oder waagrechte Leiste unter (x, y): dort Pfeil statt I-Beam.
    pub fn isMouseOverScrollbar(self: *Self, x: f32, y: f32) bool {
        if (scrollbar.hitTest(self.vscrollModel(), x, y) != .none) return true;
        const h = self.hscrollModel() orelse return false;
        return scrollbar.hitTest(h, x, y) != .none;
    }

    fn handleScrollbarMouseDown(self: *Self, x: f32, y: f32) bool {
        const m = self.vscrollModel();
        const hit = scrollbar.hitTest(m, x, y);
        switch (hit) {
            .none => return false,
            .thumb => |d| self.vscroll_drag = d,
            .page_back, .page_forward => self.view.row = scrollbar.pageOffset(m, hit),
        }
        return true;
    }

    /// Ausgeblendete Menüeinträge: Markdown Preview nur bei .md, Export to PDF nur
    /// bei Marp-Decks (`marp: true` im Front-Matter des Buffers), im Eingabefeld
    /// (compact_menu) weder Preview noch Split.
    fn menuHidden(self: *Self) ctx_menu.Hidden {
        var hidden = ctx_menu.none;
        const is_md = std.mem.endsWith(u8, self.buffer.get_file_path(), ".md");
        if (!is_md or self.compact_menu) {
            hidden.insert(.md_preview);
            hidden.insert(.md_export_pdf);
        } else if (!marp.isMarpDeck(self.buffer.store_to_string_cached(self.buffer.root, self.buffer.file_eol_mode))) {
            hidden.insert(.md_export_pdf);
        }
        if (self.compact_menu) {
            hidden.insert(.split_vertical);
            hidden.insert(.split_horizontal);
        }
        if (self.compact_menu or self.buffer.get_file_path().len == 0) hidden.insert(.file_history);
        return hidden;
    }

    /// Kontextmenü (`shortcuts.editor_menu_items`, IDs `editor_menu_<command>`) im gemeinsamen Stil.
    fn renderContextMenu(self: *Self) void {
        if (ctx_menu.render("editor_menu", &shortcuts.editor_menu_items, self.context_menu_x, self.context_menu_y, self.menuHidden(), self.menu_colors)) {
            self.desired_cursor = .arrow;
        }
    }

    pub fn getLineByteLen(self: *Self, line_idx: usize) usize {
        return self.getLine(line_idx).len;
    }
};

// =========================================================================
// Tests (adapted for flow_core.Buffer)
// =========================================================================

test "setText: CRLF wird zu LF normalisiert" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("line1\r\nline2\r\nline3");
    try std.testing.expectEqual(@as(usize, 3), ed.lineCount());
    try std.testing.expectEqualStrings("line1", ed.getLine(0));
    try std.testing.expectEqualStrings("line2", ed.getLine(1));
    try std.testing.expectEqualStrings("line3", ed.getLine(2));
}

test "setText: leerer String erzeugt eine leere Zeile" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("");
    try std.testing.expectEqual(@as(usize, 1), ed.lineCount());
    try std.testing.expectEqualStrings("", ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "Enter mitten in der Zeile splittet korrekt" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("abcdef");
    const m = ed.metrics();
    const byte_pos = ed.buffer.root.get_line_width_to_pos(0, 3, m) catch 0;
    ed.cursor.col = byte_pos;
    ed.handleKeyPress(.enter);

    try std.testing.expectEqual(@as(usize, 2), ed.lineCount());
    try std.testing.expectEqualStrings("abc", ed.getLine(0));
    try std.testing.expectEqualStrings("def", ed.getLine(1));
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.row);
}

test "Backspace am Zeilenanfang mergt mit vorheriger Zeile" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 1;
    ed.cursor.col = 0;
    ed.handleKeyPress(.backspace);

    try std.testing.expectEqual(@as(usize, 1), ed.lineCount());
    try std.testing.expectEqualStrings("abcdef", ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "Delete am Zeilenende mergt mit nächster Zeile" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 0;
    const m = ed.metrics();
    const lw = ed.buffer.root.line_width(0, m) catch 0;
    ed.cursor.col = lw;
    ed.handleKeyPress(.delete);

    try std.testing.expectEqual(@as(usize, 1), ed.lineCount());
    try std.testing.expectEqualStrings("abcdef", ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "Navigation: Left am Zeilenanfang springt ans Ende der vorherigen Zeile" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 1;
    ed.cursor.col = 0;
    ed.handleKeyPress(.left);

    try std.testing.expectEqual(@as(usize, 0), ed.cursor.row);
}

test "Navigation: Right bewegt Cursor um EINE Position weiter" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("abcdef");
    ed.cursor.row = 0;
    ed.cursor.col = 0;
    const m = ed.metrics();

    // Erster Right: col=0 → col=1
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);

    // Zweiter Right: col=1 → col=2
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.col);

    // Dritter Right: col=2 → col=3
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);

    // Am Zeilenende (col=6): Right springt zur nächsten Zeile
    ed.cursor.col = 6;
    ed.cursor.row = 0;
    ed.setText("abcdef\nxyz");
    ed.cursor.col = 6;
    ed.cursor.row = 0;
    ed.cursor.move_right(ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "Navigation: Right am Zeilenende springt an Anfang der nächsten Zeile" {
    const allocator = std.testing.allocator;
    var buffer = try flow_core.Buffer.create(allocator);
    defer buffer.deinit();
    var ed = CodeEditor.init(allocator, buffer);
    defer ed.deinit();

    ed.setText("abc\ndef");
    ed.cursor.row = 0;
    const m = ed.metrics();
    const lw = ed.buffer.root.line_width(0, m) catch 0;
    ed.cursor.col = lw;
    ed.handleKeyPress(.right);

    try std.testing.expectEqual(@as(usize, 1), ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

// Test-Binary: wio-Backend-Symbole erzwingen (wio_wl_proxy_* werden sonst nicht
// emittiert und der Linker meldet undefined symbols). Nur im Test relevant.
comptime {
    if (@import("builtin").is_test) {
        _ = &wio.backend.init;
        _ = &wio.backend.deinit;
        if (@hasDecl(wio.backend, "wayland")) _ = &wio.backend.wayland.init;
    }
}

fn testEditor(allocator: std.mem.Allocator, text: []const u8) !struct { buffer: *flow_core.Buffer, ed: CodeEditor } {
    const buffer = try flow_core.Buffer.create(allocator);
    var ed = CodeEditor.init(allocator, buffer);
    ed.setText(text);
    return .{ .buffer = buffer, .ed = ed };
}

test "Kontextmenü: Export to PDF nur bei Marp-Decks, Preview bei jeder .md" {
    var plain = try testEditor(std.testing.allocator, "# Notiz\n\nText\n");
    defer plain.buffer.deinit();
    defer plain.ed.deinit();
    plain.buffer.set_file_path("/tmp/plain.md");
    try std.testing.expect(!plain.ed.menuHidden().contains(.md_preview));
    try std.testing.expect(plain.ed.menuHidden().contains(.md_export_pdf));

    var deck = try testEditor(std.testing.allocator, "---\nmarp: true\n---\n\n# Eins\n");
    defer deck.buffer.deinit();
    defer deck.ed.deinit();
    deck.buffer.set_file_path("/tmp/deck.md");
    try std.testing.expect(!deck.ed.menuHidden().contains(.md_preview));
    try std.testing.expect(!deck.ed.menuHidden().contains(.md_export_pdf));

    // Front-Matter erst nach dem Tippen: Menü folgt dem Buffer, nicht der Platte.
    deck.ed.setText("# Kein Deck mehr\n");
    try std.testing.expect(deck.ed.menuHidden().contains(.md_export_pdf));

    var zig_file = try testEditor(std.testing.allocator, "---\nmarp: true\n---\n");
    defer zig_file.buffer.deinit();
    defer zig_file.ed.deinit();
    zig_file.buffer.set_file_path("/tmp/x.zig");
    try std.testing.expect(zig_file.ed.menuHidden().contains(.md_export_pdf));
}

test "Kontextmenü: File History bei Dateien mit Pfad, nicht im Eingabefeld; Klick setzt pending" {
    var t = try testEditor(std.testing.allocator, "x\n");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    try std.testing.expect(t.ed.menuHidden().contains(.file_history)); // noch kein Pfad
    t.buffer.set_file_path("/tmp/a.zig");
    try std.testing.expect(!t.ed.menuHidden().contains(.file_history));
    t.ed.compact_menu = true;
    try std.testing.expect(t.ed.menuHidden().contains(.file_history));

    t.ed.dispatchAction(.FileHistory);
    try std.testing.expect(t.ed.pending_file_history);
}

/// Editor mit 10 Wrap-Spalten (Untergrenze) und Word-Wrap an.
fn wrapTestEditor(allocator: std.mem.Allocator, text: []const u8) !struct { buffer: *flow_core.Buffer, ed: CodeEditor } {
    var t = try testEditor(allocator, text);
    t.ed.width = 50 + 12 + t.ed.scrollbar_width + 145;
    t.ed.height = 3 * (24 + 16);
    t.ed.show_minimap = false;
    t.ed.word_wrap = true;
    return .{ .buffer = t.buffer, .ed = t.ed };
}

test "totalVisualRows: exakt bei kleinen Dateien, Cache folgt dem Buffer" {
    var t = try wrapTestEditor(std.testing.allocator, "aaa bbb ccc ddd eee\nkurz\nfff ggg hhh");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    try std.testing.expectEqual(@as(usize, 6), t.ed.totalVisualRows());
    // Zweiter Aufruf ohne Änderung: gleicher Wert (aus dem Cache)
    try std.testing.expectEqual(@as(usize, 6), t.ed.totalVisualRows());
    // Edit ändert den Root → Cache verfällt: "kurz" wird zu drei Reihen
    t.ed.cursor = .{ .row = 1, .col = 4, .target = 4 };
    try t.ed.insertString(" aaa bbb ccc ddd");
    try std.testing.expectEqual(@as(usize, 8), t.ed.totalVisualRows());
    // Ohne Word-Wrap zählt jede Zeile eine Reihe
    t.ed.word_wrap = false;
    try std.testing.expectEqual(@as(usize, 3), t.ed.totalVisualRows());
}

test "totalVisualRows: große Dateien werden gesampelt, Schätzung bleibt nah dran" {
    const allocator = std.testing.allocator;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    // 20000 Zeilen, abwechselnd 3 Reihen und 1 Reihe → exakt 40000 Reihen. Eine
    // Stichprobe mit festem Schritt liefe hier auf ein Muster; die Schätzung muss trotzdem passen.
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        try text.appendSlice(allocator, if (i % 2 == 0) "aaa bbb ccc ddd eee\n" else "kurz\n");
    }
    var t = try wrapTestEditor(allocator, text.items);
    defer t.buffer.deinit();
    defer t.ed.deinit();
    const total = t.ed.lineCount();
    try std.testing.expect(total > visual_rows_sample_max);
    const rows = t.ed.totalVisualRows();
    try std.testing.expect(rows >= 36000 and rows <= 44000);
    try std.testing.expect(rows >= total);
}

test "DeleteLine: mittlere Zeile verschwindet, Cursor bleibt auf der Zeile" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei\ndrei");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor.row = 1;
    t.ed.dispatchAction(.DeleteLine);
    try std.testing.expectEqual(@as(usize, 2), t.ed.lineCount());
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
}

test "DeleteLine: letzte Zeile ohne Umbruch verschwindet samt vorherigem Umbruch" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei\ndrei");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor.row = 2;
    t.ed.dispatchAction(.DeleteLine);
    try std.testing.expectEqual(@as(usize, 2), t.ed.lineCount());
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
}

test "DeleteLine: einzige Zeile wird nur geleert" {
    var t = try testEditor(std.testing.allocator, "allein");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.dispatchAction(.DeleteLine);
    try std.testing.expectEqual(@as(usize, 1), t.ed.lineCount());
    try std.testing.expectEqual(@as(usize, 0), t.ed.cursor.row);
}

test "ensureCursorVisible: eine sichtbare Zeile, Cursor in Zeile 2 → kein Überlauf, Cursor sichtbar" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei\ndrei");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    // Höhe für genau eine Zeile (z. B. auf 40 px verkleinertes Chat-Eingabefeld)
    t.ed.height = @as(f32, @floatFromInt(t.ed.font_size + 16)) + 1;
    t.ed.width = 800;
    try std.testing.expectEqual(@as(usize, 1), t.ed.visibleLineCount());
    t.ed.cursor.row = 1;
    t.ed.ensureCursorVisible();
    try std.testing.expect(t.ed.view.row <= t.ed.cursor.row);
    try std.testing.expect(t.ed.cursor.row < t.ed.view.row + t.ed.view.rows);
}

test "Undo/Redo: Cursor steht an der Änderung, nicht am Dateianfang" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei\ndrei");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor.row = 2;
    t.ed.cursor.col = 4;
    t.ed.handleChar('X');
    try std.testing.expectEqualStrings("dreiX", t.ed.getLine(2));
    t.ed.dispatchAction(.Undo);
    try std.testing.expectEqualStrings("drei", t.ed.getLine(2));
    try std.testing.expectEqual(@as(usize, 2), t.ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 4), t.ed.cursor.col);
    t.ed.dispatchAction(.Redo);
    try std.testing.expectEqualStrings("dreiX", t.ed.getLine(2));
    try std.testing.expectEqual(@as(usize, 2), t.ed.cursor.row);
}

test "Undo: Tippen nach einem Cursorsprung ist ein eigener Schritt" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei\ndrei");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor.col = 4;
    t.ed.handleChar('a');
    t.ed.handleChar('b');
    t.ed.cursor.row = 2; // woanders hin, ohne dazwischen etwas anderes zu tun
    t.ed.cursor.col = 4;
    t.ed.handleChar('X');
    t.ed.dispatchAction(.Undo);
    try std.testing.expectEqualStrings("einsab", t.ed.getLine(0));
    try std.testing.expectEqualStrings("drei", t.ed.getLine(2));
    try std.testing.expectEqual(@as(usize, 2), t.ed.cursor.row);
}

test "Undo: nach dem Speichern beginnt ein neuer Schritt, Undo trifft den gespeicherten Stand" {
    var t = try testEditor(std.testing.allocator, "eins");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor.col = 4;
    t.ed.handleChar('a');
    t.buffer.last_save = t.buffer.root; // wie store_to_file_and_clean
    t.ed.markSaved();
    t.ed.handleChar('b');
    t.ed.dispatchAction(.Undo);
    try std.testing.expectEqualStrings("einsa", t.ed.getLine(0));
    try std.testing.expect(!t.ed.is_modified);
}

test "Undo zurück auf den gespeicherten Stand: Tab wieder sauber, Redo wieder geändert" {
    var t = try testEditor(std.testing.allocator, "eins\n");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.buffer.last_save = t.buffer.root; // wie nach dem Laden/Speichern
    t.ed.is_modified = false;
    t.ed.cursor.col = 4;
    t.ed.handleChar('X');
    try std.testing.expect(t.ed.is_modified);
    t.ed.dispatchAction(.Undo);
    try std.testing.expect(!t.ed.is_modified);
    t.ed.dispatchAction(.Redo);
    try std.testing.expect(t.ed.is_modified);
}

test "handleChar: nach einem Umlaut steht der Cursor eine Spalte weiter, nicht zwei" {
    var t = try testEditor(std.testing.allocator, "x");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    for ([_]u21{ 'a', 'b', 0xE4, 'c', 'd' }) |c| t.ed.handleChar(c);
    try std.testing.expectEqualStrings("abäcdx", t.ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 5), t.ed.cursor.col);
}

test "handleChar: Umlaut am Zeilenende, danach geht Tippen weiter (Chat-Eingabe)" {
    var t = try testEditor(std.testing.allocator, "");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    for ([_]u21{ 0xD6, 'f', 'f', 'n', 'e' }) |c| t.ed.handleChar(c);
    try std.testing.expectEqualStrings("Öffne", t.ed.getLine(0));
}

test "DeleteLine: getippter Text, letzte Zeile verschwindet" {
    var t = try testEditor(std.testing.allocator, "");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    for ("abc") |c| t.ed.handleChar(c);
    t.ed.dispatchAction(.InsertNewline);
    for ("zwei") |c| t.ed.handleChar(c);
    t.ed.dispatchAction(.InsertNewline);
    for ("drei") |c| t.ed.handleChar(c);
    t.ed.dispatchAction(.DeleteLine);
    const after = try t.ed.getTextInRange(.{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = 1, .col = 100 } });
    defer std.testing.allocator.free(after);
    try std.testing.expectEqual(@as(usize, 2), t.ed.lineCount());
    try std.testing.expectEqualStrings("abc\nzwei", after);
}

test "Cut ohne Auswahl entfernt die ganze Zeile (VS-Code-Verhalten)" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei\ndrei");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor.row = 1;
    t.ed.cursor.col = 2;
    t.ed.dispatchAction(.Cut);
    const after = try t.ed.getTextInRange(.{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = 1, .col = 100 } });
    defer std.testing.allocator.free(after);
    try std.testing.expectEqual(@as(usize, 2), t.ed.lineCount());
    try std.testing.expectEqualStrings("eins\ndrei", after);
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), t.ed.cursor.col);
}

test "Cut mit Auswahl entfernt nur die Auswahl" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor.row = 0;
    t.ed.cursor.col = 0;
    t.ed.selection_anchor = .{ .row = 0, .col = 2 };
    t.ed.dispatchAction(.Cut);
    const after = try t.ed.getTextInRange(.{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = 1, .col = 100 } });
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("ns\nzwei", after);
}

test "Tippen nach Klick (Anker = Cursor, kein Ziehen) behält jedes Zeichen" {
    var t = try testEditor(std.testing.allocator, "");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.selection_anchor = t.ed.cursor; // wie handleMouseDown ohne Drag
    for ("abc") |c| t.ed.handleChar(c);
    const text = try t.ed.getTextInRange(.{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 100 } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("abc", text);
    try std.testing.expect(!t.ed.hasSelection());
}

test "Enter nach Klick und dann Tippen frisst den Zeilenumbruch nicht" {
    var t = try testEditor(std.testing.allocator, "");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.selection_anchor = t.ed.cursor;
    t.ed.dispatchAction(.InsertNewline);
    t.ed.handleChar('x');
    try std.testing.expectEqual(@as(usize, 2), t.ed.lineCount());
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
}

test "lange Zeile: Cursor am Ende scrollt die Ansicht horizontal, sichtbarer Ausschnitt bleibt klein" {
    var t = try testEditor(std.testing.allocator, "");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    var long: [5000]u8 = undefined;
    @memset(&long, 'x');
    t.ed.setText(&long);
    t.ed.width = 800; // ~ (800 - Gutter - Padding) / (0.6 * font_size) sichtbare Spalten

    // Anfang: kein horizontaler Versatz, Ausschnitt deutlich kürzer als die Zeile
    t.ed.ensureCursorVisible();
    try std.testing.expectEqual(@as(usize, 0), t.ed.view.col);
    const head = t.ed.visibleSlice(0);
    try std.testing.expect(head.text.len < 200);
    try std.testing.expectEqual(@as(usize, 0), head.start_byte);

    // Ende der Zeile: Ansicht folgt dem Cursor, der Ausschnitt endet am Zeilenende
    t.ed.handleKeyPress(.end);
    try std.testing.expect(t.ed.view.col > 0);
    try std.testing.expect(t.ed.cursor.col >= t.ed.view.col);
    try std.testing.expect(t.ed.cursor.col < t.ed.view.col + t.ed.view.cols);
    const tail = t.ed.visibleSlice(0);
    try std.testing.expect(tail.text.len < 200);
    try std.testing.expectEqual(@as(usize, 5000), tail.start_byte + tail.text.len);

    // Zurück an den Anfang: Versatz verschwindet
    t.ed.handleKeyPress(.home);
    try std.testing.expectEqual(@as(usize, 0), t.ed.view.col);

    // Shift+Mausrad scrollt Spalten, nie unter 0
    t.ed.scrollColumns(-8);
    try std.testing.expectEqual(@as(usize, 8), t.ed.view.col);
    t.ed.scrollColumns(20);
    try std.testing.expectEqual(@as(usize, 0), t.ed.view.col);
}

test "visibleSliceOf: Spalten sind Codepoints, der Ausschnitt zerschneidet keine UTF-8-Sequenz" {
    // Mit Byte-Spalten endete der Ausschnitt bei 10 Spalten nach Byte 12, mitten im Gedankenstrich
    var t = try testEditor(std.testing.allocator, "> **Tab 1 \xe2\x80\x93 Positive Befunde (erf\xc3\xbcllt)**");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.width = 0; // visibleColCount = 10 → 12 Spalten sichtbar
    t.ed.ensureCursorVisible();
    try std.testing.expectEqual(@as(usize, 10), t.ed.view.cols);
    const head = t.ed.visibleSlice(0);
    try std.testing.expectEqualStrings("> **Tab 1 \xe2\x80\x93 ", head.text);
    try std.testing.expectEqual(@as(usize, 0), head.start_byte);

    // Spalte 11 = das Leerzeichen hinter dem Gedankenstrich (Byte 13)
    t.ed.view.col = 11;
    const mid = t.ed.visibleSlice(0);
    try std.testing.expectEqual(@as(usize, 13), mid.start_byte);
    try std.testing.expectEqualStrings(" Positive Be", mid.text);

    // Am Zeilenende bleibt der Ausschnitt leer statt zu überlaufen
    t.ed.view.col = 200;
    const tail = t.ed.visibleSlice(0);
    try std.testing.expectEqual(@as(usize, 0), tail.text.len);
}

test "Cursor läuft in einem Schritt über ein Mehrbyte-Zeichen, Tippen und Löschen bleiben gültiges UTF-8" {
    var t = try testEditor(std.testing.allocator, "a\xc3\xbcb \xe2\x82\xac");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    const m = t.ed.metrics();
    try std.testing.expectEqual(@as(usize, 5), t.ed.lineWidth(0)); // a ü b ␠ € — 8 Bytes, 5 Spalten

    t.ed.cursor.move_right(t.ed.buffer.root, m) catch {};
    t.ed.cursor.move_right(t.ed.buffer.root, m) catch {};
    try std.testing.expectEqual(@as(usize, 2), t.ed.cursor.col); // hinter dem ü
    t.ed.handleChar('x');
    try std.testing.expectEqualStrings("a\xc3\xbcxb \xe2\x82\xac", t.ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 3), t.ed.cursor.col);

    t.ed.handleKeyPress(.backspace);
    t.ed.handleKeyPress(.backspace);
    try std.testing.expectEqualStrings("ab \xe2\x82\xac", t.ed.getLine(0));
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.col);

    // Delete am Zeilenanfang der Restzeile: „b“, dann Leerzeichen, dann das dreibyteige €
    t.ed.handleKeyPress(.delete);
    t.ed.handleKeyPress(.delete);
    t.ed.handleKeyPress(.delete);
    try std.testing.expectEqualStrings("a", t.ed.getLine(0));

    // Ctrl+F sucht in denselben Spalten: Treffer hinter dem Umlaut landet auf der richtigen Spalte
    t.ed.setText("\xc3\xa4\xc3\xb6 foo");
    t.ed.findText("foo");
    try std.testing.expectEqual(@as(usize, 3), t.ed.selectionRange().?.begin.col);
    try std.testing.expectEqual(@as(usize, 6), t.ed.cursor.col);
}

fn editorText(ed: *CodeEditor) ![]u8 {
    const last = ed.lineCount() -| 1;
    return ed.getTextInRange(.{ .begin = .{ .row = 0, .col = 0 }, .end = .{ .row = last, .col = 100_000 } });
}

test "Enter übernimmt die Einrückung und rückt nach { eine Stufe ein; }-Paar wird aufgespannt" {
    var t = try testEditor(std.testing.allocator, "    if (x) {}");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor = .{ .row = 0, .col = 12, .target = 12 }; // zwischen { und }
    t.ed.handleKeyPress(.enter);
    const text = try editorText(&t.ed);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("    if (x) {\n        \n    }", text);
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 8), t.ed.cursor.col);
}

test "Autoclose: ( fügt () ein, ) springt drüber, Backspace löscht das leere Paar, it's bleibt" {
    var t = try testEditor(std.testing.allocator, "");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.handleChar('(');
    var text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("()", text);
    std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.col);
    t.ed.handleChar(')');
    text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("()", text);
    std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 2), t.ed.cursor.col);
    t.ed.handleKeyPress(.backspace);
    t.ed.handleKeyPress(.backspace);
    text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("", text);
    std.testing.allocator.free(text);
    for ("it") |c| t.ed.handleChar(c);
    t.ed.handleChar('\'');
    t.ed.handleChar('s');
    text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("it's", text);
    std.testing.allocator.free(text);
}

test "Tab rückt eine mehrzeilige Auswahl ein, Shift+Tab wieder aus" {
    var t = try testEditor(std.testing.allocator, "a\nb\nc");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.selection_anchor = .{ .row = 0, .col = 0, .target = 0 };
    t.ed.cursor = .{ .row = 1, .col = 1, .target = 1 };
    t.ed.handleKeyPress(.tab);
    var text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("    a\n    b\nc", text);
    std.testing.allocator.free(text);
    t.ed.dispatchAction(.OutdentLines);
    text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("a\nb\nc", text);
    std.testing.allocator.free(text);
}

test "Ctrl+/ kommentiert die Cursorzeile je Endung und wieder aus" {
    var t = try testEditor(std.testing.allocator, "const x = 1;\nconst y = 2;");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.buffer.set_file_path("/tmp/x.zig");
    t.ed.cursor = .{ .row = 1, .col = 3, .target = 3 };
    t.ed.dispatchAction(.ToggleComment);
    var text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("const x = 1;\n// const y = 2;", text);
    std.testing.allocator.free(text);
    t.ed.dispatchAction(.ToggleComment);
    text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("const x = 1;\nconst y = 2;", text);
    std.testing.allocator.free(text);
}

test "Alt+↓ / Alt+↑ verschieben die Zeile, Ctrl+Shift+D dupliziert sie" {
    var t = try testEditor(std.testing.allocator, "one\ntwo\nthree");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor = .{ .row = 0, .col = 2, .target = 2 };
    t.ed.dispatchAction(.MoveLineDown);
    var text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("two\none\nthree", text);
    std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
    t.ed.dispatchAction(.MoveLineUp);
    text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("one\ntwo\nthree", text);
    std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 0), t.ed.cursor.row);
    t.ed.dispatchAction(.DuplicateLine);
    text = try editorText(&t.ed);
    try std.testing.expectEqualStrings("one\none\ntwo\nthree", text);
    std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
}

test "Ersetzen: replaceAll ersetzt alle Treffer, Gehe zu Zeile springt" {
    var t = try testEditor(std.testing.allocator, "foo bar foo\nbaz foo");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.findText("foo");
    t.ed.find.replace_mode = true;
    @memcpy(t.ed.find.replacement[0..2], "XY");
    t.ed.find.replacement_len = 2;
    const n = t.ed.replaceAll();
    try std.testing.expectEqual(@as(usize, 3), n);
    const text = try editorText(&t.ed);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("XY bar XY\nbaz XY", text);

    t.ed.closeFind();
    t.ed.dispatchAction(.GotoLine);
    try std.testing.expect(t.ed.goto.active);
    t.ed.handleChar('2');
    t.ed.handleKeyPress(.enter);
    try std.testing.expect(!t.ed.goto.active);
    try std.testing.expectEqual(@as(usize, 1), t.ed.cursor.row);
}

test "gotoDefinition springt zur fn-Zeile des Worts unter dem Cursor" {
    var t = try testEditor(std.testing.allocator, "pub fn hello() void {}\n\nfn main() void {\n    hello();\n}");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.gotoDefinition(3, 6);
    try std.testing.expectEqual(@as(usize, 0), t.ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 7), t.ed.cursor.col);
}

test "CRLF-Datei bleibt beim Speichern CRLF" {
    var t = try testEditor(std.testing.allocator, "a\r\nb\r\n");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    try std.testing.expectEqual(flow_core.Buffer.EolMode.crlf, t.buffer.file_eol_mode);
    t.ed.cursor = .{ .row = 1, .col = 1, .target = 1 };
    t.ed.handleChar('c');
    const out = t.buffer.store_to_string_cached(t.buffer.root, t.buffer.file_eol_mode);
    try std.testing.expectEqualStrings("a\r\nbc\r\n", out);
}

test "Mehrfach-Cursor: Ctrl+D markiert Wort und nächstes Vorkommen, Tippen ersetzt beide" {
    var t = try testEditor(std.testing.allocator, "foo bar foo\nbaz foo");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.cursor = .{ .row = 0, .col = 1, .target = 1 };
    t.ed.dispatchAction(.SelectNextOccurrence);
    try std.testing.expect(t.ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), t.ed.extra_cursors.items.len);
    t.ed.dispatchAction(.SelectNextOccurrence);
    try std.testing.expectEqual(@as(usize, 1), t.ed.extra_cursors.items.len);
    try std.testing.expectEqual(@as(usize, 8), t.ed.extra_cursors.items[0].anchor.?.col);
    t.ed.dispatchAction(.SelectNextOccurrence);
    try std.testing.expectEqual(@as(usize, 2), t.ed.extra_cursors.items.len);
    t.ed.handleChar('X');
    const text = try editorText(&t.ed);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("X bar X\nbaz X", text);
    t.ed.dispatchAction(.DeleteBack);
    const text2 = try editorText(&t.ed);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(" bar \nbaz ", text2);
    t.ed.handleKeyPress(.escape);
    try std.testing.expectEqual(@as(usize, 0), t.ed.extra_cursors.items.len);
}

test "Mehrfach-Cursor: Cursor darunter, Tippen in beiden Zeilen, Enter löst auf" {
    var t = try testEditor(std.testing.allocator, "aa\nbb\ncc");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.dispatchAction(.AddCursorBelow);
    t.ed.dispatchAction(.AddCursorBelow);
    try std.testing.expectEqual(@as(usize, 2), t.ed.extra_cursors.items.len);
    t.ed.handleChar('-');
    const text = try editorText(&t.ed);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("-aa\n-bb\n-cc", text);
    t.ed.dispatchAction(.InsertNewline);
    try std.testing.expectEqual(@as(usize, 0), t.ed.extra_cursors.items.len);
    try std.testing.expectEqual(@as(usize, 4), t.ed.lineCount());
}

test "Mehrfach-Cursor: Undo nach Eingabe in drei Zeilen stellt den Text her" {
    var t = try testEditor(std.testing.allocator, "aa\nbb\ncc");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.dispatchAction(.AddCursorBelow);
    t.ed.dispatchAction(.AddCursorBelow);
    t.ed.handleChar('-');
    t.ed.handleKeyPress(.escape);
    t.ed.dispatchAction(.Undo);
    const text = try editorText(&t.ed);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("aa\nbb\ncc", text);
    // Nach dem Undo muss der Buffer weiter benutzbar sein (Zeile lesen, Klammersuche)
    try std.testing.expectEqualStrings("bb", t.ed.getLine(1));
    _ = t.ed.findBracketPair();
}

test "setText nach Tippen: Undo bleibt sicher (alte Undo-Bäume zeigen auf freigegebene Leaf-Puffer)" {
    var t = try testEditor(std.testing.allocator, "aa\nbb\ncc");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.handleChar('x');
    // Externer Reload ersetzt den Inhalt komplett; flow-core gibt dabei die Leaf-Puffer des alten Baums frei
    t.ed.setText("neu\nzwei\ndrei");
    t.ed.dispatchAction(.AddCursorBelow);
    t.ed.handleChar('-');
    t.ed.handleKeyPress(.escape);
    t.ed.dispatchAction(.Undo);
    const text = try editorText(&t.ed);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("neu\nzwei\ndrei", text);
    try std.testing.expectEqualStrings("zwei", t.ed.getLine(1));
    _ = t.ed.findBracketPair();
    // Zweites Undo darf nicht in den Zustand vor dem Reload springen (dessen Speicher ist weg)
    t.ed.dispatchAction(.Undo);
    const text2 = try editorText(&t.ed);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings("neu\nzwei\ndrei", text2);
}

test "Clay-IDs je Editor: zwei Panes bekommen verschiedene Zeilen-IDs, dieselbe Pane stabile" {
    // Vorher IDI("code", zeile) in jeder Pane gleich → bei Split ~80 duplicate_id-Fehler pro Frame.
    var a = try testEditor(std.testing.allocator, "x");
    defer a.buffer.deinit();
    defer a.ed.deinit();
    var b = try testEditor(std.testing.allocator, "y");
    defer b.buffer.deinit();
    defer b.ed.deinit();
    try std.testing.expect(a.ed.idi("code", 3).id != b.ed.idi("code", 3).id);
    try std.testing.expect(a.ed.idi("code", 3).id == a.ed.idi("code", 3).id);
    try std.testing.expect(a.ed.idi("code", 3).id != a.ed.idi("code", 4).id);
    try std.testing.expect(a.ed.idi("code", 3).id != a.ed.idi("row", 3).id);
}

test "Minimap: Balken plus Innenabstand passen in die Editor-Höhe (kein Wachstum pro Frame)" {
    // Vorher: rows_fit = height / 2 Balken à 2 px + padding.top 2 → Minimap 2 px höher als der
    // Editor; Clay reichte die Mindesthöhe bis zur Wurzel durch, die Bounding-Box wuchs jeden
    // zweiten Frame um 2 px und der Editor zeichnete minutenlang immer mehr Zeilen.
    var t = try testEditor(std.testing.allocator, "");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    var text: [4000]u8 = undefined;
    @memset(&text, '\n');
    t.ed.setText(&text);
    for ([_]f32{ 672, 673, 800, 26, 3 }) |h| {
        t.ed.height = h;
        const w = t.ed.minimapWindow();
        const px = @as(f32, @floatFromInt(w.rows)) * CodeEditor.minimap_line_px + @as(f32, @floatFromInt(CodeEditor.minimap_pad_top));
        try std.testing.expect(px <= h or w.rows == 1);
        try std.testing.expect(w.end - w.start <= w.rows);
    }
}

test "Word-Wrap: sichtbare Reihen, Treffer je Reihe und Cursor bleibt sichtbar" {
    var t = try testEditor(std.testing.allocator, "aaa bbb ccc ddd eee\nkurz\nfff ggg hhh");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    // Ohne measure_fn: charWidth = font_size * 0.6 = 14.4 → 10 Spalten bei 144 + Gutter 50 + 12 + Scrollbar
    t.ed.width = 50 + 12 + t.ed.scrollbar_width + 145;
    t.ed.height = 3 * (24 + 16); // drei Reihen
    t.ed.show_minimap = false;
    try std.testing.expectEqual(@as(usize, 10), t.ed.visibleColCount());
    try std.testing.expectEqual(@as(usize, 10), t.ed.wrapCols()); // Untergrenze 10
    try std.testing.expectEqual(@as(usize, 1), t.ed.visualRowsOf(0));
    t.ed.word_wrap = true;
    // "aaa bbb " | "ccc ddd " | "eee" → 3 Reihen; "kurz" 1; "fff ggg " | "hhh" 2
    try std.testing.expectEqual(@as(usize, 3), t.ed.visualRowsOf(0));
    try std.testing.expectEqual(@as(usize, 6), t.ed.visualRowsBetween(0, 2));
    const h1 = t.ed.hitRow(1);
    try std.testing.expectEqual(@as(usize, 0), h1.line);
    try std.testing.expectEqual(@as(usize, 8), h1.first_byte);
    const h3 = t.ed.hitRow(3);
    try std.testing.expectEqual(@as(usize, 1), h3.line);
    try std.testing.expectEqual(@as(usize, 0), h3.first_byte);
    // Cursor in Zeile 2: die drei Reihen von Zeile 0 passen nicht mehr mit → view.row rückt vor
    t.ed.cursor = .{ .row = 2, .col = 0, .target = 0 };
    t.ed.ensureCursorVisible();
    try std.testing.expect(t.ed.view.row >= 1);
    try std.testing.expectEqual(@as(usize, 0), t.ed.view.col);
    // Klick in die zweite Reihe von Zeile 0 landet in Spalte ≥ 8
    t.ed.view.row = 0;
    t.ed.content_origin_x = 0;
    t.ed.content_origin_y = 0;
    t.ed.handleMouseDown(50 + 12 + 1, 40 + 5, .mouse_left);
    try std.testing.expectEqual(@as(usize, 0), t.ed.cursor.row);
    try std.testing.expectEqual(@as(usize, 8), t.ed.cursor.col);
}

test "Word-Wrap: Mausrad und Leiste kommen bis zur letzten Reihe" {
    var t = try testEditor(std.testing.allocator, "aaa bbb ccc ddd eee\nkurz\nfff ggg hhh");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.width = 50 + 12 + t.ed.scrollbar_width + 145; // 10 Umbruchspalten, wie im Test davor
    t.ed.height = 3 * (24 + 16); // drei Reihen
    t.ed.show_minimap = false;

    // Ohne Umbruch passen alle drei Zeilen: nichts zu scrollen.
    try std.testing.expectEqual(@as(usize, 0), t.ed.maxViewRow());
    t.ed.scrollLines(-10);
    try std.testing.expectEqual(@as(usize, 0), t.ed.view.row);

    // Mit Umbruch: 3 + 1 + 2 = 6 Reihen. Ab Zeile 1 passen die restlichen drei Reihen,
    // ab Zeile 0 nicht → das Rad muss bis Zeile 1 kommen.
    t.ed.word_wrap = true;
    try std.testing.expectEqual(@as(usize, 1), t.ed.maxViewRow());
    t.ed.scrollLines(-10);
    try std.testing.expectEqual(@as(usize, 1), t.ed.view.row);
    // Die letzte Reihe ist jetzt sichtbar: Zeile 1 und beide Reihen von Zeile 2 füllen den Schirm.
    try std.testing.expectEqual(@as(usize, 3), t.ed.visualRowsBetween(t.ed.view.row, 2));

    // Bildlaufleiste: trotz nur drei Buffer-Zeilen ist sie da, ganz unten steht Zeile 1.
    t.ed.content_origin_x = 0;
    t.ed.content_origin_y = 0;
    try std.testing.expect(t.ed.isMouseOverScrollbar(t.ed.width - 1, 1));
    t.ed.view.row = 0;
    t.ed.vscroll_drag = .{ .start = 0, .offset_at_start = 0 };
    t.ed.handleMouseMove(t.ed.width - 1, t.ed.height);
    try std.testing.expectEqual(@as(usize, 1), t.ed.view.row);
}

test "Eingabefeld-Modus: ohne Gutter zählt die ganze Breite als Text" {
    var t = try testEditor(std.testing.allocator, "abc");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.width = 12 + t.ed.scrollbar_width + 20 * 14.4 + 1; // Platz für 20 Spalten (charWidth 14,4)
    try std.testing.expectEqual(@as(usize, 16), t.ed.visibleColCount()); // Gutter 50 px kostet ~3,5 Spalten
    t.ed.show_gutter = false;
    t.ed.gutter_width = 0;
    try std.testing.expectEqual(@as(usize, 20), t.ed.visibleColCount());
    // Klick in Spalte 2 landet ohne Gutter-Versatz richtig
    t.ed.content_origin_x = 0;
    t.ed.content_origin_y = 0;
    t.ed.handleMouseDown(12 + 2 * 14.4 + 1, 5, .mouse_left);
    try std.testing.expectEqual(@as(usize, 2), t.ed.cursor.col);
}

test "H-Scrollbar: längste Zeile der Datei zählt, auch außerhalb des Ausschnitts, und folgt Änderungen" {
    var t = try testEditor(std.testing.allocator, "kurz\n" ++ "x" ** 120 ++ "\nkurz\nkurz\nkurz");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.width = 400;
    t.ed.height = 40;
    t.ed.view.cols = t.ed.visibleColCount();
    t.ed.view.row = 2; // lange Zeile liegt über dem Ausschnitt
    try std.testing.expectEqual(@as(usize, 120), t.ed.maxLineWidth());
    try std.testing.expect(t.ed.hscrollModel() != null);
    // Längste Zeile kürzen: Leiste verschwindet
    t.ed.replaceLineSpan(1, 1, "xy");
    try std.testing.expectEqual(@as(usize, 4), t.ed.maxLineWidth());
    try std.testing.expect(t.ed.hscrollModel() == null);
    // Andere Zeile verlängern
    t.ed.replaceLineSpan(3, 3, "y" ** 80);
    try std.testing.expectEqual(@as(usize, 80), t.ed.maxLineWidth());
    try std.testing.expectEqual(@as(usize, 3), t.ed.longest_line_idx);
    // Zeile davor einfügen: Index rückt nach, Breite bleibt
    t.ed.cursor = .{ .row = 0, .col = 0, .target = 0 };
    t.ed.handleKeyPress(.enter);
    try std.testing.expectEqual(@as(usize, 80), t.ed.maxLineWidth());
    try std.testing.expectEqual(@as(usize, 4), t.ed.longest_line_idx);
    // Undo: voller Neuaufbau
    t.ed.dispatchAction(.Undo);
    try std.testing.expectEqual(@as(usize, 80), t.ed.maxLineWidth());
    try std.testing.expectEqual(@as(usize, 3), t.ed.longest_line_idx);
}

test "H-Scrollbar: Klick auf den Track blättert, Thumb ziehen scrollt Spalten" {
    var t = try testEditor(std.testing.allocator, "x" ** 200 ++ "\nkurz");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.width = 400;
    t.ed.height = 200;
    t.ed.content_origin_x = 0;
    t.ed.content_origin_y = 0;
    t.ed.view.cols = t.ed.visibleColCount();
    const m = t.ed.hscrollModel().?;
    const g = scrollbar.geometry(m).?;
    try std.testing.expectEqual(@as(f32, 0), g.thumb_start);
    try std.testing.expectEqual(@as(f32, 0), m.x); // Leiste beginnt am Editorrand, nicht erst nach dem Gutter
    // Klick rechts vom Thumb: eine Seite weiter, kein Ziehen, Cursor bleibt
    t.ed.handleMouseDown(m.x + m.len - 2, m.y + 2, .mouse_left);
    try std.testing.expectEqual(t.ed.view.cols, t.ed.view.col);
    try std.testing.expect(t.ed.hscroll_drag == null);
    try std.testing.expectEqual(@as(usize, 0), t.ed.cursor.col);
    // Thumb greifen und bis ganz nach rechts ziehen
    const m2 = t.ed.hscrollModel().?;
    const g2 = scrollbar.geometry(m2).?;
    t.ed.handleMouseDown(m2.x + g2.thumb_start + 5, m2.y + 2, .mouse_left);
    try std.testing.expect(t.ed.hscroll_drag != null);
    t.ed.handleMouseMove(m2.x + g2.thumb_start + 5 + (m2.len - g2.thumb_len), m2.y + 2);
    try std.testing.expectEqual(m2.max_offset, t.ed.view.col);
    t.ed.handleMouseUp();
    try std.testing.expect(t.ed.hscroll_drag == null);
    // Klick links vom Thumb: eine Seite zurück
    const m3 = t.ed.hscrollModel().?;
    t.ed.handleMouseDown(m3.x + 1, m3.y + 2, .mouse_left);
    try std.testing.expectEqual(m3.max_offset - t.ed.view.cols, t.ed.view.col);
}

test "setBuffer: Auswahl und Zusatz-Cursor der alten Datei bleiben nicht hängen" {
    var t = try testEditor(std.testing.allocator, "eins\nzwei\ndrei\nvier\n");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    // Zustand wie nach Klick in Zeile 3 der alten Datei (Anker = Cursor) plus Mehrfach-Cursor
    t.ed.cursor = .{ .row = 3, .col = 2, .target = 2 };
    t.ed.selection_anchor = t.ed.cursor;
    t.ed.extra_cursors.append(std.testing.allocator, .{ .cursor = .{ .row = 1, .col = 0 }, .anchor = null }) catch unreachable;

    const other = try flow_core.Buffer.create(std.testing.allocator);
    defer other.deinit();
    other.root = try other.load_from_string("a\nb\nc\n", &other.file_eol_mode, &other.file_utf8_sanitized);
    t.ed.setBuffer(other, "/tmp/other.txt");

    try std.testing.expect(!t.ed.hasSelection());
    try std.testing.expect(t.ed.selection_anchor == null);
    try std.testing.expectEqual(@as(usize, 0), t.ed.extra_cursors.items.len);
}

test "isMouseOverScrollbar: auch die waagrechte Leiste zählt (Mauszeiger wird Pfeil, kein I-Beam)" {
    var t = try testEditor(std.testing.allocator, "x" ** 200 ++ "\nkurz");
    defer t.buffer.deinit();
    defer t.ed.deinit();
    t.ed.width = 400;
    t.ed.height = 200;
    t.ed.content_origin_x = 0;
    t.ed.content_origin_y = 0;
    t.ed.view.cols = t.ed.visibleColCount();
    const h = t.ed.hscrollModel().?;
    try std.testing.expect(t.ed.isMouseOverScrollbar(h.x + 10, h.y + h.thickness / 2));
    try std.testing.expect(t.ed.isMouseOverScrollbar(h.x + h.len - 2, h.y + 1));
    // Text darüber bleibt Editor
    try std.testing.expect(!t.ed.isMouseOverScrollbar(h.x + 10, h.y - 20));
    // Ohne Scrollbedarf (Word-Wrap) keine waagrechte Leiste
    t.ed.word_wrap = true;
    try std.testing.expect(!t.ed.isMouseOverScrollbar(h.x + 10, h.y + 1));
}
