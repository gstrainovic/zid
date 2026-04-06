/// vkvg Bindings für Zig
/// Vulkan-basierte 2D Graphics Library (Cairo-ähnliche API)

const std = @import("std");
const c = @cImport({
    @cInclude("vkvg.h");
});

pub const Context = opaque {};
pub const Surface = opaque {};
pub const Device = opaque {};

pub const Status = enum(c_int) {
    success = c.VKVG_STATUS_SUCCESS,
    no_memory = c.VKVG_STATUS_NO_MEMORY,
    invalid_status = c.VKVG_STATUS_INVALID_STATUS,
    invalid_matrix = c.VKVG_STATUS_INVALID_MATRIX,
    invalid_surface = c.VKVG_STATUS_INVALID_SURFACE,
    invalid_context = c.VKVG_STATUS_INVALID_CONTEXT,
    invalid_rect = c.VKVG_STATUS_INVALID_RECT,
    invalid_path = c.VKVG_STATUS_INVALID_PATH,
    invalid_string = c.VKVG_STATUS_INVALID_STRING,
    file_not_found = c.VKVG_STATUS_FILE_NOT_FOUND,
};

pub const LineCap = enum(c_int) {
    butt = c.VKVG_LINE_CAP_BUTT,
    round = c.VKVG_LINE_CAP_ROUND,
    square = c.VKVG_LINE_CAP_SQUARE,
};

pub const LineJoin = enum(c_int) {
    miter = c.VKVG_LINE_JOIN_MITER,
    round = c.VKVG_LINE_JOIN_ROUND,
    bevel = c.VKVG_LINE_JOIN_BEVEL,
};

pub const FillRule = enum(c_int) {
    winding = c.VKVG_FILL_RULE_WINDING,
    even_odd = c.VKVG_FILL_RULE_EVEN_ODD,
};

pub const PatternType = enum(c_int) {
    solid = c.VKVG_PATTERN_TYPE_SOLID,
    surface = c.VKVG_PATTERN_TYPE_SURFACE,
    linear = c.VKVG_PATTERN_TYPE_LINEAR,
    radial = c.VKVG_PATTERN_TYPE_RADIAL,
};

pub const FontSlant = enum(c_int) {
    normal = c.VKVG_FONT_SLANT_NORMAL,
    italic = c.VKVG_FONT_SLANT_ITALIC,
    oblique = c.VKVG_FONT_SLANT_OBLIQUE,
};

pub const FontWeight = enum(c_int) {
    normal = c.VKVG_FONT_WEIGHT_NORMAL,
    bold = c.VKVG_FONT_WEIGHT_BOLD,
};

pub const TextExtents = extern struct {
    x_bearing: f64,
    y_bearing: f64,
    width: f64,
    height: f64,
    x_advance: f64,
    y_advance: f64,
};

pub const FontExtents = extern struct {
    ascent: f64,
    descent: f64,
    height: f64,
    max_x_advance: f64,
    max_y_advance: f64,
};

pub const Rectangle = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const Point = extern struct {
    x: f64,
    y: f64,
};

pub const Matrix = extern struct {
    xx: f64,
    xy: f64,
    yx: f64,
    yy: f64,
    x0: f64,
    y0: f64,
};

// =============================================================================
// Device
// =============================================================================

pub fn deviceCreate(physical_device: anytype, device: anytype, queue: anytype, queue_family_index: u32) ?*Device {
    return @ptrCast(c.vkvg_device_create(@ptrCast(physical_device), @ptrCast(device), @ptrCast(queue), queue_family_index));
}

pub fn deviceDestroy(dev: ?*Device) void {
    c.vkvg_device_destroy(@ptrCast(dev));
}

pub fn deviceGetVkDevice(dev: ?*Device) anytype {
    return c.vkvg_device_get_vk_device(@ptrCast(dev));
}

pub fn deviceGetVkInstance(dev: ?*Device) anytype {
    return c.vkvg_device_get_vk_instance(@ptrCast(dev));
}

pub fn deviceWaitIdle(dev: ?*Device) void {
    c.vkvg_device_wait_idle(@ptrCast(dev));
}

// =============================================================================
// Surface
// =============================================================================

pub fn surfaceCreate(dev: ?*Device, width: u32, height: u32) ?*Surface {
    return @ptrCast(c.vkvg_surface_create(@ptrCast(dev), width, height));
}

pub fn surfaceCreateForVulkanImage(dev: ?*Device, vk_image: anytype, width: u32, height: u32) ?*Surface {
    return @ptrCast(c.vkvg_surface_create_for_vk_image(@ptrCast(dev), vk_image, width, height));
}

pub fn surfaceCreateFromPng(dev: ?*Device, path: [*:0]const u8) ?*Surface {
    return @ptrCast(c.vkvg_surface_create_from_png(@ptrCast(dev), path));
}

pub fn surfaceCreateFromSvg(dev: ?*Device, path: [*:0]const u8) ?*Surface {
    return @ptrCast(c.vkvg_surface_create_from_svg(@ptrCast(dev), path));
}

pub fn surfaceCreateForImage(dev: ?*Device, img: ?*Image) ?*Surface {
    return @ptrCast(c.vkvg_surface_create_for_image(@ptrCast(dev), @ptrCast(img)));
}

pub fn surfaceReference(ctx: ?*Context) ?*Surface {
    return @ptrCast(c.vkvg_surface_reference(@ptrCast(ctx)));
}

pub fn surfaceDestroy(surf: ?*Surface) void {
    c.vkvg_surface_destroy(@ptrCast(surf));
}

pub fn surfaceGetWidth(surf: ?*Surface) u32 {
    return c.vkvg_surface_get_width(@ptrCast(surf));
}

pub fn surfaceGetHeight(surf: ?*Surface) u32 {
    return c.vkvg_surface_get_height(@ptrCast(surf));
}

pub fn surfaceFlush(surf: ?*Surface) void {
    c.vkvg_surface_flush(@ptrCast(surf));
}

pub fn surfaceWriteToPng(surf: ?*Surface, path: [*:0]const u8) void {
    c.vkvg_surface_write_to_png(@ptrCast(surf), path);
}

pub fn surfaceGetVkImage(surf: ?*Surface) anytype {
    return c.vkvg_surface_get_vk_image(@ptrCast(surf));
}

pub fn surfaceGetContent(surf: ?*Surface) c_int {
    return c.vkvg_surface_get_content(@ptrCast(surf));
}

// =============================================================================
// Image
// =============================================================================

pub const Image = opaque {};

pub fn imageCreateFromPng(dev: ?*Device, path: [*:0]const u8) ?*Image {
    return @ptrCast(c.vkvg_image_create_from_png(@ptrCast(dev), path));
}

pub fn imageCreateFromPngData(dev: ?*Device, data: [*]const u8, size: usize) ?*Image {
    return @ptrCast(c.vkvg_image_create_from_png_data(@ptrCast(dev), data, size));
}

pub fn imageDestroy(img: ?*Image) void {
    c.vkvg_image_destroy(@ptrCast(img));
}

pub fn imageGetWidth(img: ?*Image) u32 {
    return c.vkvg_image_get_width(@ptrCast(img));
}

pub fn imageGetHeight(img: ?*Image) u32 {
    return c.vkvg_image_get_height(@ptrCast(img));
}

pub fn imageGetStride(img: ?*Image) i32 {
    return c.vkvg_image_get_stride(@ptrCast(img));
}

pub fn imageReference(img: ?*Image) ?*Image {
    return @ptrCast(c.vkvg_image_reference(@ptrCast(img)));
}

pub fn imageGetUserData(img: ?*Image) ?*anyopaque {
    return c.vkvg_image_get_user_data(@ptrCast(img));
}

pub fn imageSetUserData(img: ?*Image, key: ?*const anyopaque, user_data: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.C) void) c_int {
    return c.vkvg_image_set_user_data(@ptrCast(img), key, user_data, destroy);
}

pub fn imageGetMimeType(img: ?*Image) ?[*:0]const u8 {
    return c.vkvg_image_get_mime_type(@ptrCast(img));
}

// =============================================================================
// Context
// =============================================================================

pub fn contextCreate(surf: ?*Surface) ?*Context {
    return @ptrCast(c.vkvg_context_create(@ptrCast(surf)));
}

pub fn contextReference(ctx: ?*Context) ?*Context {
    return @ptrCast(c.vkvg_context_reference(@ptrCast(ctx)));
}

pub fn contextDestroy(ctx: ?*Context) void {
    c.vkvg_context_destroy(@ptrCast(ctx));
}

pub fn contextGetDevice(ctx: ?*Context) ?*Device {
    return @ptrCast(c.vkvg_context_get_device(@ptrCast(ctx)));
}

pub fn contextGetTarget(ctx: ?*Context) ?*Surface {
    return @ptrCast(c.vkvg_context_get_target(@ptrCast(ctx)));
}

// =============================================================================
// Drawing Operations
// =============================================================================

pub fn save(ctx: ?*Context) void {
    c.vkvg_save(@ptrCast(ctx));
}

pub fn restore(ctx: ?*Context) void {
    c.vkvg_restore(@ptrCast(ctx));
}

pub fn pushGroup(ctx: ?*Context) void {
    c.vkvg_push_group(@ptrCast(ctx));
}

pub fn pushGroupWithContent(ctx: ?*Context, content: c_int) void {
    c.vkvg_push_group_with_content(@ptrCast(ctx), content);
}

pub fn popGroup(ctx: ?*Context) ?*Pattern {
    return @ptrCast(c.vkvg_pop_group(@ptrCast(ctx)));
}

pub fn popGroupToSource(ctx: ?*Context) void {
    c.vkvg_pop_group_to_source(@ptrCast(ctx));
}

// =============================================================================
// Path Operations
// =============================================================================

pub fn newPath(ctx: ?*Context) void {
    c.vkvg_new_path(@ptrCast(ctx));
}

pub fn closePath(ctx: ?*Context) void {
    c.vkvg_close_path(@ptrCast(ctx));
}

pub fn arc(ctx: ?*Context, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) void {
    c.vkvg_arc(@ptrCast(ctx), xc, yc, radius, angle1, angle2);
}

pub fn arcNegative(ctx: ?*Context, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) void {
    c.vkvg_arc_negative(@ptrCast(ctx), xc, yc, radius, angle1, angle2);
}

pub fn curveTo(ctx: ?*Context, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) void {
    c.vkvg_curve_to(@ptrCast(ctx), x1, y1, x2, y2, x3, y3);
}

pub fn lineTo(ctx: ?*Context, x: f64, y: f64) void {
    c.vkvg_line_to(@ptrCast(ctx), x, y);
}

pub fn moveTo(ctx: ?*Context, x: f64, y: f64) void {
    c.vkvg_move_to(@ptrCast(ctx), x, y);
}

pub fn rectangle(ctx: ?*Context, x: f64, y: f64, width: f64, height: f64) void {
    c.vkvg_rectangle(@ptrCast(ctx), x, y, width, height);
}

pub fn relCurveTo(ctx: ?*Context, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) void {
    c.vkvg_rel_curve_to(@ptrCast(ctx), dx1, dy1, dx2, dy2, dx3, dy3);
}

pub fn relLineTo(ctx: ?*Context, dx: f64, dy: f64) void {
    c.vkvg_rel_line_to(@ptrCast(ctx), dx, dy);
}

pub fn relMoveTo(ctx: ?*Context, dx: f64, dy: f64) void {
    c.vkvg_rel_move_to(@ptrCast(ctx), dx, dy);
}

pub fn textPath(ctx: ?*Context, utf8: [*:0]const u8) void {
    c.vkvg_text_path(@ptrCast(ctx), utf8);
}

pub fn glyphPath(ctx: ?*Context, glyphs: [*]c.vkvg_glyph_info_t, num_glyphs: usize) void {
    c.vkvg_glyph_path(@ptrCast(ctx), glyphs, num_glyphs);
}

// =============================================================================
// Painting
// =============================================================================

pub fn fill(ctx: ?*Context) void {
    c.vkvg_fill(@ptrCast(ctx));
}

pub fn fillPreserve(ctx: ?*Context) void {
    c.vkvg_fill_preserve(@ptrCast(ctx));
}

pub fn stroke(ctx: ?*Context) void {
    c.vkvg_stroke(@ptrCast(ctx));
}

pub fn strokePreserve(ctx: ?*Context) void {
    c.vkvg_stroke_preserve(@ptrCast(ctx));
}

pub fn copyPage(ctx: ?*Context) void {
    c.vkvg_copy_page(@ptrCast(ctx));
}

pub fn showPage(ctx: ?*Context) void {
    c.vkvg_show_page(@ptrCast(ctx));
}

pub fn inFill(ctx: ?*Context, x: f64, y: f64) bool {
    return c.vkvg_in_fill(@ptrCast(ctx), x, y) != 0;
}

pub fn inStroke(ctx: ?*Context, x: f64, y: f64) bool {
    return c.vkvg_in_stroke(@ptrCast(ctx), x, y) != 0;
}

pub fn inClip(ctx: ?*Context, x: f64, y: f64) bool {
    return c.vkvg_in_clip(@ptrCast(ctx), x, y) != 0;
}

// =============================================================================
// Clipping
// =============================================================================

pub fn clip(ctx: ?*Context) void {
    c.vkvg_clip(@ptrCast(ctx));
}

pub fn clipPreserve(ctx: ?*Context) void {
    c.vkvg_clip_preserve(@ptrCast(ctx));
}

pub fn clipExtents(ctx: ?*Context, extents: *Rectangle) void {
    c.vkvg_clip_extents(@ptrCast(ctx), @ptrCast(extents));
}

pub fn inClip(ctx2: ?*Context, x: f64, y: f64) bool {
    return c.vkvg_in_clip(@ptrCast(ctx2), x, y) != 0;
}

pub fn resetClip(ctx: ?*Context) void {
    c.vkvg_reset_clip(@ptrCast(ctx));
}

// =============================================================================
// Fonts
// =============================================================================

pub fn selectFontFace(ctx: ?*Context, family: [*:0]const u8, slant: FontSlant, weight: FontWeight) void {
    c.vkvg_select_font_face(@ptrCast(ctx), family, @intFromEnum(slant), @intFromEnum(weight));
}

pub fn setFontSize(ctx: ?*Context, size: f64) void {
    c.vkvg_set_font_size(@ptrCast(ctx), size);
}

pub fn setFontMatrix(ctx: ?*Context, matrix: *Matrix) void {
    c.vkvg_set_font_matrix(@ptrCast(ctx), @ptrCast(matrix));
}

pub fn getFontMatrix(ctx: ?*Context, matrix: *Matrix) void {
    c.vkvg_get_font_matrix(@ptrCast(ctx), @ptrCast(matrix));
}

pub fn textExtents(ctx: ?*Context, utf8: [*:0]const u8, extents: *TextExtents) void {
    c.vkvg_text_extents(@ptrCast(ctx), utf8, @ptrCast(extents));
}

pub fn glyphExtents(ctx: ?*Context, glyphs: [*]c.vkvg_glyph_info_t, num_glyphs: usize, extents: *TextExtents) void {
    c.vkvg_glyph_extents(@ptrCast(ctx), glyphs, num_glyphs, @ptrCast(extents));
}

pub fn fontExtents(ctx: ?*Context, extents: *FontExtents) void {
    c.vkvg_font_extents(@ptrCast(ctx), @ptrCast(extents));
}

pub fn setFont(ctx: ?*Context, font: ?*anyopaque) void {
    c.vkvg_set_font(@ptrCast(ctx), font);
}

pub fn getFont(ctx: ?*Context) ?*anyopaque {
    return c.vkvg_get_font(@ptrCast(ctx));
}

pub fn showText(ctx: ?*Context, utf8: [*:0]const u8) void {
    c.vkvg_show_text(@ptrCast(ctx), utf8);
}

pub fn showGlyphs(ctx: ?*Context, glyphs: [*]c.vkvg_glyph_info_t, num_glyphs: usize) void {
    c.vkvg_show_glyphs(@ptrCast(ctx), glyphs, num_glyphs);
}

pub fn showTextGlyphs(ctx: ?*Context, utf8: [*:0]const u8, glyphs: [*]c.vkvg_glyph_info_t, num_glyphs: usize) void {
    c.vkvg_show_text_glyphs(@ptrCast(ctx), utf8, glyphs, num_glyphs);
}

// =============================================================================
// Transformations
// =============================================================================

pub fn translate(ctx: ?*Context, tx: f64, ty: f64) void {
    c.vkvg_translate(@ptrCast(ctx), tx, ty);
}

pub fn scale(ctx: ?*Context, sx: f64, sy: f64) void {
    c.vkvg_scale(@ptrCast(ctx), sx, sy);
}

pub fn rotate(ctx: ?*Context, radians: f64) void {
    c.vkvg_rotate(@ptrCast(ctx), radians);
}

pub fn transform(ctx: ?*Context, matrix: *Matrix) void {
    c.vkvg_transform(@ptrCast(ctx), @ptrCast(matrix));
}

pub fn setMatrix(ctx: ?*Context, matrix: *Matrix) void {
    c.vkvg_set_matrix(@ptrCast(ctx), @ptrCast(matrix));
}

pub fn getMatrix(ctx: ?*Context, matrix: *Matrix) void {
    c.vkvg_get_matrix(@ptrCast(ctx), @ptrCast(matrix));
}

pub fn identityMatrix(ctx: ?*Context) void {
    c.vkvg_identity_matrix(@ptrCast(ctx));
}

pub fn userToDevice(ctx: ?*Context, x: *f64, y: *f64) void {
    c.vkvg_user_to_device(@ptrCast(ctx), x, y);
}

pub fn userToDeviceDistance(ctx: ?*Context, dx: *f64, dy: *f64) void {
    c.vkvg_user_to_device_distance(@ptrCast(ctx), dx, dy);
}

pub fn deviceToUser(ctx: ?*Context, x: *f64, y: *f64) void {
    c.vkvg_device_to_user(@ptrCast(ctx), x, y);
}

pub fn deviceToUserDistance(ctx: ?*Context, dx: *f64, dy: *f64) void {
    c.vkvg_device_to_user_distance(@ptrCast(ctx), dx, dy);
}

// =============================================================================
// Source/Pattern
// =============================================================================

pub fn setSource(ctx: ?*Context, r: f64, g: f64, b: f64, a: f64) void {
    c.vkvg_set_source(@ptrCast(ctx), r, g, b, a);
}

pub fn setSourceRGBA(ctx: ?*Context, r: f64, g: f64, b: f64, a: f64) void {
    c.vkvg_set_source_rgba(@ptrCast(ctx), r, g, b, a);
}

pub fn setSourceRGB(ctx: ?*Context, r: f64, g: f64, b: f64) void {
    c.vkvg_set_source_rgb(@ptrCast(ctx), r, g, b);
}

pub fn setSourceSurface(ctx: ?*Context, surface: ?*Surface, x: f64, y: f64) void {
    c.vkvg_set_source_surface(@ptrCast(ctx), @ptrCast(surface), x, y);
}

pub fn setSourcePattern(ctx: ?*Context, pattern: ?*Pattern) void {
    c.vkvg_set_source_pattern(@ptrCast(ctx), @ptrCast(pattern));
}

pub fn setSourceImage(ctx: ?*Context, img: ?*Image, x: f64, y: f64) void {
    c.vkvg_set_source_image(@ptrCast(ctx), @ptrCast(img), x, y);
}

pub fn getSource(ctx: ?*Context) ?*Pattern {
    return @ptrCast(c.vkvg_get_source(@ptrCast(ctx)));
}

// =============================================================================
// Pattern
// =============================================================================

pub const Pattern = opaque {};

pub fn patternCreateSolid(red: f64, green: f64, blue: f64, alpha: f64) ?*Pattern {
    return @ptrCast(c.vkvg_pattern_create_rgba(red, green, blue, alpha));
}

pub fn patternCreateSurface(surface: ?*Surface) ?*Pattern {
    return @ptrCast(c.vkvg_pattern_create_surface(@ptrCast(surface)));
}

pub fn patternCreateLinear(x0: f64, y0: f64, x1: f64, y1: f64) ?*Pattern {
    return @ptrCast(c.vkvg_pattern_create_linear(x0, y0, x1, y1));
}

pub fn patternCreateRadial(cx0: f64, cy0: f64, radius0: f64, cx1: f64, cy1: f64, radius1: f64) ?*Pattern {
    return @ptrCast(c.vkvg_pattern_create_radial(cx0, cy0, radius0, cx1, cy1, radius1));
}

pub fn patternReference(pattern: ?*Pattern) ?*Pattern {
    return @ptrCast(c.vkvg_pattern_reference(@ptrCast(pattern)));
}

pub fn patternDestroy(pattern: ?*Pattern) void {
    c.vkvg_pattern_destroy(@ptrCast(pattern));
}

pub fn patternGetType(pattern: ?*Pattern) PatternType {
    return @enumFromInt(c.vkvg_pattern_get_type(@ptrCast(pattern)));
}

pub fn patternGetExtend(pattern: ?*Pattern) c_int {
    return c.vkvg_pattern_get_extend(@ptrCast(pattern));
}

pub fn patternSetExtend(pattern: ?*Pattern, extend: c_int) void {
    c.vkvg_pattern_set_extend(@ptrCast(pattern), extend);
}

pub fn patternGetFilter(pattern: ?*Pattern) c_int {
    return c.vkvg_pattern_get_filter(@ptrCast(pattern));
}

pub fn patternSetFilter(pattern: ?*Pattern, filter: c_int) void {
    c.vkvg_pattern_set_filter(@ptrCast(pattern), filter);
}

pub fn patternAddColorStopRgba(pattern: ?*Pattern, offset: f64, r: f64, g: f64, b: f64, a: f64) void {
    c.vkvg_pattern_add_color_stop_rgba(@ptrCast(pattern), offset, r, g, b, a);
}

pub fn patternAddColorStopRgb(pattern: ?*Pattern, offset: f64, r: f64, g: f64, b: f64) void {
    c.vkvg_pattern_add_color_stop_rgb(@ptrCast(pattern), offset, r, g, b);
}

pub fn patternGetColorStopCount(pattern: ?*Pattern) c_int {
    return c.vkvg_pattern_get_color_stop_count(@ptrCast(pattern));
}

pub fn patternGetColorStopRgba(pattern: ?*Pattern, stop_index: c_int, offset: *f64, r: *f64, g: *f64, b: *f64, a: *f64) Status {
    return @enumFromInt(c.vkvg_pattern_get_color_stop_rgba(@ptrCast(pattern), stop_index, offset, r, g, b, a));
}

pub fn patternGetMatrix(pattern: ?*Pattern, matrix: *Matrix) void {
    c.vkvg_pattern_get_matrix(@ptrCast(pattern), @ptrCast(matrix));
}

pub fn patternSetMatrix(pattern: ?*Pattern, matrix: *Matrix) void {
    c.vkvg_pattern_set_matrix(@ptrCast(pattern), @ptrCast(matrix));
}

pub fn patternGetSurface(pattern: ?*Pattern) ?*Surface {
    return @ptrCast(c.vkvg_pattern_get_surface(@ptrCast(pattern)));
}

// =============================================================================
// State
// =============================================================================

pub fn setLineWidth(ctx: ?*Context, width: f64) void {
    c.vkvg_set_line_width(@ptrCast(ctx), width);
}

pub fn setLineCap(ctx: ?*Context, line_cap: LineCap) void {
    c.vkvg_set_line_cap(@ptrCast(ctx), @intFromEnum(line_cap));
}

pub fn setLineJoin(ctx: ?*Context, line_join: LineJoin) void {
    c.vkvg_set_line_join(@ptrCast(ctx), @intFromEnum(line_join));
}

pub fn setMiterLimit(ctx: ?*Context, limit: f64) void {
    c.vkvg_set_miter_limit(@ptrCast(ctx), limit);
}

pub fn setDash(ctx: ?*Context, dashes: [*]const f64, num_dashes: c_int, offset: f64) void {
    c.vkvg_set_dash(@ptrCast(ctx), dashes, num_dashes, offset);
}

pub fn getDashCount(ctx: ?*Context) c_int {
    return c.vkvg_get_dash_count(@ptrCast(ctx));
}

pub fn setFillRule(ctx: ?*Context, fill_rule: FillRule) void {
    c.vkvg_set_fill_rule(@ptrCast(ctx), @intFromEnum(fill_rule));
}

pub fn setOperator(ctx: ?*Context, op: c_int) void {
    c.vkvg_set_operator(@ptrCast(ctx), op);
}

pub fn setTolerance(ctx: ?*Context, tolerance: f64) void {
    c.vkvg_set_tolerance(@ptrCast(ctx), tolerance);
}

pub fn setCurrentPoint(ctx: ?*Context, x: f64, y: f64) void {
    c.vkvg_set_current_point(@ptrCast(ctx), x, y);
}

pub fn getCurrentPoint(ctx: ?*Context, x: *f64, y: *f64) void {
    c.vkvg_get_current_point(@ptrCast(ctx), x, y);
}

pub fn getLineWidth(ctx: ?*Context) f64 {
    return c.vkvg_get_line_width(@ptrCast(ctx));
}

pub fn getLineCap(ctx: ?*Context) LineCap {
    return @enumFromInt(c.vkvg_get_line_cap(@ptrCast(ctx)));
}

pub fn getLineJoin(ctx: ?*Context) LineJoin {
    return @enumFromInt(c.vkvg_get_line_join(@ptrCast(ctx)));
}

pub fn getMiterLimit(ctx: ?*Context) f64 {
    return c.vkvg_get_miter_limit(@ptrCast(ctx));
}

pub fn getFillRule(ctx: ?*Context) FillRule {
    return @enumFromInt(c.vkvg_get_fill_rule(@ptrCast(ctx)));
}

pub fn getOperator(ctx: ?*Context) c_int {
    return c.vkvg_get_operator(@ptrCast(ctx));
}

pub fn getTolerance(ctx: ?*Context) f64 {
    return c.vkvg_get_tolerance(@ptrCast(ctx));
}

// =============================================================================
// Path Info
// =============================================================================

pub fn newPathFromRect(ctx: ?*Context, x: f64, y: f64, w: f64, h: f64) void {
    c.vkvg_new_path_from_rect(@ptrCast(ctx), x, y, w, h);
}

pub fn pathExtents(ctx: ?*Context, x1: *f64, y1: *f64, x2: *f64, y2: *f64) void {
    c.vkvg_path_extents(@ptrCast(ctx), x1, y1, x2, y2);
}

pub fn pathIsEmpty(ctx: ?*Context) bool {
    return c.vkvg_path_is_empty(@ptrCast(ctx)) != 0;
}

pub fn pathIsInFill(ctx: ?*Context, x: f64, y: f64) bool {
    return c.vkvg_path_is_in_fill(@ptrCast(ctx), x, y) != 0;
}

pub fn pathIsInStroke(ctx: ?*Context, x: f64, y: f64) bool {
    return c.vkvg_path_is_in_stroke(@ptrCast(ctx), x, y) != 0;
}

// =============================================================================
// SVG Rendering
// =============================================================================

pub fn svgRenderToSurface(surf: ?*Surface, path: [*:0]const u8, width: f64, height: f64) Status {
    return @enumFromInt(c.vkvg_svg_render_to_surface(@ptrCast(surf), path, width, height));
}

pub fn svgRenderToSurfaceFromString(surf: ?*Surface, svg_string: [*:0]const u8, width: f64, height: f64) Status {
    return @enumFromInt(c.vkvg_svg_render_to_surface_from_string(@ptrCast(surf), svg_string, width, height));
}

pub fn svgRenderToSurfaceFromMemory(surf: ?*Surface, data: [*]const u8, size: usize, width: f64, height: f64) Status {
    return @enumFromInt(c.vkvg_svg_render_to_surface_from_memory(@ptrCast(surf), data, size, width, height));
}

pub fn svgRenderPathToSurface(ctx: ?*Context, surf: ?*Surface) void {
    c.vkvg_svg_render_path_to_surface(@ptrCast(ctx), @ptrCast(surf));
}

pub fn svgSetSizeCallback(cb: ?*const fn ([*:0]const u8, *f64, *f64) callconv(.C) void) void {
    c.vkvg_svg_set_size_callback(cb);
}

pub fn svgGetError() [*:0]const u8 {
    return c.vkvg_svg_get_error();
}

// =============================================================================
// Gradients
// =============================================================================

pub fn addLinearGradient(
    ctx: ?*Context,
    x0: f64, y0: f64, x1: f64, y1: f64,
    r0: f64, g0: f64, b0: f64, a0: f64,
    r1: f64, g1: f64, b1: f64, a1: f64,
) void {
    c.vkvg_add_linear_gradient(@ptrCast(ctx), x0, y0, x1, y1, r0, g0, b0, a0, r1, g1, b1, a1);
}

pub fn addRadialGradient(
    ctx: ?*Context,
    cx0: f64, cy0: f64, r0: f64,
    cx1: f64, cy1: f64, r1: f64,
    r0c: f64, g0c: f64, b0c: f64, a0c: f64,
    r1c: f64, g1c: f64, b1c: f64, a1c: f64,
) void {
    c.vkvg_add_radial_gradient(@ptrCast(ctx), cx0, cy0, r0, cx1, cy1, r1, r0c, g0c, b0c, a0c, r1c, g1c, b1c, a1c);
}

// =============================================================================
// Status
// =============================================================================

pub fn status(ctx: ?*Context) Status {
    return @enumFromInt(c.vkvg_status(@ptrCast(ctx)));
}

pub fn statusString(status_val: Status) [*:0]const u8 {
    return c.vkvg_status_string(@intFromEnum(status_val));
}

pub fn errorString(status_val: c_int) [*:0]const u8 {
    return c.vkvg_error_string(status_val);
}
