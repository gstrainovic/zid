//! Source Control Graph wie VS Code, ohne Clay: Bahnen (Swimlanes) je Commit und die
//! Zeichenelemente einer Zeile. 1:1 portiert aus vscode
//! src/vs/workbench/contrib/scm/browser/scmHistory.ts (`toISCMHistoryItemViewModelArray`,
//! `renderSCMHistoryItemGraph`). Koordinaten in VS-Code-Einheiten (Bahnbreite 11, Zeile 22);
//! die Ansicht skaliert.

const std = @import("std");

const testing = std.testing;

pub const SWIMLANE_HEIGHT: f32 = 22;
pub const SWIMLANE_WIDTH: f32 = 11;
pub const SWIMLANE_CURVE_RADIUS: f32 = 5;
pub const CIRCLE_RADIUS: f32 = 4;
pub const CIRCLE_STROKE_WIDTH: f32 = 2;

/// Farben: `scmGraph.foreground1..5` rotierend, Referenzfarben für den gefilterten Branch,
/// dessen Remote und die Basis (VS Code historyItemRefColor / RemoteRefColor / BaseRefColor).
pub const Color = union(enum) {
    palette: u8,
    ref_current,
    ref_remote,
    ref_base,
};
pub const palette_len = 5;

pub const Lane = struct { id: []const u8, color: Color };

pub const Commit = struct {
    id: []const u8,
    parents: []const []const u8,
    /// Farbe einer Referenz dieses Commits aus dem Filter (VS Code `getLabelColorIdentifier`)
    label_color: ?Color = null,
};

pub const Kind = enum { node, head };

pub const Row = struct {
    input: []Lane,
    output: []Lane,
    kind: Kind,
};

pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
    }
};

/// VS Code `toISCMHistoryItemViewModelArray`: Ein- und Ausgangsbahnen je Commit, neueste zuerst.
/// `head` ist der Commit des aktuellen Branches (Ring statt Punkt).
pub fn build(alloc: std.mem.Allocator, commits: []const Commit, head: ?[]const u8) !Graph {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const rows = try a.alloc(Row, commits.len);
    var color_index: i32 = -1;
    var previous: []Lane = &.{};

    for (commits, 0..) |c, index| {
        const input = try a.dupe(Lane, previous);
        var output: std.ArrayListUnmanaged(Lane) = .empty;
        var first_parent_added = false;

        if (c.parents.len > 0) {
            for (input) |node| {
                if (std.mem.eql(u8, node.id, c.id)) {
                    if (!first_parent_added) {
                        try output.append(a, .{ .id = c.parents[0], .color = c.label_color orelse node.color });
                        first_parent_added = true;
                    }
                    continue;
                }
                try output.append(a, node);
            }
        }

        var i: usize = if (first_parent_added) 1 else 0;
        while (i < c.parents.len) : (i += 1) {
            var color: ?Color = if (i == 0) c.label_color else blk: {
                for (commits) |other| {
                    if (std.mem.eql(u8, other.id, c.parents[i])) break :blk other.label_color;
                }
                break :blk null;
            };
            if (color == null) {
                color_index = @mod(color_index + 1, palette_len);
                color = .{ .palette = @intCast(color_index) };
            }
            try output.append(a, .{ .id = c.parents[i], .color = color.? });
        }

        const kind: Kind = if (head) |h| (if (std.mem.eql(u8, h, c.id)) .head else .node) else .node;
        rows[index] = .{ .input = input, .output = try output.toOwnedSlice(a), .kind = kind };
        previous = rows[index].output;
    }
    return .{ .arena = arena, .rows = rows };
}

/// Bahn des Kreises: Position des Commits in den Eingangsbahnen, sonst eine neue rechts.
pub fn circleIndex(c: Commit, row: Row) usize {
    return indexOf(row.input, c.id) orelse row.input.len;
}

fn indexOf(lanes: []const Lane, id: []const u8) ?usize {
    for (lanes, 0..) |l, i| if (std.mem.eql(u8, l.id, id)) return i;
    return null;
}

fn lastIndexOf(lanes: []const Lane, id: []const u8) ?usize {
    var i = lanes.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, lanes[i].id, id)) return i;
    }
    return null;
}

/// Viertelkreis eines SVG-Bogens: welcher Quadrant um den Mittelpunkt gezeichnet wird.
pub const Quadrant = enum { top_left, top_right, bottom_left, bottom_right };

pub const Fill = union(enum) { lane: Color, background };

/// Zeichenelemente in VS-Code-Einheiten. Linien 1 Einheit breit; Kreise als gefüllte Scheiben,
/// die Ränder in Hintergrundfarbe entstehen durch eine größere Scheibe darunter (so wie
/// VS Codes `stroke: sideBar-background` den farbigen Kreis einfasst).
pub const Shape = union(enum) {
    vline: struct { x: f32, y0: f32, y1: f32, color: Color },
    hline: struct { x0: f32, x1: f32, y: f32, color: Color },
    arc: struct { cx: f32, cy: f32, r: f32, quadrant: Quadrant, color: Color },
    disc: struct { cx: f32, cy: f32, r: f32, fill: Fill },
};

/// VS Code `renderSCMHistoryItemGraph` als Formenliste (Reihenfolge = Zeichenreihenfolge).
pub fn shapes(alloc: std.mem.Allocator, c: Commit, row: Row) ![]Shape {
    var out: std.ArrayListUnmanaged(Shape) = .empty;
    errdefer out.deinit(alloc);
    const input = row.input;
    const output = row.output;
    const input_index = indexOf(input, c.id);
    const ci = input_index orelse input.len;
    const circle_color: ?Color = if (ci < output.len) output[ci].color else if (ci < input.len) input[ci].color else null;
    const cx = x(ci);

    var output_index: usize = 0;
    for (input, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, c.id)) {
            if (index != ci) {
                // Basis-Commit: Bogen „/“ von oben auf die eigene Bahn, dann „-“ zum Kreis
                try out.append(alloc, .{ .arc = .{ .cx = W * @as(f32, @floatFromInt(index)), .cy = 0, .r = W, .quadrant = .bottom_right, .color = node.color } });
                try appendHLine(&out, alloc, W * @as(f32, @floatFromInt(index)), cx, W, node.color);
            } else {
                output_index += 1;
            }
        } else if (output_index < output.len and std.mem.eql(u8, node.id, output[output_index].id)) {
            if (index == output_index) {
                try out.append(alloc, .{ .vline = .{ .x = x(index), .y0 = 0, .y1 = H, .color = node.color } });
            } else {
                // Bahnverschiebung: | → Bogen → - → Bogen → |
                const R = SWIMLANE_CURVE_RADIUS;
                const from = x(index);
                const to = x(output_index);
                try out.append(alloc, .{ .vline = .{ .x = from, .y0 = 0, .y1 = H / 2 - R, .color = node.color } });
                try out.append(alloc, .{ .arc = .{ .cx = from - R, .cy = H / 2 - R, .r = R, .quadrant = .bottom_right, .color = node.color } });
                try appendHLine(&out, alloc, to + R, from - R, H / 2, node.color);
                try out.append(alloc, .{ .arc = .{ .cx = to + R, .cy = H / 2 + R, .r = R, .quadrant = .top_left, .color = node.color } });
                try out.append(alloc, .{ .vline = .{ .x = to, .y0 = H / 2 + R, .y1 = H, .color = node.color } });
            }
            output_index += 1;
        }
    }

    // Weitere Eltern: Bogen „\“ nach unten auf ihre Bahn, „-“ zum Kreis
    for (c.parents[@min(1, c.parents.len)..]) |parent| {
        const pi = lastIndexOf(output, parent) orelse continue;
        const color = output[pi].color;
        const left = W * @as(f32, @floatFromInt(pi));
        try out.append(alloc, .{ .arc = .{ .cx = left, .cy = H, .r = W, .quadrant = .top_right, .color = color } });
        try appendHLine(&out, alloc, left, cx, H / 2, color);
    }

    if (input_index) |ii| try out.append(alloc, .{ .vline = .{ .x = cx, .y0 = 0, .y1 = H / 2, .color = input[ii].color } });
    if (c.parents.len > 0) {
        if (circle_color) |cc| try out.append(alloc, .{ .vline = .{ .x = cx, .y0 = H / 2, .y1 = H, .color = cc } });
    }

    const color = circle_color orelse Color.ref_current;
    const sw2 = CIRCLE_STROKE_WIDTH / 2;
    if (row.kind == .head) {
        try disc(&out, alloc, cx, CIRCLE_RADIUS + 3 + sw2, .background);
        try disc(&out, alloc, cx, CIRCLE_RADIUS + 3 - sw2, .{ .lane = color });
        // innerer Kreis r2 mit Randbreite 4, Füllung und Rand in Hintergrundfarbe
        try disc(&out, alloc, cx, CIRCLE_STROKE_WIDTH + CIRCLE_RADIUS / 2, .background);
    } else if (c.parents.len > 1) {
        try disc(&out, alloc, cx, CIRCLE_RADIUS + 2 + sw2, .background);
        try disc(&out, alloc, cx, CIRCLE_RADIUS + 2 - sw2, .{ .lane = color });
        try disc(&out, alloc, cx, CIRCLE_RADIUS - 1 + sw2, .background);
        try disc(&out, alloc, cx, CIRCLE_RADIUS - 1 - sw2, .{ .lane = color });
    } else {
        try disc(&out, alloc, cx, CIRCLE_RADIUS + 1 + sw2, .background);
        try disc(&out, alloc, cx, CIRCLE_RADIUS + 1 - sw2, .{ .lane = color });
    }
    return out.toOwnedSlice(alloc);
}

fn x(index: usize) f32 {
    return W * @as(f32, @floatFromInt(index + 1));
}

fn appendHLine(out: *std.ArrayListUnmanaged(Shape), alloc: std.mem.Allocator, a: f32, b: f32, y: f32, color: Color) !void {
    if (a == b) return;
    try out.append(alloc, .{ .hline = .{ .x0 = @min(a, b), .x1 = @max(a, b), .y = y, .color = color } });
}

fn disc(out: *std.ArrayListUnmanaged(Shape), alloc: std.mem.Allocator, cx: f32, r: f32, fill: Fill) !void {
    try out.append(alloc, .{ .disc = .{ .cx = cx, .cy = W, .r = r, .fill = fill } });
}

/// Breite der Graph-Spalte (VS Code: `SWIMLANE_WIDTH * (max(input, output, 1) + 1)`).
pub fn width(row: Row) f32 {
    return W * @as(f32, @floatFromInt(@max(row.input.len, row.output.len, 1) + 1));
}

/// Bahnen einer Dateizeile unter einem aufgeklappten Commit (VS Code
/// `renderSCMHistoryGraphPlaceholder`): senkrechte Linien, die Bahn des Commits hervorgehoben.
pub fn placeholderWidth(columns: usize) f32 {
    return W * @as(f32, @floatFromInt(columns + 1));
}

/// Viertel-Ringsegment als geschlossenes Polygon im Rahmen `r + sw` × `r + sw`; der Kreismittelpunkt
/// liegt in der Rahmenecke gegenüber dem Quadranten. Eigene Pfade je Quadrant, damit der
/// Even-Odd-Füller keine Löcher schneidet und der Atlas sie je Radius wiederverwendet.
pub fn arcPath(buf: []u8, r: f32, sw: f32, quadrant: Quadrant) []const u8 {
    const outer = r + sw / 2;
    const inner = r - sw / 2;
    const s = outer; // Rahmengröße
    // Mittelpunkt und Richtungen je Quadrant (y nach unten)
    const c: [2]f32, const dx: f32, const dy: f32 = switch (quadrant) {
        .bottom_right => .{ .{ 0, 0 }, 1, 1 },
        .bottom_left => .{ .{ s, 0 }, -1, 1 },
        .top_right => .{ .{ 0, s }, 1, -1 },
        .top_left => .{ .{ s, s }, -1, -1 },
    };
    return std.fmt.bufPrint(buf, "M{d:.3} {d:.3}A{d:.3} {d:.3} 0 0 {d} {d:.3} {d:.3}L{d:.3} {d:.3}A{d:.3} {d:.3} 0 0 {d} {d:.3} {d:.3}Z", .{
        c[0] + dx * outer, c[1],
        outer,             outer,
        @as(u8, if (dx * dy > 0) 1 else 0),
        c[0],              c[1] + dy * outer,
        c[0],              c[1] + dy * inner,
        inner,             inner,
        @as(u8, if (dx * dy > 0) 0 else 1),
        c[0] + dx * inner, c[1],
    }) catch "";
}

/// Gefüllte Kreisscheibe im Rahmen 2r × 2r.
pub fn discPath(buf: []u8, r: f32) []const u8 {
    return std.fmt.bufPrint(buf, "<circle cx=\"{d:.3}\" cy=\"{d:.3}\" r=\"{d:.3}\"/>", .{ r, r, r }) catch "";
}

fn expectLanes(expected: []const Lane, actual: []const Lane) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqualStrings(e.id, a.id);
        try testing.expectEqual(e.color, a.color);
    }
}

test "build: lineare Historie, eine Bahn, erste Farbe" {
    const commits = [_]Commit{
        .{ .id = "A", .parents = &.{"B"} },
        .{ .id = "B", .parents = &.{"C"} },
        .{ .id = "C", .parents = &.{} },
    };
    var g = try build(testing.allocator, &commits, "A");
    defer g.deinit();
    try testing.expectEqual(Kind.head, g.rows[0].kind);
    try testing.expectEqual(Kind.node, g.rows[1].kind);
    try expectLanes(&.{}, g.rows[0].input);
    try expectLanes(&.{.{ .id = "B", .color = .{ .palette = 0 } }}, g.rows[0].output);
    try expectLanes(&.{.{ .id = "C", .color = .{ .palette = 0 } }}, g.rows[1].output);
    try expectLanes(&.{}, g.rows[2].output);
}

test "build: Oktopus-Merge verteilt Farben, zusammenlaufende Bahnen fallen weg" {
    const commits = [_]Commit{
        .{ .id = "M", .parents = &.{ "A", "F", "G" } },
        .{ .id = "F", .parents = &.{"A"} },
        .{ .id = "A", .parents = &.{"R"} },
        .{ .id = "G", .parents = &.{"R"} },
        .{ .id = "R", .parents = &.{} },
    };
    var g = try build(testing.allocator, &commits, null);
    defer g.deinit();
    try expectLanes(&.{ .{ .id = "A", .color = .{ .palette = 0 } }, .{ .id = "F", .color = .{ .palette = 1 } }, .{ .id = "G", .color = .{ .palette = 2 } } }, g.rows[0].output);
    try expectLanes(&.{ .{ .id = "A", .color = .{ .palette = 0 } }, .{ .id = "A", .color = .{ .palette = 1 } }, .{ .id = "G", .color = .{ .palette = 2 } } }, g.rows[1].output);
    try expectLanes(&.{ .{ .id = "R", .color = .{ .palette = 0 } }, .{ .id = "G", .color = .{ .palette = 2 } } }, g.rows[2].output);
    try expectLanes(&.{ .{ .id = "R", .color = .{ .palette = 0 } }, .{ .id = "R", .color = .{ .palette = 2 } } }, g.rows[3].output);
    try testing.expectEqual(@as(usize, 1), circleIndex(commits[1], g.rows[1]));
}

test "build: Referenzfarbe des Commits färbt seine Bahn" {
    const commits = [_]Commit{
        .{ .id = "A", .parents = &.{"B"}, .label_color = .ref_current },
        .{ .id = "B", .parents = &.{} },
    };
    var g = try build(testing.allocator, &commits, "A");
    defer g.deinit();
    try expectLanes(&.{.{ .id = "B", .color = .ref_current }}, g.rows[0].output);
}

fn expectShapes(expected: []const Shape, actual: []const Shape) !void {
    testing.expectEqual(expected.len, actual.len) catch |err| {
        std.debug.print("Formen: {any}\n", .{actual});
        return err;
    };
    for (expected, actual, 0..) |e, a, i| {
        testing.expectEqual(e, a) catch |err| {
            std.debug.print("Form {d}: erwartet {any}, bekommen {any}\n", .{ i, e, a });
            return err;
        };
    }
}

const W = SWIMLANE_WIDTH;
const H = SWIMLANE_HEIGHT;
const p = struct {
    fn c(i: u8) Color {
        return .{ .palette = i };
    }
};

test "shapes: HEAD oben (Linie nach unten, Ring), Mitte (durchgehend), Wurzel (nur nach oben)" {
    const commits = [_]Commit{
        .{ .id = "A", .parents = &.{"B"} },
        .{ .id = "B", .parents = &.{"C"} },
        .{ .id = "C", .parents = &.{} },
    };
    var g = try build(testing.allocator, &commits, "A");
    defer g.deinit();

    const head = try shapes(testing.allocator, commits[0], g.rows[0]);
    defer testing.allocator.free(head);
    try expectShapes(&.{
        .{ .vline = .{ .x = W, .y0 = H / 2, .y1 = H, .color = p.c(0) } },
        // HEAD: Außenkreis r7 mit Hintergrund-Rand, innen Hintergrund r4 → farbiger Ring
        .{ .disc = .{ .cx = W, .cy = W, .r = 8, .fill = .background } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 6, .fill = .{ .lane = p.c(0) } } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 4, .fill = .background } },
    }, head);

    const mid = try shapes(testing.allocator, commits[1], g.rows[1]);
    defer testing.allocator.free(mid);
    try expectShapes(&.{
        .{ .vline = .{ .x = W, .y0 = 0, .y1 = H / 2, .color = p.c(0) } },
        .{ .vline = .{ .x = W, .y0 = H / 2, .y1 = H, .color = p.c(0) } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 6, .fill = .background } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 4, .fill = .{ .lane = p.c(0) } } },
    }, mid);

    const root = try shapes(testing.allocator, commits[2], g.rows[2]);
    defer testing.allocator.free(root);
    try expectShapes(&.{
        .{ .vline = .{ .x = W, .y0 = 0, .y1 = H / 2, .color = p.c(0) } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 6, .fill = .background } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 4, .fill = .{ .lane = p.c(0) } } },
    }, root);
}

test "shapes: Merge-Commit (Bogen zum zweiten Elternteil, Doppelkreis), Basis-Commit, Bahnverschiebung" {
    const commits = [_]Commit{
        .{ .id = "M", .parents = &.{ "A", "F", "G" } },
        .{ .id = "F", .parents = &.{"A"} },
        .{ .id = "A", .parents = &.{"R"} },
        .{ .id = "G", .parents = &.{"R"} },
        .{ .id = "R", .parents = &.{} },
    };
    var g = try build(testing.allocator, &commits, null);
    defer g.deinit();

    const merge = try shapes(testing.allocator, commits[0], g.rows[0]);
    defer testing.allocator.free(merge);
    try expectShapes(&.{
        // Elternteil F (Bahn 1): Bogen von (W, H/2) nach (2W, H)
        .{ .arc = .{ .cx = W, .cy = H, .r = W, .quadrant = .top_right, .color = p.c(1) } },
        // Elternteil G (Bahn 2): Bogen plus waagerecht zum Kreis
        .{ .arc = .{ .cx = 2 * W, .cy = H, .r = W, .quadrant = .top_right, .color = p.c(2) } },
        .{ .hline = .{ .x0 = W, .x1 = 2 * W, .y = H / 2, .color = p.c(2) } },
        .{ .vline = .{ .x = W, .y0 = H / 2, .y1 = H, .color = p.c(0) } },
        // Mehrere Eltern: Außenkreis r6 und Innenkreis r3
        .{ .disc = .{ .cx = W, .cy = W, .r = 7, .fill = .background } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 5, .fill = .{ .lane = p.c(0) } } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 4, .fill = .background } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 2, .fill = .{ .lane = p.c(0) } } },
    }, merge);

    // Zeile A: Bahn 1 (auch A) läuft als Basis-Bogen ein, Bahn 2 (G) rückt auf Bahn 1
    const a = try shapes(testing.allocator, commits[2], g.rows[2]);
    defer testing.allocator.free(a);
    const R = SWIMLANE_CURVE_RADIUS;
    try expectShapes(&.{
        .{ .arc = .{ .cx = W, .cy = 0, .r = W, .quadrant = .bottom_right, .color = p.c(1) } },
        .{ .vline = .{ .x = 3 * W, .y0 = 0, .y1 = H / 2 - R, .color = p.c(2) } },
        .{ .arc = .{ .cx = 3 * W - R, .cy = H / 2 - R, .r = R, .quadrant = .bottom_right, .color = p.c(2) } },
        .{ .hline = .{ .x0 = 2 * W + R, .x1 = 3 * W - R, .y = H / 2, .color = p.c(2) } },
        .{ .arc = .{ .cx = 2 * W + R, .cy = H / 2 + R, .r = R, .quadrant = .top_left, .color = p.c(2) } },
        .{ .vline = .{ .x = 2 * W, .y0 = H / 2 + R, .y1 = H, .color = p.c(2) } },
        .{ .vline = .{ .x = W, .y0 = 0, .y1 = H / 2, .color = p.c(0) } },
        .{ .vline = .{ .x = W, .y0 = H / 2, .y1 = H, .color = p.c(0) } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 6, .fill = .background } },
        .{ .disc = .{ .cx = W, .cy = W, .r = 4, .fill = .{ .lane = p.c(0) } } },
    }, a);
}

test "width: Bahnen plus eins (VS Code svg.style.width)" {
    const lanes2 = [_]Lane{ .{ .id = "a", .color = p.c(0) }, .{ .id = "b", .color = p.c(1) } };
    try testing.expectEqual(3 * W, width(.{ .input = @constCast(&lanes2), .output = &.{}, .kind = .node }));
    try testing.expectEqual(2 * W, width(.{ .input = &.{}, .output = &.{}, .kind = .node }));
}

test "arcPath und discPath: geschlossene Polygone im eigenen Rahmen" {
    var buf: [512]u8 = undefined;
    const arc = arcPath(&buf, 11, 1, .bottom_right);
    try testing.expect(std.mem.startsWith(u8, arc, "M"));
    try testing.expect(std.mem.endsWith(u8, arc, "Z"));
    const circle = discPath(&buf, 4);
    try testing.expect(std.mem.indexOf(u8, circle, "<circle") != null);
}
