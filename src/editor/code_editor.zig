//! Code Editor Component für vulkan-ed
//!
//! Code Editor mit Line Numbers, Syntax Highlighting, Cursor und Text Input.
//! Verwendet flow_core.Buffer für Text-Speicherung.

const std = @import("std");
const clay = @import("clay");
const flow_core = @import("flow_core");
const syntax = @import("syntax");
const wio = @import("wio");
const shortcuts = @import("shortcuts");
const find_ops = @import("find_ops.zig");

const actions = @import("actions.zig");
const keymap = @import("keymap.zig");
const edit_ops = @import("edit_ops.zig");
const backup = @import("backup.zig");

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

    /// Scrollbar-Dragging State
    scrollbar_dragging: bool = false,
    scrollbar_drag_start_y: f32 = 0,
    scrollbar_scroll_offset_at_drag_start: f32 = 0,

    /// Scrollbar Bounds
    scrollbar_track_x: f32 = 0,
    scrollbar_track_y: f32 = 0,
    scrollbar_thumb_y: f32 = 0,
    scrollbar_thumb_height: f32 = 0,
    scrollbar_container_width: f32 = 0,

    pending_split_v: bool = false,
    pending_split_h: bool = false,

    typing_in_progress: bool = false,

    pending_md_preview: bool = false,
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
    /// Klammerpaar am Cursor (pro Frame berechnet): Position der Klammer am Cursor und ihres Partners
    bracket_pair: ?[2]flow_core.Cursor = null,
    /// Breite der Minimap-Spalte
    minimap_width: f32 = 84,

    /// Referenz auf das Fenster
    window: ?*wio.Window = null,

    /// Kontextmenü-State
    show_context_menu: bool = false,
    context_menu_x: f32 = 0,
    context_menu_y: f32 = 0,

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
        // We might want to save/restore cursor/view per buffer too...
        // For now, reset them
        self.cursor = .{};
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

        // Sicherung der alten Version (eine je Datei unter ~/.local/share/vulkan-ed/backup)
        backup.backup(self.allocator, path) catch |err| std.log.scoped(.editor).warn("backup for '{s}' failed: {}", .{ path, err });
        try self.buffer.store_to_file_and_clean(path);

        self.is_modified = false;
        self.saved_event = true;
        std.log.scoped(.editor).info("Saved file: {s}", .{path});
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
                if (egcs[0] == '\n') { colcount.* = 1; return 1; }
                if (egcs[0] == '\t') { colcount.* = 4; return 1; }
                colcount.* = 1;
                return 1;  // ASCII: jedes Zeichen ist 1 Byte und Breite 1
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
        std.log.scoped(.highlight).debug("synchronous reparse took {d:.3} ms", .{ @as(f64, @floatFromInt(end - start)) / 1_000_000.0 });
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
        std.log.scoped(.highlight).debug("background reparse took {d:.3} ms", .{ @as(f64, @floatFromInt(end - start)) / 1_000_000.0 });

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
                std.log.scoped(.highlight).debug("background reparse swapped in {d:.3} ms", .{ @as(f64, @floatFromInt(swap_end - swap_start)) / 1_000_000.0 });
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
        const hl = self.highlighter orelse return;
        const m = self.metrics();
        const line_start = self.buffer.root.line_start_byte(row, m);
        const col_byte: usize = self.buffer.root.get_line_width_to_pos(row, col, m) catch return;

        const start_byte = line_start + col_byte;
        const old_end_byte = start_byte + old_text.len;
        const new_end_byte = start_byte + new_text.len;

        // Zeilen/Spalten-Punkte berechnen
        const old_line_count = std.mem.count(u8, old_text, "\n");
        const new_line_count = std.mem.count(u8, new_text, "\n");

        const old_end_row: u32 = @intCast(row + old_line_count);
        const new_end_row: u32 = @intCast(row + new_line_count);

        const old_end_col: u32 = if (old_line_count == 0)
            @intCast(col + old_text.len)
        else
            @intCast(old_text.len - std.mem.lastIndexOf(u8, old_text, "\n").? - 1);

        const new_end_col: u32 = if (new_line_count == 0)
            @intCast(col + new_text.len)
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

    fn prevCharBoundary(text: []const u8, pos: usize) usize {
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

    pub fn dispatchAction(self: *Self, action: actions.Action) void {
        switch (action) {
            .InsertNewline, .InsertTab,
            .DeleteBack, .DeleteForward, .DeleteWordBack, .DeleteWordForward, .DeleteLine,
            .Cut, .Paste, .IndentLines, .OutdentLines, .ToggleComment, .MoveLineUp, .MoveLineDown, .DuplicateLine => {
                self.typing_in_progress = false;
                self.snapshotForUndo();
            },
            else => {},
        }

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
                    self.cursor.row, self.cursor.col, "    ", self.buffer.allocator, m,
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
                    std.log.err("Undo failed: {}", .{err});
                    return;
                };
                std.log.info("Undo: success, meta len={}", .{meta.len});
                self.cursor = .{};
                self.selection_anchor = null;
                return;
            },
            .Redo => {
                const meta = self.buffer.redo() catch return;
                _ = meta;
                self.cursor = .{};
                self.selection_anchor = null;
                return;
            },
            .MdPreview => {
                self.pending_md_preview = true;
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
    fn snapshotForUndo(self: *Self) void {
        self.buffer.store_undo("edit") catch {
            std.log.err("Failed to store undo snapshot", .{});
        };
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
            if (clay.pointerOver(clay.getElementId("Editor-Cut"))) {
                self.dispatchAction(.Cut);
                self.show_context_menu = false;
                return;
            }
            if (clay.pointerOver(clay.getElementId("Editor-Copy"))) {
                self.dispatchAction(.Copy);
                self.show_context_menu = false;
                return;
            }
            if (clay.pointerOver(clay.getElementId("Editor-Paste"))) {
                self.dispatchAction(.Paste);
                self.show_context_menu = false;
                return;
            }
            if (clay.pointerOver(clay.getElementId("Editor-MD-Preview"))) {
                std.log.scoped(.editor).info("Context Menu: MD-Preview clicked", .{});
                self.dispatchAction(.MdPreview);
                self.show_context_menu = false;
                return;
            }
            if (clay.pointerOver(clay.getElementId("Editor-Split-V"))) {
                self.dispatchAction(.SplitVertical);
                self.show_context_menu = false;
                return;
            }
            if (clay.pointerOver(clay.getElementId("Editor-Split-H"))) {
                self.dispatchAction(.SplitHorizontal);
                self.show_context_menu = false;
                return;
            }
            self.show_context_menu = false;
        }

        if (button == .mouse_right) {
            self.show_context_menu = true;
            self.context_menu_x = x;
            self.context_menu_y = y;
            return;
        }

        if (self.handleScrollbarMouseDown(x, y)) return;

        const line_idx = self.lineFromY(y);
        const col = self.colFromX(x, line_idx);

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

        if (self.scrollbar_dragging) {
            self.handleScrollbarMouseMove(x, y);
            return;
        }

        if (!self.mouse_down) return;
        const line_idx = self.lineFromY(y);
        const col = self.colFromX(x, line_idx);
        self.cursor.row = line_idx;
        self.cursor.col = col;
        self.ensureCursorVisible();
        self.current_line = self.cursor.row + 1;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.mouse_down = false;
        self.scrollbar_dragging = false;
    }

    /// Beim Ziehen über den oberen/unteren Rand pro Frame eine Zeile scrollen und den Cursor mitziehen.
    fn autoScrollWhileDragging(self: *Self) void {
        if (!self.mouse_down or self.scrollbar_dragging) return;
        const top = self.content_origin_y;
        const bottom = self.content_origin_y + self.height;
        if (self.mouse_y < top) {
            self.scrollLines(1);
        } else if (self.mouse_y > bottom) {
            self.scrollLines(-1);
        } else return;
        const line_idx = self.lineFromY(@max(top, @min(self.mouse_y, bottom - 1)));
        self.cursor.row = line_idx;
        self.cursor.col = self.colFromX(self.mouse_x, line_idx);
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
    fn renderRowOverlays(self: *Self, arena: std.mem.Allocator, line_idx: usize, slice: []const u8, full_line: []const u8) void {
        _ = arena;
        const cw = self.charWidth();
        const row_h: f32 = @floatFromInt(self.font_size + 16);
        const first_col = self.view.col;

        // Einrück-Guides: eine Linie je 4 Spalten führenden Whitespace (Tabs zählen 4)
        if (self.show_indent_guides) {
            var indent_cols: usize = 0;
            for (full_line) |c| {
                if (c == ' ') indent_cols += 1 else if (c == '\t') indent_cols += 4 else break;
            }
            var level: usize = 4;
            while (level <= indent_cols and level < 400) : (level += 4) {
                if (level < first_col) continue;
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
                if (p.row != line_idx or p.col < first_col) continue;
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
    fn renderMinimap(self: *Self, mouse_pressed: bool) void {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        const line_px: f32 = 2;
        const rows_fit: usize = @max(1, @as(usize, @intFromFloat(@max(0, self.height) / line_px)));
        // Fenster: Viewport möglichst mittig
        const half = rows_fit / 2;
        var start: usize = if (self.view.row + visible / 2 > half) self.view.row + visible / 2 - half else 0;
        if (start + rows_fit > total) start = if (total > rows_fit) total - rows_fit else 0;
        const end = @min(start + rows_fit, total);
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
            .layout = .{ .sizing = .{ .w = .fixed(self.minimap_width), .h = .grow }, .direction = .top_to_bottom, .padding = .{ .left = 4, .top = 2 } },
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

    /// Horizontale Scrollbar unten, wenn eine sichtbare Zeile breiter als der Ausschnitt ist. Klick springt.
    fn renderHScrollbar(self: *Self, mouse_pressed: bool) void {
        const cols = if (self.view.cols > 0) self.view.cols else self.visibleColCount();
        var max_w: usize = 0;
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        var i = self.view.row;
        while (i < @min(self.view.row + visible + 1, total)) : (i += 1) max_w = @max(max_w, self.lineWidth(i));
        if (max_w <= cols) return;
        const id = clay.ElementId.IDI("hscroll", @truncate(@intFromPtr(self)));
        const data = clay.getElementData(id);
        const track_w = if (data.found) data.bounding_box.width else self.width;
        const frac_len = @as(f32, @floatFromInt(cols)) / @as(f32, @floatFromInt(max_w + 4));
        const thumb_w = @max(30, track_w * frac_len);
        const max_col = max_w + 4 - cols;
        const frac_pos = @as(f32, @floatFromInt(@min(self.view.col, max_col))) / @as(f32, @floatFromInt(max_col));
        const thumb_x = frac_pos * (track_w - thumb_w);
        if (data.found and mouse_pressed and clay.pointerOver(id)) {
            const rel = (self.mouse_x - data.bounding_box.x - thumb_w / 2) / @max(1, track_w - thumb_w);
            self.view.col = @intFromFloat(@max(0, @min(1, rel)) * @as(f32, @floatFromInt(max_col)));
        }
        clay.UI()(.{
            .id = id,
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(8) } },
            .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_bottom, .parent = .left_bottom }, .offset = .{ .x = self.gutter_width, .y = 0 }, .z_index = 50 },
            .background_color = .{ 0, 0, 0, 60 },
        })({
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .fixed(thumb_w), .h = .grow } },
                .floating = .{ .attach_to = .to_parent, .attach_points = .{ .element = .left_top, .parent = .left_top }, .offset = .{ .x = thumb_x, .y = 0 } },
                .background_color = .{ self.line_number_color[0], self.line_number_color[1], self.line_number_color[2], 180 },
                .corner_radius = .all(3),
            })({});
        });
    }

    /// Wort unter (row, col) im Text suchen: erste Zeile, die wie eine Definition aussieht.
    pub fn gotoDefinition(self: *Self, row: usize, col: usize) void {
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

    fn lineFromY(self: *const Self, y: f32) usize {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return 0;
        const rel_y = y - self.content_origin_y;
        if (rel_y < 0) return 0;
        const raw_line = @as(isize, @intFromFloat(@floor(rel_y / line_height)));
        const line = raw_line + @as(isize, @intCast(self.view.row));
        if (line < 0) return 0;
        const total = self.lineCount();
        return @min(@as(usize, @intCast(line)), if (total > 0) total - 1 else 0);
    }

    fn colFromX(self: *Self, x: f32, line_idx: usize) usize {
        const rel_x = x - self.content_origin_x - self.gutter_width - 12;
        if (rel_x <= 0) return 0;

        const line_text = self.getLine(line_idx);
        if (line_text.len == 0) return 0;
        // Horizontal gescrollt: Messung beginnt beim ersten sichtbaren Byte
        const first_visible = @min(self.buffer.root.get_line_width_to_pos(line_idx, self.view.col, self.metrics()) catch 0, line_text.len);

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
        return @min(@as(usize, @intCast(col_f)) + self.view.col, self.lineWidth(line_idx));
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
    /// Zeilen über 2048 Bytes (Shaper-Grenze) bleiben sichtbar.
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

    /// Horizontal scrollen (Shift+Mausrad): positiv = nach links wie scrollLines nach oben.
    pub fn scrollColumns(self: *Self, delta: i32) void {
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
            const total = self.lineCount();
            const visible = self.visibleLineCount();
            const max_offset = if (total > visible) total - visible else 0;
            self.view.row = @min(self.view.row + amount, max_offset);
        }
    }

    fn visibleLineCount(self: *const Self) usize {
        const line_height: f32 = @floatFromInt(self.font_size + 16);
        if (line_height <= 0) return 10;
        const available = self.height;
        if (available <= 0) return 10;
        return @max(1, @as(usize, @intFromFloat(@floor(available / line_height))));
    }

    pub fn ensureCursorVisible(self: *Self) void {
        self.view.rows = self.visibleLineCount();
        self.view.cols = self.visibleColCount();
        self.view.clamp(&self.cursor, true);
    }

    pub fn handleChar(self: *Self, char_code: u21) void {
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

        if (!self.typing_in_progress) {
            self.snapshotForUndo();
            self.typing_in_progress = true;
        }

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
            self.cursor.row, self.cursor.col, buf[0..len], self.buffer.allocator, m,
        ) catch |err| {
            std.log.err("INSERT FAILED: {} row={} col={} err={}", .{ char_code, self.cursor.row, self.cursor.col, err });
            return;
        };
        std.log.debug("INSERT OK: row={} col={}", .{ self.cursor.row, self.cursor.col });
        self.buffer.root = result[2];
        self.cursor.col += @as(usize, @intCast(len));
        self.cursor.target = self.cursor.col;
        self.recordCursorMovement();
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    pub fn render(self: *Self, arena: std.mem.Allocator, mouse_pressed: bool) void {
        self.desired_cursor = .arrow;
        self.last_frame_hovered = false;  // Reset each frame

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
                    .id = clay.ElementId.ID("parsing_indicator"),
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
                .id = clay.ElementId.ID("editor_scroll"),
                .layout = .{ .sizing = .grow },
                .background_color = self.bg_color,
                .clip = .{ .vertical = true, .horizontal = true },
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("editor_content"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                    },
                })({
                    const total = self.lineCount();
                    
                    // Dynamische Gutter-Breite basierend auf maximaler Zeilennummer
                    if (self.measure_fn) |measure| {
                        var buf: [16]u8 = undefined;
                        const sample = std.fmt.bufPrint(&buf, "{d}", .{total}) catch "000";
                        // Padding: 8 (links) + 16 (rechts) = 24
                        const needed = measure(sample.ptr, sample.len) + 24;
                        // Nur vergrößern (oder sanft schrumpfen), um Flackern zu vermeiden
                        self.gutter_width = @max(50, needed);
                    }

                    const visible_count = self.visibleLineCount();
                    const start_line = @min(self.view.row, total);
                    const end_line = @min(start_line + visible_count + 1, total);

                    var i: usize = start_line;
                    while (i < end_line) : (i += 1) {
                        const line_text = arena.dupe(u8, self.getLine(i)) catch "";
                        const is_current = (i == self.cursor.row);

                        const is_selected = if (self.hasSelection()) blk: {
                            const range = self.selectionRange().?;
                            break :blk i >= range.begin.row and i <= range.end.row;
                        } else false;

                        clay.UI()(.{
                            .id = clay.ElementId.IDI("row", @intCast(i)),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                .direction = .left_to_right,
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            clay.UI()(.{
                                .id = clay.ElementId.IDI("gutter", @intCast(i)),
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
                                const line_num_str = std.fmt.bufPrint(&buf, "{d}", .{i + 1}) catch "?";
                                const persistent_str = arena.dupe(u8, line_num_str) catch "";
                                clay.text(persistent_str, .{ .font_size = self.font_size, .color = color });
                            });

                            clay.UI()(.{
                                .id = clay.ElementId.IDI("code", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(self.font_size + 16)) },
                                    .padding = .{ .left = 12 },
                                    .child_alignment = .{ .x = .left, .y = .center },
                                },
                                .background_color = if (is_current) self.current_line_highlight else .{ 0, 0, 0, 0 },
                            })({
                                const slice = self.visibleSliceOf(i, line_text);
                                self.renderLine(arena, i, slice.text, slice.start_byte, line_text.len);
                            });
                        });
                    }
                });
            });

            if (self.lineCount() > self.visibleLineCount()) {
                self.renderScrollbar();
            }
            self.renderHScrollbar(mouse_pressed);
            if (self.show_minimap) self.renderMinimap(mouse_pressed);
        });

        if (self.show_context_menu) {
            self.renderContextMenu(arena, mouse_pressed);
        }
    }

    fn renderLine(self: *Self, arena: std.mem.Allocator, line_idx: usize, line: []const u8, offset: usize, full_len: usize) void {
        clay.UI()(.{
            .layout = .{ 
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right, 
                .child_alignment = .{ .x = .left, .y = .center } 
            },
        })({
            if (self.hasSelection()) {
                self.renderSelection(arena, line_idx);
            }

            const plain_color: clay.Color = self.text_color;
            if (self.highlighter != null) {
                renderHighlightedLine(arena, self.highlighter.?, line_idx, line, offset, full_len, self.font_size, plain_color);
            } else {
                const persistent = arena.dupe(u8, line) catch "";
                clay.text(persistent, .{ .font_size = self.font_size, .color = plain_color, .wrap_mode = .none });
            }

            if (line_idx == self.cursor.row) {
                self.renderCursor(arena, offset);
            }
            self.renderRowOverlays(arena, line_idx, line, self.getLine(line_idx));
        });
    }

    fn renderSelection(self: *Self, arena: std.mem.Allocator, line_idx: usize) void {
        const range = self.selectionRange() orelse return;
        if (line_idx < range.begin.row or line_idx > range.end.row) return;

        const full_line = self.getLine(line_idx);

        const start_col = if (line_idx == range.begin.row) range.begin.col else 0;
        const end_col = if (line_idx == range.end.row) range.end.col else self.lineWidth(line_idx);

        const start_byte = self.buffer.root.get_line_width_to_pos(line_idx, start_col, self.metrics()) catch 0;
        const end_byte = self.buffer.root.get_line_width_to_pos(line_idx, end_col, self.metrics()) catch full_line.len;

        // In den sichtbaren Ausschnitt verschieben (horizontales Scrollen)
        const vis = self.visibleSliceOf(line_idx, full_line);
        const line = vis.text;
        const start_clamped = @min(start_byte -| vis.start_byte, line.len);
        const end_clamped = @min(end_byte -| vis.start_byte, line.len);

        if (start_clamped >= end_clamped and line_idx < range.end.row) {
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

    fn renderCursor(self: *Self, arena: std.mem.Allocator, offset: usize) void {
        const blink_ms: f32 = 500.0;
        const blink_delay_ms: f32 = 400.0;

        const time_since_movement = self.time_ms - self.last_cursor_movement_ms;
        const is_moving = time_since_movement < blink_delay_ms;
        const visible = is_moving or (@mod(self.time_ms, blink_ms * 2.0) < blink_ms);
        if (!visible) return;

        const line = self.getLine(self.cursor.row);
        const m = self.metrics();
        const byte_pos = @min(self.buffer.root.get_line_width_to_pos(self.cursor.row, self.cursor.col, m) catch line.len, line.len);
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

    fn renderScrollbar(self: *Self) void {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total <= visible) return;

        const track_data = clay.getElementData(clay.ElementId.ID("scrollbar_track"));
        if (track_data.found) {
            self.scrollbar_track_x = track_data.bounding_box.x;
            self.scrollbar_track_y = track_data.bounding_box.y;
        }

        const track_height = self.height;
        const thumb_ratio: f32 = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
        const thumb_height = @max(20.0, track_height * thumb_ratio);
        const max_offset: usize = total - visible;
        const scroll_frac: f32 = if (max_offset > 0)
            @as(f32, @floatFromInt(self.view.row)) / @as(f32, @floatFromInt(max_offset))
        else
            0.0;
        const thumb_y = scroll_frac * (track_height - thumb_height);

        self.scrollbar_thumb_y = self.scrollbar_track_y + thumb_y;
        self.scrollbar_thumb_height = thumb_height;

        const track_color: clay.Color = .{ 30, 30, 46, 255 };
        const thumb_color: clay.Color = .{ 88, 88, 120, 200 };

        clay.UI()(.{
            .id = clay.ElementId.ID("scrollbar_track"),
            .floating = .{
                .attach_to = .to_parent,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .z_index = 1000,
            },
            .layout = .{
                .sizing = .{ .w = .fixed(self.scrollbar_width), .h = .grow },
                .direction = .top_to_bottom,
            },
            .background_color = track_color,
        })({
            if (clay.hovered()) self.desired_cursor = .arrow;
            clay.UI()(.{
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_y) } },
            })({});
            clay.UI()(.{
                .id = clay.ElementId.ID("scrollbar_thumb"),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(thumb_height) } },
                .background_color = thumb_color,
                .corner_radius = .all(3),
            })({
                if (clay.hovered()) self.desired_cursor = .arrow;
            });
        });
    }

    pub fn isMouseOverScrollbar(self: *Self, x: f32, y: f32) bool {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total <= visible) return false;

        if (x < self.scrollbar_track_x) return false;
        if (x > self.scrollbar_track_x + self.scrollbar_width) return false;
        if (y < self.scrollbar_track_y) return false;
        if (y > self.scrollbar_track_y + self.height) return false;
        return true;
    }

    fn handleScrollbarMouseDown(self: *Self, x: f32, y: f32) bool {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total <= visible) return false;

        if (x < self.scrollbar_track_x) return false;
        if (x > self.scrollbar_track_x + self.scrollbar_width) return false;
        if (y < self.scrollbar_track_y) return false;
        if (y > self.scrollbar_track_y + self.height) return false;

        if (y >= self.scrollbar_thumb_y and y <= self.scrollbar_thumb_y + self.scrollbar_thumb_height) {
            self.scrollbar_dragging = true;
            self.scrollbar_drag_start_y = y;
            self.scrollbar_scroll_offset_at_drag_start = @as(f32, @floatFromInt(self.view.row));
            return true;
        }

        if (y < self.scrollbar_thumb_y) {
            self.scrollLines(@as(i32, @intCast(visible)));
        } else {
            self.scrollLines(-@as(i32, @intCast(visible)));
        }
        return true;
    }

    fn handleScrollbarMouseMove(self: *Self, _: f32, y: f32) void {
        const total = self.lineCount();
        const visible = self.visibleLineCount();
        if (total <= visible) return;

        const track_height = self.height;
        const thumb_ratio: f32 = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total));
        const thumb_height = @max(20.0, track_height * thumb_ratio);
        const max_offset: usize = total - visible;
        const scrollable_height = track_height - thumb_height;

        if (scrollable_height <= 0) return;

        const delta_y = y - self.scrollbar_drag_start_y;
        const scroll_delta_frac = delta_y / scrollable_height;
        const scroll_delta_lines = scroll_delta_frac * @as(f32, @floatFromInt(max_offset));
        const scroll_delta_int: i32 = @intFromFloat(@round(scroll_delta_lines));

        var new_offset: isize = @as(isize, @intFromFloat(self.scrollbar_scroll_offset_at_drag_start)) + @as(isize, scroll_delta_int);
        new_offset = @max(0, @min(new_offset, @as(isize, @intCast(max_offset))));

        self.view.row = @as(usize, @intCast(new_offset));
    }

    fn renderContextMenu(self: *Self, arena: std.mem.Allocator, mouse_pressed: bool) void {
        _ = mouse_pressed;
        if (std.process.getEnvVarOwned(arena, "FORCE_SHOW_MENU") catch null) |_| {
            if (!self.show_context_menu) {
                self.show_context_menu = true;
                self.context_menu_x = 100;
                self.context_menu_y = 100;
            }
        }
        
        var item_count: f32 = 5; // Cut, Copy, Paste + Split V, Split H
        const path = self.buffer.get_file_path();
        const is_md = std.mem.endsWith(u8, path, ".md");
        if (is_md) item_count += 1;

        clay.UI()(.{
            .id = clay.ElementId.ID("context-menu-anchor"),
            .layout = .{ .sizing = .{ .w = .fixed(0), .h = .fixed(0) } },
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .left_top, .parent = .left_top },
                .offset = .{ .x = self.context_menu_x, .y = self.context_menu_y },
                .z_index = 1000,
            },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("context-menu-container"),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .direction = .top_to_bottom,
                    .padding = .all(8),
                    .child_gap = 4,
                },
                .background_color = .{ 45, 45, 60, 255 },
                .border = .{ .width = .all(1), .color = .{ 100, 100, 120, 255 } },
                .corner_radius = .all(4),
            })({
                if (clay.hovered()) {
                    self.desired_cursor = .arrow;
                }
                self.renderContextMenuItem(.cut, "Editor-Cut");
                self.renderContextMenuItem(.copy, "Editor-Copy");
                self.renderContextMenuItem(.paste, "Editor-Paste");
                if (is_md) {
                    self.renderContextMenuItem(.md_preview, "Editor-MD-Preview");
                }

                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(1) } }, .background_color = .{ 80, 80, 80, 255 } })({});

                self.renderContextMenuItem(.split_vertical, "Editor-Split-V");
                self.renderContextMenuItem(.split_horizontal, "Editor-Split-H");
            });
        });
    }

    fn renderContextMenuItemClickable(self: *Self, label: []const u8, id: []const u8, arena: std.mem.Allocator, mouse_pressed: bool) bool {
        _ = arena;
        const item_id = clay.getElementId(id);
        const is_hovered = clay.pointerOver(item_id);
        
        clay.UI()(.{
            .id = item_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(@as(f32, @floatFromInt(self.font_size)) + 12) },
                .padding = .{ .left = 8, .right = 8 },
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = if (is_hovered) .{ 70, 70, 90, 255 } else .{ 0, 0, 0, 0 },
            .corner_radius = .all(2),
        })({
            clay.text(label, .{ .font_size = self.font_size, .color = .{ 220, 220, 220, 255 }, .wrap_mode = .none });
        });

        return is_hovered and mouse_pressed;
    }

    /// Kontextmenü-Eintrag: Label links, Kürzel rechts, beides aus shortcuts.zig.
    /// Die ID bleibt stabil (Klick-Erkennung in handleMouseDown und E2E-Tests).
    fn renderContextMenuItem(self: *Self, cmd: shortcuts.Command, id: []const u8) void {
        const item_id = clay.getElementId(id);
        const is_hovered = clay.pointerOver(item_id);
        if (is_hovered) self.desired_cursor = .arrow;

        clay.UI()(.{
            .id = item_id,
            .layout = .{
                .sizing = .{ .w = .fixed(360), .h = .fixed(@floatFromInt(self.font_size + 12)) },
                .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
                .direction = .left_to_right,
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = if (is_hovered) .{ 80, 80, 100, 255 } else .{ 0, 0, 0, 0 },
            .corner_radius = .all(2),
        })({
            clay.text(shortcuts.label(cmd), .{ .font_size = self.font_size - 2, .color = .{ 220, 220, 240, 255 }, .wrap_mode = .none });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            const sc = shortcuts.shortcutText(cmd);
            if (sc.len > 0) clay.text(sc, .{ .font_size = self.font_size - 6, .color = .{ 150, 150, 170, 255 }, .wrap_mode = .none });
        });
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
