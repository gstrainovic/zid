//! Verzögerter Hover für Tooltips (ohne Clay): welches Element die Maus gerade überfährt und
//! seit wann. Ein Tooltip erscheint, wenn dasselbe Element `delay_ms` lang überfahren wird;
//! wechselt das Element oder verlässt die Maus es, beginnt die Zeit neu.

const std = @import("std");
const testing = std.testing;

pub const Hover = struct {
    /// Clay-ID (`ElementId.id`) des überfahrenen Elements, 0 = keins
    id: u32 = 0,
    since_ms: f32 = 0,
    /// In diesem Frame per `note` bestätigt
    seen: bool = false,

    pub fn beginFrame(self: *Hover) void {
        self.seen = false;
    }

    /// Element `id` wird gerade überfahren (aus dem Zeichnen heraus melden).
    pub fn note(self: *Hover, id: u32, now_ms: f32) void {
        if (self.id != id) {
            self.id = id;
            self.since_ms = now_ms;
        }
        self.seen = true;
    }

    /// Ohne `note` in diesem Frame hat die Maus das Element verlassen.
    pub fn endFrame(self: *Hover) void {
        if (!self.seen) self.id = 0;
    }

    pub fn current(self: *const Hover) ?u32 {
        return if (self.id == 0) null else self.id;
    }

    pub fn visible(self: *const Hover, id: u32, now_ms: f32, delay_ms: f32) bool {
        return self.id == id and self.id != 0 and now_ms - self.since_ms >= delay_ms;
    }
};

test "Hover: erst nach der Verzögerung sichtbar, Wechsel und Verlassen setzen zurück" {
    var h = Hover{};
    // Frame 1: Element 7 überfahren
    h.beginFrame();
    h.note(7, 0);
    h.endFrame();
    try testing.expect(!h.visible(7, 100, 700));
    // Frame 2 nach 800 ms: sichtbar, aber nur für 7
    h.beginFrame();
    h.note(7, 800);
    h.endFrame();
    try testing.expect(h.visible(7, 800, 700));
    try testing.expect(!h.visible(8, 800, 700));
    try testing.expectEqual(@as(?u32, 7), h.current());
    // Wechsel auf 8: Zeit beginnt neu
    h.beginFrame();
    h.note(8, 900);
    h.endFrame();
    try testing.expect(!h.visible(8, 900, 700));
    try testing.expect(!h.visible(7, 2000, 700));
    try testing.expect(h.visible(8, 1700, 700));
    // Frame ohne note: Maus hat das Element verlassen
    h.beginFrame();
    h.endFrame();
    try testing.expect(h.current() == null);
    try testing.expect(!h.visible(8, 5000, 700));
    // Zurückkommen: wieder warten
    h.beginFrame();
    h.note(8, 5000);
    h.endFrame();
    try testing.expect(!h.visible(8, 5100, 700));
}
