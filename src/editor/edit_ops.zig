//! Reine Text-Operationen des Editors (ohne Buffer/Clay, unit-getestet):
//! Auto-Indent bei Enter, Autoclose von Klammern, Ein-/Ausrücken, Kommentar umschalten,
//! Kommentar-Präfix und Sprachname je Endung, Definitionssuche im Text.

const std = @import("std");

pub const indent_unit = "    ";

/// Führende Leerzeichen/Tabs einer Zeile.
pub fn leadingWhitespace(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[0..i];
}

pub const NewlineInsertion = struct {
    /// Text, der am Cursor eingefügt wird
    text: []u8,
    /// Zeilen, um die der Cursor nach dem Einfügen wieder nach oben geht (0 oder 1)
    rows_back: usize,
};

/// Was Enter einfügt: Umbruch + Einrückung der aktuellen Zeile; steht vor dem Cursor eine
/// öffnende Klammer, eine Stufe mehr; folgt direkt die schließende Klammer, kommt sie auf
/// eine eigene Zeile mit der alten Einrückung (Cursor bleibt auf der eingerückten Mitte).
pub fn newlineInsertion(alloc: std.mem.Allocator, line: []const u8, cursor_byte: usize) !NewlineInsertion {
    const at = @min(cursor_byte, line.len);
    const indent = leadingWhitespace(line);
    const before = std.mem.trimRight(u8, line[0..at], " \t");
    const opens = before.len > 0 and (before[before.len - 1] == '{' or before[before.len - 1] == '(' or before[before.len - 1] == '[');
    const after = std.mem.trimLeft(u8, line[at..], " \t");
    const closes = opens and after.len > 0 and (after[0] == '}' or after[0] == ')' or after[0] == ']');

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, indent);
    if (opens) try buf.appendSlice(alloc, indent_unit);
    if (closes) {
        try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, indent);
    }
    return .{ .text = try buf.toOwnedSlice(alloc), .rows_back = if (closes) 1 else 0 };
}

pub const AutoclosePolicy = enum { plain, insert_pair, skip_over };

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn closerFor(c: u21) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        '\'' => '\'',
        '`' => '`',
        else => null,
    };
}

/// Entscheidung beim Tippen von `c` mit dem Byte davor (`prev`) und danach (`next`):
/// öffnende Klammer → Paar; schließende Klammer oder Anführungszeichen, das schon folgt → drüberspringen;
/// Anführungszeichen neben Wortzeichen (it's, "abc) → normal einfügen.
pub fn autoclosePolicy(c: u21, prev: ?u8, next: ?u8) AutoclosePolicy {
    const next_is_word = if (next) |n| isWordByte(n) else false;
    switch (c) {
        ')', ']', '}' => return if (next != null and next.? == c) .skip_over else .plain,
        '(', '[', '{' => return if (next_is_word) .plain else .insert_pair,
        '"', '\'', '`' => {
            if (next != null and next.? == c) return .skip_over;
            const prev_is_word = if (prev) |p| isWordByte(p) else false;
            if (prev_is_word or next_is_word) return .plain;
            return .insert_pair;
        },
        else => return .plain,
    }
}

/// Backspace zwischen einem leeren Paar löscht beide Zeichen.
pub fn deletesPair(prev: ?u8, next: ?u8) bool {
    const p = prev orelse return false;
    const n = next orelse return false;
    return (closerFor(p) orelse return false) == n;
}

/// Zeilen ein- oder ausrücken; `lines` sind die Zeilen ohne Umbruch, Ergebnis ist mit
/// "\n" verbunden (ohne Umbruch am Ende). Ausrücken nimmt bis zu 4 Leerzeichen oder einen Tab.
pub fn indentLines(alloc: std.mem.Allocator, lines: []const []const u8, outdent: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (lines, 0..) |line, i| {
        if (i > 0) try buf.append(alloc, '\n');
        if (outdent) {
            var strip: usize = 0;
            if (line.len > 0 and line[0] == '\t') {
                strip = 1;
            } else {
                while (strip < indent_unit.len and strip < line.len and line[strip] == ' ') : (strip += 1) {}
            }
            try buf.appendSlice(alloc, line[strip..]);
        } else {
            if (line.len > 0) try buf.appendSlice(alloc, indent_unit);
            try buf.appendSlice(alloc, line);
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Zeilenkommentar-Präfix je Dateiendung; null = keine Zeilenkommentare (Markdown, HTML).
pub fn commentPrefixForPath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const base = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(base, "Makefile") or std.ascii.eqlIgnoreCase(base, "Dockerfile")) return "#";
    const slashes = [_][]const u8{ ".zig", ".c", ".h", ".cpp", ".hpp", ".cc", ".js", ".ts", ".jsx", ".tsx", ".mjs", ".rs", ".go", ".java", ".kt", ".swift", ".cs", ".scala", ".dart", ".glsl", ".wgsl", ".json5", ".proto" };
    const hashes = [_][]const u8{ ".py", ".sh", ".bash", ".zsh", ".fish", ".rb", ".toml", ".yaml", ".yml", ".pl", ".r", ".conf", ".ini", ".cmake", ".nix", ".txt", ".gitignore", ".env", ".ps1" };
    const dashes = [_][]const u8{ ".lua", ".sql", ".hs", ".elm" };
    for (slashes) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return "//";
    for (hashes) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return "#";
    for (dashes) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return "--";
    if (std.ascii.eqlIgnoreCase(ext, ".lisp") or std.ascii.eqlIgnoreCase(ext, ".el") or std.ascii.eqlIgnoreCase(ext, ".clj")) return ";;";
    if (std.ascii.eqlIgnoreCase(ext, ".tex")) return "%";
    if (std.ascii.eqlIgnoreCase(ext, ".vim")) return "\"";
    return null;
}

/// Sprachname für die Statusleiste je Endung.
pub fn languageNameForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".zig", "Zig" },        .{ ".c", "C" },           .{ ".h", "C" },          .{ ".cpp", "C++" },
        .{ ".hpp", "C++" },        .{ ".js", "JavaScript" }, .{ ".ts", "TypeScript" }, .{ ".tsx", "TypeScript" },
        .{ ".jsx", "JavaScript" }, .{ ".rs", "Rust" },       .{ ".go", "Go" },        .{ ".py", "Python" },
        .{ ".rb", "Ruby" },        .{ ".java", "Java" },     .{ ".kt", "Kotlin" },    .{ ".swift", "Swift" },
        .{ ".cs", "C#" },          .{ ".sh", "Shell" },      .{ ".bash", "Shell" },   .{ ".zsh", "Shell" },
        .{ ".md", "Markdown" },    .{ ".json", "JSON" },     .{ ".toml", "TOML" },    .{ ".yaml", "YAML" },
        .{ ".yml", "YAML" },       .{ ".html", "HTML" },     .{ ".css", "CSS" },      .{ ".xml", "XML" },
        .{ ".sql", "SQL" },        .{ ".lua", "Lua" },       .{ ".txt", "Plain Text" }, .{ ".svg", "SVG" },
        .{ ".glsl", "GLSL" },      .{ ".wgsl", "WGSL" },     .{ ".nix", "Nix" },      .{ ".tex", "LaTeX" },
    };
    for (table) |row| if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    return if (ext.len > 1) ext[1..] else "Plain Text";
}

/// Kommentar umschalten: sind alle nicht-leeren Zeilen kommentiert, wird das Präfix entfernt,
/// sonst vor die kleinste Einrückung gesetzt. Leere Zeilen bleiben leer.
pub fn toggleCommentLines(alloc: std.mem.Allocator, lines: []const []const u8, prefix: []const u8) ![]u8 {
    var all_commented = true;
    var any = false;
    var min_indent: usize = std.math.maxInt(usize);
    for (lines) |line| {
        const ws = leadingWhitespace(line);
        if (ws.len == line.len) continue; // leer
        any = true;
        min_indent = @min(min_indent, ws.len);
        if (!std.mem.startsWith(u8, line[ws.len..], prefix)) all_commented = false;
    }
    if (!any) {
        all_commented = false;
        min_indent = 0;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (lines, 0..) |line, i| {
        if (i > 0) try buf.append(alloc, '\n');
        const ws = leadingWhitespace(line);
        if (ws.len == line.len) {
            try buf.appendSlice(alloc, line);
            continue;
        }
        if (all_commented) {
            var rest = line[ws.len + prefix.len ..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            try buf.appendSlice(alloc, ws);
            try buf.appendSlice(alloc, rest);
        } else {
            try buf.appendSlice(alloc, line[0..min_indent]);
            try buf.appendSlice(alloc, prefix);
            try buf.append(alloc, ' ');
            try buf.appendSlice(alloc, line[min_indent..]);
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Wort (Buchstaben, Ziffern, `_`) um die Byte-Position herum, leer wenn keins.
pub fn wordAt(line: []const u8, byte: usize) []const u8 {
    if (line.len == 0) return line[0..0];
    var s = @min(byte, line.len);
    if (s == line.len or !isWordByte(line[s])) {
        if (s > 0 and isWordByte(line[s - 1])) s -= 1 else return line[0..0];
    }
    var e = s;
    while (s > 0 and isWordByte(line[s - 1])) : (s -= 1) {}
    while (e < line.len and isWordByte(line[e])) : (e += 1) {}
    return line[s..e];
}

/// Sieht die Zeile wie die Definition von `word` aus? (fn/const/var/def/class/struct/function/
/// let/type/enum/impl … gefolgt vom Wort und einem Nicht-Wortzeichen). Ersatz für LSP im Text.
pub fn looksLikeDefinition(line: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    const keywords = [_][]const u8{ "fn ", "const ", "var ", "def ", "class ", "struct ", "function ", "let ", "type ", "enum ", "union ", "interface ", "trait ", "impl ", "module ", "macro ", "func " };
    var rest = std.mem.trimLeft(u8, line, " \t");
    // Modifier überspringen
    const mods = [_][]const u8{ "pub ", "export ", "extern ", "inline ", "static ", "async ", "private ", "public ", "protected ", "default " };
    var stripped = true;
    while (stripped) {
        stripped = false;
        for (mods) |m| {
            if (std.mem.startsWith(u8, rest, m)) {
                rest = rest[m.len..];
                stripped = true;
            }
        }
    }
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) {
            const after = rest[kw.len..];
            if (std.mem.startsWith(u8, after, word)) {
                const tail = after[word.len..];
                return tail.len == 0 or !isWordByte(tail[0]);
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

test "newlineInsertion: Einrückung übernehmen, nach Klammer eine Stufe mehr, Klammerpaar aufspannen" {
    const a = testing.allocator;
    const plain = try newlineInsertion(a, "    foo();", 10);
    defer a.free(plain.text);
    try testing.expectEqualStrings("\n    ", plain.text);
    try testing.expectEqual(@as(usize, 0), plain.rows_back);

    const open = try newlineInsertion(a, "  if (x) {", 10);
    defer a.free(open.text);
    try testing.expectEqualStrings("\n      ", open.text);

    const pair = try newlineInsertion(a, "  fn f() {}", 10);
    defer a.free(pair.text);
    try testing.expectEqualStrings("\n      \n  ", pair.text);
    try testing.expectEqual(@as(usize, 1), pair.rows_back);

    const mid = try newlineInsertion(a, "\tabc def", 4);
    defer a.free(mid.text);
    try testing.expectEqualStrings("\n\t", mid.text);
}

test "autoclosePolicy: Paare, Drüberspringen, Anführungszeichen neben Wörtern" {
    try testing.expectEqual(AutoclosePolicy.insert_pair, autoclosePolicy('(', null, null));
    try testing.expectEqual(AutoclosePolicy.insert_pair, autoclosePolicy('{', 'x', ' '));
    try testing.expectEqual(AutoclosePolicy.plain, autoclosePolicy('(', null, 'a')); // vor Wort: kein Paar
    try testing.expectEqual(AutoclosePolicy.skip_over, autoclosePolicy(')', null, ')'));
    try testing.expectEqual(AutoclosePolicy.plain, autoclosePolicy(')', null, 'x'));
    try testing.expectEqual(AutoclosePolicy.insert_pair, autoclosePolicy('"', ' ', null));
    try testing.expectEqual(AutoclosePolicy.skip_over, autoclosePolicy('"', 'a', '"'));
    try testing.expectEqual(AutoclosePolicy.plain, autoclosePolicy('\'', 't', 's')); // it's
    try testing.expectEqual(AutoclosePolicy.plain, autoclosePolicy('a', null, null));
    try testing.expect(deletesPair('(', ')'));
    try testing.expect(deletesPair('"', '"'));
    try testing.expect(!deletesPair('(', 'x'));
    try testing.expect(!deletesPair(null, ')'));
}

test "indentLines: ein- und ausrücken, leere Zeilen bleiben leer" {
    const a = testing.allocator;
    const lines = [_][]const u8{ "a", "", "  b" };
    const in = try indentLines(a, &lines, false);
    defer a.free(in);
    try testing.expectEqualStrings("    a\n\n      b", in);
    const out_lines = [_][]const u8{ "    a", "  b", "\tc", "d" };
    const out = try indentLines(a, &out_lines, true);
    defer a.free(out);
    try testing.expectEqualStrings("a\nb\nc\nd", out);
}

test "toggleCommentLines: hin und zurück, kleinste Einrückung, leere Zeilen" {
    const a = testing.allocator;
    const lines = [_][]const u8{ "    x = 1", "", "  y = 2" };
    const on = try toggleCommentLines(a, &lines, "//");
    defer a.free(on);
    try testing.expectEqualStrings("  // " ++ "  x = 1\n\n  // y = 2", on);
    const commented = [_][]const u8{ "  //   x = 1", "", "  // y = 2" };
    const off = try toggleCommentLines(a, &commented, "//");
    defer a.free(off);
    try testing.expectEqualStrings("    x = 1\n\n  y = 2", off);
    // Gemischt → alles kommentieren
    const mixed = [_][]const u8{ "# a", "b" };
    const m = try toggleCommentLines(a, &mixed, "#");
    defer a.free(m);
    try testing.expectEqualStrings("# # a\n# b", m);
}

test "commentPrefixForPath und languageNameForPath" {
    try testing.expectEqualStrings("//", commentPrefixForPath("src/main.zig").?);
    try testing.expectEqualStrings("#", commentPrefixForPath("run.py").?);
    try testing.expectEqualStrings("#", commentPrefixForPath("Makefile").?);
    try testing.expectEqualStrings("--", commentPrefixForPath("q.sql").?);
    try testing.expect(commentPrefixForPath("README.md") == null);
    try testing.expectEqualStrings("Zig", languageNameForPath("a/b.zig"));
    try testing.expectEqualStrings("Plain Text", languageNameForPath("notes"));
    try testing.expectEqualStrings("foo", languageNameForPath("x.foo"));
}

test "wordAt und looksLikeDefinition" {
    try testing.expectEqualStrings("hello", wordAt("say hello world", 6));
    try testing.expectEqualStrings("hello", wordAt("say hello world", 9)); // direkt hinter dem Wort
    try testing.expectEqualStrings("", wordAt("a  b", 2));
    try testing.expect(looksLikeDefinition("pub fn hello(x: u8) void {", "hello"));
    try testing.expect(looksLikeDefinition("    const hello = 3;", "hello"));
    try testing.expect(looksLikeDefinition("def hello():", "hello"));
    try testing.expect(!looksLikeDefinition("pub fn helloWorld() void {", "hello"));
    try testing.expect(!looksLikeDefinition("hello();", "hello"));
}
