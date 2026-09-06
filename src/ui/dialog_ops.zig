//! Tastaturlogik für modale Dialoge (ohne Clay/wio, unit-getestet).
//!
//! Enter wählt den fokussierten Button, Escape den Cancel-Button (sonst den letzten),
//! Tab/Shift+Tab wandern, ein Buchstabe wählt den Button mit diesem Anfangsbuchstaben
//! („d“ = Delete, „s“ = Save, „n“ = No). Fokus startet auf dem ersten (primären) Button.

const std = @import("std");

pub const Key = enum { enter, escape, tab, shift_tab, letter };

pub const Outcome = union(enum) {
    none,
    focus: usize,
    choose: usize,
};

pub fn handleKey(labels: []const []const u8, focused: usize, key: Key, letter: u8) Outcome {
    const n = labels.len;
    if (n == 0) return .none;
    const cur = if (focused < n) focused else 0;
    switch (key) {
        .enter => return .{ .choose = cur },
        .escape => {
            for (labels, 0..) |l, i| {
                if (std.ascii.eqlIgnoreCase(l, "cancel")) return .{ .choose = i };
            }
            return .{ .choose = n - 1 };
        },
        .tab => return .{ .focus = (cur + 1) % n },
        .shift_tab => return .{ .focus = (cur + n - 1) % n },
        .letter => {
            for (labels, 0..) |l, i| {
                if (l.len > 0 and std.ascii.toLower(l[0]) == std.ascii.toLower(letter)) return .{ .choose = i };
            }
            return .none;
        },
    }
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;
const delete_labels = [_][]const u8{ "Delete", "Cancel" };
const save_labels = [_][]const u8{ "Save", "Don't Save", "Cancel" };

test "Enter wählt den fokussierten Button" {
    try testing.expectEqual(Outcome{ .choose = 0 }, handleKey(&delete_labels, 0, .enter, 0));
    try testing.expectEqual(Outcome{ .choose = 1 }, handleKey(&delete_labels, 1, .enter, 0));
}

test "Escape wählt Cancel, egal wo der Fokus steht; ohne Cancel den letzten" {
    try testing.expectEqual(Outcome{ .choose = 2 }, handleKey(&save_labels, 0, .escape, 0));
    const no_cancel = [_][]const u8{ "Allow", "Deny" };
    try testing.expectEqual(Outcome{ .choose = 1 }, handleKey(&no_cancel, 0, .escape, 0));
}

test "Tab und Shift+Tab wandern zyklisch" {
    try testing.expectEqual(Outcome{ .focus = 1 }, handleKey(&save_labels, 0, .tab, 0));
    try testing.expectEqual(Outcome{ .focus = 0 }, handleKey(&save_labels, 2, .tab, 0));
    try testing.expectEqual(Outcome{ .focus = 2 }, handleKey(&save_labels, 0, .shift_tab, 0));
}

test "Buchstabe wählt den Button mit diesem Anfangsbuchstaben" {
    try testing.expectEqual(Outcome{ .choose = 0 }, handleKey(&delete_labels, 1, .letter, 'd'));
    try testing.expectEqual(Outcome{ .choose = 1 }, handleKey(&delete_labels, 0, .letter, 'c'));
    try testing.expectEqual(Outcome{ .choose = 0 }, handleKey(&save_labels, 2, .letter, 's'));
    try testing.expectEqual(Outcome{ .choose = 1 }, handleKey(&save_labels, 2, .letter, 'd'));
    try testing.expectEqual(Outcome.none, handleKey(&save_labels, 0, .letter, 'x'));
}

test "leere Aktionsliste ist harmlos" {
    const none = [_][]const u8{};
    try testing.expectEqual(Outcome.none, handleKey(&none, 0, .enter, 0));
    try testing.expectEqual(Outcome.none, handleKey(&none, 0, .tab, 0));
}
