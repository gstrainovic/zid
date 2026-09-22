//! Schnellöffner (Ctrl+P: Dateien des Projekts) und Command Palette (Ctrl+Shift+P: alle
//! Kommandos der Kürzel-Tabelle). Ein modales Eingabefeld mit fuzzy gefilterter Liste,
//! ↑/↓ wählen, Enter bestätigt, Escape schließt. Matching in fuzzy.zig (unit-getestet).

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const fuzzy = @import("fuzzy.zig");
const shortcuts = @import("shortcuts");
const explorer_ops = @import("explorer_ops.zig");
const path_display = @import("path_display.zig");
const ui_mod = @import("mod.zig");
const line_edit = @import("line_edit.zig");

/// Suchzeile (Textelement-ID, Schriftgröße)
const query_field: line_edit.Config = .{ .id = "pk_query", .font_size = 20, .z_index = 2002 };
const Theme = @import("theme.zig").Theme;

const log = std.log.scoped(.picker);

pub const ROW_HEIGHT: f32 = 32;
const VISIBLE_ROWS: usize = 12;
const LIST_HEIGHT: f32 = VISIBLE_ROWS * ROW_HEIGHT;
const BOX_WIDTH: f32 = 720;
const NAME_SIZE: f32 = 18;
const DIR_SIZE: f32 = 14;
/// Nutzbare Breite einer Zeile: Box minus Innenabstand der Box (12 je Seite),
/// minus Innenabstand der Zeile (10 je Seite), minus etwas Luft zwischen Name
/// und Ordner.
const ROW_WIDTH: f32 = BOX_WIDTH - 2 * 12 - 2 * 10 - 16;
/// Obergrenze der Projektdateien (große Bäume wie ~/projects). Breitensuche: flache
/// Projektdateien stehen vor tiefen Abhängigkeiten (libs/…), falls die Grenze greift.
const MAX_FILES: usize = 100_000;
const MAX_MATCHES: usize = 200;

pub const Mode = enum { files, commands, tabs };

pub const Item = struct {
    /// Anzeige (Dateipfad relativ zum Root bzw. Kommando-Label); bei Dateien owned
    label: []const u8,
    /// Rechts: Kürzel-Text (Kommandos)
    detail: []const u8 = "",
    command: ?shortcuts.Command = null,
    /// Offener Tab (Modus tabs): Index in der Tab-Leiste
    tab_index: ?usize = null,
};

/// Ordner, die beim Sammeln der Projektdateien übersprungen werden (plus alle `.`-Ordner)
const ignored_dirs = [_][]const u8{ "zig-out", "zig-cache", "node_modules", "target", "__pycache__", "build", "dist" };

pub const Picker = struct {
    alloc: std.mem.Allocator,
    visible: bool = false,
    mode: Mode = .files,
    edit: explorer_ops.EditBuffer(256) = .{},
    items: std.ArrayList(Item) = .empty,
    /// Gefilterte Treffer (Index in items), absteigend nach Punktzahl
    matches: std.ArrayList(fuzzy.Match) = .empty,
    selected: usize = 0,
    scroll_y: f32 = 0,
    /// Ergebnis: gewählte Datei (Pfad relativ zum Root, owned) bzw. Kommando; die UI holt es ab
    pending_file: ?[]u8 = null,
    pending_command: ?shortcuts.Command = null,
    pending_tab: ?usize = null,
    /// Root der Dateiliste (owned)
    root: ?[]u8 = null,
    /// Labels der Dateiliste liegen in einer Arena: 30 000 einzelne free() dauern mit dem
    /// Debug-Allocator Sekunden und blockierten den Main-Thread beim Wechsel zur Palette.
    file_arena: ?*std.heap.ArenaAllocator = null,
    /// Hintergrund-Scan der Projektdateien: Ergebnis wird unter dem Mutex übergeben,
    /// die UI holt es per poll() ab. Ein zweiter Ctrl+P während des Scans startet keinen neuen.
    scan_mutex: std.Thread.Mutex = .{},
    scan_thread: ?std.Thread = null,
    scan_done: ?ScanResult = null,
    scan_generation: u32 = 0,
    scanning: bool = false,
    /// Zeitpunkt des letzten fertigen Scans (ms), für den Cache
    last_scan_ms: i64 = 0,

    const Self = @This();
    const cache_ms: i64 = 10_000;
    const ScanResult = struct { list: std.ArrayList(Item), arena: *std.heap.ArenaAllocator };

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        if (self.scan_thread) |t| t.join();
        if (self.scan_done) |r| self.destroyResult(r);
        self.clearItems();
        self.items.deinit(self.alloc);
        self.matches.deinit(self.alloc);
        if (self.pending_file) |p| self.alloc.free(p);
        if (self.root) |r| self.alloc.free(r);
    }

    fn clearItems(self: *Self) void {
        if (self.file_arena) |arena| {
            arena.deinit();
            self.alloc.destroy(arena);
            self.file_arena = null;
        }
        self.items.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
    }

    fn destroyResult(self: *Self, r: ScanResult) void {
        var l = r.list;
        l.deinit(self.alloc);
        r.arena.deinit();
        self.alloc.destroy(r.arena);
    }

    /// Ctrl+P: Picker sofort zeigen; Dateien unter `root` sammelt ein Hintergrund-Thread
    /// (relativ, ohne versteckte/ignorierte Ordner). Gleicher Root innerhalb von 10 s: Cache.
    pub fn openFiles(self: *Self, root: []const u8) void {
        const same_root = if (self.root) |r| std.mem.eql(u8, r, root) else false;
        if (self.mode != .files or !same_root) {
            self.clearItems();
        }
        self.mode = .files;
        if (!same_root) {
            if (self.root) |r| self.alloc.free(r);
            self.root = self.alloc.dupe(u8, root) catch null;
        }
        const fresh = same_root and (std.time.milliTimestamp() - self.last_scan_ms) < cache_ms and self.items.items.len > 0;
        if (!fresh and !self.scanning) self.startScan();
        self.show();
    }

    fn startScan(self: *Self) void {
        const root = self.root orelse return;
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        self.scan_generation +%= 1;
        self.scanning = true;
        const root_copy = self.alloc.dupe(u8, root) catch {
            self.scanning = false;
            return;
        };
        self.scan_thread = std.Thread.spawn(.{}, scanWorker, .{ self, root_copy, self.scan_generation }) catch |err| {
            log.warn("quick open: scan thread failed: {}", .{err});
            self.alloc.free(root_copy);
            self.scanning = false;
            return;
        };
    }

    fn scanWorker(self: *Self, root: []u8, generation: u32) void {
        defer self.alloc.free(root);
        const arena = self.alloc.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(self.alloc);
        var list: std.ArrayList(Item) = .empty;
        var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| {
            log.warn("quick open: cannot open '{s}': {}", .{ root, err });
            self.finishScan(.{ .list = list, .arena = arena }, generation);
            return;
        };
        defer dir.close();
        collectInto(self.alloc, arena.allocator(), &list, dir) catch |err| log.warn("quick open: collecting stopped: {}", .{err});
        std.sort.pdq(Item, list.items, {}, lessThanLabel);
        self.finishScan(.{ .list = list, .arena = arena }, generation);
    }

    fn finishScan(self: *Self, result: ScanResult, generation: u32) void {
        self.scan_mutex.lock();
        defer self.scan_mutex.unlock();
        if (self.scan_done) |old| {
            self.destroyResult(old);
            self.scan_done = null;
        }
        if (generation != self.scan_generation) {
            self.destroyResult(result);
            return;
        }
        self.scan_done = result;
    }

    /// Pro Frame von der UI: fertigen Scan übernehmen und die Liste neu filtern.
    pub fn poll(self: *Self) void {
        if (!self.scanning) return;
        self.scan_mutex.lock();
        const done = self.scan_done;
        self.scan_done = null;
        self.scan_mutex.unlock();
        const result = done orelse return;
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.mode == .files) {
            self.clearItems();
            self.items.deinit(self.alloc);
            self.items = result.list;
            self.file_arena = result.arena;
        } else {
            self.destroyResult(result);
        }
        self.scanning = false;
        self.last_scan_ms = std.time.milliTimestamp();
        if (self.visible) self.filter();
    }

    fn lessThanLabel(_: void, a: Item, b: Item) bool {
        return std.mem.lessThan(u8, a.label, b.label);
    }

    /// Breitensuche über den Baum: Warteschlange relativer Ordnerpfade. Labels und
    /// Zwischenpfade kommen aus der Arena (ein deinit statt 30 000 free).
    fn collectInto(list_alloc: std.mem.Allocator, label_alloc: std.mem.Allocator, list: *std.ArrayList(Item), root: std.fs.Dir) !void {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(list_alloc);
        try queue.append(list_alloc, "");
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const prefix = queue.items[head];
            var dir = if (prefix.len == 0) root else root.openDir(prefix, .{ .iterate = true }) catch continue;
            defer if (prefix.len > 0) dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (list.items.len >= MAX_FILES) return;
                if (entry.name.len == 0 or entry.name[0] == '.') continue;
                if (entry.kind == .directory) {
                    var skip = false;
                    for (ignored_dirs) |d| {
                        if (std.mem.eql(u8, entry.name, d)) skip = true;
                    }
                    if (skip or std.mem.count(u8, prefix, "/") >= 24) continue;
                    const rel = if (prefix.len == 0)
                        try label_alloc.dupe(u8, entry.name)
                    else
                        try std.fmt.allocPrint(label_alloc, "{s}/{s}", .{ prefix, entry.name });
                    try queue.append(list_alloc, rel);
                } else if (entry.kind == .file or entry.kind == .sym_link) {
                    const rel = if (prefix.len == 0)
                        try label_alloc.dupe(u8, entry.name)
                    else
                        try std.fmt.allocPrint(label_alloc, "{s}/{s}", .{ prefix, entry.name });
                    try list.append(list_alloc, .{ .label = rel });
                }
            }
        }
    }

    /// Ctrl+Shift+P: alle Kommandos der Tabelle mit Label und Kürzel.
    pub fn openCommands(self: *Self) void {
        if (self.mode == .files) self.last_scan_ms = 0; // Dateiliste wird verworfen
        self.clearItems();
        self.mode = .commands;
        inline for (@typeInfo(shortcuts.Command).@"enum".fields) |f| {
            const cmd: shortcuts.Command = @enumFromInt(f.value);
            self.items.append(self.alloc, .{ .label = shortcuts.label(cmd), .detail = shortcuts.shortcutText(cmd), .command = cmd }) catch {};
        }
        self.show();
    }

    /// Ctrl+E: offene Tabs der aktiven Leiste in „zuletzt benutzt“-Reihenfolge.
    /// `labels[i]` gehört zu Tab `indices[i]`; die Labels werden kopiert.
    pub fn openTabs(self: *Self, labels: []const []const u8, details: []const []const u8, indices: []const usize) void {
        if (self.mode == .files) self.last_scan_ms = 0;
        self.clearItems();
        self.mode = .tabs;
        const arena = self.alloc.create(std.heap.ArenaAllocator) catch return;
        arena.* = std.heap.ArenaAllocator.init(self.alloc);
        self.file_arena = arena;
        const a = arena.allocator();
        for (labels, details, indices) |l, d, i| {
            self.items.append(self.alloc, .{ .label = a.dupe(u8, l) catch continue, .detail = a.dupe(u8, d) catch "", .tab_index = i }) catch {};
        }
        self.show();
    }

    fn show(self: *Self) void {
        self.edit = .{};
        self.selected = 0;
        self.scroll_y = 0;
        self.visible = true;
        self.filter();
    }

    pub fn close(self: *Self) void {
        self.visible = false;
    }

    pub fn query(self: *const Self) []const u8 {
        return self.edit.text();
    }

    /// Ranking erst fertig rechnen, dann die Trefferliste tauschen: der RPC-Thread (Tests)
    /// liest `matches` nebenläufig und sah sonst eine leere Liste während des Rankings.
    fn filter(self: *Self) void {
        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(self.alloc);
        for (self.items.items) |it| labels.append(self.alloc, it.label) catch return;
        var out: [MAX_MATCHES]fuzzy.Match = undefined;
        const n = fuzzy.rank(self.query(), labels.items, &out);
        var fresh: std.ArrayList(fuzzy.Match) = .empty;
        fresh.appendSlice(self.alloc, out[0..n]) catch return;
        const old = self.matches;
        self.matches = fresh;
        var o = old;
        o.deinit(self.alloc);
        if (self.selected >= n) self.selected = if (n > 0) n - 1 else 0;
        self.ensureSelectedVisible();
    }

    fn ensureSelectedVisible(self: *Self) void {
        const top = @as(f32, @floatFromInt(self.selected)) * ROW_HEIGHT;
        if (top < self.scroll_y) self.scroll_y = top;
        if (top + ROW_HEIGHT > self.scroll_y + LIST_HEIGHT) self.scroll_y = top + ROW_HEIGHT - LIST_HEIGHT;
    }

    fn choose(self: *Self, match_index: usize) void {
        if (match_index >= self.matches.items.len) return;
        const item = self.items.items[self.matches.items[match_index].index];
        switch (self.mode) {
            .files => {
                if (self.pending_file) |p| self.alloc.free(p);
                self.pending_file = self.alloc.dupe(u8, item.label) catch null;
            },
            .commands => self.pending_command = item.command,
            .tabs => self.pending_tab = item.tab_index,
        }
        self.visible = false;
    }

    pub fn takeFile(self: *Self) ?[]u8 {
        const p = self.pending_file orelse return null;
        self.pending_file = null;
        return p;
    }

    pub fn takeTab(self: *Self) ?usize {
        const t = self.pending_tab;
        self.pending_tab = null;
        return t;
    }

    pub fn takeCommand(self: *Self) ?shortcuts.Command {
        const c = self.pending_command;
        self.pending_command = null;
        return c;
    }

    pub fn matchCount(self: *const Self) usize {
        return self.matches.items.len;
    }

    pub fn selectedLabel(self: *const Self) []const u8 {
        if (self.selected >= self.matches.items.len) return "";
        return self.items.items[self.matches.items[self.selected].index].label;
    }

    fn measureDir(text: []const u8) f32 {
        return ui_mod.measureTextWidth(text, DIR_SIZE);
    }

    /// Ordneranteil eines Treffers, gekürzt wie ihn die Zeile zeichnet.
    /// Eine Quelle für Render und E2E, damit der Test das Sichtbare prüft.
    ///
    /// Gemessen statt gezählt: Name und Ordner stehen in verschiedenen
    /// Schriftgrößen, ein Zeichenbudget für beide schätzte daneben und der
    /// Ordner lief rechts aus dem Kasten.
    fn dirShown(label: []const u8, buf: []u8) []const u8 {
        const parts = path_display.split(label);
        if (parts.dir.len == 0) return "";
        const room = ROW_WIDTH - ui_mod.measureTextWidth(parts.name, NAME_SIZE);
        return path_display.truncateToWidth(buf, parts.dir, room, measureDir);
    }

    /// Gezeichneter Ordneranteil des ausgewählten Treffers (E2E).
    pub fn selectedDirShown(self: *const Self, buf: []u8) []const u8 {
        return dirShown(self.selectedLabel(), buf);
    }

    pub fn handleKey(self: *Self, key: wio.Button, mods: line_edit.Mods, clip: ?line_edit.Clipboard) void {
        const n = self.matches.items.len;
        switch (key) {
            .escape => self.close(),
            .enter, .kp_enter => self.choose(self.selected),
            // Backspace/Entf/Ausschneiden/Einfügen ändern die Suche, Links/Rechts (auch mit
            // Shift/Ctrl) nur Cursor und Auswahl; Pos1/Ende springen in der Trefferliste (unten)
            .backspace, .delete, .left, .right, .a, .c, .x, .v => if (line_edit.handleKey(&self.edit, key, mods, clip) == .edited) {
                self.selected = 0;
                self.filter();
            },
            .up => {
                self.selected = if (self.selected == 0) n -| 1 else self.selected - 1;
                self.ensureSelectedVisible();
            },
            .down => {
                self.selected = if (n == 0) 0 else (self.selected + 1) % n;
                self.ensureSelectedVisible();
            },
            .page_up => {
                self.selected -|= VISIBLE_ROWS;
                self.ensureSelectedVisible();
            },
            .page_down => {
                self.selected = @min(self.selected + VISIBLE_ROWS, n -| 1);
                self.ensureSelectedVisible();
            },
            .home => {
                self.selected = 0;
                self.ensureSelectedVisible();
            },
            .end => {
                self.selected = n -| 1;
                self.ensureSelectedVisible();
            },
            else => {},
        }
    }

    pub fn handleChar(self: *Self, cp: u21) void {
        if (cp < 32 or cp == 127) return;
        self.edit.insertCodepoint(cp);
        self.selected = 0;
        self.filter();
    }

    pub fn handleScroll(self: *Self, lines: i32) void {
        const content = @as(f32, @floatFromInt(self.matches.items.len)) * ROW_HEIGHT;
        const max_scroll = @max(0, content - LIST_HEIGHT);
        self.scroll_y = std.math.clamp(self.scroll_y - @as(f32, @floatFromInt(lines)) * ROW_HEIGHT, 0, max_scroll);
    }

    /// Maus mit gedrückter Taste: Auswahl in der Suchzeile ziehen.
    pub fn handleMouseMove(self: *Self, x: f32) void {
        line_edit.handleDrag(&self.edit, query_field, x);
    }

    pub fn handleMouseUp(self: *Self) void {
        line_edit.handleRelease(&self.edit);
    }

    /// Klick: Zeile wählt, außerhalb des Kastens schließt. `shift` markiert bis zum Klick.
    pub fn handleMouseDown(self: *Self, x: f32, shift: bool) void {
        if (line_edit.handleClick(&self.edit, query_field, x, shift)) return;
        for (0..self.matches.items.len) |i| {
            if (clay.pointerOver(rowId(i))) {
                self.choose(i);
                return;
            }
        }
        if (!clay.pointerOver(clay.ElementId.ID("pk_box"))) self.close();
    }

    fn rowId(index: usize) clay.ElementId {
        return clay.ElementId.IDI("pk_row", @intCast(index));
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme) void {
        if (!self.visible) return;
        const t = theme;
        clay.UI()(.{
            .id = clay.ElementId.ID("pk_backdrop"),
            .floating = .{ .attach_to = .to_root, .z_index = 2000 },
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .center, .y = .top },
                .padding = .{ .top = 80 },
            },
            .background_color = .{ 0, 0, 0, 120 },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("pk_box"),
                .layout = .{
                    .sizing = .{ .w = .fixed(BOX_WIDTH) },
                    .padding = .all(12),
                    .direction = .top_to_bottom,
                    .child_gap = 8,
                },
                .background_color = t.surface,
                .border = .{ .width = .all(1), .color = t.border },
                .corner_radius = .all(8),
            })({
                clay.UI()(.{
                    .id = clay.ElementId.ID("pk_input"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fixed(36) },
                        .padding = .axes(0, 10),
                        .child_alignment = .{ .x = .left, .y = .center },
                        .child_gap = 8,
                    },
                    .background_color = t.overlay,
                    .border = .{ .width = .all(1), .color = t.border_focus },
                    .corner_radius = .all(4),
                })({
                    const prefix: []const u8 = switch (self.mode) {
                        .commands => ">",
                        .tabs => "tabs:",
                        .files => "",
                    };
                    if (prefix.len > 0) clay.text(prefix, .{ .font_size = 20, .color = t.muted });
                    line_edit.render(&self.edit, query_field, t.text, true, t);
                });
                clay.UI()(.{
                    .id = clay.ElementId.ID("pk_list"),
                    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(LIST_HEIGHT) } },
                    .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -self.scroll_y } },
                    .background_color = t.bg,
                    .corner_radius = .all(4),
                })({
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom },
                    })({
                        if (self.matches.items.len == 0) {
                            clay.UI()(.{ .layout = .{ .padding = .all(10) } })({
                                clay.text("No matches", .{ .font_size = 18, .color = t.muted });
                            });
                        }
                        for (self.matches.items, 0..) |m, i| {
                            const item = self.items.items[m.index];
                            const id = rowId(i);
                            const active = i == self.selected;
                            const hover = clay.pointerOver(id);
                            clay.UI()(.{
                                .id = id,
                                .layout = .{
                                    // Obergrenze wie `max-width` in CSS. Ohne sie meldet
                                    // Text ohne Umbruch seine volle Breite als Mindestmaß
                                    // und zieht Zeile und Liste über den Kasten hinaus.
                                    .sizing = .{
                                        .w = .growMinMax(.{ .min = 0, .max = ROW_WIDTH }),
                                        .h = .fixed(ROW_HEIGHT),
                                    },
                                    .padding = .axes(0, 10),
                                    .child_gap = 10,
                                    .child_alignment = .{ .y = .center },
                                },
                                // Kein eigenes .clip auf der Zeile: ein verschachteltes
                                // Clip ersetzt im Renderer das äußere, statt sich damit
                                // zu schneiden, und dann läuft die Liste unten aus dem
                                // Kasten. Die Breite hält allein die Messung in dirShown.
                                .background_color = if (active) t.primary else if (hover) t.overlay else .{ 0, 0, 0, 0 },
                                .corner_radius = .all(3),
                            })({
                                const fg = if (active) t.text_on_primary else t.text;
                                const dim = if (active) t.text_on_primary else t.muted;
                                if (self.mode == .files) {
                                    // Dateiname links, Ordner rechtsbündig und mittig
                                    // gekürzt. Der Ordner darf nicht am Namen kleben,
                                    // sonst wandert er mit dessen Länge und der rechte
                                    // Rand franst über die Zeilen aus.
                                    const parts = path_display.split(item.label);
                                    clay.text(parts.name, .{ .font_size = 18, .color = fg, .wrap_mode = .none });
                                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                                    if (parts.dir.len > 0) {
                                        // Reicht der Arena der Speicher nicht, bleibt der
                                        // Ordner ungekürzt — der Name steht ohnehin schon da.
                                        const shown_dir = if (arena.alloc(u8, parts.dir.len + path_display.ellipsis.len)) |buf|
                                            dirShown(item.label, buf)
                                        else |_|
                                            parts.dir;
                                        clay.text(shown_dir, .{ .font_size = 14, .color = dim, .wrap_mode = .none });
                                    }
                                } else {
                                    clay.text(item.label, .{ .font_size = 18, .color = fg, .wrap_mode = .none });
                                    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
                                    if (item.detail.len > 0) clay.text(item.detail, .{ .font_size = 14, .color = dim, .wrap_mode = .none });
                                }
                            });
                        }
                    });
                });
                const hint = if (self.scanning)
                    std.fmt.allocPrint(arena, "Scanning… {d} of {d}   ↑↓ wählen  Enter öffnet  Esc", .{ self.matches.items.len, self.items.items.len }) catch ""
                else
                    std.fmt.allocPrint(arena, "{d} of {d}   ↑↓ wählen  Enter öffnet  Esc", .{ self.matches.items.len, self.items.items.len }) catch "";
                clay.text(hint, .{ .font_size = 14, .color = t.muted, .wrap_mode = .none });
            });
        });
    }
};
