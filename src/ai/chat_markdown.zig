//! Aufbereitung von AI-Chat-Nachrichten für die Markdown-Darstellung.
//!
//! Reines String-Modul ohne UI-Abhängigkeiten, damit die Tool-Call-Erkennung
//! und die Umwandlung in Anzeige-Markdown testbar bleiben.

const std = @import("std");

/// Sucht im rohen Antwort-Text den ersten JSON-Block mit einem "tool"-Schlüssel.
/// Liefert den Slice des JSON-Objekts (inklusive Klammern) oder null.
pub fn findToolCall(response: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, response, search_from, '{')) |start| {
        if (matchingBrace(response, start)) |end| {
            const candidate = response[start .. end + 1];
            if (std.mem.indexOf(u8, candidate, "\"tool\"") != null) return candidate;
            // Balanciertes Objekt ohne "tool": dahinter weitersuchen
            search_from = end + 1;
        } else {
            // Unbalanciert ab hier: nächste öffnende Klammer probieren
            search_from = start + 1;
        }
    }
    return null;
}

/// Index der schließenden Klammer zum '{' an `start`, unter Berücksichtigung
/// von JSON-Strings und Escapes. null wenn unbalanciert.
fn matchingBrace(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Wandelt den rohen Antwort-Text in Anzeige-Markdown um: Prosa bleibt
/// unverändert, ein erkannter Tool-Call wird als ```json-Codeblock eingebettet.
/// Rückgabe gehört dem Aufrufer.
fn toDisplayMarkdownRaw(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    const json = findToolCall(content) orelse return alloc.dupe(u8, content);
    const start = @intFromPtr(json.ptr) - @intFromPtr(content.ptr);
    const before = std.mem.trimRight(u8, content[0..start], " \t\r\n");
    const after = std.mem.trimLeft(u8, content[start + json.len ..], " \t\r\n");

    // Modell hat den Block schon selbst eingezäunt: nichts doppelt einpacken
    if (std.mem.endsWith(u8, before, "```json") or std.mem.endsWith(u8, before, "```")) {
        return alloc.dupe(u8, content);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    if (before.len > 0) {
        try out.appendSlice(alloc, before);
        try out.appendSlice(alloc, "\n\n");
    }
    try out.appendSlice(alloc, "```json\n");
    try out.appendSlice(alloc, json);
    try out.appendSlice(alloc, "\n```");
    if (after.len > 0) {
        try out.appendSlice(alloc, "\n\n");
        try out.appendSlice(alloc, after);
    }
    return out.toOwnedSlice(alloc);
}

/// Tool-Ergebnisse (system-Rolle): erste Zeile bleibt Text, der Rest wird
/// als Codeblock eingebettet, damit Dateiinhalte nicht als Markdown geparst werden.
fn wrapToolResultRaw(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    const nl = std.mem.indexOfScalar(u8, content, '\n') orelse return alloc.dupe(u8, content);
    const header = content[0..nl];
    const body = std.mem.trimRight(u8, content[nl + 1 ..], "\r\n");
    if (body.len == 0) return alloc.dupe(u8, header);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, header);
    try out.appendSlice(alloc, "\n\n```\n");
    try out.appendSlice(alloc, body);
    try out.appendSlice(alloc, "\n```");
    return out.toOwnedSlice(alloc);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

/// Text so abschließen, dass zigdown ihn sicher parst: immer mit Zeilenumbruch enden (eine
/// Zeile, die genau mit ``` endet und kein Newline hat, brachte `handleLineCode` zum Absturz:
/// leerer Tag, `tag[0]` auf Länge 0 — typisch für Antworten, die nur aus einem Codeblock
/// bestehen, und für jeden Streaming-Stand, der auf ``` endet). Ein offener Zaun (ungerade
/// Zahl von ```-Zeilen, Streaming mitten im Codeblock) wird geschlossen.
pub fn finishForParser(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, text);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
    var fences: usize = 0;
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) fences += 1;
    }
    if (fences % 2 == 1) try out.appendSlice(alloc, "```\n");
    return out.toOwnedSlice(alloc);
}

pub fn toDisplayMarkdown(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    const raw = try toDisplayMarkdownRaw(alloc, content);
    defer alloc.free(raw);
    return finishForParser(alloc, raw);
}

pub fn wrapToolResult(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    const raw = try wrapToolResultRaw(alloc, content);
    defer alloc.free(raw);
    return finishForParser(alloc, raw);
}

const testing = std.testing;

test "finishForParser: Zeilenumbruch am Ende, offener Zaun wird geschlossen" {
    const a = testing.allocator;
    const t1 = try finishForParser(a, "```zig\nconst x = 1;\n```");
    defer a.free(t1);
    try testing.expectEqualStrings("```zig\nconst x = 1;\n```\n", t1);
    const t2 = try finishForParser(a, "Text\n\n```zig\nconst x");
    defer a.free(t2);
    try testing.expectEqualStrings("Text\n\n```zig\nconst x\n```\n", t2);
    const t3 = try finishForParser(a, "fertig\n");
    defer a.free(t3);
    try testing.expectEqualStrings("fertig\n", t3);
    const t4 = try finishForParser(a, "");
    defer a.free(t4);
    try testing.expectEqualStrings("", t4);
}



test "findToolCall: Prosa ohne JSON liefert null" {
    try testing.expect(findToolCall("Hallo, wie kann ich helfen?") == null);
}

test "findToolCall: reines JSON liefert den ganzen String" {
    const json = "{\"tool\": \"read_file\", \"path\": \"a.zig\"}";
    try testing.expectEqualStrings(json, findToolCall(json) orelse return error.NoToolCall);
}

test "findToolCall: JSON zwischen Prosa liefert nur das JSON" {
    const resp = "Ich lese die Datei.\n{\"tool\": \"read_file\", \"path\": \"a.zig\"}\nMoment {bitte}.";
    try testing.expectEqualStrings("{\"tool\": \"read_file\", \"path\": \"a.zig\"}", findToolCall(resp) orelse return error.NoToolCall);
}

test "findToolCall: JSON in Code-Fence wird gefunden" {
    const resp = "```json\n{\"tool\": \"replace_text\", \"path\": \"b.zig\", \"old\": \"x\", \"new\": \"y\"}\n```";
    try testing.expectEqualStrings("{\"tool\": \"replace_text\", \"path\": \"b.zig\", \"old\": \"x\", \"new\": \"y\"}", findToolCall(resp) orelse return error.NoToolCall);
}

test "findToolCall: verschachtelte Klammern und Klammern in Strings" {
    const resp = "{\"tool\": \"replace_text\", \"path\": \"c.zig\", \"old\": \"if (x) { y }\", \"new\": \"{}\"} danach";
    try testing.expectEqualStrings("{\"tool\": \"replace_text\", \"path\": \"c.zig\", \"old\": \"if (x) { y }\", \"new\": \"{}\"}", findToolCall(resp) orelse return error.NoToolCall);
}

test "findToolCall: Klammern ohne tool-Schlüssel liefern null" {
    try testing.expect(findToolCall("Zig nutzt {} für Blöcke und {\"a\": 1} ist JSON.") == null);
}

test "toDisplayMarkdown: Prosa bleibt unverändert" {
    const out = try toDisplayMarkdownRaw(testing.allocator, "# Titel\n\nText mit **fett**.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# Titel\n\nText mit **fett**.", out);
}

test "toDisplayMarkdown: Tool-Call wird als json-Codeblock eingebettet" {
    const out = try toDisplayMarkdownRaw(testing.allocator, "Ich lese die Datei.\n{\"tool\": \"read_file\", \"path\": \"a.zig\"}\nFertig.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "Ich lese die Datei.\n\n```json\n{\"tool\": \"read_file\", \"path\": \"a.zig\"}\n```\n\nFertig.",
        out,
    );
}

test "toDisplayMarkdown: bereits eingezäunter Tool-Call bleibt unverändert" {
    const src = "```json\n{\"tool\": \"read_file\", \"path\": \"a.zig\"}\n```";
    const out = try toDisplayMarkdownRaw(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "wrapToolResult: Kopfzeile bleibt Text, Rest wird Codeblock" {
    const out = try wrapToolResultRaw(testing.allocator, "Tool read_file result for 'a.zig':\nconst x = 1;\n# kein Heading");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "Tool read_file result for 'a.zig':\n\n```\nconst x = 1;\n# kein Heading\n```",
        out,
    );
}

test "wrapToolResult: einzeilige Meldung bleibt unverändert" {
    const out = try wrapToolResultRaw(testing.allocator, "Tool replace_text success.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Tool replace_text success.", out);
}
test "zigdown parst eine Antwort, die nur aus einem Codeblock besteht (früher Panic)" {
    const zigdown = @import("zigdown");
    const a = testing.allocator;
    const display = try toDisplayMarkdown(a, "```zig\nconst std = @import(\"std\");\n```");
    defer a.free(display);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try zigdown.parser.timedParse(arena.allocator(), display, false);
    // Streaming-Stand mitten im Codeblock
    const partial = try toDisplayMarkdown(a, "Hier:\n\n```zig\nconst x");
    defer a.free(partial);
    _ = try zigdown.parser.timedParse(arena.allocator(), partial, false);
}
