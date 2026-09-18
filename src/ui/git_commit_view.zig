//! Multi-File-Diff eines Commits wie VS Codes `_workbench.openMultiDiffEditor` (git.viewCommit):
//! Tab „kurz - betreff“, alle geänderten Dateien untereinander, jede mit Kopfzeile (Klappknopf,
//! Name, Ordner, Status R/D/A) und eingebettetem Diff-Editor. Unveränderte Bereiche sind wie in
//! VS Code (diffEditorItemTemplate: hideUnchangedRegions.enabled = true) eingeklappt.
//! Die Dateien laden erst, wenn ihr Abschnitt sichtbar wird.

const std = @import("std");
const clay = @import("clay");
const ui = @import("mod.zig");
const Theme = ui.Theme;
const git_scm = @import("git_scm");
const git_diff = @import("git_diff");
const git_diff_view = @import("git_diff_view.zig");
const svg = @import("components/svg.zig");
const tooltip = @import("components/tooltip.zig");

pub const HEADER_HEIGHT: f32 = 36;
const TOOLBAR_HEIGHT: f32 = 34;

pub const Section = struct {
    view: *git_diff_view.GitDiffView,
    change: git_scm.Change,
    collapsed: bool = false,
    /// Abschnitt war schon einmal sichtbar: Inhalt anfordern
    needed: bool = false,
};

pub const GitCommitView = struct {
    alloc: std.mem.Allocator,
    tab_path: []u8,
    spec: git_scm.CommitSpec,
    title_text: []u8,
    want_changes: bool = true,
    loading: bool = false,
    error_text: ?[]u8 = null,
    changes_text: []u8 = &.{},
    sections: std.ArrayListUnmanaged(Section) = .empty,
    scroll_y: f32 = 0,
    row_height: f32 = 24,
    rendered_rows: usize = 0,

    const Self = @This();

    pub fn create(alloc: std.mem.Allocator, tab_path: []const u8) !*Self {
        const owned = try alloc.dupe(u8, tab_path);
        errdefer alloc.free(owned);
        const spec = git_scm.parseCommitTabPath(owned) orelse return error.InvalidCommitPath;
        const title = try git_scm.commitTitle(alloc, spec.hash, spec.subject);
        errdefer alloc.free(title);
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .tab_path = owned, .spec = spec, .title_text = title };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const alloc = self.alloc;
        for (self.sections.items) |s| s.view.destroy();
        self.sections.deinit(alloc);
        alloc.free(self.changes_text);
        if (self.error_text) |e| alloc.free(e);
        alloc.free(self.title_text);
        alloc.free(self.tab_path);
        alloc.destroy(self);
    }

    pub fn takeChangesRequest(self: *Self) bool {
        if (!self.want_changes) return false;
        self.want_changes = false;
        self.loading = true;
        return true;
    }

    /// Ergebnis von `taskGitCommitChanges`: je Datei ein Abschnitt mit eigenem Diff-Zustand.
    pub fn applyChanges(self: *Self, ok: bool, out: []const u8) !void {
        self.loading = false;
        if (!ok) {
            self.error_text = try self.alloc.dupe(u8, out);
            return;
        }
        self.changes_text = try self.alloc.dupe(u8, out);
        const changes = try git_scm.parseChanges(self.alloc, self.changes_text);
        defer self.alloc.free(changes);
        for (changes) |c| {
            const path = try git_diff.tabPath(self.alloc, .{ .hash = self.spec.hash, .parent = self.spec.parent, .repo = self.spec.repo, .path = c.path, .previous_path = c.old_path });
            defer self.alloc.free(path);
            const view = try git_diff_view.GitDiffView.create(self.alloc, path);
            view.state.collapse_unchanged = true;
            view.state.want_load = false; // erst wenn sichtbar
            try self.sections.append(self.alloc, .{ .view = view, .change = c });
        }
    }

    /// Diff-Ergebnis einer Datei, falls es zu einem Abschnitt gehört.
    pub fn applyFileDiff(self: *Self, key: []const u8, ok: bool, body: []const u8) bool {
        for (self.sections.items) |s| {
            if (std.mem.eql(u8, s.view.state.tab_path, key)) {
                s.view.apply(ok, body) catch {};
                return true;
            }
        }
        return false;
    }

    pub fn sectionSalt(salt: u32, index: usize) u32 {
        return salt +% @as(u32, @truncate(index + 1)) *% 0x9E3779B1;
    }

    fn headerId(salt: u32, index: usize) clay.ElementId {
        return clay.ElementId.IDI("gc_header", sectionSalt(salt, index));
    }

    pub fn bodyId(salt: u32) clay.ElementId {
        return clay.ElementId.IDI("gc_body", salt);
    }

    fn toggleAllId(salt: u32) clay.ElementId {
        return clay.ElementId.IDI("gc_btn_collapse_all", salt);
    }

    fn box(id: clay.ElementId) ?clay.BoundingBox {
        const d = clay.getElementData(id);
        return if (d.found) d.bounding_box else null;
    }

    fn inside(b: clay.BoundingBox, x: f32, y: f32) bool {
        return x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height;
    }

    pub fn allCollapsed(self: *const Self) bool {
        for (self.sections.items) |s| if (!s.collapsed) return false;
        return self.sections.items.len > 0;
    }

    /// „Collapse All Diffs“ / „Expand All Diffs“
    pub fn toggleAll(self: *Self) void {
        const collapse = !self.allCollapsed();
        for (self.sections.items) |*s| s.collapsed = collapse;
    }

    fn sectionHeight(self: *Self, s: *Section, layout: git_diff.Layout) f32 {
        if (s.collapsed) return HEADER_HEIGHT;
        const n = s.view.itemCount(layout);
        return HEADER_HEIGHT + @as(f32, @floatFromInt(@max(n, 1))) * self.row_height;
    }

    pub fn handleMouseDown(self: *Self, x: f32, y: f32, salt: u32) bool {
        if (box(toggleAllId(salt))) |b| if (inside(b, x, y)) {
            self.toggleAll();
            return true;
        };
        const body = box(bodyId(salt)) orelse return false;
        if (!inside(body, x, y)) return false;
        for (self.sections.items, 0..) |*s, i| {
            if (box(headerId(salt, i))) |b| if (inside(b, x, y)) {
                s.collapsed = !s.collapsed;
                return true;
            };
            if (!s.collapsed and s.view.state.loaded and s.view.handleMouseDown(x, y, sectionSalt(salt, i))) return true;
        }
        return true;
    }

    pub fn scrollLines(self: *Self, delta: i32) void {
        self.scroll_y -= @as(f32, @floatFromInt(delta * 3)) * self.row_height;
    }

    pub fn render(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, font_size: u16, mouse_x: f32, mouse_y: f32) void {
        const fs: f32 = @floatFromInt(font_size);
        self.row_height = @ceil(fs * 1.45);
        self.rendered_rows = 0;
        const width = if (box(clay.ElementId.IDI("gc_container", salt))) |b| b.width else 1200;
        const vp = if (box(bodyId(salt))) |b| b.height else 800;
        // Layout wie der einzelne Diff-Editor: nebeneinander ab 900 px
        const layout: git_diff.Layout = if (git_diff.useSideBySide(width)) .side_by_side else .inline_;

        var total: f32 = 0;
        for (self.sections.items) |*s| total += self.sectionHeight(s, layout);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, @max(0, total - vp));

        clay.UI()(.{
            .id = clay.ElementId.IDI("gc_container", salt),
            .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
            .background_color = theme.bg,
        })({
            self.renderToolbar(arena, theme, salt);
            clay.UI()(.{
                .id = bodyId(salt),
                .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
                .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -self.scroll_y } },
            })({
                if (self.error_text) |e| {
                    message(std.fmt.allocPrint(arena, "git: {s}", .{e}) catch "git failed", theme);
                } else if (self.loading or self.want_changes) {
                    message("Loading…", theme);
                } else {
                    self.renderSections(arena, theme, salt, layout, width, fs, vp, mouse_x, mouse_y);
                }
            });
        });
    }

    fn renderToolbar(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32) void {
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(TOOLBAR_HEIGHT) },
                .direction = .left_to_right,
                .child_alignment = .{ .y = .center },
                .child_gap = 8,
                .padding = .{ .left = 12, .right = 8 },
            },
            .border = .{ .width = .{ .bottom = 1 }, .color = theme.border },
        })({
            const n = self.sections.items.len;
            clay.text(std.fmt.allocPrint(arena, "{d} {s} changed", .{ n, if (n == 1) "file" else "files" }) catch "", .{ .font_size = 14, .color = theme.subtext, .wrap_mode = .none });
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            const all_collapsed = self.allCollapsed();
            tooltip.iconButton(arena, theme, toggleAllId(salt), std.fmt.allocPrint(arena, "gc_icon_all_{d}", .{salt}) catch "gc_icon_all", if (all_collapsed) svg.Lucide.unfold_vertical else svg.Lucide.fold_vertical, if (all_collapsed) "Expand All Diffs" else "Collapse All Diffs", .{ .size = 28 });
        });
    }

    fn renderSections(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, layout: git_diff.Layout, width: f32, fs: f32, vp: f32, mouse_x: f32, mouse_y: f32) void {
        var y: f32 = 0;
        var skipped: f32 = 0;
        const top = self.scroll_y - vp;
        const bottom = self.scroll_y + 2 * vp;
        for (self.sections.items, 0..) |*s, i| {
            const h = self.sectionHeight(s, layout);
            defer y += h;
            if (y + h < top or y > bottom) {
                skipped += h;
                continue;
            }
            spacer(skipped);
            skipped = 0;
            s.needed = true;
            self.renderHeader(arena, theme, salt, i, s, mouse_x, mouse_y);
            if (s.collapsed) continue;
            if (!s.view.state.loaded) {
                clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(self.row_height) }, .padding = .{ .left = 16 } } })({
                    clay.text(if (s.view.state.error_text != null) "Could not load diff" else "Loading…", .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
                });
                continue;
            }
            // nur die sichtbaren Zeilen des Abschnitts zeichnen
            const count = s.view.itemCount(layout);
            const body_top = y + HEADER_HEIGHT;
            const first: usize = @intFromFloat(@max(0, @floor((top - body_top) / self.row_height)));
            const end: usize = @min(count, @as(usize, @intFromFloat(@max(0, @ceil((bottom - body_top) / self.row_height)))));
            const f = @min(first, end);
            spacer(@as(f32, @floatFromInt(f)) * self.row_height);
            s.view.renderItems(arena, theme, sectionSalt(salt, i), layout, width, fs, f, end);
            self.rendered_rows += end - f;
            spacer(@as(f32, @floatFromInt(count - end)) * self.row_height);
        }
        spacer(skipped);
    }

    fn renderHeader(self: *Self, arena: std.mem.Allocator, theme: Theme, salt: u32, index: usize, s: *Section, mouse_x: f32, mouse_y: f32) void {
        _ = self;
        const id = headerId(salt, index);
        const hovered = if (box(id)) |b| inside(b, mouse_x, mouse_y) else false;
        const c = s.change;
        const name = std.fs.path.basename(c.path);
        const dir = std.fs.path.dirname(c.path) orelse "";
        clay.UI()(.{
            .id = id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(HEADER_HEIGHT) },
                .direction = .left_to_right,
                .child_alignment = .{ .y = .center },
                .child_gap = 8,
                .padding = .{ .left = 8, .right = 12 },
            },
            .background_color = if (hovered) tint(theme.text, 18) else theme.surface,
            .border = .{ .width = .{ .top = 1, .bottom = 1 }, .color = theme.border },
        })({
            svg.Svg(arena, std.fmt.allocPrint(arena, "gc_chev_{d}_{d}", .{ salt, index }) catch "gc_chev", if (s.collapsed) svg.Lucide.chevron_right else svg.Lucide.chevron_down, 16, theme.subtext);
            clay.text(name, .{ .font_size = 16, .color = if (c.status == .deleted) theme.muted else theme.text, .wrap_mode = .none });
            if (dir.len > 0) clay.text(dir, .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
            if (c.status == .renamed) {
                clay.text(std.fmt.allocPrint(arena, "\u{2190} {s}", .{c.old_path}) catch "", .{ .font_size = 14, .color = theme.muted, .wrap_mode = .none });
            }
            clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow } } })({});
            // VS Code zeigt nur R, D und A; geänderte Dateien ohne Buchstaben
            if (c.status != .modified) {
                var letter_buf: [1]u8 = .{c.status.letter()};
                clay.text(arena.dupe(u8, &letter_buf) catch "", .{ .font_size = 15, .color = statusColor(theme, c.status), .wrap_mode = .none });
            }
        });
    }
};

/// Farben wie VS Code gitDecoration.*ResourceForeground (dunkles Theme).
pub fn statusColor(theme: Theme, status: git_scm.ChangeStatus) clay.Color {
    const light = theme.bg[0] > 128;
    return switch (status) {
        .modified => if (light) .{ 0x89, 0x55, 0x03, 255 } else .{ 0xE2, 0xC0, 0x8D, 255 },
        .added => if (light) .{ 0x58, 0x7c, 0x0c, 255 } else .{ 0x81, 0xb8, 0x8b, 255 },
        .deleted => if (light) .{ 0xad, 0x07, 0x07, 255 } else .{ 0xc7, 0x4e, 0x39, 255 },
        .renamed, .copied => if (light) .{ 0x00, 0x71, 0x00, 255 } else .{ 0x73, 0xC9, 0x91, 255 },
    };
}

fn tint(c: clay.Color, alpha: f32) clay.Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn spacer(height: f32) void {
    if (height <= 0) return;
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(height) } } })({});
}

fn message(text: []const u8, theme: Theme) void {
    clay.UI()(.{ .layout = .{ .sizing = .{ .w = .grow }, .padding = .all(16) } })({
        clay.text(text, .{ .font_size = 16, .color = theme.muted, .wrap_mode = .words });
    });
}
