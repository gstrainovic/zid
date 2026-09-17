//! Führt Werkzeugaufrufe des Agenten auf dem Main-Thread aus. Alles, was der
//! Editor kann, geht über `UI.executeCommand` (Kürzel-Tabelle); Dateizugriffe
//! bleiben per ai_tools.resolveInProject im Projektordner. Ergebnisse sind
//! JSON-Strings, die als `tool`-Nachricht ans Modell zurückgehen.

const std = @import("std");
const ai_tools = @import("ai_tools");
const shortcuts = @import("shortcuts");
const ui_mod = @import("mod.zig");
const pane_mod = @import("pane.zig");
const env = @import("env");
const UI = ui_mod.UI;

const log = std.log.scoped(.agent_actions);

const max_read_bytes: usize = 200 * 1024;
const max_list_entries: usize = 200;

pub const Outcome = union(enum) {
    /// Ergebnis-JSON (owned)
    done: []u8,
    /// Frage an den Benutzer (owned); bei Ja erneut mit confirmed=true aufrufen
    needs_confirm: []u8,
};

pub fn execute(ui: *UI, alloc: std.mem.Allocator, call: *const ai_tools.ToolCall, confirmed: bool) Outcome {
    return executeInner(ui, alloc, call, confirmed) catch |err| {
        return .{ .done = errorJson(alloc, "{s}", .{@errorName(err)}) };
    };
}

fn executeInner(ui: *UI, alloc: std.mem.Allocator, call: *const ai_tools.ToolCall, confirmed: bool) !Outcome {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments, .{}) catch {
        return .{ .done = errorJson(alloc, "arguments are not valid JSON: {s}", .{call.arguments}) };
    };
    defer parsed.deinit();
    const args: std.json.ObjectMap = if (parsed.value == .object) parsed.value.object else std.json.ObjectMap.init(alloc);

    const root = ui.current_directory orelse ".";

    if (std.mem.eql(u8, call.name, "command")) {
        const name = strArg(args, "name") orelse return .{ .done = errorJson(alloc, "missing 'name'", .{}) };
        const cmd = std.meta.stringToEnum(shortcuts.Command, name) orelse {
            return .{ .done = errorJson(alloc, "unknown command '{s}'; use one of the enum values", .{name}) };
        };
        ui.executeCommand(cmd);
        log.info("agent: command {s}", .{name});
        return .{ .done = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"command\":\"{s}\",\"label\":\"{s}\"}}", .{ name, shortcuts.label(cmd) }) };
    }

    if (std.mem.eql(u8, call.name, "open_file")) {
        const rel = strArg(args, "path") orelse return .{ .done = errorJson(alloc, "missing 'path'", .{}) };
        const path = (try ai_tools.resolveInProject(alloc, root, rel)) orelse return .{ .done = outsideJson(alloc, rel) };
        defer alloc.free(path);
        std.fs.cwd().access(path, .{}) catch return .{ .done = errorJson(alloc, "file not found: {s}", .{rel}) };
        // Regel aus ai_tools.choosePaneForFile: Chat bleibt sichtbar, notfalls wird
        // gesplittet. Der Buffer lädt für jedes Pane (main.zig, leavesWithPendingSwitch),
        // darum kann der Fokus danach zurück zum Chat.
        const chat_pane = ui.active_pane;
        const chat_active = isChatActive(ui);
        const other = firstOtherLeaf(ui.root_pane, chat_pane);
        var target: *pane_mod.Pane = chat_pane;
        var focus_after: *pane_mod.Pane = chat_pane;
        switch (ai_tools.choosePaneForFile(chat_active, other != null)) {
            .active => {},
            .other => target = other.?,
            .split_new => {
                try ui.splitActivePane(.vertical);
                // chat_pane ist jetzt der Split-Knoten: Chat oben, Datei unten
                target = chat_pane.data.split.children[1];
                focus_after = chat_pane.data.split.children[0];
            },
        }
        const tb = &target.data.leaf.tab_bar;
        try tb.openFile(path);
        if (tb.active_index) |idx| tb.setActive(idx);
        ui.active_pane = focus_after;
        log.info("agent: open_file {s}", .{path});
        return .{ .done = try okPath(alloc, path) };
    }

    if (std.mem.eql(u8, call.name, "read_file")) {
        const rel = strArg(args, "path") orelse return .{ .done = errorJson(alloc, "missing 'path'", .{}) };
        const path = (try ai_tools.resolveInProject(alloc, root, rel)) orelse return .{ .done = outsideJson(alloc, rel) };
        defer alloc.free(path);
        const content = std.fs.cwd().readFileAlloc(alloc, path, max_read_bytes) catch |err| switch (err) {
            error.FileTooBig => return .{ .done = errorJson(alloc, "file larger than 200 KB: {s}", .{rel}) },
            error.FileNotFound => return .{ .done = errorJson(alloc, "file not found: {s}", .{rel}) },
            else => return err,
        };
        defer alloc.free(content);
        return .{ .done = try jsonObject(alloc, &.{ .{ "path", path }, .{ "content", content } }) };
    }

    if (std.mem.eql(u8, call.name, "write_file")) {
        const rel = strArg(args, "path") orelse return .{ .done = errorJson(alloc, "missing 'path'", .{}) };
        const content = strArg(args, "content") orelse return .{ .done = errorJson(alloc, "missing 'content'", .{}) };
        const path = (try ai_tools.resolveInProject(alloc, root, rel)) orelse return .{ .done = outsideJson(alloc, rel) };
        defer alloc.free(path);
        const exists = if (std.fs.cwd().statFile(path)) |_| true else |_| false;
        if (exists and !confirmed) {
            return .{ .needs_confirm = try std.fmt.allocPrint(alloc, "The AI agent wants to overwrite '{s}' ({d} bytes). Allow?", .{ rel, content.len }) };
        }
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
        ui.file_explorer.refresh(path);
        const reloaded = ui.reloadFileFromDisk(path, content);
        log.info("agent: write_file {s} ({d} bytes, reloaded={})", .{ path, content.len, reloaded });
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wrote {d} bytes{s}", .{ content.len, if (reloaded) "; open tab reloaded" else "" }) catch "written";
        return .{ .done = try jsonObject(alloc, &.{ .{ "path", path }, .{ "result", msg } }) };
    }

    if (std.mem.eql(u8, call.name, "replace_text")) {
        const rel = strArg(args, "path") orelse return .{ .done = errorJson(alloc, "missing 'path'", .{}) };
        const old = strArg(args, "old") orelse return .{ .done = errorJson(alloc, "missing 'old'", .{}) };
        const new = strArg(args, "new") orelse return .{ .done = errorJson(alloc, "missing 'new'", .{}) };
        const path = (try ai_tools.resolveInProject(alloc, root, rel)) orelse return .{ .done = outsideJson(alloc, rel) };
        defer alloc.free(path);
        const content = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch return .{ .done = errorJson(alloc, "file not found: {s}", .{rel}) };
        defer alloc.free(content);
        const idx = std.mem.indexOf(u8, content, old) orelse return .{ .done = errorJson(alloc, "old text not found in {s}", .{rel}) };
        if (ai_tools.replaceCountsAsRewrite(content.len, old.len) and !confirmed) {
            return .{ .needs_confirm = try std.fmt.allocPrint(alloc, "The AI agent wants to replace {d} of {d} bytes in '{s}' (most of the file). Allow?", .{ old.len, content.len, rel }) };
        }
        const updated = try std.mem.concat(alloc, u8, &.{ content[0..idx], new, content[idx + old.len ..] });
        defer alloc.free(updated);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = updated });
        ui.file_explorer.refresh(path);
        const reloaded = ui.reloadFileFromDisk(path, updated);
        log.info("agent: replace_text {s} (reloaded={})", .{ path, reloaded });
        const note = if (reloaded) "replaced; open tab reloaded" else "replaced";
        return .{ .done = try jsonObject(alloc, &.{ .{ "path", path }, .{ "result", note } }) };
    }

    if (std.mem.eql(u8, call.name, "list_files")) {
        const rel = strArg(args, "path") orelse ".";
        const path = (try ai_tools.resolveInProject(alloc, root, rel)) orelse return .{ .done = outsideJson(alloc, rel) };
        defer alloc.free(path);
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return .{ .done = errorJson(alloc, "folder not found: {s}", .{rel}) };
        defer dir.close();
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("path");
        try jw.write(path);
        try jw.objectField("entries");
        try jw.beginArray();
        var it = dir.iterate();
        var n: usize = 0;
        var name_buf: [std.fs.max_name_bytes + 1]u8 = undefined;
        while (try it.next()) |entry| {
            if (n >= max_list_entries) break;
            if (entry.kind == .directory) {
                const shown = try std.fmt.bufPrint(&name_buf, "{s}/", .{entry.name});
                try jw.write(shown);
            } else {
                try jw.write(entry.name);
            }
            n += 1;
        }
        try jw.endArray();
        if (n >= max_list_entries) {
            try jw.objectField("truncated");
            try jw.write(true);
        }
        try jw.endObject();
        return .{ .done = try out.toOwnedSlice() };
    }

    if (std.mem.eql(u8, call.name, "open_folder")) {
        const raw = strArg(args, "path") orelse return .{ .done = errorJson(alloc, "missing 'path'", .{}) };
        const expanded = try expandHome(alloc, raw);
        defer alloc.free(expanded);
        const real = std.fs.cwd().realpathAlloc(alloc, expanded) catch return .{ .done = errorJson(alloc, "folder not found: {s}", .{raw}) };
        errdefer alloc.free(real);
        const st = try std.fs.cwd().statFile(real);
        if (st.kind != .directory) {
            alloc.free(real);
            return .{ .done = errorJson(alloc, "not a folder: {s}", .{raw}) };
        }
        // main.zig holt pending_open_folder ab und stellt Explorer, Git und Watcher um
        if (ui.pending_open_folder) |old| ui.allocator.free(old);
        ui.pending_open_folder = try ui.allocator.dupe(u8, real);
        log.info("agent: open_folder {s}", .{real});
        const res = try okPath(alloc, real);
        alloc.free(real);
        return .{ .done = res };
    }

    if (std.mem.eql(u8, call.name, "find_in_editor")) {
        const query = strArg(args, "query") orelse return .{ .done = errorJson(alloc, "missing 'query'", .{}) };
        const ed = ui.getActiveEditor();
        ed.findText(query);
        if (ed.find.last_match) |m| {
            return .{ .done = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"line\":{d}}}", .{m.begin.row + 1}) };
        }
        return .{ .done = try alloc.dupe(u8, "{\"ok\":true,\"matches\":0}") };
    }

    // Enum-Wert direkt als Werkzeugname aufgerufen (siehe ai_tools.commandFromToolName)
    if (ai_tools.commandFromToolName(call.name)) |cmd| {
        ui.executeCommand(cmd);
        log.info("agent: command {s} (als Werkzeugname aufgerufen)", .{call.name});
        return .{ .done = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"command\":\"{s}\",\"label\":\"{s}\"}}", .{ call.name, shortcuts.label(cmd) }) };
    }

    const names = try ai_tools.toolNames(alloc);
    defer alloc.free(names);
    return .{ .done = errorJson(alloc, "unknown tool '{s}'. Available tools: {s}", .{ call.name, names }) };
}

fn isChatActive(ui: *UI) bool {
    if (ui.active_pane.data != .leaf) return false;
    const tab = ui.active_pane.data.leaf.tab_bar.getActiveTab() orelse return false;
    return tab.kind == .chat;
}

fn firstOtherLeaf(pane: *pane_mod.Pane, exclude: *pane_mod.Pane) ?*pane_mod.Pane {
    switch (pane.data) {
        .leaf => return if (pane != exclude) pane else null,
        .split => |s| {
            if (firstOtherLeaf(s.children[0], exclude)) |p| return p;
            return firstOtherLeaf(s.children[1], exclude);
        },
    }
}

fn strArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = args.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn expandHome(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/") or std.mem.eql(u8, path, "~")) {
        if (env.home()) |home| {
            return std.fs.path.join(alloc, &.{ home, if (path.len > 1) path[2..] else "" });
        }
    }
    return alloc.dupe(u8, path);
}

fn errorJson(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []u8 {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch return @constCast("{\"error\":\"out of memory\"}");
    defer alloc.free(msg);
    return jsonObject(alloc, &.{.{ "error", msg }}) catch @constCast("{\"error\":\"out of memory\"}");
}

fn outsideJson(alloc: std.mem.Allocator, rel: []const u8) []u8 {
    return errorJson(alloc, "path is outside the project folder: {s}", .{rel});
}

fn okPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return jsonObject(alloc, &.{ .{ "ok", "true" }, .{ "path", path } });
}

/// Kleines JSON-Objekt aus Schlüssel/Wert-Paaren; "true"/"false" werden als bool geschrieben.
fn jsonObject(alloc: std.mem.Allocator, pairs: []const struct { []const u8, []const u8 }) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    for (pairs) |p| {
        try jw.objectField(p[0]);
        if (std.mem.eql(u8, p[1], "true")) try jw.write(true) else if (std.mem.eql(u8, p[1], "false")) try jw.write(false) else try jw.write(p[1]);
    }
    try jw.endObject();
    return out.toOwnedSlice();
}
