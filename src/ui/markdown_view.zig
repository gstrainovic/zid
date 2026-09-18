const std = @import("std");
const clay = @import("clay");
const zigdown = @import("zigdown");
const word_wrap = @import("word_wrap.zig");
const md_select = @import("md_select.zig");
const ui_mod = @import("mod.zig");
const shortcuts = @import("shortcuts");
const marp = @import("marp");
const marp_pdf = @import("../rendering/marp_pdf.zig");
const ctx_menu = @import("context_menu");
const scrollbar = @import("scrollbar");
const wio = @import("wio");
const Theme = ui_mod.Theme;
const ImageTexture = @import("../clay_renderer/image_renderer.zig").ImageTexture;
const flow_core = @import("flow_core");
const Block = zigdown.Block;
const Inline = zigdown.Inline;

pub const MarkdownView = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    font_size: u16 = 20,
    base_path: []const u8 = "",
    /// Überschreibt theme.text, wenn der Inhalt auf einem Hintergrund liegt,
    /// der nicht dem Theme-Hintergrund entspricht (z.B. Chat-Bubbles).
    text_color: ?clay.Color = null,
    /// Laufende Nummer der Fließtext-Container und Tabellen **im aktuellen Block** (für die
    /// Element-IDs, an denen `flushPieces` und `renderTable` ihre Breite vom letzten Frame
    /// ablesen). Je Block gezählt, nicht je Frame: die virtualisierte Vorschau zeichnet nur ein
    /// Fenster von Blöcken, und sobald oben ein Block herausfiel, rutschten frameweite Nummern
    /// um eins — jeder Lauf las die Breite eines anderen Laufs (Listenpunkt, Zitat) und brach
    /// einen Frame lang falsch um. Die Vorschau zappelte beim Rad-Scrollen auf und ab.
    run_counter: u32 = 0,
    block_table_counter: u32 = 0,
    /// Laufende Nummer der Tabellen im Frame, nur für die abfragbaren `md_tcell`-IDs (E2E).
    table_counter: u32 = 0,
    /// Laufende Nummern für abfragbare IDs (E2E): `md_quote`, `md_li`/`md_bullet`, `md_code`.
    quote_counter: u32 = 0,
    list_item_counter: u32 = 0,
    code_counter: u32 = 0,
    /// Salz der Pane, die diese Ansicht gerade zeichnet (`UI.renderPane`): dieselbe Ansicht in
    /// zwei Panes bekommt so verschiedene Clay-IDs.
    pane_salt: u32 = 0,
    /// Obergrenze für die Umbruchbreite. Nötig in horizontal scrollbaren
    /// Viewports, wo Clay dem Container die volle Inhaltsbreite meldet.
    wrap_width_hint: ?f32 = null,
    /// Feste Umbruchbreite während eine Tabellenzelle gerendert wird, sonst null.
    wrap_width_forced: ?f32 = null,
    /// Summe der Einrückungen um den gerade gezeichneten Block (Liste 24 px plus Punkt,
    /// Zitat 16 px, Alert 32 px). `availWidth` zieht sie vom Hint ab: vorher brach Text in
    /// Listen an der vollen Breite um, ragte um die Einrückung über den Rand und wurde vom
    /// Viewport abgeschnitten.
    indent: f32 = 0,

    /// Gemessene Höhe je Block auf oberster Ebene, für die Virtualisierung.
    block_heights: std.ArrayListUnmanaged(f32) = .empty,
    /// Blockbereich, der im letzten Frame gezeichnet wurde (nur der ist messbar).
    measured_from: usize = 0,
    measured_to: usize = 0,

    /// Marp-Deck, falls `text` eines ist (`marp: true` im Front-Matter). Dann
    /// zeigt die Vorschau Folien statt eines durchgehenden Dokuments.
    deck: ?marp.Deck = null,
    current_slide: usize = 0,
    /// Maßstab Rahmen zu Foliengröße aus dem letzten Frame (1.0 = unbekannt).
    slide_scale: f32 = 1.0,
    /// Inhalt der gezeigten Folie ragt über den Rahmen hinaus (wird im PDF abgeschnitten).
    slide_overflow: bool = false,
    /// Parse-Ergebnis der gezeigten Folie. Eigene Arena, wird beim Folienwechsel
    /// verworfen — es ist immer nur eine Folie im Blick.
    slide_arena: ?*std.heap.ArenaAllocator = null,
    slide_parsed: ?*zigdown.parser.ParseResult = null,

    /// View for scrolling
    view: flow_core.View,

    /// Beide Balken kommen aus `scrollbar.zig` (Geometrie, Klick, Ziehen, Zeichnen) mit Pixeln
    /// als Einheiten; hier nur Lage des Viewports und der laufende Zug.
    scrollbar_track_x: f32 = 0,
    scrollbar_track_y: f32 = 0,
    scrollbar_width: f32 = 10,
    vdrag: ?scrollbar.Drag = null,
    /// Maus stand im letzten Frame über einem der Balken: Pfeil statt I-Beam (`cursorAt`)
    scrollbar_hovered: bool = false,

    scroll_offset_y: f32 = 0,
    viewport_height: f32 = 0,
    content_height: f32 = 0,

    /// Waagrechter Bildlauf: nur Codeblöcke ragen über den Rand (Fließtext und Tabellen
    /// brechen immer um). `content_width` ist die gemessene Breite von `md_content`, die mit
    /// der längsten Codezeile wächst; der Balken erscheint, sobald sie den Viewport übersteigt.
    scroll_offset_x: f32 = 0,
    viewport_x: f32 = 0,
    viewport_width: f32 = 0,
    content_width: f32 = 0,
    /// Waagrechter Balken wird gezogen (`scrollbar.Drag`)
    hdrag: ?scrollbar.Drag = null,
    /// „Toggle Word Wrap“ (Alt+Z), in `render` von den Editoren übernommen — ein Schalter für
    /// Editor und Vorschau, so will es der Projektinhaber (18.09.2026). Ein: Fließtext und
    /// Codezeilen brechen an der Inhaltsbreite um. Aus: nichts bricht um, jeder Absatz ist eine
    /// Zeile, der Viewport scrollt waagrecht. Tabellen passen in beiden Fällen in die Breite.
    wrap: bool = true,

    /// Context Menu State
    show_context_menu: bool = false,
    context_menu_x: f32 = 0,
    context_menu_y: f32 = 0,

    pending_split_v: bool = false,
    pending_split_h: bool = false,
    pending_export_pdf: bool = false,
    pending_copy: bool = false,

    /// Textauswahl (Logik in `md_select.zig`): Anker = Mausdruck, Kopf folgt dem Ziehen.
    sel_anchor: ?md_select.Pos = null,
    sel_head: ?md_select.Pos = null,
    selecting: bool = false,
    sel_color: clay.Color = .{ 100, 120, 200, 110 },
    sel_counter: u32 = 0,
    /// Block auf oberster Ebene, der gerade gezeichnet wird, und seine Zeilen bisher.
    cur_block: u32 = 0,
    block_line_counter: u32 = 0,
    /// Im letzten Frame gezeichnete Zeilen; der Index ist die `md_line`-ID, die Geometrie
    /// holt `hitLine` aus Clay.
    frame_lines: std.ArrayListUnmanaged(FrameLine) = .empty,
    /// Text jeder je gezeichneten Zeile (Schlüssel Block<<32 | Zeile). Bleibt über Frames,
    /// damit eine Auswahl auch kopierbar ist, wenn ihre Enden aus dem Sichtbereich sind.
    line_texts: std.AutoHashMapUnmanaged(u64, LineText) = .empty,
    /// Umbruchbreite und Schriftgröße des letzten Frames: ändern sie sich, stimmen die
    /// Zeilennummern der Auswahl nicht mehr, sie wird aufgehoben.
    sel_layout_key: f32 = -1,

    /// Geparster Dokumentbaum, einmal pro View erzeugt. Arena und Ergebnis
    /// liegen auf dem Heap: Views leben in ArrayLists und dürfen wandern,
    /// der Parser hält aber einen Pointer auf seinen Allocator.
    doc_arena: ?*std.heap.ArenaAllocator = null,
    parsed: ?*zigdown.parser.ParseResult = null,

    /// Code-Block-Highlighter je Sprache (Schlüssel owned). Vorher wurde bei jedem
    /// Sprachwechsel neu erzeugt: vier Blöcke in vier Sprachen = vier Tree-sitter-Parser pro Frame.
    code_highlighters: ?std.StringHashMap(*flow_core.highlight.SyntaxHighlighter) = null,

    const Self = @This();

    const FrameLine = struct { block: u32, line: u32, size: f32 };
    const LineText = struct { text: []u8, join: md_select.Join };
    const LineCtx = struct { id: clay.ElementId, range: ?md_select.Range };

    fn lineKey(block: u32, line: u32) u64 {
        return (@as(u64, block) << 32) | line;
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
        return a.end > b.end;
    }

    pub fn init(allocator: std.mem.Allocator, text: []const u8, base_path: []const u8) Self {
        // CRLF-Dateien: sonst hängt an jeder Codeblock-Zeile ein `\r` (siehe md_select.ownedLf).
        const lf = md_select.ownedLf(allocator, text);
        return .{
            .allocator = allocator,
            .text = lf,
            .base_path = allocator.dupe(u8, base_path) catch "",
            // Kein Deck ist der Normalfall, nicht der Fehlerfall.
            .deck = marp.parse(allocator, lf) catch null,
            .view = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.block_heights.deinit(self.allocator);
        self.frame_lines.deinit(self.allocator);
        var lt = self.line_texts.valueIterator();
        while (lt.next()) |v| self.allocator.free(v.text);
        self.line_texts.deinit(self.allocator);
        self.dropSlideDocument();
        if (self.deck) |*d| {
            d.deinit();
            self.deck = null;
        }
        if (self.parsed) |pr| {
            self.allocator.destroy(pr);
            self.parsed = null;
        }
        if (self.doc_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.doc_arena = null;
        }
        if (self.code_highlighters) |*map| {
            var it = map.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.*.destroy();
                self.allocator.free(kv.key_ptr.*);
            }
            map.deinit();
            self.code_highlighters = null;
        }
        if (self.text.len > 0 and self.text.ptr != "".ptr) {
            self.allocator.free(self.text);
        }
        if (self.base_path.len > 0 and self.base_path.ptr != "".ptr) {
            self.allocator.free(self.base_path);
        }
        self.text = "";
        self.base_path = "";
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        // Im Deck blättert das Rad, es gibt nichts zu scrollen.
        if (self.deck != null) {
            if (delta < 0) self.nextSlide() else if (delta > 0) self.prevSlide();
            return;
        }
        const scroll_speed: f32 = 60.0;
        if (delta > 0) {
            self.scroll_offset_y = @max(0, self.scroll_offset_y - @as(f32, @floatFromInt(delta)) * scroll_speed);
        } else if (delta < 0) {
            const max_scroll = @max(0, self.content_height - self.viewport_height);
            self.scroll_offset_y = @min(max_scroll, self.scroll_offset_y + @as(f32, @floatFromInt(-delta)) * scroll_speed);
        }
    }

    /// Umbruchbreite an der aktuellen Stelle: Hint minus Einrückung, null solange der Hint
    /// unbekannt ist (erster Frame).
    fn availWidth(self: *const Self) ?f32 {
        const hint = self.wrap_width_hint orelse return null;
        return @max(0, hint - self.indent);
    }

    /// Shift+Rad bzw. Touchpad waagrecht: 60 px je Schritt, positiv = nach links (wie
    /// `CodeEditor.scrollColumns`).
    pub fn scrollColumns(self: *Self, delta: i32) void {
        if (self.deck != null) return;
        const max_x = @max(0, self.content_width - self.viewport_width);
        self.scroll_offset_x = std.math.clamp(self.scroll_offset_x - @as(f32, @floatFromInt(delta)) * 60.0, 0, max_x);
    }

    /// Modell des senkrechten Balkens (Pixel als Einheiten), null wenn alles hineinpasst.
    fn vModel(self: *const Self) ?scrollbar.Model {
        if (self.deck != null) return null;
        const over = self.content_height - self.viewport_height;
        if (over <= 0.5 or self.viewport_height <= 0) return null;
        return .{
            .axis = .vertical,
            .x = self.scrollbar_track_x - self.scrollbar_width,
            .y = self.scrollbar_track_y,
            .len = self.viewport_height,
            .thickness = self.scrollbar_width,
            .total = @intFromFloat(@round(self.content_height)),
            .visible = @intFromFloat(@round(self.viewport_height)),
            .offset = @intFromFloat(@round(@max(0, self.scroll_offset_y))),
            .max_offset = @intFromFloat(@round(over)),
        };
    }

    /// Cursorform über der Vorschau: Pfeil über den Balken, I-Beam über dem Inhalt, null
    /// außerhalb (dann entscheidet die UI).
    pub fn cursorAt(self: *const Self, x: f32, y: f32) ?wio.Cursor {
        if (self.scrollbar_hovered or self.vdrag != null or self.hdrag != null) return .arrow;
        if (self.show_context_menu) return .arrow;
        if (self.deck != null) return null;
        return if (self.hitElement("md_viewport", x, y)) .text else null;
    }

    /// Modell des waagrechten Balkens (Pixel als Einheiten), null wenn nichts überragt.
    fn hModel(self: *const Self) ?scrollbar.Model {
        if (self.deck != null) return null;
        const over = self.content_width - self.viewport_width;
        if (over <= 0.5 or self.viewport_width <= 0) return null;
        // rechts bleibt der senkrechte Balken frei
        const len = if (self.content_height > self.viewport_height) self.viewport_width - self.scrollbar_width else self.viewport_width;
        return .{
            .axis = .horizontal,
            .x = self.viewport_x,
            .y = self.scrollbar_track_y + self.viewport_height - self.scrollbar_width,
            .len = @max(len, 1),
            .thickness = self.scrollbar_width,
            .total = @intFromFloat(@round(self.content_width)),
            .visible = @intFromFloat(@round(self.viewport_width)),
            .offset = @intFromFloat(@round(@max(0, self.scroll_offset_x))),
            .max_offset = @intFromFloat(@round(over)),
        };
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32) bool {
        if (self.show_context_menu) {
            self.show_context_menu = false;
            if (ctx_menu.hit("md_menu", &shortcuts.markdown_menu_items, self.menuHidden())) |cmd| {
                switch (cmd) {
                    .split_vertical => self.pending_split_v = true,
                    .split_horizontal => self.pending_split_h = true,
                    .md_export_pdf => self.pending_export_pdf = true,
                    .copy => self.pending_copy = true,
                    else => {},
                }
                return true;
            }
        }

        if (self.deck != null) {
            if (self.hitElement("md_slide_prev", x, y)) {
                self.prevSlide();
                return true;
            }
            if (self.hitElement("md_slide_next", x, y)) {
                self.nextSlide();
                return true;
            }
            return self.beginSelection("md_slide", x, y);
        }

        // Scrollbalken zuerst, jeder andere Klick gilt dem Text (Auswahl).
        if (self.hModel()) |m| switch (scrollbar.hitTest(m, x, y)) {
            .none => {},
            .thumb => |d| {
                self.hdrag = d;
                return true;
            },
            else => |h| {
                self.scroll_offset_x = @floatFromInt(scrollbar.pageOffset(m, h));
                return true;
            },
        };
        if (self.vModel()) |m| switch (scrollbar.hitTest(m, x, y)) {
            .none => {},
            .thumb => |d| {
                self.vdrag = d;
                return true;
            },
            else => |h| {
                self.scroll_offset_y = @floatFromInt(scrollbar.pageOffset(m, h));
                return true;
            },
        };
        return self.beginSelection("md_viewport", x, y);
    }

    /// Clay-ID mit Instanz-Salz: zwei Vorschauen in zwei Panes (oder Deck und Dokument) haben
    /// sonst dieselben md_*-IDs, Clay meldet duplicate_id, und `getElementData` liefert die Box
    /// der anderen Ansicht. E2E: `element_bounds(_i)` löst Namen auch über die aktive Vorschau auf.
    pub fn idi(self: *const Self, name: []const u8, index: u32) clay.ElementId {
        return clay.ElementId.IDI(name, index +% @as(u32, @truncate(@intFromPtr(self))) +% self.pane_salt);
    }

    /// Liegt (x, y) in der Bounding-Box des Elements aus dem letzten Frame?
    fn hitElement(self: *const Self, id: []const u8, x: f32, y: f32) bool {
        const data = clay.getElementData(self.idi(id, 0));
        if (!data.found) return false;
        const b = data.bounding_box;
        return x >= b.x and x <= b.x + b.width and y >= b.y and y <= b.y + b.height;
    }

    pub fn handleMouseUp(self: *Self) void {
        self.vdrag = null;
        self.hdrag = null;
        self.selecting = false;
    }

    pub fn handleMouseMove(self: *Self, x: f32, y: f32) void {
        if (self.vdrag) |d| if (self.vModel()) |m| {
            self.scroll_offset_y = @floatFromInt(scrollbar.dragOffset(m, d, x, y));
        };
        if (self.hdrag) |d| if (self.hModel()) |m| {
            self.scroll_offset_x = @floatFromInt(scrollbar.dragOffset(m, d, x, y));
        };
        if (self.selecting) {
            if (self.hitLine(x, y)) |p| self.sel_head = p;
        }
    }

    // ---- Textauswahl ----------------------------------------------------------------

    /// Klick auf eine Zeile setzt den Anker; ein Klick ohne Zeile hebt die Auswahl nur auf.
    /// `container` begrenzt den Klick auf ein Element (Viewport, Folie); null = der Aufrufer
    /// hat den Bereich schon geprüft (Chat-Bubble).
    pub fn beginSelection(self: *Self, container: ?[]const u8, x: f32, y: f32) bool {
        self.clearSelection();
        if (container) |c| if (!self.hitElement(c, x, y)) return false;
        const pos = self.hitLine(x, y) orelse return false;
        self.sel_anchor = pos;
        self.sel_head = pos;
        self.selecting = true;
        return true;
    }

    pub fn clearSelection(self: *Self) void {
        self.sel_anchor = null;
        self.sel_head = null;
        self.selecting = false;
    }

    fn span(self: *const Self) ?md_select.Span {
        return md_select.ordered(self.sel_anchor orelse return null, self.sel_head orelse return null);
    }

    pub fn hasSelection(self: *const Self) bool {
        return self.span() != null;
    }

    /// Position unter (x, y) aus den Zeilen des letzten Frames: die getroffene Zeile, sonst
    /// die nächste darüber (Ziehen über den Rand hinaus klemmt an Anfang und Ende).
    fn hitLine(self: *Self, x: f32, y: f32) ?md_select.Pos {
        const n = self.frame_lines.items.len;
        if (n == 0) return null;
        const boxes = self.allocator.alloc(md_select.LineBox, n) catch return null;
        defer self.allocator.free(boxes);
        for (boxes, 0..) |*b, i| {
            const bb = clay.getElementData(self.idi("md_line", @intCast(i))).bounding_box;
            b.* = .{ .y = bb.y, .h = bb.height };
        }
        const i = md_select.lineAtY(boxes, y) orelse return null;
        const fl = self.frame_lines.items[i];
        const bb = clay.getElementData(self.idi("md_line", @intCast(i))).bounding_box;
        const lt = self.line_texts.get(lineKey(fl.block, fl.line)) orelse return null;
        return .{ .block = fl.block, .line = fl.line, .offset = md_select.offsetAtX(ui_mod.measureTextWidth, fl.size, lt.text, x - bb.x) };
    }

    /// Ausgewählter Text, gehört dem Aufrufer; null ohne Auswahl. Zeilen kommen aus dem
    /// Cache, weiche Umbrüche werden wieder zu Leerzeichen; ein Block dazwischen, der nie
    /// gezeichnet wurde, kommt als Fließtext aus dem Dokumentbaum.
    pub fn selectedText(self: *Self, alloc: std.mem.Allocator) ?[]u8 {
        const sp = self.span() orelse return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var prev_block: ?u32 = null;
        var block = sp.start.block;
        while (block <= sp.end.block) : (block += 1) {
            var line: u32 = if (block == sp.start.block) sp.start.line else 0;
            var any = false;
            while (self.line_texts.get(lineKey(block, line))) |lt| : (line += 1) {
                if (block == sp.end.block and line > sp.end.line) break;
                const from: usize = if (block == sp.start.block and line == sp.start.line) @min(@as(usize, sp.start.offset), lt.text.len) else 0;
                const to: usize = if (block == sp.end.block and line == sp.end.line) @min(@as(usize, sp.end.offset), lt.text.len) else lt.text.len;
                if (prev_block) |pb| {
                    trimTrailingSpaces(&out);
                    out.appendSlice(alloc, md_select.joinWith(pb, block, lt.join)) catch {};
                }
                out.appendSlice(alloc, lt.text[from..@max(from, to)]) catch {};
                // Absätze enden auf ein Leerzeichen-Stück; das gehört nicht in die Zwischenablage.
                if (to == lt.text.len) trimTrailingSpaces(&out);
                prev_block = block;
                any = true;
            }
            if (!any and block != sp.start.block and block != sp.end.block) {
                // Nie gezeichneter Block: Fließtext aus dem Baum. Leere Blöcke (zigdown macht
                // aus einer Leerzeile einen `Break`) lassen keinen Trenner zurück.
                const before = out.items.len;
                self.appendBlockText(alloc, block, &out);
                if (out.items.len == before) continue;
                if (prev_block != null) out.insertSlice(alloc, before, "\n\n") catch {};
                prev_block = block;
            }
        }
        if (out.items.len == 0) {
            out.deinit(alloc);
            return null;
        }
        return out.toOwnedSlice(alloc) catch {
            out.deinit(alloc);
            return null;
        };
    }

    fn trimTrailingSpaces(out: *std.ArrayListUnmanaged(u8)) void {
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    }

    fn appendBlockText(self: *Self, alloc: std.mem.Allocator, block: u32, out: *std.ArrayListUnmanaged(u8)) void {
        const doc = self.cachedDocument() orelse return;
        const children = switch (doc.*) {
            .Container => |*c| c.children.items,
            else => return,
        };
        if (block >= children.len) return;
        appendPlainText(alloc, &children[block], out);
    }

    fn appendPlainText(alloc: std.mem.Allocator, block: *const Block, out: *std.ArrayListUnmanaged(u8)) void {
        switch (block.*) {
            .Container => |*c| for (c.children.items, 0..) |*child, i| {
                if (i > 0) out.append(alloc, '\n') catch {};
                appendPlainText(alloc, child, out);
            },
            .Leaf => |*l| switch (l.content) {
                .Code => |c| out.appendSlice(alloc, c.text orelse "") catch {},
                else => for (l.inlines.items) |*it| appendInlineText(alloc, it, out),
            },
        }
    }

    fn appendInlineText(alloc: std.mem.Allocator, item: *const Inline, out: *std.ArrayListUnmanaged(u8)) void {
        switch (item.content) {
            .text => |t| out.appendSlice(alloc, t.text) catch {},
            .codespan => |c| out.appendSlice(alloc, c.text) catch {},
            .link => |l| for (l.text.items) |t| out.appendSlice(alloc, t.text) catch {},
            else => {},
        }
    }

    fn beginBlock(self: *Self, index: u32) void {
        self.cur_block = index;
        self.block_line_counter = 0;
        self.run_counter = 0;
        self.block_table_counter = 0;
    }

    /// Zeilen aus einem früheren Frame, die es nach neuem Umbruch nicht mehr gibt, vergessen.
    fn endBlock(self: *Self) void {
        var line = self.block_line_counter;
        while (self.line_texts.fetchRemove(lineKey(self.cur_block, line))) |kv| : (line += 1) {
            self.allocator.free(kv.value.text);
        }
    }

    /// Merkt eine auswählbare Zeile (Text im Cache, Geometrie-Index für den nächsten Frame)
    /// und liefert die Clay-ID der Reihe samt ausgewähltem Bereich.
    fn registerLine(self: *Self, text: []const u8, soft: bool, size: u16) LineCtx {
        return self.registerLineJoin(text, if (soft) .space else .hard, size);
    }

    fn registerLineJoin(self: *Self, text: []const u8, join: md_select.Join, size: u16) LineCtx {
        const block = self.cur_block;
        const line = self.block_line_counter;
        self.block_line_counter += 1;
        const idx: u32 = @intCast(self.frame_lines.items.len);
        self.frame_lines.append(self.allocator, .{ .block = block, .line = line, .size = @floatFromInt(size) }) catch {};
        const id = self.idi("md_line", idx);
        const gop = self.line_texts.getOrPut(self.allocator, lineKey(block, line)) catch return .{ .id = id, .range = null };
        if (!gop.found_existing or !std.mem.eql(u8, gop.value_ptr.text, text) or gop.value_ptr.join != join) {
            if (gop.found_existing) self.allocator.free(gop.value_ptr.text);
            gop.value_ptr.* = .{ .text = self.allocator.dupe(u8, text) catch "", .join = join };
        }
        const range = if (self.span()) |sp| md_select.lineRange(sp, block, line) else null;
        return .{ .id = id, .range = range };
    }

    /// Ein Textstück mit Auswahlhervorhebung: der ausgewählte Teil steht in einem eigenen
    /// Element mit Hintergrund (`md_sel`, ab 1), Text davor und danach bleiben nackte
    /// Textelemente. Leere Stücke bleiben leere Textelemente (Zeilenhöhe in Codeblöcken).
    fn textSel(self: *Self, text: []const u8, piece_start: u32, size: u16, color: clay.Color, range: ?md_select.Range) void {
        const cfg: clay.TextElementConfig = .{ .font_size = size, .color = color, .wrap_mode = .none };
        if (range) |r| {
            if (md_select.intersect(r, piece_start, @intCast(text.len))) |ir| {
                if (ir.start > 0) clay.text(text[0..ir.start], cfg);
                self.sel_counter += 1;
                clay.UI()(.{
                    .id = self.idi("md_sel", self.sel_counter),
                    .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
                    .background_color = self.sel_color,
                })({
                    clay.text(text[ir.start..ir.end], cfg);
                });
                if (ir.end < text.len) clay.text(text[ir.end..], cfg);
                return;
            }
        }
        clay.text(text, cfg);
    }

    pub fn showContextMenu(self: *Self, x: f32, y: f32) void {
        self.show_context_menu = true;
        self.context_menu_x = x;
        self.context_menu_y = y;
    }

    /// Export to PDF nur, wenn die Vorschau ein Marp-Deck zeigt.
    fn menuHidden(self: *const Self) ctx_menu.Hidden {
        var hidden = ctx_menu.none;
        if (self.deck == null) hidden.insert(.md_export_pdf);
        if (!self.hasSelection()) hidden.insert(.copy);
        return hidden;
    }

    /// Kontextmenü (`shortcuts.markdown_menu_items`, IDs `md_menu_<command>`) im gemeinsamen Stil.
    fn renderContextMenu(self: *Self, theme: Theme) void {
        if (!self.show_context_menu) return;
        _ = ctx_menu.render("md_menu", &shortcuts.markdown_menu_items, self.context_menu_x, self.context_menu_y, self.menuHidden(), ctx_menu.Colors.fromTheme(theme));
    }

    /// Parst self.text und rendert die Blöcke ohne Root-, Scroll- oder
    /// Kontextmenü-Container. Für eingebettetes Markdown, z.B. Chat-Nachrichten.
    /// Liefert den geparsten Baum, beim ersten Aufruf wird geparst.
    fn cachedDocument(self: *Self) ?*Block {
        if (self.parsed) |pr| return &pr.parser.document;

        const arena = self.allocator.create(std.heap.ArenaAllocator) catch return null;
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        const pr = self.allocator.create(zigdown.parser.ParseResult) catch {
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        pr.* = zigdown.parser.timedParse(arena.allocator(), self.text, false) catch |err| {
            std.log.scoped(.markdown).err("Failed to parse markdown: {any}", .{err});
            self.allocator.destroy(pr);
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        std.log.scoped(.markdown).debug("parsed markdown once: {d} bytes in {d:.2} ms", .{ self.text.len, pr.time_s * 1000.0 });
        self.doc_arena = arena;
        self.parsed = pr;
        return &pr.parser.document;
    }

    /// Anzahl Folien; 0 wenn der Text kein Marp-Deck ist.
    pub fn slideCount(self: *const Self) usize {
        const d = self.deck orelse return 0;
        return d.slides.len;
    }

    fn dropSlideDocument(self: *Self) void {
        if (self.slide_parsed) |pr| {
            self.allocator.destroy(pr);
            self.slide_parsed = null;
        }
        if (self.slide_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.slide_arena = null;
        }
    }

    /// Blättert zur Folie `index` (geklemmt) und wirft den alten Parse weg.
    pub fn showSlide(self: *Self, index: usize) void {
        const count = self.slideCount();
        if (count == 0) return;
        const clamped = @min(index, count - 1);
        if (clamped == self.current_slide and self.slide_parsed != null) return;
        self.current_slide = clamped;
        self.slide_overflow = false;
        self.clearSelection();
        self.dropSlideDocument();
        self.scroll_offset_y = 0;
    }

    pub fn nextSlide(self: *Self) void {
        if (self.current_slide + 1 < self.slideCount()) self.showSlide(self.current_slide + 1);
    }

    pub fn prevSlide(self: *Self) void {
        if (self.current_slide > 0) self.showSlide(self.current_slide - 1);
    }

    /// Wie `cachedDocument`, nur für die gerade gezeigte Folie.
    fn cachedSlideDocument(self: *Self) ?*Block {
        if (self.slide_parsed) |pr| return &pr.parser.document;
        const d = self.deck orelse return null;
        if (self.current_slide >= d.slides.len) return null;

        const arena = self.allocator.create(std.heap.ArenaAllocator) catch return null;
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        const pr = self.allocator.create(zigdown.parser.ParseResult) catch {
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        pr.* = zigdown.parser.timedParse(arena.allocator(), d.slides[self.current_slide].markdown, false) catch |err| {
            std.log.scoped(.markdown).err("Failed to parse slide: {any}", .{err});
            self.allocator.destroy(pr);
            arena.deinit();
            self.allocator.destroy(arena);
            return null;
        };
        self.slide_arena = arena;
        self.slide_parsed = pr;
        // Ob die Folie aufs Blatt passt, beantwortet die Story-Engine des
        // Exports — Clay kann es nicht, weil der Rahmen den Inhalt abschneidet
        // und die gemessene Höhe damit nie über die Innenhöhe geht.
        self.slide_overflow = !marp_pdf.slideFits(self.allocator, d, self.current_slide);
        return &pr.parser.document;
    }

    pub fn renderDocument(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        const doc = self.cachedDocument() orelse return;
        var effective_theme = theme;
        if (self.text_color) |c| effective_theme.text = c;
        self.sel_color = .{ theme.primary[0], theme.primary[1], theme.primary[2], 110 };
        self.resetCounters();
        self.beginBlock(0);
        self.renderBlock(doc, arena, effective_theme, ui_ptr);
        self.endBlock();
    }

    /// Zu Beginn jedes Frames: gleiche Elemente bekommen so in jedem Frame dieselbe ID.
    fn resetCounters(self: *Self) void {
        self.run_counter = 0;
        self.block_table_counter = 0;
        self.table_counter = 0;
        self.quote_counter = 0;
        self.list_item_counter = 0;
        self.code_counter = 0;
        self.sel_counter = 0;
        self.frame_lines.clearRetainingCapacity();
        self.cur_block = 0;
        self.block_line_counter = 0;
    }

    /// Abstand zwischen zwei Blöcken auf oberster Ebene (`child_gap` im Dokument).
    const block_gap: f32 = 16;
    /// Innenabstand von `md_content` (Clay `.padding = .all(24)`), Oberkante des ersten Blocks
    const content_pad: f32 = 24;

    /// Geschätzte Höhe eines Blocks, der noch nie gezeichnet wurde. Aus Blockart
    /// und Textlänge, damit Bildlaufleiste und Scrollweg schon vor dem ersten
    /// Besuch ungefähr stimmen. Eine feste Zahl lag bei Tabellen und Codeblöcken
    /// weit daneben.
    fn estimateBlockHeight(self: *const Self, block: *const Block) f32 {
        const line_h = @as(f32, @floatFromInt(self.font_size)) * 1.5;
        const width = self.wrap_width_hint orelse 800;
        const char_w = @as(f32, @floatFromInt(self.font_size)) * 0.6;
        const per_line: f32 = @max(20, width / @max(1, char_w));

        const chars: f32 = @floatFromInt(countText(block));
        const lines: f32 = @max(1, @ceil(chars / per_line));

        return switch (block.*) {
            .Leaf => |*leaf| switch (leaf.content) {
                // Überschriften sind größer, aber selten umgebrochen.
                .Heading => |h| line_h * (switch (h.level) {
                    1 => @as(f32, 2.0),
                    2 => 1.5,
                    3 => 1.2,
                    else => 1.1,
                }),
                // Codeblöcke brechen nicht um: eine Zeile je Zeilenumbruch.
                .Code => |c| line_h * @as(f32, @floatFromInt(1 + std.mem.count(u8, c.text orelse "", "\n"))),
                .Break => line_h * 0.5,
                else => line_h * lines,
            },
            // Container: Kinder aufsummieren, plus Abstand dazwischen.
            .Container => |*c| blk: {
                var sum: f32 = 0;
                if (c.content == .Table) {
                    // Zellen flach, je `ncol` eine Zeile: pro Zeile zählt die höchste Zelle.
                    const ncol = @max(1, c.content.Table.ncol);
                    const cells = c.children.items;
                    var i: usize = 0;
                    while (i < cells.len) : (i += ncol) {
                        var row_h: f32 = line_h;
                        for (cells[i..@min(i + ncol, cells.len)]) |*cell| row_h = @max(row_h, self.estimateBlockHeight(cell));
                        sum += row_h + 8;
                    }
                    break :blk sum;
                }
                for (c.children.items) |*child| sum += self.estimateBlockHeight(child) + block_gap * 0.5;
                break :blk @max(line_h, sum);
            },
        };
    }

    /// Ungefähre Zeichenzahl eines Blocks, für die Höhenschätzung.
    fn countText(block: *const Block) usize {
        return switch (block.*) {
            .Leaf => |*leaf| blk: {
                var n: usize = 0;
                for (leaf.inlines.items) |*item| n += switch (item.content) {
                    .autolink => |a| a.url.len,
                    .codespan => |c| c.text.len,
                    .image => |i| blk_img: {
                        var m: usize = 0;
                        for (i.alt.items) |t| m += t.text.len;
                        break :blk_img m;
                    },
                    .linebreak => 0,
                    .link => |l| blk_link: {
                        var m: usize = 0;
                        for (l.text.items) |t| m += t.text.len;
                        break :blk_link m;
                    },
                    .text => |t| t.text.len,
                };
                break :blk n;
            },
            .Container => |*c| blk: {
                var n: usize = 0;
                for (c.children.items) |*child| n += countText(child);
                break :blk n;
            },
        };
    }

    /// Wie `renderDocument`, legt aber nur die sichtbaren Blöcke als
    /// Clay-Elemente an. Ohne das baut die Vorschau ein ganzes Dokument pro
    /// Frame auf und sprengt bei großen Dateien Clays Elementgrenze.
    ///
    /// Höhen kommen aus dem letzten Frame (`block_heights`); was noch nie
    /// sichtbar war, zählt mit einer Schätzung. Ober- und unterhalb steht je
    /// ein Abstandhalter, damit Gesamthöhe und Bildlauf stimmen.
    fn renderDocumentVirtualized(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        const doc = self.cachedDocument() orelse return;
        const children = switch (doc.*) {
            .Container => |*c| c.children.items,
            else => {
                self.renderDocument(arena, theme, ui_ptr);
                return;
            },
        };
        if (children.len == 0) return;

        self.syncBlockHeights(children);

        var effective_theme = theme;
        if (self.text_color) |c| effective_theme.text = c;
        self.resetCounters();

        // Sichtbaren Bereich bestimmen. Ein Bildschirm Vorlauf nach oben und
        // unten, damit beim Scrollen nichts nachklappt.
        const margin = @max(self.viewport_height, 200);
        const top = self.scroll_offset_y - margin;
        const bottom = self.scroll_offset_y + self.viewport_height + margin;

        var first: usize = children.len;
        var last: usize = 0;
        var before: f32 = 0;
        var after: f32 = 0;
        var y: f32 = 0;
        for (self.block_heights.items, 0..) |h, i| {
            const block_bottom = y + h;
            if (block_bottom >= top and y <= bottom) {
                first = @min(first, i);
                last = @max(last, i);
            } else if (block_bottom < top) {
                before += h + block_gap;
            } else {
                after += h + block_gap;
            }
            y = block_bottom + block_gap;
        }
        if (first > last) { // nichts im Sichtbereich: alles als Abstand
            self.spacer("md_v_top", before + after);
            return;
        }

        self.spacer("md_v_top", before);
        for (children[first .. last + 1], first..) |*child, i| {
            self.beginBlock(@intCast(i));
            clay.UI()(.{
                .id = self.idi("md_block", @intCast(i)),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fit } },
            })({
                self.renderBlock(child, arena, effective_theme, ui_ptr);
            });
            self.endBlock();
        }
        self.spacer("md_v_bottom", after);

        self.measured_from = first;
        self.measured_to = last;
    }

    fn spacer(self: *Self, id: []const u8, height: f32) void {
        if (height <= 0) return;
        clay.UI()(.{
            .id = self.idi(id, 0),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(height) } },
        })({});
    }

    /// Höhenliste auf die Blockzahl bringen und die im letzten Frame
    /// gezeichneten Blöcke nachmessen.
    ///
    /// Der Vorlauf oberhalb des Sichtbereichs (`renderDocumentVirtualized`) misst
    /// auch Blöcke, die noch über der Oberkante liegen. Ersetzt dort die Messung
    /// eine Schätzung, rutscht alles darunter um die Differenz, und die Vorschau
    /// sprang beim Rad-Scrollen auf und ab. Der Offset geht deshalb um dieselbe
    /// Differenz mit (`scrollbar.anchorShift`), der sichtbare Inhalt bleibt stehen.
    fn syncBlockHeights(self: *Self, children: []Block) void {
        const count = children.len;
        while (self.block_heights.items.len < count) {
            const i = self.block_heights.items.len;
            self.block_heights.append(self.allocator, self.estimateBlockHeight(&children[i])) catch return;
        }
        if (self.block_heights.items.len > count) {
            self.block_heights.shrinkRetainingCapacity(count);
        }
        // Oberkante des Blocks i mit den alten Höhen, ab dem Inhaltsrand (content_pad)
        var top: f32 = content_pad;
        var shift: f32 = 0;
        for (self.block_heights.items, 0..) |old, i| {
            if (i >= self.measured_from and i <= self.measured_to) {
                const data = clay.getElementData(self.idi("md_block", @intCast(i)));
                if (data.found and data.bounding_box.height > 0) {
                    const new = data.bounding_box.height;
                    shift += scrollbar.anchorShift(self.scroll_offset_y, top, old, new);
                    self.block_heights.items[i] = new;
                }
            }
            top += old + block_gap;
        }
        if (shift != 0) self.scroll_offset_y = @max(0, self.scroll_offset_y + shift);
    }

    /// Folienvorschau: eine Folie im 16:9-Rahmen plus Blätterleiste. Der Rahmen
    /// hat die Seitenverhältnisse des Decks, damit man sieht, was ins PDF passt.
    fn renderDeck(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        const d = self.deck.?;
        const deck_w: f32 = @floatFromInt(d.global.size.w);
        const aspect: f32 = if (d.global.size.h > 0)
            deck_w / @as(f32, @floatFromInt(d.global.size.h))
        else
            16.0 / 9.0;

        // Rahmengröße selbst rechnen statt Clays Aspect-Ratio zu überlassen:
        // mit `.w = .grow` blieb der Rahmen auf Inhaltsgröße stehen, also winzig.
        // Grundlage ist die Fläche des Wurzelelements aus dem letzten Frame; das
        // Wurzelelement clippt, sonst wüchse es mit dem Rahmen mit und der
        // nächste Frame rechnete daraus einen noch größeren Rahmen.
        const root = clay.getElementData(self.idi("markdown_view_root", 0));
        const bar = clay.getElementData(self.idi("md_slide_bar", 0));
        const reserve: f32 = if (bar.found) bar.bounding_box.height + 16 else chrome_reserve;
        const avail_w = if (root.found) @max(120.0, root.bounding_box.width - 2 * root_padding) else deck_w;
        const avail_h = if (root.found)
            @max(80.0, root.bounding_box.height - 2 * root_padding - reserve)
        else
            deck_w / aspect;
        const frame_w = @min(avail_w, avail_h * aspect);
        const frame_h = frame_w / aspect;

        const scale: f32 = frame_w / deck_w;
        self.slide_scale = scale;

        clay.UI()(.{
            .id = self.idi("markdown_view_root", 0),
            .layout = .{
                .sizing = .grow,
                .direction = .top_to_bottom,
                .padding = .all(root_padding),
                .child_gap = 16,
                .child_alignment = .{ .x = .center, .y = .center },
            },
            // Clippt, damit der Rahmen das Wurzelelement nicht aufblähen kann.
            .clip = .{ .vertical = true, .horizontal = true },
            .background_color = theme.bg,
        })({
            clay.UI()(.{
                .id = self.idi("md_slide", 0),
                .layout = .{
                    .sizing = .{ .w = .fixed(frame_w), .h = .fixed(frame_h) },
                    .direction = .top_to_bottom,
                    // Dieselben Ränder wie im PDF, nur im Maßstab des Rahmens.
                    .padding = .{
                        .left = scaled(pdf_margin_x, scale),
                        .right = scaled(pdf_margin_x, scale),
                        .top = scaled(pdf_margin_y, scale),
                        .bottom = scaled(pdf_margin_y, scale),
                    },
                    .child_gap = scaled(10, scale),
                },
                .clip = .{ .vertical = true, .horizontal = true },
                .background_color = theme.surface,
                .border = .{ .color = theme.border, .width = .all(1) },
                .corner_radius = .all(theme.radius_sm),
            })({
                clay.UI()(.{
                    .id = self.idi("md_slide_content", 0),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .child_gap = scaled(10, scale),
                    },
                })({
                    const doc = self.cachedSlideDocument();
                    if (doc) |block| {
                        var effective_theme = theme;
                        if (self.text_color) |cc| effective_theme.text = cc;
                        self.resetCounters();
                        // Grundschrift wie im Export, skaliert auf den Rahmen. Die
                        // Überschriften-Faktoren in renderBlock (2.0 / 1.5 / 1.2)
                        // sind dieselben wie im Export-CSS.
                        const outer = self.font_size;
                        self.font_size = @max(6, scaled(pdf_content_em, scale));
                        self.wrap_width_hint = @max(0, frame_w - 2 * @as(f32, @floatFromInt(scaled(pdf_margin_x, scale))));
                        self.beginBlock(0);
                        self.renderBlock(block, arena, effective_theme, ui_ptr);
                        self.endBlock();
                        self.font_size = outer;
                    }
                });
            });

            // Blätterleiste: ‹ Folie / Gesamt ›
            clay.UI()(.{
                .id = self.idi("md_slide_bar", 0),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .child_gap = 16,
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            })({
                self.renderSlideButton("md_slide_prev", "<", self.current_slide > 0, theme);
                var buf: [48]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{d} / {d}", .{ self.current_slide + 1, d.slides.len }) catch "";
                clay.UI()(.{
                    .id = self.idi("md_slide_counter", 0),
                    .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
                })({
                    clay.text(arena.dupe(u8, label) catch "", .{
                        .font_size = self.font_size,
                        .color = theme.subtext,
                    });
                });
                self.renderSlideButton("md_slide_next", ">", self.current_slide + 1 < d.slides.len, theme);
            });

            if (self.slide_overflow) {
                clay.UI()(.{
                    .id = self.idi("md_slide_overflow", 0),
                    .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
                })({
                    clay.text("Inhalt passt nicht auf die Folie", .{
                        .font_size = self.font_size - 4,
                        .color = theme.warning,
                    });
                });
            }

            // Die Fußzeile der Folie steht bewusst nicht unter dem Rahmen: sie
            // gehört ins PDF, nicht in die Bedienleiste der Vorschau.
        });

        self.renderContextMenu(theme);
    }

    /// Ränder und Schriftgrößen des Exports (`rendering/marp_pdf.zig`), damit
    /// Vorschau und PDF denselben Umbruch zeigen.
    const pdf_margin_x: f32 = 70;
    const pdf_margin_y: f32 = 78;
    const pdf_content_em: f32 = 26;

    /// Rand um die Folie und Platz für Blätterleiste, Warnung und Fußzeile.
    const root_padding: u16 = 24;
    const chrome_reserve: f32 = 110;

    /// Grundschriftgröße, in der die Folie gezeichnet wird (E2E-Sicht).
    pub fn slideFontSize(self: *const Self) u16 {
        return @max(6, scaled(pdf_content_em, self.slide_scale));
    }

    fn scaled(value: f32, scale: f32) u16 {
        const px = @round(value * scale);
        if (px <= 0) return 0;
        return @intFromFloat(@min(px, 4000));
    }

    fn renderSlideButton(self: *Self, id: []const u8, label: []const u8, enabled: bool, theme: Theme) void {
        clay.UI()(.{
            .id = self.idi(id, 0),
            .layout = .{
                .sizing = .{ .w = .fixed(36), .h = .fixed(28) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = if (enabled) theme.overlay else theme.bg,
            .corner_radius = .all(theme.radius_sm),
        })({
            clay.text(label, .{
                .font_size = 20,
                .color = if (enabled) theme.text else theme.muted,
            });
        });
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        self.sel_color = .{ theme.primary[0], theme.primary[1], theme.primary[2], 110 };
        const layout_key = (self.wrap_width_hint orelse 0) * 1000 + @as(f32, @floatFromInt(self.font_size));
        if (layout_key != self.sel_layout_key) {
            if (self.sel_layout_key >= 0) self.clearSelection();
            self.sel_layout_key = layout_key;
        }
        if (self.deck != null) return self.renderDeck(arena, theme, ui_ptr);

        // Update layout info from previous frame
        const clip_data = clay.getElementData(self.idi("md_viewport", 0));
        const content_data = clay.getElementData(self.idi("md_content", 0));
        if (clip_data.found) {
            self.viewport_height = clip_data.bounding_box.height;
            self.viewport_x = clip_data.bounding_box.x;
            self.viewport_width = clip_data.bounding_box.width;
            self.scrollbar_track_x = clip_data.bounding_box.x + clip_data.bounding_box.width;
            self.scrollbar_track_y = clip_data.bounding_box.y;
            // md_content hat 24px Padding je Seite
            self.wrap_width_hint = @max(0, clip_data.bounding_box.width - 48);
        }
        if (content_data.found) {
            self.content_height = content_data.bounding_box.height;
            self.content_width = content_data.bounding_box.width;
        }
        // Word Wrap der Editoren gilt auch hier (Alt+Z schaltet alle Editoren, `toggleEditorOption`)
        self.wrap = ui_ptr.getActiveEditor().word_wrap;
        // Nach Umbruch oder schmalerem Fenster nicht im Leeren stehen bleiben
        self.scroll_offset_x = std.math.clamp(self.scroll_offset_x, 0, @max(0, self.content_width - self.viewport_width));

        clay.UI()(.{
            .id = self.idi("markdown_view_root", 0),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .grow },
                .direction = .left_to_right,
            },
            .background_color = theme.bg,
        })({
            // Content area
            clay.UI()(.{
                .id = self.idi("md_viewport", 0),
                .layout = .{ .sizing = .grow },
                .clip = .{ .vertical = true, .horizontal = true, .child_offset = .{ .x = -self.scroll_offset_x, .y = -self.scroll_offset_y } },
            })({
                clay.UI()(.{
                    .id = self.idi("md_content", 0),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fit },
                        .direction = .top_to_bottom,
                        .padding = .all(24),
                        .child_gap = 16,
                    },
                })({
                    // Nur hier virtualisiert: der Chat rendert dasselbe Dokument
                    // ohne eigenen Viewport und braucht alle Blöcke.
                    self.renderDocumentVirtualized(arena, theme, ui_ptr);
                });
            });

            // Balken: senkrecht rechts, waagrecht unten (nur wenn Code über den Rand ragt).
            // `render` meldet, ob die Maus darüber steht → Pfeil statt I-Beam.
            self.scrollbar_hovered = false;
            if (self.vModel()) |m| {
                if (scrollbar.render(m, .{ .track = self.idi("md_scrollbar_track", 0), .thumb = self.idi("md_scrollbar_thumb", 0) })) self.scrollbar_hovered = true;
            }
            if (self.hModel()) |m| {
                if (scrollbar.render(m, .{ .track = self.idi("md_hscroll_track", 0), .thumb = self.idi("md_hscroll_thumb", 0) })) self.scrollbar_hovered = true;
            }
        });

        self.renderContextMenu(theme);
    }

    /// Highlighter für eine Sprache holen oder einmalig anlegen (null = keine Sprache / unbekannt).
    fn highlighterFor(self: *Self, lang_name: []const u8) ?*flow_core.highlight.SyntaxHighlighter {
        if (lang_name.len == 0) return null;
        if (self.code_highlighters == null) self.code_highlighters = std.StringHashMap(*flow_core.highlight.SyntaxHighlighter).init(self.allocator);
        const map = &self.code_highlighters.?;
        if (map.get(lang_name)) |hl| return hl;
        const created = flow_core.highlight.SyntaxHighlighter.create(self.allocator, lang_name) catch |err| {
            std.log.debug("md_preview: highlighter create failed for '{s}': {s}", .{ lang_name, @errorName(err) });
            return null;
        };
        const key = self.allocator.dupe(u8, lang_name) catch {
            created.destroy();
            return null;
        };
        map.put(key, created) catch {
            self.allocator.free(key);
            created.destroy();
            return null;
        };
        std.log.debug("md_preview: highlighter created for '{s}'", .{lang_name});
        return created;
    }

    fn renderCodeBlock(self: *Self, code: []const u8, lang_tag: ?[]const u8, arena: std.mem.Allocator, theme: Theme) void {
        // Determine language for highlighter
        const lang_name = lang_tag orelse "";
        std.log.debug("md_preview: renderCodeBlock lang='{s}' code_len={d}", .{ lang_name, code.len });

        const hl = self.highlighterFor(lang_name);
        if (hl) |highlighter| {
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
                    colcount.* = 1;
                    return 1;
                }
                fn egc_chunk_width(_: flow_core.Buffer.Metrics, chunk_: []const u8, _: usize) usize {
                    if (chunk_.len == 0) return 0;
                    if (chunk_[0] == '\n') return 1;
                    if (chunk_[0] == '\t') return 4;
                    return 1;
                }
                fn egc_last(_: flow_core.Buffer.Metrics, egcs: []const u8) []const u8 {
                    return egcs;
                }
            };
            const m = flow_core.Buffer.Metrics{
                .ctx = undefined,
                .egc_length = Ctx.egc_length,
                .egc_chunk_width = Ctx.egc_chunk_width,
                .egc_last = Ctx.egc_last,
                .tab_width = 4,
            };

            // Reset cached state so tags from a previous block don't leak.
            highlighter.resetTree();
            highlighter.invalidateAllLines();

            if (flow_core.Buffer.create(arena)) |buf| {
                defer buf.deinit();
                var eol_mode: flow_core.Buffer.EolMode = .lf;
                var utf8_sanitized: bool = false;
                if (buf.load_from_string(code, &eol_mode, &utf8_sanitized)) |root| {
                    highlighter.reparseFromBuffer(root, m) catch {};
                } else |_| {}
            } else |_| {}

            const line_count = std.mem.count(u8, code, "\n") + 1;
            std.log.debug("md_preview: highlighter ready, rendering {d} lines", .{line_count});
        } else {
            std.log.debug("md_preview: no highlighter, plain text rendering", .{});
        }

        // Split code into lines manually
        var start: usize = 0;
        var line_idx: usize = 0;
        const code_size = self.font_size - 2;
        // Mit Word Wrap bricht jede Zeile an der Inhaltsbreite (md_code hat 16 px Padding je
        // Seite; -4 für Clays Viertelpixel je Highlight-Segment); ohne läuft sie nach rechts
        // hinaus und der Viewport scrollt waagrecht.
        const wrap_at: f32 = if (self.wrap) @max(0, (self.availWidth() orelse 0) - 32 - 4) else 0;

        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom } })({
            while (start < code.len) {
                const remaining = code[start..];
                const end_offset = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
                const end = start + end_offset;
                if (end > code.len) break;
                const line = code[start..end];

                const tags_opt: ?[]flow_core.highlight.ColorTag = if (hl) |highlighter|
                    (highlighter.tagsForLine(line_idx, line.len, arena) catch null)
                else
                    null;
                if (tags_opt) |tags| std.sort.insertion(flow_core.highlight.ColorTag, tags, {}, lessThanTag);

                // Reihen der Zeile: eine, oder mit Word Wrap so viele, wie die Breite verlangt
                var row_start: usize = 0;
                while (true) {
                    const row_end = if (wrap_at > 0) codeRowEnd(line, row_start, wrap_at, @floatFromInt(code_size)) else line.len;
                    const join: md_select.Join = if (row_start == 0) .hard else .none;
                    const ctx = self.registerLineJoin(line[row_start..row_end], join, code_size);
                    clay.UI()(.{ .id = ctx.id, .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 0 } })({
                        self.renderCodeRow(line, row_start, row_end, tags_opt, code_size, theme, ctx.range);
                    });
                    if (row_end >= line.len) break;
                    row_start = row_end;
                }

                start = end + 1;
                line_idx += 1;
            }
        });
    }

    /// Ende der Reihe ab `from`: das längste Präfix, das in `max_width` passt, mindestens ein
    /// Zeichen. Code bricht an jeder Stelle, nicht nur an Leerzeichen.
    fn codeRowEnd(line: []const u8, from: usize, max_width: f32, size: f32) usize {
        if (ui_mod.measureTextWidth(line[from..], size) <= max_width) return line.len;
        var take: usize = from;
        var i: usize = from;
        while (i < line.len) {
            i += std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i > line.len) i = line.len;
            if (ui_mod.measureTextWidth(line[from..i], size) > max_width) break;
            take = i;
        }
        if (take == from) take = @min(line.len, from + (std.unicode.utf8ByteSequenceLength(line[from]) catch 1));
        return take;
    }

    /// Eine Reihe `line[row_start..row_end]` mit Highlight-Tags (Offsets der ganzen Zeile);
    /// die Auswahl (`range`) und `textSel` rechnen relativ zur Reihe.
    fn renderCodeRow(self: *Self, line: []const u8, row_start: usize, row_end: usize, tags_opt: ?[]flow_core.highlight.ColorTag, code_size: u16, theme: Theme, range: ?md_select.Range) void {
        const row = line[row_start..row_end];
        if (tags_opt) |tags| {
            var pos: usize = row_start;
            for (tags) |tag| {
                if (tag.end > line.len or tag.start >= tag.end) continue;
                const s = @max(@max(tag.start, pos), row_start);
                const e = @min(tag.end, row_end);
                if (s >= e) continue;
                if (s > pos) self.textSel(line[pos..s], @intCast(pos - row_start), code_size, theme.text, range);
                self.textSel(line[s..e], @intCast(s - row_start), code_size, colorFromTag(tag.fg), range);
                pos = e;
            }
            if (pos < row_end) self.textSel(line[pos..row_end], @intCast(pos - row_start), code_size, theme.text, range);
        } else {
            self.textSel(row, 0, code_size, theme.text, range);
        }
    }

    fn renderBlock(self: *Self, block: *Block, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        switch (block.*) {
            .Container => |*container| {
                if (container.content == .Table) {
                    self.renderTable(container, arena, theme, ui_ptr);
                    return;
                }
                const layout_options = switch (container.content) {
                    .Document => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 16 },
                    .Quote => clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .{ .left = 16, .right = 0, .top = 4, .bottom = 4 }, .child_gap = 8 },
                    .List => |_| clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .{ .left = 24, .right = 0, .top = 0, .bottom = 0 }, .child_gap = 8 },
                    .ListItem => |_| clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 4 },
                    .Table => |_| clay.LayoutConfig{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 0 },
                };
                const quote_id = if (container.content == .Quote) blk: {
                    self.quote_counter += 1;
                    break :blk self.idi("md_quote", self.quote_counter);
                } else (clay.ElementDeclaration{}).id;
                // Einrückung dieses Containers für die Umbruchbreite der Kinder (siehe `indent`)
                const pad: f32 = switch (container.content) {
                    .Quote => 16,
                    .List => 24,
                    else => 0,
                };
                self.indent += pad;
                defer self.indent -= pad;
                clay.UI()(.{
                    .id = quote_id,
                    .layout = layout_options,
                    .border = if (container.content == .Quote) .{ .width = .{ .left = 4 }, .color = theme.accent } else .{},
                })({
                    for (container.children.items) |*child| {
                        if (container.content == .List) {
                            self.list_item_counter += 1;
                            const n = self.list_item_counter;
                            clay.UI()(.{
                                .id = self.idi("md_li", n),
                                .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 8 },
                            })({
                                clay.UI()(.{ .id = self.idi("md_bullet", n), .layout = .{ .sizing = .{ .w = .fit, .h = .fit } } })({
                                    clay.text("•", .{ .font_size = self.font_size, .color = theme.text });
                                });
                                // Punkt plus child_gap nehmen dem Text Breite weg
                                const bullet_w = ui_mod.measureTextWidth("•", @floatFromInt(self.font_size)) + 0.25 + 8;
                                self.indent += bullet_w;
                                defer self.indent -= bullet_w;
                                self.renderBlock(child, arena, theme, ui_ptr);
                            });
                        } else {
                            self.renderBlock(child, arena, theme, ui_ptr);
                        }
                    }
                });
            },
            .Leaf => |*leaf| {
                switch (leaf.content) {
                    .Heading => |h| {
                        const multiplier: f32 = switch (h.level) {
                            1 => 2.0,
                            2 => 1.5,
                            3 => 1.2,
                            else => 1.1,
                        };
                        const size: u16 = @intFromFloat(@as(f32, @floatFromInt(self.font_size)) * multiplier);
                        self.renderInlineRun(leaf.inlines.items, size, theme, arena, ui_ptr);
                    },
                    .Paragraph => {
                        self.renderInlineRun(leaf.inlines.items, self.font_size, theme, arena, ui_ptr);
                    },
                    .Code => |c| {
                        self.code_counter += 1;
                        clay.UI()(.{ .id = self.idi("md_code", self.code_counter), .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .padding = .all(16) }, .background_color = theme.surface, .corner_radius = .all(4) })({
                            self.renderCodeBlock(c.text orelse "", c.tag, arena, theme);
                        });
                    },
                    .Alert => |a| {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .padding = .all(16) }, .background_color = theme.surface, .border = .{ .width = .{ .left = 4 }, .color = theme.accent } })({
                            clay.text(if (a.alert) |at| at else "ALERT", .{ .font_size = self.font_size, .color = theme.accent });
                            self.indent += 32; // Padding links und rechts
                            defer self.indent -= 32;
                            self.renderInlineRun(leaf.inlines.items, self.font_size, theme, arena, ui_ptr);
                        });
                    },
                    .Break => {
                        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(8) } } })({});
                    },
                }
            },
        }
    }

    /// Breite einer Zelle, wie sie ein Browser für die Tabellenberechnung misst:
    /// `max` ist die Breite in einer einzigen Zeile, `min` die des breitesten
    /// unteilbaren Stücks (längstes Wort, ganzer Codespan). Leerzeichen sind
    /// Umbruchstellen und zählen nicht zur Mindestbreite.
    const CellWidth = struct { min: f32 = 0, max: f32 = 0 };

    /// Ein Textstück in die Messung einrechnen. Ein Leerzeichen beendet das laufende Wort.
    fn addPiece(line: *f32, word: *f32, out: *CellWidth, text: []const u8, size: f32, fudge: f32) void {
        const w = ui_mod.measureTextWidth(text, size) + fudge;
        line.* += w;
        if (std.mem.eql(u8, text, " ")) {
            out.min = @max(out.min, word.*);
            word.* = 0;
        } else {
            word.* += w;
        }
    }

    fn measureCell(self: *const Self, block: *const Block, size: f32) CellWidth {
        // Clay schlägt je Textelement 0.25 px auf (siehe `measureText` in mod.zig). Ohne
        // denselben Aufschlag ist eine Spalte ein Viertelpixel je Wort zu schmal und der
        // Umbruch schlägt zu früh zu — sichtbar an einer Kopfzelle wie „Nr.", die in
        // „Nr" und „." zerfiel.
        const fudge: f32 = 0.25;
        var out: CellWidth = .{};
        switch (block.*) {
            .Container => |*c| for (c.children.items) |*child| {
                const w = self.measureCell(child, size);
                out.min = @max(out.min, w.min);
                out.max = @max(out.max, w.max);
            },
            .Leaf => |*leaf| {
                // `line` ist die Breite ohne Umbruch, `word` die des laufenden Worts.
                // Umgebrochen wird nur an Leerzeichen, also zählen aufeinanderfolgende
                // Stücke ohne Leerzeichen dazwischen als ein Wort: „Nr." kommt als „Nr"
                // und „." und passt sonst scheinbar in eine zu schmale Spalte.
                var line: f32 = 0;
                var word: f32 = 0;
                for (leaf.inlines.items) |*item| {
                    switch (item.content) {
                        .text => |t| addPiece(&line, &word, &out, t.text, size, fudge),
                        .codespan => |cs| addPiece(&line, &word, &out, cs.text, size, fudge),
                        .autolink => |a| addPiece(&line, &word, &out, a.url, size, fudge),
                        .link => |l| for (l.text.items) |t| addPiece(&line, &word, &out, t.text, size, fudge),
                        .linebreak => {
                            out.max = @max(out.max, line);
                            out.min = @max(out.min, word);
                            line = 0;
                            word = 0;
                        },
                        else => {},
                    }
                }
                out.max = @max(out.max, line);
                out.min = @max(out.min, word);
            },
        }
        return out;
    }

    /// Tabelle als Raster. zigdown liefert die Zellen flach, Zeile für Zeile je `ncol`
    /// Paragraphen; die erste Zeile ist der Kopf. Vorher lagen alle Zellen untereinander,
    /// weil die Tabelle ein gewöhnlicher top_to_bottom-Container war.
    ///
    /// Spaltenbreiten wie im Browser (und damit wie in der VS-Code-Vorschau): jede Spalte
    /// will ihre Wunschbreite `max` (längste Zelle ohne Umbruch); passt die Summe nicht,
    /// wird proportional verkleinert, aber keine Spalte unter ihre Mindestbreite `min`.
    /// `relative_width` aus der Trennzeile (`|---|-----|`) bleibt ungenutzt — die Zahl der
    /// Striche sagt nichts über den Inhalt, und Browser werten sie ebenso wenig aus.
    ///
    /// Anders als der Browser bricht die Tabelle nie über den Rand: der waagrechte Bildlauf
    /// der Vorschau ist für Codeblöcke gedacht, eine Tabelle soll wie im Browser in die
    /// Breite passen. Notfalls werden deshalb auch die Mindestbreiten anteilig gestaucht; zu
    /// lange Wörter schneidet dann die Zelle ab.
    fn renderTable(self: *Self, container: *const zigdown.Container, arena: std.mem.Allocator, theme: Theme, ui_ptr: *ui_mod.UI) void {
        const cells = container.children.items;
        const ncol = container.content.Table.ncol;
        if (ncol == 0) return;
        const nrow = cells.len / ncol;
        if (nrow == 0) return;

        self.table_counter += 1;
        self.block_table_counter += 1;
        // Gemessen wird die Hülle, nicht die Tabelle: die Tabelle ist `fit` und schrumpft,
        // ihre eigene Breite als Vorgabe zu nehmen würde sie Frame für Frame enger machen.
        // Zwei Hüllen: `md_table_row` mit Frame-Nummer für die E2E, darin `md_table_box` mit
        // je Block stabiler Nummer (siehe `run_counter`) zum Messen — sonst liest die Tabelle
        // nach einem Fensterwechsel die Breite einer anderen ab.
        const row_id = self.idi("md_table_row", self.table_counter);
        const box_id = self.idi("md_table_box", self.cur_block *% 1024 +% self.block_table_counter);
        const data = clay.getElementData(box_id);
        var avail: f32 = self.availWidth() orelse 800;
        // Die Hülle wächst mit einer zu breiten Tabelle mit (`grow` ist nie schmaler als
        // ihr Kind). Ohne Deckel hielte sie die Überbreite aus dem ersten Frame fest.
        if (data.found and data.bounding_box.width > 0) avail = @min(avail, data.bounding_box.width);

        const size_f: f32 = @floatFromInt(self.font_size);
        const cell_pad: f32 = 16; // 8 links + 8 rechts
        const ncol_f: f32 = @floatFromInt(ncol);
        // Rahmen: außen 1 px je Seite, zwischen den Spalten je 1 px
        const inner = @max(ncol_f, avail - 2 - (ncol_f - 1) - cell_pad * ncol_f);

        const cols = arena.alloc(CellWidth, ncol) catch return;
        @memset(cols, .{});
        for (0..nrow) |r| for (0..ncol) |c| {
            const w = self.measureCell(&cells[r * ncol + c], size_f);
            cols[c].min = @max(cols[c].min, w.min);
            cols[c].max = @max(cols[c].max, w.max);
        };

        const widths = arena.alloc(f32, ncol) catch return;
        var sum_max: f32 = 0;
        for (cols) |cw| sum_max += cw.max;
        if (sum_max <= inner or sum_max <= 0) {
            for (cols, widths) |cw, *w| w.* = cw.max;
        } else {
            // Proportional stauchen, dabei Spalten an ihrer Mindestbreite festnageln und
            // den Rest neu verteilen. Zwei Durchgänge reichen für die üblichen Tabellen.
            var scale = inner / sum_max;
            for (0..2) |_| {
                var pinned: f32 = 0;
                var flex: f32 = 0;
                for (cols) |cw| {
                    if (cw.max * scale < cw.min) pinned += cw.min else flex += cw.max;
                }
                if (flex <= 0) break;
                scale = @max(0, inner - pinned) / flex;
            }
            for (cols, widths) |cw, *w| w.* = @max(cw.min, cw.max * scale);
            var total: f32 = 0;
            for (widths) |w| total += w;
            // Reichen selbst die Mindestbreiten nicht, zahlt die jeweils breiteste Spalte:
            // sie hat die meisten Wörter und bricht anständig um, während eine schmale
            // Spalte wie „Nr." schon bei zwei Pixeln weniger mitten im Wort umbräche.
            var deficit = total - inner;
            var guard: usize = 0;
            while (deficit > 0.01 and guard < 1000) : (guard += 1) {
                var widest: usize = 0;
                for (widths, 0..) |w, k| {
                    if (w > widths[widest]) widest = k;
                }
                var second: f32 = 0;
                for (widths, 0..) |w, k| {
                    if (k != widest and w > second) second = w;
                }
                const cut = @min(deficit, @max(1, widths[widest] - second));
                widths[widest] -= cut;
                deficit -= cut;
            }
        }

        var head_theme = theme;
        head_theme.text = theme.primary;

        clay.UI()(.{
            .id = row_id,
            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right },
        })({
            clay.UI()(.{
                .id = box_id,
                .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right },
            })({
                clay.UI()(.{
                    .layout = .{ .sizing = .{ .w = .fit, .h = .fit }, .direction = .top_to_bottom },
                    .border = .{ .width = .all(1), .color = theme.border },
                })({
                    for (0..nrow) |r| {
                        clay.UI()(.{
                            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right },
                            .background_color = if (r == 0) theme.surface else .{ 0, 0, 0, 0 },
                            .border = .{ .width = .{ .between_children = 1 }, .color = theme.border },
                        })({
                            for (0..ncol) |c| {
                                // E2E: `md_tcell` mit Tabelle * 100000 + Zellindex (Zeile * ncol + Spalte).
                                clay.UI()(.{
                                    .id = self.idi("md_tcell", self.table_counter * 100000 + @as(u32, @intCast(r * ncol + c))),
                                    .layout = .{
                                        .sizing = .{ .w = .fixed(widths[c] + cell_pad), .h = .grow },
                                        .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
                                    },
                                })({
                                    // Kein `clip` je Zelle: Clay hält nur zehn Clip-Container im
                                    // Kontext, eine Tabelle sprengt das sofort („out of bounds array
                                    // access"). Stattdessen bricht `splitWide` zu lange Wörter um.
                                    // Der Umbruch richtet sich nach der berechneten Spaltenbreite,
                                    // nicht nach dem gemessenen Element.
                                    // +2: `wrapLines` rechnet mit `avail - 2` Sicherheitsabstand,
                                    // sonst bräche eine Zelle genau an ihrer eigenen Wunschbreite um.
                                    self.wrap_width_forced = widths[c] + 2;
                                    self.renderBlock(&cells[r * ncol + c], arena, if (r == 0) head_theme else theme, ui_ptr);
                                    self.wrap_width_forced = null;
                                });
                            }
                        });
                    }
                });
            });
        });
    }

    const link_color: clay.Color = .{ 100, 149, 237, 255 };

    /// Ein gemessenes Textstück: Wort, Leerzeichen, Codespan oder Link-Text.
    const Piece = struct {
        text: []const u8,
        color: clay.Color,
        is_space: bool,
    };

    /// Farbe eines Text-Inlines aus seinem zigdown-Style. Es gibt nur eine
    /// Font-Face, deshalb werden Fett/Kursiv/Durchgestrichen über Farbe angezeigt.
    fn styledColor(style: anytype, base: clay.Color, theme: Theme) clay.Color {
        if (style.strike) return theme.muted;
        if (style.bold) return theme.primary;
        if (style.italic) return theme.accent;
        return base;
    }

    /// Rendert eine Inline-Folge als umbrechenden Fließtext mit Per-Wort-Farben.
    ///
    /// zigdown liefert jedes Wort und jedes Leerzeichen als eigenes Inline. Clay
    /// bricht Reihen von Elementen nicht um, also messen wir jedes Stück selbst,
    /// lassen word_wrap die Zeilen berechnen und rendern pro Zeile eine Reihe.
    /// Die verfügbare Breite stammt aus dem Bounding-Box des Containers im
    /// vorherigen Frame; im allerersten Frame fällt der Lauf auf ein einzelnes
    /// umbrechendes Textelement zurück. Nur Bilder unterbrechen den Lauf.
    fn renderInlineRun(self: *Self, inlines: []const Inline, base_size: u16, theme: Theme, arena: std.mem.Allocator, ui_ptr: *ui_mod.UI) void {
        var pieces: std.ArrayListUnmanaged(Piece) = .empty;
        for (inlines) |*item| {
            switch (item.content) {
                .text => |t| pieces.append(arena, .{
                    .text = t.text,
                    .color = styledColor(t.style, theme.text, theme),
                    .is_space = std.mem.eql(u8, t.text, " "),
                }) catch {},
                .codespan => |c| pieces.append(arena, .{ .text = c.text, .color = theme.warning, .is_space = false }) catch {},
                .link => |l| {
                    for (l.text.items) |t| pieces.append(arena, .{
                        .text = t.text,
                        .color = link_color,
                        .is_space = std.mem.eql(u8, t.text, " "),
                    }) catch {};
                },
                .image => {
                    self.flushPieces(&pieces, base_size, theme, arena);
                    self.renderInline(item, base_size, theme.text, arena, ui_ptr);
                },
                else => {},
            }
        }
        self.flushPieces(&pieces, base_size, theme, arena);
    }

    /// Stücke, die für sich allein breiter sind als die Zeile, in passende Teile zerlegen.
    /// Betrifft lange Pfade und URLs ohne Leerzeichen: sonst ragen sie aus ihrer Spalte
    /// oder aus dem Fenster; Fließtext soll nie waagrecht scrollen, nur Codeblöcke.
    /// Getrennt wird an UTF-8-Grenzen, nicht mitten in einem Zeichen.
    fn splitWide(arena: std.mem.Allocator, pieces: []const Piece, size: f32, max_width: f32) []const Piece {
        if (max_width <= 0) return pieces;
        var any = false;
        for (pieces) |p| {
            if (ui_mod.measureTextWidth(p.text, size) > max_width) any = true;
        }
        if (!any) return pieces;

        var out: std.ArrayListUnmanaged(Piece) = .empty;
        for (pieces) |p| {
            var rest = p.text;
            while (rest.len > 0 and ui_mod.measureTextWidth(rest, size) > max_width) {
                // Längstes Präfix suchen, das noch passt; mindestens ein Zeichen.
                var take: usize = 0;
                var i: usize = 0;
                while (i < rest.len) {
                    i += std.unicode.utf8ByteSequenceLength(rest[i]) catch 1;
                    if (ui_mod.measureTextWidth(rest[0..i], size) > max_width) break;
                    take = i;
                }
                if (take == 0) take = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
                out.append(arena, .{ .text = rest[0..take], .color = p.color, .is_space = false }) catch return pieces;
                rest = rest[take..];
            }
            if (rest.len > 0) out.append(arena, .{ .text = rest, .color = p.color, .is_space = p.is_space }) catch return pieces;
        }
        return out.items;
    }

    fn flushPieces(self: *Self, pieces: *std.ArrayListUnmanaged(Piece), base_size: u16, theme: Theme, arena: std.mem.Allocator) void {
        if (pieces.items.len == 0) return;
        defer pieces.clearRetainingCapacity();

        self.run_counter += 1;
        // Block-Index in der ID: stabil über Frames, auch wenn das virtualisierte Fenster wandert
        const id_str = std.fmt.allocPrint(arena, "md_run_{x}_{x}_{d}_{d}", .{ @intFromPtr(self), self.pane_salt, self.cur_block, self.run_counter }) catch "md_run";
        const run_id = clay.ElementId.ID(id_str);
        const data = clay.getElementData(run_id);
        // In einer Tabellenzelle steht die Breite fest (`wrap_width_forced`); die gemessene
        // Breite des Laufs taugt dort nicht, weil die klippende Zelle ihre Kinder am Inhalt
        // misst und ein zu kleiner Wert vorzeitig umbräche.
        // Gemessene Breite des Laufs, gedeckelt durch Hint minus Einrückung: der Lauf ist
        // `grow` und wäre nach einem Überlauf so breit wie der ganze Inhalt.
        var avail: f32 = if (data.found) data.bounding_box.width else (self.availWidth() orelse 0);
        if (self.availWidth()) |cap| avail = @min(avail, cap);
        if (self.wrap_width_forced) |w| avail = w;
        const size_f: f32 = @floatFromInt(base_size);

        clay.UI()(.{
            .id = run_id,
            .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .top_to_bottom, .child_gap = 2 },
        })({
            if (avail <= 0) {
                // Breite noch unbekannt (erster Frame): ein Element, Clay bricht selbst um
                var run: std.ArrayListUnmanaged(u8) = .empty;
                for (pieces.items) |p| run.appendSlice(arena, p.text) catch {};
                const text = std.mem.trim(u8, run.items, " ");
                if (text.len > 0) clay.text(text, .{ .font_size = base_size, .color = theme.text, .wrap_mode = .words });
            } else {
                // Ohne Word Wrap: nichts zerlegen, eine Reihe für den ganzen Lauf (Breite „unendlich“)
                const limit: f32 = if (self.wrap) avail - 2 else std.math.floatMax(f32);
                const parts = if (self.wrap) splitWide(arena, pieces.items, size_f, avail - 2) else pieces.items;
                const items = arena.alloc(word_wrap.Item, parts.len) catch return;
                for (parts, 0..) |p, i| {
                    // +0.25: Clay schlägt je Textelement ein Viertelpixel auf (`measureText` in
                    // mod.zig), und jedes Stück wird ein eigenes Element. Ohne den Zuschlag war
                    // eine Zeile aus 40 Wörtern 10 px breiter als berechnet und ragte über den Rand.
                    items[i] = .{ .width = ui_mod.measureTextWidth(p.text, size_f) + 0.25, .is_space = p.is_space };
                }
                const lines = word_wrap.wrapLines(arena, items, limit) catch return;
                for (lines, 0..) |line, li| {
                    var line_text: std.ArrayListUnmanaged(u8) = .empty;
                    for (parts[line.start..line.end]) |p| line_text.appendSlice(arena, p.text) catch {};
                    const ctx = self.registerLine(line_text.items, li > 0, base_size);
                    clay.UI()(.{ .id = ctx.id, .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .direction = .left_to_right, .child_gap = 0 } })({
                        var pos: u32 = 0;
                        for (parts[line.start..line.end]) |p| {
                            self.textSel(p.text, pos, base_size, p.color, ctx.range);
                            pos += @intCast(p.text.len);
                        }
                    });
                }
            }
        });
    }

    fn renderInline(self: *Self, item: *const Inline, base_size: u16, base_color: clay.Color, arena: std.mem.Allocator, ui_ptr: *ui_mod.UI) void {
        switch (item.content) {
            .text => |t| {
                clay.text(t.text, .{ .font_size = base_size, .color = base_color, .wrap_mode = .words });
            },
            .link => |l| {
                for (l.text.items) |t| {
                    clay.text(t.text, .{ .font_size = base_size, .color = .{ 100, 149, 237, 255 }, .wrap_mode = .words });
                }
            },
            .codespan => |c| {
                clay.text(c.text, .{ .font_size = base_size, .color = base_color, .wrap_mode = .words });
            },
            .image => |img| {
                var path: []const u8 = img.src;
                if (!std.fs.path.isAbsolute(path) and self.base_path.len > 0) {
                    const dir = std.fs.path.dirname(self.base_path) orelse ".";
                    path = std.fs.path.join(arena, &[_][]const u8{ dir, img.src }) catch img.src;
                }

                if (ui_ptr.open_images.get(path)) |texture_ptr| {
                    const tex: *const ImageTexture = @ptrCast(@alignCast(texture_ptr));
                    const aspect: f32 = if (tex.height > 0) @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height)) else 1.0;
                    const max_w = @as(f32, @floatFromInt(tex.width));

                    clay.UI()(.{
                        .layout = .{
                            .sizing = .{ .w = .{ .type = .grow, .size = .{ .minmax = .{ .min = 0, .max = max_w } } }, .h = .fit },
                        },
                        .background_color = .{ 255, 255, 255, 255 },
                        .aspect_ratio = .{ .aspect_ratio = aspect },
                        .image = .{ .image_data = texture_ptr },
                    })({});
                } else {
                    _ = ui_ptr.getOrCreateTexture(path);
                    clay.UI()(.{
                        .layout = .{ .sizing = .{ .w = .fixed(120), .h = .fixed(40) }, .child_alignment = .{ .x = .center, .y = .center } },
                        .background_color = .{ 80, 80, 80, 255 },
                        .corner_radius = .all(4),
                    })({
                        clay.text("LOADING...", .{ .font_size = 14, .color = .{ 200, 200, 200, 255 } });
                    });
                }
            },
            else => {},
        }
    }
};
