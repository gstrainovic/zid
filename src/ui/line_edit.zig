//! Einzeiliges Editierfeld: gemeinsame Tasten-, Klick- und Zeichenlogik für
//! alle `explorer_ops.EditBuffer`-Felder (Explorer-Umbenennen/-Anlegen/-Filter,
//! Pfad im Ordner-Dialog, Suchzeile im Picker, Commit-Nachricht). Der Aufrufer
//! zeichnet den Rahmen selbst und ruft darin `render` auf; `handleClick` misst am
//! selben Textelement, deshalb spielt der Innenabstand des Rahmens keine Rolle.
//!
//! Auswahl wie im Editor: Shift+Pfeile/Pos1/Ende erweitern, Ctrl+←/→ springen
//! wortweise, Ctrl+A markiert alles, Ctrl+C/X/V über die `Clipboard`-Schnittstelle
//! der UI, Ziehen mit gedrückter Maustaste (`handleDrag`). Tippen, Backspace und
//! Entf ersetzen bzw. löschen die Auswahl (im `EditBuffer`).

const std = @import("std");
const clay = @import("clay");
const wio = @import("wio");
const ui = @import("mod.zig");
const Theme = @import("theme.zig").Theme;

/// Feste Eigenschaften eines Felds: Clay-ID des Textelements und Schriftgröße.
pub const Config = struct {
    id: []const u8,
    font_size: f32,
};

/// Gehaltene Modifier beim Tastendruck.
pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
};

/// Zwischenablage der UI (Fenster oder headless-Merker), als Schnittstelle, damit die
/// Felder kein `UI` kennen müssen. `paste` liefert eine Kopie (Aufrufer gibt frei).
pub const Clipboard = struct {
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    copyFn: *const fn (ctx: *anyopaque, text: []const u8) void,
    pasteFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8,

    pub fn copy(self: Clipboard, text: []const u8) void {
        if (text.len > 0) self.copyFn(self.ctx, text);
    }

    pub fn paste(self: Clipboard) ?[]u8 {
        return self.pasteFn(self.ctx, self.allocator);
    }
};

/// Ergebnis von `handleKey`: Text geändert (Backspace/Entf/Ausschneiden/Einfügen),
/// nur Cursor oder Auswahl bewegt (Pfeile, Pos1, Ende, Ctrl+A, Ctrl+C) oder Taste
/// nicht für das Feld bestimmt.
pub const KeyResult = enum { edited, moved, ignored };

/// Tasten eines Felds. `multiline` erlaubt Zeilenumbrüche beim Einfügen (Commit-Nachricht).
pub fn handleKeyEx(edit: anytype, key: wio.Button, mods: Mods, clip: ?Clipboard, multiline: bool) KeyResult {
    if (mods.ctrl) switch (key) {
        .a => {
            edit.selectAll();
            return .moved;
        },
        .c => {
            if (clip) |c| c.copy(edit.selectedText());
            return .moved;
        },
        .x => {
            const c = clip orelse return .moved;
            if (!edit.hasSelection()) return .moved;
            c.copy(edit.selectedText());
            _ = edit.deleteSelection();
            return .edited;
        },
        .v => {
            const c = clip orelse return .moved;
            const text = c.paste() orelse return .moved;
            defer c.allocator.free(text);
            edit.insertText(text, multiline);
            return .edited;
        },
        // Ctrl+Z zurück, Ctrl+Shift+Z und Ctrl+Y wieder vor — ein Schritt, wie im
        // Namens- und Pfadfeld üblich (`EditBuffer.undoEdit`).
        .z => return if (mods.shift)
            (if (edit.redoEdit()) .edited else .moved)
        else
            (if (edit.undoEdit()) .edited else .moved),
        .y => return if (edit.redoEdit()) .edited else .moved,
        else => {},
    };
    switch (key) {
        .backspace => edit.backspace(),
        .delete => edit.delete(),
        .left => {
            edit.prepareMove(mods.shift);
            if (mods.ctrl) edit.moveWordLeft() else edit.moveLeft();
        },
        .right => {
            edit.prepareMove(mods.shift);
            if (mods.ctrl) edit.moveWordRight() else edit.moveRight();
        },
        .home => {
            edit.prepareMove(mods.shift);
            edit.moveHome();
        },
        .end => {
            edit.prepareMove(mods.shift);
            edit.moveEnd();
        },
        else => return .ignored,
    }
    return switch (key) {
        .backspace, .delete => .edited,
        else => .moved,
    };
}

/// Einzeiliges Feld (kein Umbruch beim Einfügen).
pub fn handleKey(edit: anytype, key: wio.Button, mods: Mods, clip: ?Clipboard) KeyResult {
    return handleKeyEx(edit, key, mods, clip, false);
}

/// Klick ins Feld: Cursor an die Mausposition `x` (Fensterkoordinate); mit `extend`
/// (Shift) wird bis dorthin markiert. Beginnt das Ziehen (`handleDrag`).
/// False, wenn die Maus nicht über dem Textelement steht.
pub fn handleClick(edit: anytype, comptime cfg: Config, x: f32, extend: bool) bool {
    const id = clay.ElementId.ID(cfg.id);
    if (!clay.pointerOver(id)) return false;
    const data = clay.getElementData(id);
    if (!data.found) return false;
    edit.prepareMove(extend);
    edit.setCursorAtX(ui.measureTextWidth, cfg.font_size, x - data.bounding_box.x);

    // Doppelklick markiert das Wort. Die Zeit kommt direkt von der Uhr, damit die
    // Aufrufer (Explorer, Picker, Ordner-Dialog) keine Uhr durchreichen müssen.
    const now = std.time.milliTimestamp();
    const quick = now - edit.last_click_ms < 500;
    if (quick and edit.last_click_cursor == edit.cursor and !extend) {
        edit.selectWordAtCursor();
        edit.last_click_ms = 0;
    } else {
        edit.last_click_ms = now;
        edit.last_click_cursor = edit.cursor;
    }
    edit.mouse_selecting = true;
    return true;
}

/// Maus mit gedrückter Taste bewegt: Auswahl bis zur Position ziehen (auch außerhalb des
/// Textelements, damit die Auswahl bis zum Anfang/Ende reicht).
pub fn handleDrag(edit: anytype, comptime cfg: Config, x: f32) void {
    if (!edit.mouse_selecting) return;
    const data = clay.getElementData(clay.ElementId.ID(cfg.id));
    if (!data.found) return;
    edit.prepareMove(true);
    edit.setCursorAtX(ui.measureTextWidth, cfg.font_size, x - data.bounding_box.x);
}

/// Maustaste losgelassen: Ziehen beendet.
pub fn handleRelease(edit: anytype) void {
    edit.mouse_selecting = false;
}

/// Farbe der Markierung (Primärfarbe, durchscheinend über dem Text).
pub fn selectionColor(theme: Theme) clay.Color {
    return .{ theme.primary[0], theme.primary[1], theme.primary[2], 90 };
}

/// Text plus Cursorstrich als eigenes Element (füllt die Breite des Rahmens,
/// damit Klicks rechts vom Text den Cursor ans Ende setzen). Der Strich ist
/// ein Rechteck an der gemessenen Textbreite, wie im Editor, statt eines
/// eingefügten "|"-Zeichens, das den Text hinter dem Cursor verschieben würde.
/// Die Markierung ist ein durchscheinendes Rechteck über dem markierten Teil.
pub fn render(edit: anytype, comptime cfg: Config, color: clay.Color, show_caret: bool, theme: Theme) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(cfg.id),
        .layout = .{ .sizing = .{ .w = .grow, .h = .fit }, .child_alignment = .{ .y = .center } },
    })({
        clay.text(edit.text(), .{ .font_size = cfg.font_size, .color = color, .wrap_mode = .none });
        // Kein `return` im Block: der Block ist das Argument des schließenden Aufrufs,
        // ein return würde ihn überspringen und das Clay-Layout offen lassen.
        if (edit.selection()) |sel| {
            const x0 = ui.measureTextWidth(edit.text()[0..sel.start], cfg.font_size);
            const x1 = ui.measureTextWidth(edit.text()[0..sel.end], cfg.font_size);
            clay.UI()(.{
                .id = clay.ElementId.ID(cfg.id ++ "_sel"),
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_center, .parent = .left_center },
                    .offset = .{ .x = x0, .y = 0 },
                    .z_index = 9,
                    .pointer_capture_mode = .passthrough,
                },
                .layout = .{ .sizing = .{ .w = .fixed(@max(1, x1 - x0)), .h = .fixed(cfg.font_size + 4) } },
                .background_color = selectionColor(theme),
            })({});
        }
        if (show_caret) {
            clay.UI()(.{
                .id = clay.ElementId.ID(cfg.id ++ "_caret"),
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_center, .parent = .left_center },
                    .offset = .{ .x = ui.measureTextWidth(edit.textBeforeCursor(), cfg.font_size), .y = 0 },
                    .z_index = 10,
                    .pointer_capture_mode = .passthrough,
                },
                .layout = .{ .sizing = .{ .w = .fixed(2), .h = .fixed(cfg.font_size) } },
                .background_color = theme.text,
            })({});
        }
    });
}
