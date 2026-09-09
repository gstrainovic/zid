//! Marp-Folie → HTML + CSS für MuPDFs Story-Engine.
//!
//! Der Folieninhalt kommt aus zigdowns HTML-Renderer, drumherum baut dieses
//! Modul den Rahmen: Foliengröße, Theme-Grundstil und die Direktiven der Folie.
//! Kopf-, Fußzeile und Seitenzahl bleiben bewusst draußen — die platziert der
//! PDF-Schritt in eigenen Rechtecken, weil MuPDFs CSS kein `position` kennt.
//!
//! MuPDF beherrscht grob CSS 2.1: kein Flexbox, kein Grid, keine Custom
//! Properties. Die Stile hier bleiben deshalb bei Blockfluss und Rändern.

const std = @import("std");
const zigdown = @import("zigdown");
const marp = @import("marp");

pub const Rendered = struct {
    /// Vollständiges HTML-Fragment der Folie.
    html: []const u8,
    /// Stylesheet, das als `user_css` an `fz_new_story` geht.
    css: []const u8,
};

/// Rendert eine Folie. Das Ergebnis gehört dem übergebenen Allocator.
pub fn renderSlide(
    allocator: std.mem.Allocator,
    global: marp.Global,
    slide: marp.Slide,
) ![]const u8 {
    _ = global;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.Io.Writer.Allocating = .init(arena);
    if (slide.markdown.len > 0) {
        const result = try zigdown.parser.timedParse(arena, slide.markdown, false);
        var renderer = zigdown.HtmlRenderer.init(&body.writer, arena, .{ .body_only = true });
        defer renderer.deinit();
        try renderer.renderBlock(result.parser.document);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (slide.local.class) |class| {
        try out.writer.print("<div class=\"slide {s}\">\n", .{class});
    } else {
        try out.writer.writeAll("<div class=\"slide\">\n");
    }
    try out.writer.writeAll(body.written());
    try out.writer.writeAll("\n</div>\n");
    return out.toOwnedSlice();
}

/// Grundstil für alle Folien. Bewusst CSS 2.1: MuPDFs Story-Engine kennt
/// weder Flexbox noch Grid noch Custom Properties.
const base_css =
    \\.slide { margin: 0; padding: 0; }
    \\body { font-family: sans-serif; line-height: 1.4; }
    \\h1 { font-size: 2.0em; margin: 0 0 0.4em 0; }
    \\h2 { font-size: 1.5em; margin: 0 0 0.4em 0; }
    \\h3 { font-size: 1.2em; margin: 0 0 0.3em 0; }
    \\p, ul, ol, table { margin: 0 0 0.7em 0; }
    \\li { margin: 0 0 0.2em 0; }
    \\pre { background-color: #f2f2f2; padding: 0.5em; }
    \\code { font-family: monospace; }
    \\table { border-collapse: collapse; }
    \\th, td { border: 1px solid #999999; padding: 0.2em 0.5em; }
    \\blockquote { margin: 0 0 0.7em 1em; padding-left: 0.7em; border-left: 4px solid #999999; }
    \\
;

/// Stylesheet für das Deck plus die Farbdirektiven dieser Folie.
pub fn slideCss(
    allocator: std.mem.Allocator,
    global: marp.Global,
    slide: marp.Slide,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(base_css);
    if (slide.local.color) |color| {
        try out.writer.print("body {{ color: {s}; }}\n", .{color});
    }
    if (slide.local.background_color) |bg| {
        // MuPDF malt den Seitenhintergrund nicht; die Farbe steht hier nur für
        // den Textblock. Die volle Fläche füllt der PDF-Schritt selbst.
        try out.writer.print("body {{ background-color: {s}; }}\n", .{bg});
    }
    if (global.style) |style| {
        try out.writer.writeAll(style);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseFirst(alloc: std.mem.Allocator, src: []const u8) !marp.Deck {
    return marp.parse(alloc, src);
}

test "renderSlide gibt den Markdown-Inhalt als HTML zurück" {
    var deck = try parseFirst(testing.allocator, "---\nmarp: true\n---\n\n# Titel\n\nAbsatz\n");
    defer deck.deinit();

    const html = try renderSlide(testing.allocator, deck.global, deck.slides[0]);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "Titel") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<h1") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Absatz") != null);
}

test "renderSlide packt die Folie in einen Wrapper mit Klasse" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\<!-- _class: lead -->
        \\
        \\# Titel
        \\
    ;
    var deck = try parseFirst(testing.allocator, src);
    defer deck.deinit();

    const html = try renderSlide(testing.allocator, deck.global, deck.slides[0]);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "class=\"slide lead\"") != null);
}

test "renderSlide ohne Klasse hat nur die Basisklasse" {
    var deck = try parseFirst(testing.allocator, "---\nmarp: true\n---\n\n# Titel\n");
    defer deck.deinit();

    const html = try renderSlide(testing.allocator, deck.global, deck.slides[0]);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "class=\"slide\"") != null);
}

test "renderSlide maskiert spitze Klammern aus dem Markdown" {
    // zigdown maskiert nur Textstücke, die selbst eine spitze Klammer
    // enthalten (`html_chars` ist "<>"); ein & oder ein > in einem anderen
    // Stück derselben Zeile bleibt roh. MuPDFs Parser liest solche Zeichen als
    // Literal, das ist formal falsch, aber im Ergebnis unauffällig.
    var deck = try parseFirst(testing.allocator, "---\nmarp: true\n---\n\nA < B\n");
    defer deck.deinit();

    const html = try renderSlide(testing.allocator, deck.global, deck.slides[0]);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "&lt;") != null);
}

test "slideCss übernimmt Hintergrund- und Textfarbe der Folie" {
    const src =
        \\---
        \\marp: true
        \\---
        \\
        \\<!-- _backgroundColor: "#101418"
        \\     _color: "#e8e8e8" -->
        \\
        \\# Titel
        \\
    ;
    var deck = try parseFirst(testing.allocator, src);
    defer deck.deinit();

    const css = try slideCss(testing.allocator, deck.global, deck.slides[0]);
    defer testing.allocator.free(css);

    try testing.expect(std.mem.indexOf(u8, css, "#101418") != null);
    try testing.expect(std.mem.indexOf(u8, css, "#e8e8e8") != null);
}

test "slideCss hängt das Deck-Stylesheet aus der style-Direktive an" {
    const src =
        \\---
        \\marp: true
        \\style: "h1 { letter-spacing: 2px; }"
        \\---
        \\
        \\# Titel
        \\
    ;
    var deck = try parseFirst(testing.allocator, src);
    defer deck.deinit();

    const css = try slideCss(testing.allocator, deck.global, deck.slides[0]);
    defer testing.allocator.free(css);

    try testing.expect(std.mem.indexOf(u8, css, "letter-spacing: 2px") != null);
}

test "slideCss enthält keine CSS-Features, die MuPDF nicht kennt" {
    var deck = try parseFirst(testing.allocator, "---\nmarp: true\n---\n\n# Titel\n");
    defer deck.deinit();

    const css = try slideCss(testing.allocator, deck.global, deck.slides[0]);
    defer testing.allocator.free(css);

    try testing.expect(std.mem.indexOf(u8, css, "flex") == null);
    try testing.expect(std.mem.indexOf(u8, css, "grid") == null);
    try testing.expect(std.mem.indexOf(u8, css, "var(--") == null);
}
