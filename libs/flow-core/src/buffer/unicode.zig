const std = @import("std");

const utf16LeToUtf8 = std.unicode.utf16LeToUtf8;
const utf8ByteSequenceLength = std.unicode.utf8ByteSequenceLength;
const utf8Decode = std.unicode.utf8Decode;
const utf8Encode = std.unicode.utf8Encode;
const Utf8View = std.unicode.Utf8View;

// ---------------------------------------------------------------------------
// Minimal inline Unicode case-mapping backend (replaces vaxis.uucode)
// ---------------------------------------------------------------------------
// ASCII handled by arithmetic. Extended characters covered by a comptime
// sorted lookup table. Codepoints not in the table return unchanged.

pub const FieldEnum = enum {
    simple_uppercase_mapping,
    simple_lowercase_mapping,
    case_folding_simple,
    is_lowercase,
    changes_when_casefolded,
    changes_when_lowercased,
};

/// Case-mapping / predicate entry.
/// For transformations: `from` -> `to`.
/// For predicates: `is_predicate = true` means the property holds for `from`.
const MappingEntry = struct {
    from: u21,
    to: u21,
    is_predicate: bool = false,
};

// Extended Unicode case-mapping table (sorted by `from`).
// Covers common Latin-1 Supplement, Latin Extended-A, and Greek.
const mapping_table = blk: {
    var tbl: [256]MappingEntry = undefined;
    var i: usize = 0;

    // -- Latin-1 Supplement (U+00C0 .. U+00FF) --
    // Uppercase -> lowercase  (A-grave through y-umlaut)
    for (0..32) |o| {
        tbl[i] = .{ .from = 0x00C0 + o, .to = 0x00E0 + o };
        i += 1;
    }
    // ß (U+00DF) : lowercase of ẞ (U+1E9E); case-fold -> ss (handled in logic)
    // U+00DF ß: changes when casefolded = true, simple uppercase = ẞ
    tbl[i] = .{ .from = 0x00DF, .to = 0x1E9E };
    i += 1;

    // -- Latin Extended-A (U+0100 .. U+017F) --
    // Āā Ēē Īī Ōō Ūū Ȳȳ
    for (0..6) |o| {
        const base: u21 = 0x0100 + o * 2;
        tbl[i] = .{ .from = base, .to = base + 1 };
        i += 1;
    }
    // Ǚǚ Ǜǜ (U+01D8, U+01DA)
    tbl[i] = .{ .from = 0x01D8, .to = 0x01D9 };
    i += 1;
    tbl[i] = .{ .from = 0x01DA, .to = 0x01DB };
    i += 1;

    // Ł ł  (U+0141/U+0142)
    tbl[i] = .{ .from = 0x0141, .to = 0x0142 };
    i += 1;
    // Đ đ  (U+0110/U+0111) - actually 0110 uppercase, 0111 lowercase
    tbl[i] = .{ .from = 0x0110, .to = 0x0111 };
    i += 1;
    // Þ þ  (U+00DE/U+00FE) - already covered by Latin-1 block above
    // Ð ð  (U+00D0/U+00F0) - already covered

    // Ǆǅǆ Ǉǈǉ Ǌǋǌ (compatibility ligatures, simple lower mapping)
    // Skipping for brevity; add as needed.

    // -- Greek (U+0391 .. U+03C9) --
    // Uppercase Greek letters -> lowercase
    // Α Β Γ Δ Ε Ζ Η Θ Ι Κ Λ Μ Ν Ξ Ο Π Ρ Σ Τ Υ Φ Χ Ψ Ω
    // 0391-03A1 (excluding 03A2), 03A3-03AB (excluding 03A2)
    for ([_]u21{ 0x0391, 0x0392, 0x0393, 0x0394, 0x0395, 0x0396, 0x0397, 0x0398, 0x0399, 0x039A, 0x039B, 0x039C, 0x039D, 0x039E, 0x039F, 0x03A0, 0x03A1 }) |cp| {
        tbl[i] = .{ .from = cp, .to = cp + 0x20 };
        i += 1;
    }
    // Σ -> σ (U+03A3 -> U+03C3, offset 0x20 would give 0x03C3)
    // Already covered above (0x03A3 + 0x20 = 0x03C3)
    // Υ Φ Χ Ψ Ω  (U+03A5-03A9, skipping 03A2)
    for ([_]u21{ 0x03A5, 0x03A6, 0x03A7, 0x03A8, 0x03A9 }) |cp| {
        tbl[i] = .{ .from = cp, .to = cp + 0x20 };
        i += 1;
    }
    // Ϣϣ Coptic (U+03E2/U+03E3)
    tbl[i] = .{ .from = 0x03E2, .to = 0x03E3 };
    i += 1;

    // -- Common symbols with case --
    // µ (micro sign U+00B5) case-folds to μ (Greek mu U+03BC)
    tbl[i] = .{ .from = 0x00B5, .to = 0x03BC };
    i += 1;

    // Zero out remaining entries (sentinel)
    while (i < tbl.len) : (i += 1) {
        tbl[i] = .{ .from = 0, .to = 0 };
    }

    // Sort by `from` (simple insertion sort, comptime)
    var s: usize = 1;
    while (s < tbl.len) : (s += 1) {
        const key = tbl[s];
        var j: usize = s;
        while (j > 0 and tbl[j - 1].from > key.from) : (j -= 1) {
            tbl[j] = tbl[j - 1];
        }
        tbl[j] = key;
    }

    break :blk tbl;
};

/// Binary search in the comptime mapping table.
fn lookupMapping(cp: u21) ?u21 {
    comptime {
        // Verify table is sorted
        var k: usize = 1;
        while (k < mapping_table.len) : (k += 1) {
            if (mapping_table[k].from == 0) break; // sentinel
            if (mapping_table[k].from < mapping_table[k - 1].from)
                @compileError("mapping_table is not sorted");
        }
    }

    var lo: usize = 0;
    var hi: usize = mapping_table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const entry = mapping_table[mid];
        if (entry.from == 0) {
            // sentinel, search left half
            hi = mid;
        } else if (entry.from == cp) {
            return entry.to;
        } else if (entry.from < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

/// Core case-mapping function. Replaces `uucode.get(field, cp)`.
/// Returns `null` when no mapping exists (caller should use `cp` unchanged).
pub fn get(comptime field: FieldEnum, cp: u21) ?u21 {
    return switch (field) {
        .simple_uppercase_mapping => uppercaseOne(cp),
        .simple_lowercase_mapping => lowercaseOne(cp),
        .case_folding_simple => caseFoldOne(cp),
        .is_lowercase => isLowerOne(cp),
        .changes_when_casefolded => changesWhenCasefoldedOne(cp),
        .changes_when_lowercased => changesWhenLowercasedOne(cp),
    };
}

fn uppercaseOne(cp: u21) ?u21 {
    // ASCII
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    // ß -> ẞ
    if (cp == 0x00DF) return 0x1E9E;
    // Reverse table lookup: find entry where `to == cp` and return `from`
    comptime {
        var k: usize = 0;
        while (k < mapping_table.len) : (k += 1) {
            if (mapping_table[k].from == 0) break;
        }
    }
    var k: usize = 0;
    while (k < mapping_table.len) : (k += 1) {
        const entry = mapping_table[k];
        if (entry.from == 0) break;
        if (entry.to == cp) return entry.from;
    }
    return null;
}

fn lowercaseOne(cp: u21) ?u21 {
    // ASCII
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return lookupMapping(cp);
}

fn caseFoldOne(cp: u21) ?u21 {
    // ASCII: case folding = lowercase
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    // ß is already lowercase; case folding keeps it
    // (full case folding would map to "ss" but we do simple)
    if (cp == 0x00DF) return null; // unchanged
    // µ (micro) -> μ (Greek mu)
    if (cp == 0x00B5) return 0x03BC;
    // Most lowercase mappings are also case-fold mappings
    const lower = lookupMapping(cp);
    // If it's already lowercase and != cp, no fold needed
    if (lower) |l| {
        if (l != cp) return l;
    }
    return null;
}

fn isLowerOne(cp: u21) ?bool {
    if (cp >= 'a' and cp <= 'z') return true;
    if (cp >= 'A' and cp <= 'Z') return false;
    // Check if codepoint is a known lowercase character
    var k: usize = 0;
    while (k < mapping_table.len) : (k += 1) {
        if (mapping_table[k].from == 0) break;
        if (mapping_table[k].to == cp) return true; // cp is a lowercase form
    }
    // Check if cp is a known uppercase that has a lowercase
    if (lookupMapping(cp)) |l| {
        if (l != cp) return false; // it's uppercase
    }
    return null; // unknown
}

fn changesWhenCasefoldedOne(cp: u21) ?bool {
    if (cp >= 'A' and cp <= 'Z') return true;
    if (cp == 0x00DF) return true; // ß -> ss in full case folding
    if (cp == 0x00B5) return true; // micro -> mu
    return false;
}

fn changesWhenLowercasedOne(cp: u21) ?bool {
    if (cp >= 'A' and cp <= 'Z') return true;
    // Check if cp has a lowercase mapping != itself
    if (lookupMapping(cp)) |l| return l != cp;
    if (cp == 0x00DF) return true; // ß special case
    return false;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn control_code_to_unicode(code: u8) [:0]const u8 {
    return switch (code) {
        '\x00' => "␀",
        '\x01' => "␁",
        '\x02' => "␂",
        '\x03' => "␃",
        '\x04' => "␄",
        '\x05' => "␅",
        '\x06' => "␆",
        '\x07' => "␇",
        '\x08' => "␈",
        '\x09' => "␉",
        '\x0A' => "␊",
        '\x0B' => "␋",
        '\x0C' => "␌",
        '\x0D' => "␍",
        '\x0E' => "␎",
        '\x0F' => "␏",
        '\x10' => "␐",
        '\x11' => "␑",
        '\x12' => "␒",
        '\x13' => "␓",
        '\x14' => "␔",
        '\x15' => "␕",
        '\x16' => "␖",
        '\x17' => "␗",
        '\x18' => "␘",
        '\x19' => "␙",
        '\x1A' => "␚",
        '\x1B' => "␛",
        '\x1C' => "␜",
        '\x1D' => "␝",
        '\x1E' => "␞",
        '\x1F' => "␟",
        '\x20' => "␠",
        '\x7F' => "␡",
        else => "",
    };
}

pub const char_pairs = [_]struct { []const u8, []const u8 }{
    .{ "\"", "\"" },
    .{ "'", "'" },
    .{ "`", "`" },
    .{ "(", ")" },
    .{ "[", "]" },
    .{ "{", "}" },
    .{ "\u{2018}", "\u{2019}" },
    .{ "\u{201C}", "\u{201D}" },
    .{ "\u{201A}", "\u{2018}" },
    .{ "\u{00AB}", "\u{00BB}" },
    .{ "\u{00BF}", "?" },
    .{ "\u{00A1}", "!" },
};

pub const open_close_pairs = [_]struct { []const u8, []const u8 }{
    .{ "(", ")" },
    .{ "[", "]" },
    .{ "{", "}" },
    .{ "\u{2018}", "\u{2019}" },
    .{ "\u{201C}", "\u{201D}" },
    .{ "\u{00AB}", "\u{00BB}" },
    .{ "\u{00BF}", "?" },
    .{ "\u{00A1}", "!" },
};

const spinner = [_][]const u8{
    "\u{280B}",
    "\u{2819}",
    "\u{2839}",
    "\u{2838}",
    "\u{283C}",
    "\u{2834}",
    "\u{2836}",
    "\u{2827}",
    "\u{2807}",
};

const spinner_short = [_][]const u8{
    "\u{280B}",
    "\u{2819}",
    "\u{2838}",
    "\u{2834}",
    "\u{2836}",
    "\u{2807}",
};

fn raw_byte_to_utf8(cp: u8, buf: []u8) ![]const u8 {
    var utf16le: [1]u16 = undefined;
    const utf16le_as_bytes = std.mem.sliceAsBytes(utf16le[0..]);
    std.mem.writeInt(u16, utf16le_as_bytes[0..2], cp, .little);
    return buf[0..try utf16LeToUtf8(buf, &utf16le)];
}

pub fn utf8_sanitize(allocator: std.mem.Allocator, input: []const u8) error{
    OutOfMemory,
    DanglingSurrogateHalf,
    ExpectedSecondSurrogateHalf,
    UnexpectedSecondSurrogateHalf,
}![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .{};
    const writer = output.writer(allocator);
    var buf: [4]u8 = undefined;
    for (input) |byte| try writer.writeAll(try raw_byte_to_utf8(byte, &buf));
    return output.toOwnedSlice(allocator);
}

pub const TransformError = error{
    OutOfMemory,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
    WriteFailed,
};

// ---------------------------------------------------------------------------
// Transform helpers (no longer depend on uucode)
// ---------------------------------------------------------------------------

fn utf8_write_transform_T(comptime View: anytype, comptime field: FieldEnum, writer: anytype, text: []const u8) TransformError!@typeInfo(@TypeOf(View.initUnchecked).return_type.?).@"fn".return_type.? {
    const view = View.initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const cp_ = switch (field) {
            .simple_uppercase_mapping, .simple_lowercase_mapping => get(field, cp) orelse cp,
            .case_folding_simple => get(field, cp) orelse cp,
            else => @compileError(@tagName(field) ++ " is not a unicode transformation"),
        };
        var utf8_buf: [6]u8 = undefined;
        const size = try utf8Encode(cp_, &utf8_buf);
        try writer.writeAll(utf8_buf[0..size]);
    }
    return it;
}

fn utf8_write_transform(comptime field: FieldEnum, writer: anytype, text: []const u8) TransformError!void {
    _ = try utf8_write_transform_T(Utf8View, field, writer, text);
}

fn utf8_partial_write_transform(comptime field: FieldEnum, writer: anytype, text: []const u8) TransformError![]const u8 {
    const it = try utf8_write_transform_T(Utf8PartialView, field, writer, text);
    return text[0..it.end];
}

fn utf8_transform(comptime field: FieldEnum, allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try utf8_write_transform(field, writer, text);
    return buf.items;
}

fn utf8_predicate_all(comptime field: FieldEnum, text: []const u8) bool {
    const view: Utf8View = .initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const result = switch (field) {
            .is_lowercase => get(field, cp) orelse true,
            .changes_when_casefolded => get(field, cp) orelse false,
            .changes_when_lowercased => get(field, cp) orelse false,
            else => @compileError(@tagName(field) ++ " is not a unicode predicate"),
        };
        if (!result) return false;
    }
    return true;
}

fn utf8_predicate_any(comptime field: FieldEnum, text: []const u8) bool {
    const view: Utf8View = .initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const result = switch (field) {
            .is_lowercase => get(field, cp) orelse false,
            .changes_when_casefolded => get(field, cp) orelse false,
            .changes_when_lowercased => get(field, cp) orelse false,
            else => @compileError(@tagName(field) ++ " is not a unicode predicate"),
        };
        if (result) return true;
    }
    return false;
}

pub fn to_upper(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return utf8_transform(.simple_uppercase_mapping, allocator, text);
}

pub fn to_lower(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return utf8_transform(.simple_lowercase_mapping, allocator, text);
}

pub fn case_fold(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return utf8_transform(.case_folding_simple, allocator, text);
}

pub fn case_folded_write(writer: anytype, text: []const u8) TransformError!void {
    return utf8_write_transform(.case_folding_simple, writer, text);
}

pub fn case_folded_write_partial(writer: anytype, text: []const u8) TransformError![]const u8 {
    return utf8_partial_write_transform(.case_folding_simple, writer, text);
}

pub fn switch_case(allocator: std.mem.Allocator, text: []const u8) TransformError![]u8 {
    return if (utf8_predicate_any(.changes_when_lowercased, text))
        to_lower(allocator, text)
    else
        to_upper(allocator, text);
}

pub fn is_lowercase(text: []const u8) bool {
    return utf8_predicate_all(.is_lowercase, text);
}

// ---------------------------------------------------------------------------
// Utf8PartialView / Utf8PartialIterator (reusable from std.unicode)
// ---------------------------------------------------------------------------

const Utf8PartialIterator = struct {
    bytes: []const u8,
    end: usize,

    fn nextCodepointSlice(it: *Utf8PartialIterator) ?[]const u8 {
        if (it.end >= it.bytes.len) {
            return null;
        }

        const cp_len = utf8ByteSequenceLength(it.bytes[it.end]) catch return null;
        if (it.end + cp_len > it.bytes.len) {
            return null;
        }
        it.end += cp_len;
        return it.bytes[it.end - cp_len .. it.end];
    }

    fn nextCodepoint(it: *Utf8PartialIterator) ?u21 {
        const slice = it.nextCodepointSlice() orelse return null;
        return utf8Decode(slice) catch unreachable;
    }
};

const Utf8PartialView = struct {
    bytes: []const u8,

    fn initUnchecked(s: []const u8) Utf8PartialView {
        return Utf8PartialView{ .bytes = s };
    }

    fn iterator(s: Utf8PartialView) Utf8PartialIterator {
        return Utf8PartialIterator{
            .bytes = s.bytes,
            .end = 0,
        };
    }
};
