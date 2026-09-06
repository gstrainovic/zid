//! Kleine Regex-Engine für die Suchleiste (Backtracking, bytebasiert, UTF-8-bewusst bei `.`):
//! Literale, `.`, `*`, `+`, `?`, `[abc]`, `[^a-z]`, `^`, `$`, `\d \w \s \b`, `\.`-Escapes,
//! Gruppen `( )` und Alternativen `|`. Keine Rückverweise, keine lazy Quantoren.
//! Unit-getestet; der Editor nutzt `compile` + `find`.

const std = @import("std");

pub const max_nodes = 256;

const NodeKind = enum { literal, any, class, start, end, word_boundary, group_start, group_end, alt };

const Node = struct {
    kind: NodeKind,
    byte: u8 = 0,
    /// Klasse: 256-Bit-Maske
    class: [32]u8 = [_]u8{0} ** 32,
    /// Quantor: min/max Wiederholungen (max 0 = unbegrenzt)
    min: u8 = 1,
    max: u8 = 1,
    unbounded: bool = false,
    /// Gruppen: Index des passenden Endes / Anfangs
    partner: u16 = 0,
};

pub const Regex = struct {
    nodes: [max_nodes]Node = undefined,
    len: usize = 0,
    case_sensitive: bool = true,

    pub const Match = struct { start: usize, end: usize };

    /// Erster Treffer ab Byte `from` (inklusiv); null wenn keiner.
    pub fn find(self: *const Regex, text: []const u8, from: usize) ?Match {
        var start = from;
        while (start <= text.len) : (start += 1) {
            if (self.matchAt(text, start)) |end| return .{ .start = start, .end = end };
            if (start == text.len) break;
        }
        return null;
    }

    /// Letzter nicht überlappender Treffer (vorwärts gescannt), der vor `before` beginnt.
    pub fn findLast(self: *const Regex, text: []const u8, before: usize) ?Match {
        var best: ?Match = null;
        var pos: usize = 0;
        while (pos <= text.len) {
            const m = self.find(text, pos) orelse break;
            if (m.start >= before) break;
            best = m;
            pos = if (m.end > m.start) m.end else m.start + 1;
        }
        return best;
    }

    /// Länge des Treffers an Position `pos` (Ende-Offset) oder null.
    pub fn matchAt(self: *const Regex, text: []const u8, pos: usize) ?usize {
        return self.matchSeq(text, pos, 0, self.len);
    }

    fn eqByte(self: *const Regex, a: u8, b: u8) bool {
        if (self.case_sensitive) return a == b;
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }

    fn classHas(self: *const Regex, node: *const Node, c: u8) bool {
        if (node.class[c >> 3] & (@as(u8, 1) << @intCast(c & 7)) != 0) return true;
        if (!self.case_sensitive) {
            const alt: u8 = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c);
            return node.class[alt >> 3] & (@as(u8, 1) << @intCast(alt & 7)) != 0;
        }
        return false;
    }

    /// Ein einzelnes Atom an `pos` matchen: Länge in Bytes oder null.
    fn matchAtom(self: *const Regex, node: *const Node, text: []const u8, pos: usize) ?usize {
        switch (node.kind) {
            .literal => {
                if (pos < text.len and self.eqByte(text[pos], node.byte)) return 1;
                return null;
            },
            .any => {
                if (pos >= text.len or text[pos] == '\n') return null;
                return std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
            },
            .class => {
                if (pos < text.len and self.classHas(node, text[pos])) return 1;
                return null;
            },
            else => return null,
        }
    }

    /// Sequenz nodes[i..end] ab pos matchen (Backtracking); liefert das Ende.
    fn matchSeq(self: *const Regex, text: []const u8, pos: usize, i: usize, end: usize) ?usize {
        if (i >= end) return pos;
        const node = &self.nodes[i];
        switch (node.kind) {
            .start => return if (pos == 0 or text[pos - 1] == '\n') self.matchSeq(text, pos, i + 1, end) else null,
            .end => return if (pos == text.len or text[pos] == '\n') self.matchSeq(text, pos, i + 1, end) else null,
            .word_boundary => {
                const before = pos > 0 and isWord(text[pos - 1]);
                const after = pos < text.len and isWord(text[pos]);
                return if (before != after) self.matchSeq(text, pos, i + 1, end) else null;
            },
            .alt => return null, // nur innerhalb von Gruppen bzw. top-level erlaubt, dort behandelt
            .group_start => {
                const close = node.partner;
                // Alternativen innerhalb der Gruppe sammeln
                var branches: [16][2]usize = undefined;
                var nb: usize = 0;
                var b_start = i + 1;
                var depth: usize = 0;
                var k = i + 1;
                while (k < close) : (k += 1) {
                    const kn = self.nodes[k];
                    if (kn.kind == .group_start) depth += 1;
                    if (kn.kind == .group_end) depth -= 1;
                    if (kn.kind == .alt and depth == 0) {
                        if (nb < branches.len) {
                            branches[nb] = .{ b_start, k };
                            nb += 1;
                        }
                        b_start = k + 1;
                    }
                }
                if (nb < branches.len) {
                    branches[nb] = .{ b_start, close };
                    nb += 1;
                }
                // Quantor der Gruppe: greedy, mit Backtracking über die Anzahl Wiederholungen
                return self.matchGroupRepeat(text, pos, branches[0..nb], node, close, end, 0);
            },
            .group_end => return self.matchSeq(text, pos, i + 1, end),
            else => {
                // Atom mit Quantor: greedy so viele wie möglich, dann zurück
                var ends: [512]usize = undefined;
                var n: usize = 0;
                var p = pos;
                ends[n] = p;
                n += 1;
                while (node.unbounded or n - 1 < node.max) {
                    const l = self.matchAtom(node, text, p) orelse break;
                    if (l == 0) break;
                    p += l;
                    if (n < ends.len) {
                        ends[n] = p;
                        n += 1;
                    } else break;
                }
                var count = n;
                while (count > node.min) : (count -= 1) {
                    if (self.matchSeq(text, ends[count - 1], i + 1, end)) |e| return e;
                }
                return null;
            },
        }
    }

    fn matchGroupRepeat(self: *const Regex, text: []const u8, pos: usize, branches: []const [2]usize, node: *const Node, close: usize, end: usize, done: usize) ?usize {
        // Weitere Wiederholung versuchen (greedy), sonst weiter hinter der Gruppe
        if (node.unbounded or done < node.max) {
            for (branches) |b| {
                if (self.matchSeq(text, pos, b[0], b[1])) |after| {
                    if (after == pos and done >= node.min) continue; // leere Wiederholung vermeiden
                    if (self.matchGroupRepeat(text, after, branches, node, close, end, done + 1)) |e| return e;
                }
            }
        }
        if (done >= node.min) return self.matchSeq(text, pos, close + 1, end);
        return null;
    }
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn setClass(node: *Node, c: u8) void {
    node.class[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
}

fn setClassRange(node: *Node, lo: u8, hi: u8) void {
    var c: usize = lo;
    while (c <= hi) : (c += 1) setClass(node, @intCast(c));
}

fn setEscapeClass(node: *Node, e: u8) bool {
    switch (e) {
        'd' => setClassRange(node, '0', '9'),
        'w' => {
            setClassRange(node, 'a', 'z');
            setClassRange(node, 'A', 'Z');
            setClassRange(node, '0', '9');
            setClass(node, '_');
            setClassRange(node, 0x80, 0xff);
        },
        's' => {
            setClass(node, ' ');
            setClass(node, '\t');
            setClass(node, '\r');
            setClass(node, '\n');
        },
        else => return false,
    }
    return true;
}

pub const CompileError = error{ InvalidPattern, TooLong };

/// Muster übersetzen. Top-level `|` wird als Gruppe um das ganze Muster behandelt.
pub fn compile(pattern: []const u8, case_sensitive: bool) CompileError!Regex {
    var re = Regex{ .case_sensitive = case_sensitive };
    // Ganzes Muster in eine Gruppe, damit `a|b` am Anfang funktioniert
    try push(&re, .{ .kind = .group_start });
    var stack: [32]usize = undefined;
    var sp: usize = 0;
    stack[sp] = 0;
    sp += 1;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        var node: Node = .{ .kind = .literal, .byte = c };
        switch (c) {
            '.' => node = .{ .kind = .any },
            '^' => node = .{ .kind = .start },
            '$' => node = .{ .kind = .end },
            '|' => node = .{ .kind = .alt },
            '(' => {
                node = .{ .kind = .group_start };
                if (sp >= stack.len) return error.InvalidPattern;
                stack[sp] = re.len;
                sp += 1;
            },
            ')' => {
                if (sp <= 1) return error.InvalidPattern;
                sp -= 1;
                const open = stack[sp];
                node = .{ .kind = .group_end, .partner = @intCast(open) };
                re.nodes[open].partner = @intCast(re.len);
            },
            '[' => {
                node = .{ .kind = .class };
                i += 1;
                var negate = false;
                if (i < pattern.len and pattern[i] == '^') {
                    negate = true;
                    i += 1;
                }
                var first = true;
                while (i < pattern.len and (pattern[i] != ']' or first)) : (i += 1) {
                    first = false;
                    var lo = pattern[i];
                    if (lo == '\\' and i + 1 < pattern.len) {
                        i += 1;
                        if (setEscapeClass(&node, pattern[i])) continue;
                        lo = pattern[i];
                    }
                    if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                        setClassRange(&node, lo, pattern[i + 2]);
                        i += 2;
                    } else setClass(&node, lo);
                }
                if (i >= pattern.len) return error.InvalidPattern;
                if (negate) {
                    for (&node.class) |*b| b.* = ~b.*;
                    node.class['\n' >> 3] &= ~(@as(u8, 1) << @intCast('\n' & 7));
                }
            },
            '\\' => {
                i += 1;
                if (i >= pattern.len) return error.InvalidPattern;
                const e = pattern[i];
                if (e == 'b') {
                    node = .{ .kind = .word_boundary };
                } else if (e == 'n') {
                    node = .{ .kind = .literal, .byte = '\n' };
                } else if (e == 't') {
                    node = .{ .kind = .literal, .byte = '\t' };
                } else {
                    node = .{ .kind = .class };
                    if (!setEscapeClass(&node, e)) node = .{ .kind = .literal, .byte = e };
                }
            },
            '*', '+', '?' => {
                // Quantor gehört zum vorigen Atom bzw. zur vorigen Gruppe
                if (re.len == 0) return error.InvalidPattern;
                var target = re.len - 1;
                if (re.nodes[target].kind == .group_end) target = re.nodes[target].partner;
                const t = &re.nodes[target];
                if (t.kind == .start or t.kind == .end or t.kind == .alt or t.kind == .group_start and re.nodes[re.len - 1].kind != .group_end) return error.InvalidPattern;
                switch (c) {
                    '*' => {
                        t.min = 0;
                        t.unbounded = true;
                    },
                    '+' => {
                        t.min = 1;
                        t.unbounded = true;
                    },
                    else => {
                        t.min = 0;
                        t.max = 1;
                    },
                }
                continue;
            },
            else => {},
        }
        try push(&re, node);
    }
    if (sp != 1) return error.InvalidPattern;
    try push(&re, .{ .kind = .group_end, .partner = 0 });
    re.nodes[0].partner = @intCast(re.len - 1);
    return re;
}

fn push(re: *Regex, node: Node) CompileError!void {
    if (re.len >= max_nodes) return error.TooLong;
    re.nodes[re.len] = node;
    re.len += 1;
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

fn firstMatch(pat: []const u8, text: []const u8, cs: bool) ?Regex.Match {
    const re = compile(pat, cs) catch return null;
    return re.find(text, 0);
}

test "Literale, Groß/Klein, Punkt" {
    const m = firstMatch("bar", "foo bar", true).?;
    try testing.expectEqual(@as(usize, 4), m.start);
    try testing.expectEqual(@as(usize, 7), m.end);
    try testing.expect(firstMatch("BAR", "foo bar", true) == null);
    try testing.expect(firstMatch("BAR", "foo bar", false) != null);
    try testing.expectEqualDeep(Regex.Match{ .start = 1, .end = 4 }, firstMatch("f.o", "xfoo", true).?);
    // `.` frisst ein ganzes UTF-8-Zeichen (ä = 2 Bytes)
    try testing.expectEqual(@as(usize, 2), firstMatch("^.$", "ä", true).?.end);
}

test "Quantoren, Klassen, Anker" {
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 3 }, firstMatch("a+", "aaab", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 0 }, firstMatch("x*", "aaab", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 1, .end = 4 }, firstMatch("[0-9]+", "v123x", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 5 }, firstMatch("colou?r", "color", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 6 }, firstMatch("colou?r", "colour", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 3, .end = 5 }, firstMatch("[^a-z ]+", "ab 12x", true).?);
    try testing.expect(firstMatch("^foo", "x foo", true) == null);
    try testing.expect(firstMatch("foo$", "foo x", true) == null);
    try testing.expectEqualDeep(Regex.Match{ .start = 4, .end = 7 }, firstMatch("^foo", "bar\nfoo", true).?);
}

test "Escapes, Wortgrenzen, Gruppen und Alternativen" {
    try testing.expectEqualDeep(Regex.Match{ .start = 3, .end = 6 }, firstMatch("\\d+", "ab 123 c", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 1, .end = 2 }, firstMatch("\\.", "a.b", true).?);
    try testing.expect(firstMatch("\\bcat\\b", "concatenate", true) == null);
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 3 }, firstMatch("\\bcat\\b", "cat cat", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 4, .end = 7 }, firstMatch("foo|bar", "xxx bar", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 4 }, firstMatch("(ab)+", "ababx", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 6 }, firstMatch("(foo|ba)+r", "foobar!", true).?);
    try testing.expectEqualDeep(Regex.Match{ .start = 0, .end = 5 }, firstMatch("a(b|c)*d", "abcbd", true).?);
    try testing.expect((compile("(ab", true)) == error.InvalidPattern);
    try testing.expect((compile("*a", true)) == error.InvalidPattern);
}

test "findLast liefert den letzten Treffer vor einer Position" {
    const re = try compile("o+", true);
    const m = re.findLast("foo boo zoo", 8).?;
    try testing.expectEqual(@as(usize, 5), m.start);
    try testing.expectEqual(@as(usize, 7), m.end);
    try testing.expect(re.findLast("xyz", 3) == null);
}
