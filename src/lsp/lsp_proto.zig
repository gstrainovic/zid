//! LSP-Protokoll ohne Prozess und Threads (reine Logik, unit-getestet):
//! JSON-RPC-Rahmen (`Content-Length`), Nachrichten bauen, `file://`-URIs,
//! Definition-Antworten (Location | Location[] | LocationLink[]) auswerten.
const std = @import("std");

pub const Frame = struct { body: []const u8, consumed: usize };

/// Ein vollständiger Rahmen am Anfang von `data`, sonst null (mehr Daten nötig).
pub fn parseFrame(data: []const u8) ?Frame {
    const sep = "\r\n\r\n";
    const headers_end = std.mem.indexOf(u8, data, sep) orelse return null;
    var content_length: ?usize = null;
    var it = std.mem.splitSequence(u8, data[0..headers_end], "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch return null;
        }
    }
    const len = content_length orelse return null;
    const body_start = headers_end + sep.len;
    if (data.len < body_start + len) return null;
    return .{ .body = data[body_start .. body_start + len], .consumed = body_start + len };
}

/// Rahmen um einen JSON-Body legen (owned).
pub fn frame(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// JSON-RPC-Request; `params` ist fertiges JSON und wird roh eingefügt.
pub fn request(alloc: std.mem.Allocator, id: i64, method: []const u8, params: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
}

pub fn notification(alloc: std.mem.Allocator, method: []const u8, params: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params });
}

/// Antwort auf einen Server-Request (Ergebnis null), damit der Server nicht wartet.
pub fn nullResponse(alloc: std.mem.Allocator, id: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
}

fn stringify(alloc: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.write(value);
    return out.toOwnedSlice();
}

pub fn initializeParams(alloc: std.mem.Allocator, root_uri: []const u8) ![]u8 {
    return stringify(alloc, .{
        .processId = @as(?i32, null),
        .rootUri = root_uri,
        .capabilities = .{ .textDocument = .{ .definition = .{ .dynamicRegistration = false } } },
    });
}

pub fn didOpenParams(alloc: std.mem.Allocator, uri: []const u8, language_id: []const u8, text: []const u8) ![]u8 {
    return stringify(alloc, .{ .textDocument = .{ .uri = uri, .languageId = language_id, .version = @as(i64, 1), .text = text } });
}

/// Volle Synchronisation (TextDocumentSyncKind.Full): eine Änderung mit dem ganzen Text.
pub fn didChangeParams(alloc: std.mem.Allocator, uri: []const u8, version: i64, text: []const u8) ![]u8 {
    return stringify(alloc, .{
        .textDocument = .{ .uri = uri, .version = version },
        .contentChanges = [_]struct { text: []const u8 }{.{ .text = text }},
    });
}

pub fn definitionParams(alloc: std.mem.Allocator, uri: []const u8, line: u32, character: u32) ![]u8 {
    return stringify(alloc, .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } });
}

/// `/abs/pfad` → `file:///abs/pfad` (Leerzeichen und `%` prozentkodiert).
pub fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |c| {
        if (c == ' ' or c == '%' or c == '#' or c == '?') {
            try out.writer(alloc).print("%{X:0>2}", .{c});
        } else try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

/// `file:///abs/pfad` → `/abs/pfad`; andere Schemata → null.
pub fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    const rest = uri["file://".len..];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch {
                try out.append(alloc, rest[i]);
                continue;
            };
            try out.append(alloc, v);
            i += 2;
        } else try out.append(alloc, rest[i]);
    }
    return try out.toOwnedSlice(alloc);
}

pub const Location = struct {
    uri: []u8,
    line: u32,
    character: u32,

    pub fn deinit(self: Location, alloc: std.mem.Allocator) void {
        alloc.free(self.uri);
    }
};

/// Erste Fundstelle aus einem `textDocument/definition`-Ergebnis (null, Location,
/// Location[] oder LocationLink[]); null wenn nichts gefunden.
pub fn firstLocation(alloc: std.mem.Allocator, result_json: []const u8) !?Location {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, result_json, .{}) catch return null;
    defer parsed.deinit();
    const v = parsed.value;
    const obj: std.json.Value = switch (v) {
        .object => v,
        .array => |a| if (a.items.len > 0) a.items[0] else return null,
        else => return null,
    };
    if (obj != .object) return null;
    const o = obj.object;
    const uri_v = o.get("uri") orelse o.get("targetUri") orelse return null;
    if (uri_v != .string) return null;
    const range_v = o.get("targetSelectionRange") orelse o.get("range") orelse o.get("targetRange") orelse return null;
    if (range_v != .object) return null;
    const start_v = range_v.object.get("start") orelse return null;
    if (start_v != .object) return null;
    const line_v = start_v.object.get("line") orelse return null;
    const char_v = start_v.object.get("character") orelse return null;
    if (line_v != .integer or char_v != .integer) return null;
    return .{
        .uri = try alloc.dupe(u8, uri_v.string),
        .line = @intCast(@max(line_v.integer, 0)),
        .character = @intCast(@max(char_v.integer, 0)),
    };
}

pub const Message = struct {
    id: ?i64,
    method: ?[]const u8,
    /// Ergebnis (bei Antworten) als JSON-Text, owned; null bei Fehlerantworten/Notifications
    result: ?[]u8,

    pub fn deinit(self: Message, alloc: std.mem.Allocator) void {
        if (self.result) |r| alloc.free(r);
    }
};

/// Nachricht grob zerlegen: Server-Request (id + method), Notification (nur method),
/// Antwort (id + result/error). `method` zeigt in `body`.
pub fn parseMessage(alloc: std.mem.Allocator, body: []const u8) !?Message {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    const id: ?i64 = if (o.get("id")) |idv| (if (idv == .integer) idv.integer else null) else null;
    const method: ?[]const u8 = if (o.get("method")) |m| (if (m == .string) blk: {
        const start = std.mem.indexOf(u8, body, m.string) orelse break :blk null;
        break :blk body[start .. start + m.string.len];
    } else null) else null;
    var result: ?[]u8 = null;
    if (o.get("result")) |r| {
        if (r != .null) result = try std.json.Stringify.valueAlloc(alloc, r, .{});
    }
    return .{ .id = id, .method = method, .result = result };
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

test "parseFrame: unvollständig → null, vollständig → Body und Verbrauch" {
    try testing.expect(parseFrame("Content-Length: 5\r\n\r\nab") == null);
    try testing.expect(parseFrame("Content-Length: 5") == null);
    const f = parseFrame("Content-Length: 5\r\nContent-Type: x\r\n\r\n{\"a\":1}REST").?;
    try testing.expectEqualStrings("{\"a\":1}"[0..5], f.body);
    try testing.expectEqual(@as(usize, "Content-Length: 5\r\nContent-Type: x\r\n\r\n".len + 5), f.consumed);
}

test "frame/request/notification bauen gültiges JSON-RPC" {
    const a = testing.allocator;
    const f = try frame(a, "{}");
    defer a.free(f);
    try testing.expectEqualStrings("Content-Length: 2\r\n\r\n{}", f);
    const r = try request(a, 3, "textDocument/definition", "{\"x\":1}");
    defer a.free(r);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/definition\",\"params\":{\"x\":1}}", r);
    const n = try notification(a, "initialized", "{}");
    defer a.free(n);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}", n);
}

test "didOpen/didChange/definition: Text wird JSON-escaped, Full-Sync-Form" {
    const a = testing.allocator;
    const o = try didOpenParams(a, "file:///p/a.zig", "zig", "const s = \"x\";\n");
    defer a.free(o);
    try testing.expectEqualStrings("{\"textDocument\":{\"uri\":\"file:///p/a.zig\",\"languageId\":\"zig\",\"version\":1,\"text\":\"const s = \\\"x\\\";\\n\"}}", o);
    const c = try didChangeParams(a, "file:///p/a.zig", 2, "neu");
    defer a.free(c);
    try testing.expectEqualStrings("{\"textDocument\":{\"uri\":\"file:///p/a.zig\",\"version\":2},\"contentChanges\":[{\"text\":\"neu\"}]}", c);
    const d = try definitionParams(a, "file:///p/a.zig", 4, 7);
    defer a.free(d);
    try testing.expectEqualStrings("{\"textDocument\":{\"uri\":\"file:///p/a.zig\"},\"position\":{\"line\":4,\"character\":7}}", d);
}

test "URIs: Pfad ↔ file://, Leerzeichen kodiert" {
    const a = testing.allocator;
    const u = try pathToUri(a, "/tmp/my dir/a.zig");
    defer a.free(u);
    try testing.expectEqualStrings("file:///tmp/my%20dir/a.zig", u);
    const p = (try uriToPath(a, u)).?;
    defer a.free(p);
    try testing.expectEqualStrings("/tmp/my dir/a.zig", p);
    try testing.expect((try uriToPath(a, "untitled:1")) == null);
}

test "firstLocation: null, Location, Location[] und LocationLink[]" {
    const a = testing.allocator;
    try testing.expect((try firstLocation(a, "null")) == null);
    try testing.expect((try firstLocation(a, "[]")) == null);
    const single = (try firstLocation(a, "{\"uri\":\"file:///p/a.zig\",\"range\":{\"start\":{\"line\":3,\"character\":4},\"end\":{\"line\":3,\"character\":9}}}")).?;
    defer single.deinit(a);
    try testing.expectEqualStrings("file:///p/a.zig", single.uri);
    try testing.expectEqual(@as(u32, 3), single.line);
    try testing.expectEqual(@as(u32, 4), single.character);
    const arr = (try firstLocation(a, "[{\"uri\":\"file:///p/b.zig\",\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}}}]")).?;
    defer arr.deinit(a);
    try testing.expectEqualStrings("file:///p/b.zig", arr.uri);
    const link = (try firstLocation(a, "[{\"targetUri\":\"file:///p/c.zig\",\"targetRange\":{\"start\":{\"line\":9,\"character\":0},\"end\":{\"line\":12,\"character\":1}},\"targetSelectionRange\":{\"start\":{\"line\":9,\"character\":7},\"end\":{\"line\":9,\"character\":13}}}]")).?;
    defer link.deinit(a);
    try testing.expectEqualStrings("file:///p/c.zig", link.uri);
    try testing.expectEqual(@as(u32, 9), link.line);
    try testing.expectEqual(@as(u32, 7), link.character);
}

test "parseMessage: Antwort, Server-Request, Notification, Fehlerantwort" {
    const a = testing.allocator;
    const resp = (try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"uri\":\"u\"}]}")).?;
    defer resp.deinit(a);
    try testing.expectEqual(@as(?i64, 2), resp.id);
    try testing.expect(resp.method == null);
    try testing.expectEqualStrings("[{\"uri\":\"u\"}]", resp.result.?);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/configuration\",\"params\":{}}";
    const req = (try parseMessage(a, body)).?;
    defer req.deinit(a);
    try testing.expectEqual(@as(?i64, 7), req.id);
    try testing.expectEqualStrings("workspace/configuration", req.method.?);
    const note = (try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{}}")).?;
    defer note.deinit(a);
    try testing.expect(note.id == null);
    try testing.expectEqualStrings("window/logMessage", note.method.?);
    const err = (try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-1,\"message\":\"x\"}}")).?;
    defer err.deinit(a);
    try testing.expectEqual(@as(?i64, 3), err.id);
    try testing.expect(err.result == null);
}
