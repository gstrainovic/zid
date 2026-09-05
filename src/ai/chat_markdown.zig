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
pub fn toDisplayMarkdown(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
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
pub fn wrapToolResult(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
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

const testing = std.testing;

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
    const out = try toDisplayMarkdown(testing.allocator, "# Titel\n\nText mit **fett**.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# Titel\n\nText mit **fett**.", out);
}

test "toDisplayMarkdown: Tool-Call wird als json-Codeblock eingebettet" {
    const out = try toDisplayMarkdown(testing.allocator, "Ich lese die Datei.\n{\"tool\": \"read_file\", \"path\": \"a.zig\"}\nFertig.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "Ich lese die Datei.\n\n```json\n{\"tool\": \"read_file\", \"path\": \"a.zig\"}\n```\n\nFertig.",
        out,
    );
}

test "toDisplayMarkdown: bereits eingezäunter Tool-Call bleibt unverändert" {
    const src = "```json\n{\"tool\": \"read_file\", \"path\": \"a.zig\"}\n```";
    const out = try toDisplayMarkdown(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "wrapToolResult: Kopfzeile bleibt Text, Rest wird Codeblock" {
    const out = try wrapToolResult(testing.allocator, "Tool read_file result for 'a.zig':\nconst x = 1;\n# kein Heading");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "Tool read_file result for 'a.zig':\n\n```\nconst x = 1;\n# kein Heading\n```",
        out,
    );
}

test "wrapToolResult: einzeilige Meldung bleibt unverändert" {
    const out = try wrapToolResult(testing.allocator, "Tool replace_text success.");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Tool replace_text success.", out);
}
