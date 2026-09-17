//! Werkzeuge des eingebauten Agenten: Definitionen als Daten, OpenAI-`tools`-Schema,
//! Parsen der Aufrufe und die Pfadgrenze auf den Projektordner. Kein UI, kein
//! Netz, damit alles unit-testbar bleibt. Ausgeführt wird in ui/agent_actions.zig.
//!
//! Das `command`-Werkzeug entsteht aus der Kürzel-Tabelle (shortcuts.zig): jedes
//! Menü-/Tastenkommando des Editors ist damit automatisch auch für den Agenten da.

const std = @import("std");
const shortcuts = @import("shortcuts");

/// Ein vom Modell angeforderter Aufruf (aus dem OpenAI-`tool_calls`-Array).
pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    /// JSON-Objekt als Text, z.B. {"path": "README.md"}
    arguments: []u8,

    pub fn deinit(self: ToolCall, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.arguments);
    }
};

pub const Confirm = enum {
    never,
    /// Nachfragen, wenn das Ziel schon existiert (Überschreiben)
    if_target_exists,
    /// Nachfragen, wenn der ersetzte Teil die halbe Datei oder mehr ist
    if_rewrite,
};

/// replace_text mit `old` = (fast) ganzer Datei ist ein verkapptes Überschreiben und
/// braucht dieselbe Bestätigung wie write_file auf eine bestehende Datei.
pub fn replaceCountsAsRewrite(file_len: usize, old_len: usize) bool {
    if (file_len == 0) return false;
    return old_len * 2 >= file_len;
}

pub const PaneChoice = enum { active, other, split_new };

/// Wo eine vom Agenten geöffnete Datei erscheint. Regel in Code statt im Prompt:
/// Läuft der Chat nicht im aktiven Pane, kommt die Datei dorthin (der Benutzer
/// arbeitet im Editor). Läuft der Chat im aktiven Pane, muss er sichtbar bleiben:
/// anderes Pane nutzen oder eines abspalten.
pub fn choosePaneForFile(chat_in_active_pane: bool, has_other_leaf: bool) PaneChoice {
    if (!chat_in_active_pane) return .active;
    return if (has_other_leaf) .other else .split_new;
}

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON-Schema der Parameter (Objekt), ohne das `command`-Enum (wird generiert)
    parameters: []const u8,
    confirm: Confirm = .never,
};

pub const tools = [_]Tool{
    .{
        .name = "command",
        .description = "Run an editor command exactly as the user could via menu or shortcut.",
        .parameters = "", // generiert: enum aus shortcuts.Command
    },
    .{
        .name = "open_file",
        .description = "Open a file from the project in a new editor tab and make it active.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the project root"}},"required":["path"]}
        ,
    },
    .{
        .name = "read_file",
        .description = "Read a text file from the project. Returns its content (truncated after 200 KB).",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the project root"}},"required":["path"]}
        ,
    },
    .{
        .name = "write_file",
        .description = "Create a file with the given content (parent folders are created). Overwriting an existing file asks the user for permission.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
        .confirm = .if_target_exists,
    },
    .{
        .name = "replace_text",
        .description = "Replace the first occurrence of an exact text in a project file. Replacing most of the file asks the user for permission.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string","description":"exact existing text"},"new":{"type":"string"}},"required":["path","old","new"]}
        ,
        .confirm = .if_rewrite,
    },
    .{
        .name = "list_files",
        .description = "List entries of a project folder (non-recursive). Folders end with '/'.",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Folder relative to the project root, default '.'"}}}
        ,
    },
    .{
        .name = "open_folder",
        .description = "Switch the project root to another folder (like File > Open Folder). Absolute path or ~/…",
        .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
    },
    .{
        .name = "find_in_editor",
        .description = "Open the find bar in the active editor and jump to the first match.",
        .parameters =
        \\{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}
        ,
    },
};

pub fn findTool(name: []const u8) ?*const Tool {
    for (&tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Kleine Modelle (gemma4:e2b über Ollama) rufen den Enum-Wert direkt als Werkzeug auf:
/// `toggle_explorer` statt `command` mit `name: toggle_explorer`. Gemeint ist dasselbe;
/// statt „unknown tool" wird das Kommando ausgeführt. Echte Werkzeugnamen haben Vorrang.
pub fn commandFromToolName(name: []const u8) ?shortcuts.Command {
    if (findTool(name) != null) return null;
    return std.meta.stringToEnum(shortcuts.Command, name);
}

test "commandFromToolName: Enum-Wert als Werkzeugname, echte Werkzeuge und Fremdes nicht" {
    try testing.expectEqual(shortcuts.Command.toggle_explorer, commandFromToolName("toggle_explorer").?);
    try testing.expectEqual(@as(?shortcuts.Command, null), commandFromToolName("open_file"));
    try testing.expectEqual(@as(?shortcuts.Command, null), commandFromToolName("hide_explorer"));
}

/// Komma-getrennte Liste aller Werkzeugnamen (für Fehlermeldungen ans Modell).
pub fn toolNames(alloc: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (tools, 0..) |t, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(t.name);
    }
    return out.toOwnedSlice();
}

/// OpenAI-`tools`-Array als JSON. Das `command`-Werkzeug bekommt ein Enum aller
/// shortcuts.Command-Namen und in der Beschreibung Label + Kürzel jedes Kommandos.
pub fn toolsJson(alloc: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try jw.beginArray();
    for (tools) |t| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("function");
        try jw.objectField("function");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(t.name);
        try jw.objectField("description");
        if (std.mem.eql(u8, t.name, "command")) {
            const desc = try commandDescription(alloc);
            defer alloc.free(desc);
            try jw.write(desc);
            try jw.objectField("parameters");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("object");
            try jw.objectField("properties");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("string");
            try jw.objectField("enum");
            try jw.beginArray();
            inline for (@typeInfo(shortcuts.Command).@"enum".fields) |f| try jw.write(f.name);
            try jw.endArray();
            try jw.endObject();
            try jw.endObject();
            try jw.objectField("required");
            try jw.beginArray();
            try jw.write("name");
            try jw.endArray();
            try jw.endObject();
        } else {
            try jw.write(t.description);
            try jw.objectField("parameters");
            try jw.beginWriteRaw();
            try jw.writer.writeAll(t.parameters);
            jw.endWriteRaw();
        }
        try jw.endObject();
        try jw.endObject();
    }
    try jw.endArray();
    return out.toOwnedSlice();
}

fn commandDescription(alloc: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(tools[0].description);
    try out.writer.writeAll(" Commands: ");
    inline for (@typeInfo(shortcuts.Command).@"enum".fields, 0..) |f, i| {
        const cmd = @field(shortcuts.Command, f.name);
        if (i > 0) try out.writer.writeAll("; ");
        try out.writer.print("{s} = {s}", .{ f.name, shortcuts.label(cmd) });
        const sc = shortcuts.shortcutText(cmd);
        if (sc.len > 0) try out.writer.print(" ({s})", .{sc});
    }
    return out.toOwnedSlice();
}

/// Ergebnis des Workers: {"content": "...", "tool_calls": [OpenAI-Array]}
pub const Envelope = struct {
    content: []u8,
    /// Rohes tool_calls-Array (JSON), unverändert in die Assistant-Nachricht zurück
    tool_calls_json: []u8,
    calls: []ToolCall,

    pub fn deinit(self: Envelope, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        alloc.free(self.tool_calls_json);
        for (self.calls) |c| c.deinit(alloc);
        alloc.free(self.calls);
    }
};

pub fn parseEnvelope(alloc: std.mem.Allocator, json_text: []const u8) !Envelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEnvelope;
    const content_v = parsed.value.object.get("content") orelse return error.InvalidEnvelope;
    const calls_v = parsed.value.object.get("tool_calls") orelse return error.InvalidEnvelope;
    if (content_v != .string or calls_v != .array) return error.InvalidEnvelope;

    const content = try alloc.dupe(u8, content_v.string);
    errdefer alloc.free(content);
    const raw = try std.json.Stringify.valueAlloc(alloc, calls_v, .{});
    errdefer alloc.free(raw);

    var calls: std.ArrayListUnmanaged(ToolCall) = .empty;
    errdefer {
        for (calls.items) |c| c.deinit(alloc);
        calls.deinit(alloc);
    }
    for (calls_v.array.items) |item| {
        if (item != .object) continue;
        const func = item.object.get("function") orelse continue;
        if (func != .object) continue;
        const name = func.object.get("name") orelse continue;
        if (name != .string) continue;
        const args_v = func.object.get("arguments");
        const id_v = item.object.get("id");
        const id = try alloc.dupe(u8, if (id_v != null and id_v.? == .string) id_v.?.string else "call");
        errdefer alloc.free(id);
        const name_dup = try alloc.dupe(u8, name.string);
        errdefer alloc.free(name_dup);
        const args = try alloc.dupe(u8, if (args_v != null and args_v.? == .string) args_v.?.string else "{}");
        errdefer alloc.free(args);
        try calls.append(alloc, .{ .id = id, .name = name_dup, .arguments = args });
    }
    return .{ .content = content, .tool_calls_json = raw, .calls = try calls.toOwnedSlice(alloc) };
}

/// Kurzform eines Aufrufs für die Anzeige: `open_file(README.md)`; Argumente
/// werden auf ihre Werte reduziert und gekürzt.
pub fn summarizeCall(alloc: std.mem.Allocator, call: ToolCall) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(call.name);
    try out.writer.writeAll("(");
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    if (parsed != null and parsed.?.value == .object) {
        var it = parsed.?.value.object.iterator();
        var first = true;
        while (it.next()) |kv| {
            if (!first) try out.writer.writeAll(", ");
            first = false;
            switch (kv.value_ptr.*) {
                .string => |s| {
                    const shown = s[0..@min(s.len, 40)];
                    try out.writer.print("{s}{s}", .{ shown, if (s.len > 40) "…" else "" });
                },
                else => try out.writer.print("{s}=…", .{kv.key_ptr.*}),
            }
        }
    }
    try out.writer.writeAll(")");
    return out.toOwnedSlice();
}

/// Löst `path` relativ zu `root` auf und prüft, dass das Ergebnis innerhalb von
/// `root` liegt. null = außerhalb (auch über `..` oder absoluten Pfad).
pub fn resolveInProject(alloc: std.mem.Allocator, root: []const u8, path: []const u8) !?[]u8 {
    const resolved = if (std.fs.path.isAbsolute(path))
        try std.fs.path.resolve(alloc, &.{path})
    else
        try std.fs.path.resolve(alloc, &.{ root, path });
    errdefer alloc.free(resolved);
    const root_norm = try std.fs.path.resolve(alloc, &.{root});
    defer alloc.free(root_norm);
    if (std.mem.eql(u8, resolved, root_norm)) return resolved;
    if (resolved.len > root_norm.len and std.mem.startsWith(u8, resolved, root_norm) and std.fs.path.isSep(resolved[root_norm.len])) return resolved;
    alloc.free(resolved);
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "toolsJson: gültiges JSON mit allen Werkzeugen und allen Commands als Enum" {
    const a = testing.allocator;
    const json = try toolsJson(a);
    defer a.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(tools.len, parsed.value.array.items.len);
    const cmd_tool = parsed.value.array.items[0].object.get("function").?.object;
    try testing.expectEqualStrings("command", cmd_tool.get("name").?.string);
    const enum_arr = cmd_tool.get("parameters").?.object.get("properties").?.object.get("name").?.object.get("enum").?.array;
    try testing.expectEqual(@typeInfo(shortcuts.Command).@"enum".fields.len, enum_arr.items.len);
    try testing.expect(std.mem.indexOf(u8, cmd_tool.get("description").?.string, "split_vertical = Split Vertically") != null);
    try testing.expect(std.mem.indexOf(u8, cmd_tool.get("description").?.string, "open_folder = Open Folder… (Ctrl+O)") != null);
}

test "parseEnvelope: Aufrufe mit id/name/arguments, Rohdaten bleiben erhalten" {
    const a = testing.allocator;
    const env = try parseEnvelope(a,
        \\{"content":"","tool_calls":[{"id":"abc","type":"function","function":{"name":"command","arguments":"{\"name\": \"split_vertical\"}"}},{"id":"def","type":"function","function":{"name":"open_file","arguments":"{\"path\": \"README.md\"}"}}]}
    );
    defer env.deinit(a);
    try testing.expectEqual(@as(usize, 2), env.calls.len);
    try testing.expectEqualStrings("abc", env.calls[0].id);
    try testing.expectEqualStrings("command", env.calls[0].name);
    try testing.expectEqualStrings("{\"name\": \"split_vertical\"}", env.calls[0].arguments);
    try testing.expectEqualStrings("open_file", env.calls[1].name);
    try testing.expect(std.mem.indexOf(u8, env.tool_calls_json, "\"id\":\"def\"") != null);
    const summary = try summarizeCall(a, env.calls[1]);
    defer a.free(summary);
    try testing.expectEqualStrings("open_file(README.md)", summary);
}

test "parseEnvelope: kaputte Hülle ist ein Fehler" {
    try testing.expectError(error.InvalidEnvelope, parseEnvelope(testing.allocator, "{\"content\":\"x\"}"));
}

test "resolveInProject: relativ ok, .. und absolute Pfade außerhalb werden abgelehnt" {
    const a = testing.allocator;
    // Absolute Wurzel je Plattform; Erwartungen über join, weil resolve unter
    // Windows '\' setzt und Pfade ohne Laufwerk aufs aktuelle Laufwerk legt.
    const win = @import("builtin").os.tag == .windows;
    const R = if (win) "C:\\home\\u\\proj" else "/home/u/proj";
    const sep = std.fs.path.sep_str;

    const ok = (try resolveInProject(a, R, "src/main.zig")).?;
    defer a.free(ok);
    try testing.expectEqualStrings(R ++ sep ++ "src" ++ sep ++ "main.zig", ok);

    const dot = (try resolveInProject(a, R, "./src/../README.md")).?;
    defer a.free(dot);
    try testing.expectEqualStrings(R ++ sep ++ "README.md", dot);

    const root = (try resolveInProject(a, R ++ sep, ".")).?;
    defer a.free(root);
    try testing.expectEqualStrings(R, root);

    try testing.expect((try resolveInProject(a, R, "../secret")) == null);
    const outside = if (win) "C:\\Windows\\win.ini" else "/etc/passwd";
    try testing.expect((try resolveInProject(a, R, outside)) == null);
    // Gleicher Präfix, anderer Ordner
    try testing.expect((try resolveInProject(a, R, R ++ "2" ++ sep ++ "x")) == null);
    const abs_in = (try resolveInProject(a, R, R ++ sep ++ "a.txt")).?;
    defer a.free(abs_in);
    try testing.expectEqualStrings(R ++ sep ++ "a.txt", abs_in);
}

test "replaceCountsAsRewrite: kleine Edits frei, halbe Datei oder mehr fragt nach" {
    try testing.expect(!replaceCountsAsRewrite(1000, 10));
    try testing.expect(!replaceCountsAsRewrite(1000, 499));
    try testing.expect(replaceCountsAsRewrite(1000, 500));
    try testing.expect(replaceCountsAsRewrite(47, 47));
    try testing.expect(!replaceCountsAsRewrite(0, 0));
    try testing.expect(findTool("replace_text").?.confirm == .if_rewrite);
}

test "choosePaneForFile: Chat bleibt sichtbar, Editor-Fokus bleibt Editor" {
    try testing.expectEqual(PaneChoice.active, choosePaneForFile(false, false));
    try testing.expectEqual(PaneChoice.active, choosePaneForFile(false, true));
    try testing.expectEqual(PaneChoice.other, choosePaneForFile(true, true));
    try testing.expectEqual(PaneChoice.split_new, choosePaneForFile(true, false));
}

test "findTool/toolNames" {
    try testing.expect(findTool("write_file").?.confirm == .if_target_exists);
    try testing.expect(findTool("nope") == null);
    const names = try toolNames(testing.allocator);
    defer testing.allocator.free(names);
    try testing.expect(std.mem.startsWith(u8, names, "command, open_file"));
}
