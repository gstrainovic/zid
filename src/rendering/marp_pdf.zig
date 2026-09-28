//! Marp-Deck → PDF über MuPDFs Story-Engine.
//!
//! Pro Folie eine Seite in Foliengröße. Der Folieninhalt kommt als HTML plus
//! CSS aus `ui/marp_html.zig` und wird von `fz_story` layoutet; Hintergrund,
//! Kopf-/Fußzeile und Seitenzahl zeichnet dieses Modul selbst, weil MuPDFs
//! CSS-Teilmenge kein `position` kennt.
//!
//! Alle MuPDF-Aufrufe laufen über die `*_z`-Wrapper in `mupdf_wrapper/`, weil
//! `fz_try`/`fz_catch` auf setjmp beruht und Zig das nicht überlebt.

const std = @import("std");
const marp = @import("marp");
const marp_html = @import("marp_html");
const svg_fixup = @import("svg_fixup.zig");

const c = @cImport({
    @cInclude("fitz-z.h");
    @cInclude("mupdf/fitz.h");
});

pub const ExportError = error{
    ContextFailed,
    WriterFailed,
    StoryFailed,
    PageFailed,
} || std.mem.Allocator.Error;

/// Rand um den Folieninhalt, in Foliengrößen-Einheiten.
const margin_x: f32 = 70;
const margin_y: f32 = 50;
/// Höhe des Streifens für Kopf-, Fußzeile und Seitenzahl. Muss eine Zeile
/// samt Zeilenabstand fassen, sonst platziert `fz_place_story` gar nichts.
const chrome_h: f32 = 40;
/// Grundschriftgröße der Folie.
const content_em: f32 = 26;
const chrome_em: f32 = 14;

/// Fläche für den Folieninhalt. Eine Bildspalte aus `![bg left/right]` nimmt
/// ihren Anteil der Breite weg, der Inhalt behält daneben seine Ränder.
fn contentRect(deck: marp.Deck, slide: marp.Slide) c.fz_rect {
    const page_w: f32 = @floatFromInt(deck.global.size.w);
    const page_h: f32 = @floatFromInt(deck.global.size.h);
    const split = marp.Split.of(slide.backgrounds);
    const col = page_w * split.frac;
    return .{
        .x0 = margin_x + (if (split.side == .left) col else 0),
        .y0 = margin_y + chrome_h,
        .x1 = page_w - margin_x - (if (split.side == .right) col else 0),
        .y1 = page_h - margin_y - chrome_h,
    };
}

/// Zeichnet die `![bg]`-Bilder: volle Folie oder Bildspalte, mehrere Bilder
/// derselben Fläche nebeneinander. Relative Pfade gelten ab `base_dir`.
/// Unlesbare Bilder werden übersprungen, wie Marp ein kaputtes Bild auslässt.
fn drawBackgrounds(
    ctx: *c.fz_context,
    allocator: std.mem.Allocator,
    dev: *c.fz_device,
    deck: marp.Deck,
    slide: marp.Slide,
    base_dir: []const u8,
) !void {
    const page_w: f32 = @floatFromInt(deck.global.size.w);
    const page_h: f32 = @floatFromInt(deck.global.size.h);
    const split = marp.Split.of(slide.backgrounds);
    const col = page_w * split.frac;

    for ([_]marp.Background.Side{ .full, .left, .right }) |side| {
        // Volle Hintergründe nur ohne Teilung, wie in der Vorschau.
        if (side == .full and split.side != .full) continue;
        if (side != .full and side != split.side) continue;
        var n: usize = 0;
        for (slide.backgrounds) |bg| {
            if (bg.side == side) n += 1;
        }
        if (n == 0) continue;
        const area: c.fz_rect = switch (side) {
            .full => .{ .x0 = 0, .y0 = 0, .x1 = page_w, .y1 = page_h },
            .left => .{ .x0 = 0, .y0 = 0, .x1 = col, .y1 = page_h },
            .right => .{ .x0 = page_w - col, .y0 = 0, .x1 = page_w, .y1 = page_h },
        };
        const each = (area.x1 - area.x0) / @as(f32, @floatFromInt(n));
        var i: usize = 0;
        for (slide.backgrounds) |bg| {
            if (bg.side != side) continue;
            const box: c.fz_rect = .{
                .x0 = area.x0 + each * @as(f32, @floatFromInt(i)),
                .y0 = area.y0,
                .x1 = area.x0 + each * @as(f32, @floatFromInt(i + 1)),
                .y1 = area.y1,
            };
            i += 1;
            drawBackground(ctx, allocator, dev, bg, base_dir, box) catch |err| {
                std.log.scoped(.marp_pdf).warn("Hintergrundbild {s}: {s}", .{ bg.src, @errorName(err) });
            };
        }
    }
}

fn drawBackground(
    ctx: *c.fz_context,
    allocator: std.mem.Allocator,
    dev: *c.fz_device,
    bg: marp.Background,
    base_dir: []const u8,
    box: c.fz_rect,
) !void {
    const path = if (std.fs.path.isAbsolute(bg.src))
        try allocator.dupe(u8, bg.src)
    else
        try std.fs.path.join(allocator, &.{ base_dir, bg.src });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(raw);
    // SVG wie in der Vorschau aufbereiten (MuPDF: `<symbol>`, geerbte Schrift).
    const data = if (std.ascii.endsWithIgnoreCase(path, ".svg")) try svg_fixup.fixup(allocator, raw) else try allocator.dupe(u8, raw);
    defer allocator.free(data);

    var w: f32 = 0;
    var h: f32 = 0;
    if (c.fz_doc_page_size_z(ctx, path_z.ptr, data.ptr, data.len, &w, &h) != 0) return error.PageFailed;
    const box_w = box.x1 - box.x0;
    const box_h = box.y1 - box.y0;
    const fit = bg.fitSize(w, h, box_w, box_h);
    const dest: c.fz_rect = .{
        .x0 = box.x0 + (box_w - fit[0]) / 2,
        .y0 = box.y0 + (box_h - fit[1]) / 2,
        .x1 = box.x0 + (box_w + fit[0]) / 2,
        .y1 = box.y0 + (box_h + fit[1]) / 2,
    };
    if (c.fz_draw_doc_page_z(ctx, dev, path_z.ptr, data.ptr, data.len, box, dest) != 0) return error.PageFailed;
}

/// Schreibt das Deck als PDF nach `out_path`. Relative Bildpfade gelten ab
/// `base_dir` (Ordner der Markdown-Datei).
pub fn exportDeck(
    allocator: std.mem.Allocator,
    deck: marp.Deck,
    base_dir: []const u8,
    out_path: []const u8,
) !void {
    const path_z = try allocator.dupeZ(u8, out_path);
    defer allocator.free(path_z);

    const ctx = c.fz_new_context(null, null, c.FZ_STORE_UNLIMITED) orelse return error.ContextFailed;
    defer c.fz_drop_context(ctx);
    c.fz_register_document_handlers(ctx);

    const wri = c.fz_new_document_writer_z(ctx, path_z.ptr, "pdf", null) orelse return error.WriterFailed;
    defer c.fz_drop_document_writer(ctx, wri);

    const page_w: f32 = @floatFromInt(deck.global.size.w);
    const page_h: f32 = @floatFromInt(deck.global.size.h);
    const mediabox = c.fz_rect{ .x0 = 0, .y0 = 0, .x1 = page_w, .y1 = page_h };

    for (deck.slides, 0..) |slide, index| {
        const html = try marp_html.renderSlide(allocator, deck.global, slide);
        defer allocator.free(html);
        const css = try marp_html.slideCss(allocator, deck.global, slide);
        defer allocator.free(css);

        const dev = c.fz_begin_page_z(ctx, wri, mediabox) orelse return error.PageFailed;

        if (slide.local.background_color) |hex| {
            if (parseHexColor(hex)) |rgb| {
                var color = rgb;
                _ = c.fz_fill_rect_z(ctx, dev, mediabox, c.fz_device_rgb(ctx), &color, 1.0);
            }
        }

        try drawBackgrounds(ctx, allocator, dev, deck, slide, base_dir);
        try drawStory(ctx, allocator, dev, html, css, content_em, contentRect(deck, slide));

        if (slide.local.header) |text| {
            try drawText(ctx, allocator, dev, text, css, .{
                .x0 = margin_x,
                .y0 = margin_y * 0.4,
                .x1 = page_w - margin_x,
                .y1 = margin_y * 0.4 + chrome_h,
            });
        }
        if (slide.local.footer) |text| {
            try drawText(ctx, allocator, dev, text, css, .{
                .x0 = margin_x,
                .y0 = page_h - margin_y * 0.4 - chrome_h,
                .x1 = page_w - margin_x,
                .y1 = page_h - margin_y * 0.4,
            });
        }
        if (slide.local.paginate) {
            var buf: [16]u8 = undefined;
            const num = std.fmt.bufPrint(&buf, "{d}", .{index + 1}) catch "";
            try drawText(ctx, allocator, dev, num, css, .{
                .x0 = page_w - margin_x - 60,
                .y0 = page_h - margin_y * 0.4 - chrome_h,
                .x1 = page_w - margin_x,
                .y1 = page_h - margin_y * 0.4,
            });
        }

        if (c.fz_end_page_z(ctx, wri) != 0) return error.PageFailed;
    }

    if (c.fz_close_document_writer_z(ctx, wri) != 0) return error.WriterFailed;
}

/// Liest eine Markdown-Datei, parst sie als Deck und exportiert sie.
pub fn exportFile(
    allocator: std.mem.Allocator,
    md_path: []const u8,
    out_path: []const u8,
) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, md_path, 16 * 1024 * 1024);
    defer allocator.free(source);

    var deck = try marp.parse(allocator, source);
    defer deck.deinit();

    try exportDeck(allocator, deck, std.fs.path.dirname(md_path) orelse ".", out_path);
}

/// Standardpfad für den Export: Markdown-Pfad mit `.pdf` statt `.md`.
pub fn defaultOutputPath(allocator: std.mem.Allocator, md_path: []const u8) ![]u8 {
    const ext = std.fs.path.extension(md_path);
    const stem = md_path[0 .. md_path.len - ext.len];
    return std.fmt.allocPrint(allocator, "{s}.pdf", .{stem});
}

/// Passt die Folie auf eine Seite? Fragt dieselbe Story-Engine, die auch das
/// PDF schreibt, legt aber nur aus und zeichnet nichts. Damit stimmt die
/// Aussage der Vorschau mit dem Export überein.
pub fn slideFits(allocator: std.mem.Allocator, deck: marp.Deck, index: usize) bool {
    if (index >= deck.slides.len) return true;
    const slide = deck.slides[index];

    const html = marp_html.renderSlide(allocator, deck.global, slide) catch return true;
    defer allocator.free(html);
    const css = marp_html.slideCss(allocator, deck.global, slide) catch return true;
    defer allocator.free(css);
    const css_z = allocator.dupeZ(u8, css) catch return true;
    defer allocator.free(css_z);

    const ctx = c.fz_new_context(null, null, c.FZ_STORE_UNLIMITED) orelse return true;
    defer c.fz_drop_context(ctx);

    const buf = c.fz_new_buffer_from_copied_data_z(ctx, html.ptr, html.len) orelse return true;
    defer c.fz_drop_buffer(ctx, buf);
    const story = c.fz_new_story_z(ctx, buf, css_z.ptr, content_em, null) orelse return true;
    defer c.fz_drop_story(ctx, story);

    var filled: c.fz_rect = undefined;
    var more: c_int = 0;
    if (c.fz_place_story_z(ctx, story, contentRect(deck, slide), &filled, &more) != 0) return true;

    // more != 0: es bliebe Inhalt für eine weitere Seite übrig, das PDF
    // schneidet ihn ab.
    return more == 0;
}

// --- MuPDF-Hilfen ---------------------------------------------------------

fn drawStory(
    ctx: *c.fz_context,
    allocator: std.mem.Allocator,
    dev: *c.fz_device,
    html: []const u8,
    css: []const u8,
    em: f32,
    where: c.fz_rect,
) !void {
    const css_z = try allocator.dupeZ(u8, css);
    defer allocator.free(css_z);

    const buf = c.fz_new_buffer_from_copied_data_z(ctx, html.ptr, html.len) orelse return error.StoryFailed;
    defer c.fz_drop_buffer(ctx, buf);

    const story = c.fz_new_story_z(ctx, buf, css_z.ptr, em, null) orelse return error.StoryFailed;
    defer c.fz_drop_story(ctx, story);

    // Passt der Inhalt nicht, wird der Rest verworfen — eine Folie ist eine
    // Seite, genau wie bei Marp.
    var filled: c.fz_rect = undefined;
    var more: c_int = 0;
    if (c.fz_place_story_z(ctx, story, where, &filled, &more) != 0) return error.StoryFailed;
    if (c.fz_draw_story_z(ctx, story, dev, c.fz_identity) != 0) return error.StoryFailed;
}

fn drawText(
    ctx: *c.fz_context,
    allocator: std.mem.Allocator,
    dev: *c.fz_device,
    text: []const u8,
    css: []const u8,
    where: c.fz_rect,
) !void {
    const html = try std.fmt.allocPrint(allocator, "<p>{s}</p>", .{text});
    defer allocator.free(html);
    // Ohne den Absatzabstand des Grundstils passt die Zeile in den Streifen.
    const chrome_css = try std.fmt.allocPrint(allocator, "{s}\np {{ margin: 0; }}\n", .{css});
    defer allocator.free(chrome_css);
    try drawStory(ctx, allocator, dev, html, chrome_css, chrome_em, where);
}

/// `#rgb` oder `#rrggbb` → drei Kanäle in 0..1. Alles andere: null.
fn parseHexColor(hex: []const u8) ?[3]f32 {
    if (hex.len == 0 or hex[0] != '#') return null;
    const digits = hex[1..];
    const step: usize = switch (digits.len) {
        3 => 1,
        6 => 2,
        else => return null,
    };
    var out: [3]f32 = undefined;
    for (&out, 0..) |*channel, i| {
        const part = digits[i * step ..][0..step];
        const value = std.fmt.parseInt(u8, part, 16) catch return null;
        const scaled: u8 = if (step == 1) value * 17 else value;
        channel.* = @as(f32, @floatFromInt(scaled)) / 255.0;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseHexColor liest lange und kurze Schreibweise" {
    const long = parseHexColor("#101418").?;
    try testing.expectApproxEqAbs(@as(f32, 0x10) / 255.0, long[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0x14) / 255.0, long[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0x18) / 255.0, long[2], 0.001);

    const short = parseHexColor("#fff").?;
    try testing.expectApproxEqAbs(@as(f32, 1.0), short[0], 0.001);
}

test "parseHexColor lehnt Namen und Unsinn ab" {
    try testing.expect(parseHexColor("white") == null);
    try testing.expect(parseHexColor("#12") == null);
    try testing.expect(parseHexColor("#gggggg") == null);
    try testing.expect(parseHexColor("") == null);
}

test "defaultOutputPath ersetzt die Endung" {
    const out = try defaultOutputPath(testing.allocator, "test_data/marp_test.md");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("test_data/marp_test.pdf", out);
}
