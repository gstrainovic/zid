/// vkvg Bindings für Zig - korrekte API v0.5+
const std = @import("std");
const c = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("vkvg.h");
});

// =============================================================================
// Opaque Types
// =============================================================================
pub const Device = c.VkvgDevice;
pub const Surface = c.VkvgSurface;
pub const Context = c.VkvgContext;
pub const Pattern = c.VkvgPattern;
pub const Recording = c.VkvgRecording;
pub const Text = c.VkvgText;

// =============================================================================
// Enums
// =============================================================================
pub const Status = enum(c_int) {
    success = c.VKVG_STATUS_SUCCESS,
    no_memory = c.VKVG_STATUS_NO_MEMORY,
    null_pointer = c.VKVG_STATUS_NULL_POINTER,
    invalid_restore = c.VKVG_STATUS_INVALID_RESTORE,
    no_current_point = c.VKVG_STATUS_NO_CURRENT_POINT,
    invalid_matrix = c.VKVG_STATUS_INVALID_MATRIX,
    invalid_status = c.VKVG_STATUS_INVALID_STATUS,
    invalid_index = c.VKVG_STATUS_INVALID_INDEX,
    write_error = c.VKVG_STATUS_WRITE_ERROR,
    pattern_type_mismatch = c.VKVG_STATUS_PATTERN_TYPE_MISMATCH,
    pattern_invalid_gradient = c.VKVG_STATUS_PATTERN_INVALID_GRADIENT,
    invalid_format = c.VKVG_STATUS_INVALID_FORMAT,
    file_not_found = c.VKVG_STATUS_FILE_NOT_FOUND,
    invalid_dash = c.VKVG_STATUS_INVALID_DASH,
    invalid_rect = c.VKVG_STATUS_INVALID_RECT,
    timeout = c.VKVG_STATUS_TIMEOUT,
    device_error = c.VKVG_STATUS_DEVICE_ERROR,
    invalid_device_create_info = c.VKVG_STATUS_INVALID_DEVICE_CREATE_INFO,
    invalid_image = c.VKVG_STATUS_INVALID_IMAGE,
    invalid_surface = c.VKVG_STATUS_INVALID_SURFACE,
    invalid_font = c.VKVG_STATUS_INVALID_FONT,
    in_cache = c.VKVG_STATUS_IN_CACHE,
    _,
};

pub const Format = enum(c_int) {
    argb32 = c.VKVG_FORMAT_ARGB32,
    rgb24 = c.VKVG_FORMAT_RGB24,
    a8 = c.VKVG_FORMAT_A8,
    a1 = c.VKVG_FORMAT_A1,
    _,
};

pub const Extend = enum(c_int) {
    none = c.VKVG_EXTEND_NONE,
    repeat = c.VKVG_EXTEND_REPEAT,
    reflect = c.VKVG_EXTEND_REFLECT,
    pad = c.VKVG_EXTEND_PAD,
    _,
};

pub const Filter = enum(c_int) {
    fast = c.VKVG_FILTER_FAST,
    good = c.VKVG_FILTER_GOOD,
    best = c.VKVG_FILTER_BEST,
    nearest = c.VKVG_FILTER_NEAREST,
    bilinear = c.VKVG_FILTER_BILINEAR,
    gaussian = c.VKVG_FILTER_GAUSSIAN,
    _,
};

pub const PatternType = enum(c_int) {
    solid = c.VKVG_PATTERN_TYPE_SOLID,
    surface = c.VKVG_PATTERN_TYPE_SURFACE,
    linear = c.VKVG_PATTERN_TYPE_LINEAR,
    radial = c.VKVG_PATTERN_TYPE_RADIAL,
    mesh = c.VKVG_PATTERN_TYPE_MESH,
    raster_source = c.VKVG_PATTERN_TYPE_RASTER_SOURCE,
    _,
};

pub const LineCap = enum(c_int) {
    butt = c.VKVG_LINE_CAP_BUTT,
    round = c.VKVG_LINE_CAP_ROUND,
    square = c.VKVG_LINE_CAP_SQUARE,
    _,
};

pub const LineJoin = enum(c_int) {
    miter = c.VKVG_LINE_JOIN_MITER,
    round = c.VKVG_LINE_JOIN_ROUND,
    bevel = c.VKVG_LINE_JOIN_BEVEL,
    _,
};

pub const FillRule = enum(c_int) {
    winding = c.VKVG_FILL_RULE_WINDING,
    even_odd = c.VKVG_FILL_RULE_EVEN_ODD,
    _,
};

pub const FontWeight = enum(c_int) {
    normal = c.VKVG_FONT_WEIGHT_NORMAL,
    bold = c.VKVG_FONT_WEIGHT_BOLD,
    _,
};

pub const FontSlant = enum(c_int) {
    normal = c.VKVG_FONT_SLANT_NORMAL,
    italic = c.VKVG_FONT_SLANT_ITALIC,
    oblique = c.VKVG_FONT_SLANT_OBLIQUE,
    _,
};

pub const Operator = enum(c_int) {
    clear = c.VKVG_OPERATOR_CLEAR,
    source = c.VKVG_OPERATOR_SOURCE,
    over = c.VKVG_OPERATOR_OVER,
    in = c.VKVG_OPERATOR_IN,
    out = c.VKVG_OPERATOR_OUT,
    atop = c.VKVG_OPERATOR_ATOP,
    dest = c.VKVG_OPERATOR_DEST,
    dest_over = c.VKVG_OPERATOR_DEST_OVER,
    dest_in = c.VKVG_OPERATOR_DEST_IN,
    dest_out = c.VKVG_OPERATOR_DEST_OUT,
    dest_atop = c.VKVG_OPERATOR_DEST_ATOP,
    xor = c.VKVG_OPERATOR_XOR,
    add = c.VKVG_OPERATOR_ADD,
    saturate = c.VKVG_OPERATOR_SATURATE,
    _,
};

// =============================================================================
// Structs
// =============================================================================
pub const DeviceCreateInfo = extern struct {
    instance: c.VkInstance,
    phy: c.VkPhysicalDevice,
    vkdev: c.VkDevice,
    qFamIdx: u32,
    qIndex: u32,
    threadAware: bool,
};

pub const Matrix = extern struct {
    xx: f32,
    yx: f32,
    xy: f32,
    yy: f32,
    x0: f32,
    y0: f32,
};

pub const Rectangle = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Point = extern struct {
    x: f32,
    y: f32,
};

pub const TextExtents = extern struct {
    x_bearing: f32,
    y_bearing: f32,
    width: f32,
    height: f32,
    x_advance: f32,
    y_advance: f32,
};

pub const FontExtents = extern struct {
    ascent: f32,
    descent: f32,
    height: f32,
    max_x_advance: f32,
    max_y_advance: f32,
};

// =============================================================================
// Matrix Functions
// =============================================================================
pub fn matrixInitIdentity(matrix: *Matrix) void {
    c.vkvg_matrix_init_identity(@ptrCast(matrix));
}

pub fn matrixInit(matrix: *Matrix, xx: f32, yx: f32, xy: f32, yy: f32, x0: f32, y0: f32) void {
    c.vkvg_matrix_init(@ptrCast(matrix), xx, yx, xy, yy, x0, y0);
}

pub fn matrixInitTranslate(matrix: *Matrix, tx: f32, ty: f32) void {
    c.vkvg_matrix_init_translate(@ptrCast(matrix), tx, ty);
}

pub fn matrixInitScale(matrix: *Matrix, sx: f32, sy: f32) void {
    c.vkvg_matrix_init_scale(@ptrCast(matrix), sx, sy);
}

pub fn matrixInitRotate(matrix: *Matrix, radians: f32) void {
    c.vkvg_matrix_init_rotate(@ptrCast(matrix), radians);
}

pub fn matrixTranslate(matrix: *Matrix, tx: f32, ty: f32) void {
    c.vkvg_matrix_translate(@ptrCast(matrix), tx, ty);
}

pub fn matrixScale(matrix: *Matrix, sx: f32, sy: f32) void {
    c.vkvg_matrix_scale(@ptrCast(matrix), sx, sy);
}

pub fn matrixRotate(matrix: *Matrix, radians: f32) void {
    c.vkvg_matrix_rotate(@ptrCast(matrix), radians);
}

pub fn matrixMultiply(result: *Matrix, a: *const Matrix, b: *const Matrix) void {
    c.vkvg_matrix_multiply(@ptrCast(result), @ptrCast(a), @ptrCast(b));
}

pub fn matrixTransformDistance(matrix: *const Matrix, dx: *f32, dy: *f32) void {
    c.vkvg_matrix_transform_distance(@ptrCast(matrix), dx, dy);
}

pub fn matrixTransformPoint(matrix: *const Matrix, x: *f32, y: *f32) void {
    c.vkvg_matrix_transform_point(@ptrCast(matrix), x, y);
}

pub fn matrixInvert(matrix: *Matrix) Status {
    return @enumFromInt(c.vkvg_matrix_invert(@ptrCast(matrix)));
}

pub fn matrixGetScale(matrix: *const Matrix, sx: *f32, sy: *f32) void {
    c.vkvg_matrix_get_scale(@ptrCast(matrix), sx, sy);
}

// =============================================================================
// Device Functions
// =============================================================================
pub fn deviceCreate(info: *DeviceCreateInfo) ?Device {
    return c.vkvg_device_create(@ptrCast(info));
}

pub fn deviceDestroy(dev: Device) void {
    c.vkvg_device_destroy(dev);
}

pub fn deviceStatus(dev: Device) Status {
    return @enumFromInt(c.vkvg_device_status(dev));
}

pub fn deviceReference(dev: Device) Device {
    return c.vkvg_device_reference(dev);
}

pub fn deviceGetReferenceCount(dev: Device) u32 {
    return c.vkvg_device_get_reference_count(dev);
}

pub fn deviceSetContextCacheSize(dev: Device, max_count: u32) void {
    c.vkvg_device_set_context_cache_size(dev, max_count);
}

pub fn getRequiredInstanceExtensions(extensions: [*c]const u8, count: *u32) void {
    c.vkvg_get_required_instance_extensions(extensions, count);
}

// =============================================================================
// Surface Functions
// =============================================================================
pub fn surfaceCreate(dev: Device, width: u32, height: u32) ?Surface {
    return c.vkvg_surface_create(dev, width, height);
}

pub fn surfaceCreateFromImage(dev: Device, file_path: [*:0]const u8) ?Surface {
    return c.vkvg_surface_create_from_image(dev, file_path);
}

pub fn surfaceStatus(surf: Surface) Status {
    return @enumFromInt(c.vkvg_surface_status(surf));
}

pub fn surfaceReference(surf: Surface) Surface {
    return c.vkvg_surface_reference(surf);
}

pub fn surfaceGetReferenceCount(surf: Surface) u32 {
    return c.vkvg_surface_get_reference_count(surf);
}

pub fn surfaceDestroy(surf: Surface) void {
    c.vkvg_surface_destroy(surf);
}

pub fn surfaceClear(surf: Surface) void {
    c.vkvg_surface_clear(surf);
}

pub fn surfaceGetVkImage(surf: Surface) c.VkImage {
    return c.vkvg_surface_get_vk_image(surf);
}

pub fn surfaceGetWidth(surf: Surface) u32 {
    return c.vkvg_surface_get_width(surf);
}

pub fn surfaceGetHeight(surf: Surface) u32 {
    return c.vkvg_surface_get_height(surf);
}

pub fn surfaceFlush(surf: Surface) void {
    c.vkvg_surface_flush(surf);
}

pub fn surfaceWriteToPng(surf: Surface, path: [*:0]const u8) Status {
    return @enumFromInt(c.vkvg_surface_write_to_png(surf, path));
}

// =============================================================================
// Context Functions
// =============================================================================
pub fn contextCreate(surf: Surface) ?Context {
    return c.vkvg_context_create(surf);
}

pub fn contextDestroy(ctx: Context) void {
    c.vkvg_context_destroy(ctx);
}

pub fn contextStatus(ctx: Context) Status {
    return @enumFromInt(c.vkvg_context_status(ctx));
}

pub fn contextGetDevice(ctx: Context) Device {
    return c.vkvg_context_get_device(ctx);
}

pub fn contextGetTarget(ctx: Context) Surface {
    return c.vkvg_context_get_target(ctx);
}

pub fn contextReference(ctx: Context) Context {
    return c.vkvg_context_reference(ctx);
}

// =============================================================================
// Save/Restore
// =============================================================================
pub fn save(ctx: Context) void {
    c.vkvg_save(ctx);
}

pub fn restore(ctx: Context) void {
    c.vkvg_restore(ctx);
}

// =============================================================================
// Path Operations
// =============================================================================
pub fn newPath(ctx: Context) void {
    c.vkvg_new_path(ctx);
}

pub fn closePath(ctx: Context) void {
    c.vkvg_close_path(ctx);
}

pub fn arc(ctx: Context, xc: f32, yc: f32, radius: f32, angle1: f32, angle2: f32) void {
    c.vkvg_arc(ctx, xc, yc, radius, angle1, angle2);
}

pub fn arcNegative(ctx: Context, xc: f32, yc: f32, radius: f32, angle1: f32, angle2: f32) void {
    c.vkvg_arc_negative(ctx, xc, yc, radius, angle1, angle2);
}

pub fn curveTo(ctx: Context, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) void {
    c.vkvg_curve_to(ctx, x1, y1, x2, y2, x3, y3);
}

pub fn lineTo(ctx: Context, x: f32, y: f32) void {
    c.vkvg_line_to(ctx, x, y);
}

pub fn moveTo(ctx: Context, x: f32, y: f32) void {
    c.vkvg_move_to(ctx, x, y);
}

pub fn rectangle(ctx: Context, x: f32, y: f32, width: f32, height: f32) void {
    c.vkvg_rectangle(ctx, x, y, width, height);
}

pub fn relCurveTo(ctx: Context, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) void {
    c.vkvg_rel_curve_to(ctx, dx1, dy1, dx2, dy2, dx3, dy3);
}

pub fn relLineTo(ctx: Context, dx: f32, dy: f32) void {
    c.vkvg_rel_line_to(ctx, dx, dy);
}

pub fn relMoveTo(ctx: Context, dx: f32, dy: f32) void {
    c.vkvg_rel_move_to(ctx, dx, dy);
}

// =============================================================================
// Painting
// =============================================================================
pub fn fill(ctx: Context) void {
    c.vkvg_fill(ctx);
}

pub fn fillPreserve(ctx: Context) void {
    c.vkvg_fill_preserve(ctx);
}

pub fn stroke(ctx: Context) void {
    c.vkvg_stroke(ctx);
}

pub fn strokePreserve(ctx: Context) void {
    c.vkvg_stroke_preserve(ctx);
}

pub fn copyPage(ctx: Context) void {
    c.vkvg_copy_page(ctx);
}

pub fn showPage(ctx: Context) void {
    c.vkvg_show_page(ctx);
}

pub fn inFill(ctx: Context, x: f32, y: f32) bool {
    return c.vkvg_in_fill(ctx, x, y) != 0;
}

pub fn inStroke(ctx: Context, x: f32, y: f32) bool {
    return c.vkvg_in_stroke(ctx, x, y) != 0;
}

// =============================================================================
// Clipping
// =============================================================================
pub fn clip(ctx: Context) void {
    c.vkvg_clip(ctx);
}

pub fn clipPreserve(ctx: Context) void {
    c.vkvg_clip_preserve(ctx);
}

pub fn clipExtents(ctx: Context, extents: *Rectangle) void {
    c.vkvg_clip_extents(ctx, @ptrCast(extents));
}

pub fn resetClip(ctx: Context) void {
    c.vkvg_reset_clip(ctx);
}

// =============================================================================
// Source/Pattern
// =============================================================================
pub fn setSource(ctx: Context, r: f32, g: f32, b: f32, a: f32) void {
    c.vkvg_set_source(ctx, r, g, b, a);
}

pub fn setSourceRGBA(ctx: Context, r: f32, g: f32, b: f32, a: f32) void {
    c.vkvg_set_source_rgba(ctx, r, g, b, a);
}

pub fn setSourceRGB(ctx: Context, r: f32, g: f32, b: f32) void {
    c.vkvg_set_source_rgb(ctx, r, g, b);
}

pub fn setSourceSurface(ctx: Context, surface: Surface, x: f32, y: f32) void {
    c.vkvg_set_source_surface(ctx, surface, x, y);
}

pub fn setSourcePattern(ctx: Context, pattern: Pattern) void {
    c.vkvg_set_source_pattern(ctx, pattern);
}

pub fn getSource(ctx: Context) Pattern {
    return c.vkvg_get_source(ctx);
}

// =============================================================================
// Pattern Functions
// =============================================================================
pub fn patternCreateSolid(red: f32, green: f32, blue: f32, alpha: f32) ?Pattern {
    return c.vkvg_pattern_create_solid(red, green, blue, alpha);
}

pub fn patternCreateSurface(surface: Surface) ?Pattern {
    return c.vkvg_pattern_create_surface(surface);
}

pub fn patternCreateLinear(x0: f32, y0: f32, x1: f32, y1: f32) ?Pattern {
    return c.vkvg_pattern_create_linear(x0, y0, x1, y1);
}

pub fn patternCreateRadial(cx0: f32, cy0: f32, radius0: f32, cx1: f32, cy1: f32, radius1: f32) ?Pattern {
    return c.vkvg_pattern_create_radial(cx0, cy0, radius0, cx1, cy1, radius1);
}

pub fn patternReference(pattern: Pattern) Pattern {
    return c.vkvg_pattern_reference(pattern);
}

pub fn patternDestroy(pattern: Pattern) void {
    c.vkvg_pattern_destroy(pattern);
}

pub fn patternGetType(pattern: Pattern) PatternType {
    return @enumFromInt(c.vkvg_pattern_get_type(pattern));
}

pub fn patternAddColorStopRgba(pattern: Pattern, offset: f32, r: f32, g: f32, b: f32, a: f32) void {
    c.vkvg_pattern_add_color_stop_rgba(pattern, offset, r, g, b, a);
}

pub fn patternAddColorStopRgb(pattern: Pattern, offset: f32, r: f32, g: f32, b: f32) void {
    c.vkvg_pattern_add_color_stop_rgb(pattern, offset, r, g, b);
}

// =============================================================================
// State
// =============================================================================
pub fn setLineWidth(ctx: Context, width: f32) void {
    c.vkvg_set_line_width(ctx, width);
}

pub fn setLineCap(ctx: Context, line_cap: LineCap) void {
    c.vkvg_set_line_cap(ctx, @intFromEnum(line_cap));
}

pub fn setLineJoin(ctx: Context, line_join: LineJoin) void {
    c.vkvg_set_line_join(ctx, @intFromEnum(line_join));
}

pub fn setMiterLimit(ctx: Context, limit: f32) void {
    c.vkvg_set_miter_limit(ctx, limit);
}

pub fn setFillRule(ctx: Context, fill_rule: FillRule) void {
    c.vkvg_set_fill_rule(ctx, @intFromEnum(fill_rule));
}

pub fn setOperator(ctx: Context, op: Operator) void {
    c.vkvg_set_operator(ctx, @intFromEnum(op));
}

pub fn setTolerance(ctx: Context, tolerance: f32) void {
    c.vkvg_set_tolerance(ctx, tolerance);
}

pub fn getLineWidth(ctx: Context) f32 {
    return c.vkvg_get_line_width(ctx);
}

pub fn getLineCap(ctx: Context) LineCap {
    return @enumFromInt(c.vkvg_get_line_cap(ctx));
}

pub fn getLineJoin(ctx: Context) LineJoin {
    return @enumFromInt(c.vkvg_get_line_join(ctx));
}

pub fn getMiterLimit(ctx: Context) f32 {
    return c.vkvg_get_miter_limit(ctx);
}

pub fn getFillRule(ctx: Context) FillRule {
    return @enumFromInt(c.vkvg_get_fill_rule(ctx));
}

pub fn getOperator(ctx: Context) Operator {
    return @enumFromInt(c.vkvg_get_operator(ctx));
}

pub fn getTolerance(ctx: Context) f32 {
    return c.vkvg_get_tolerance(ctx);
}

// =============================================================================
// Transformations
// =============================================================================
pub fn translate(ctx: Context, tx: f32, ty: f32) void {
    c.vkvg_translate(ctx, tx, ty);
}

pub fn scale(ctx: Context, sx: f32, sy: f32) void {
    c.vkvg_scale(ctx, sx, sy);
}

pub fn rotate(ctx: Context, radians: f32) void {
    c.vkvg_rotate(ctx, radians);
}

pub fn transform(ctx: Context, matrix: *const Matrix) void {
    c.vkvg_transform(ctx, @ptrCast(matrix));
}

pub fn setMatrix(ctx: Context, matrix: *const Matrix) void {
    c.vkvg_set_matrix(ctx, @ptrCast(matrix));
}

pub fn getMatrix(ctx: Context, matrix: *Matrix) void {
    c.vkvg_get_matrix(ctx, @ptrCast(matrix));
}

pub fn identityMatrix(ctx: Context) void {
    c.vkvg_identity_matrix(ctx);
}

// =============================================================================
// Fonts
// =============================================================================
pub fn selectFontFace(ctx: Context, family: [*:0]const u8, slant: FontSlant, weight: FontWeight) void {
    c.vkvg_select_font_face(ctx, family, @intFromEnum(slant), @intFromEnum(weight));
}

pub fn setFontSize(ctx: Context, size: f32) void {
    c.vkvg_set_font_size(ctx, size);
}

pub fn textExtents(ctx: Context, utf8: [*:0]const u8, extents: *TextExtents) void {
    c.vkvg_text_extents(ctx, utf8, @ptrCast(extents));
}

pub fn fontExtents(ctx: Context, extents: *FontExtents) void {
    c.vkvg_font_extents(ctx, @ptrCast(extents));
}

pub fn showText(ctx: Context, utf8: [*:0]const u8) void {
    c.vkvg_show_text(ctx, utf8);
}

// =============================================================================
// Gradients
// =============================================================================
pub fn addLinearGradient(
    ctx: Context,
    x0: f32, y0: f32, x1: f32, y1: f32,
    r0: f32, g0: f32, b0: f32, a0: f32,
    r1: f32, g1: f32, b1: f32, a1: f32,
) void {
    c.vkvg_add_linear_gradient(ctx, x0, y0, x1, y1, r0, g0, b0, a0, r1, g1, b1, a1);
}

pub fn addRadialGradient(
    ctx: Context,
    cx0: f32, cy0: f32, r0: f32,
    cx1: f32, cy1: f32, r1: f32,
    r0c: f32, g0c: f32, b0c: f32, a0c: f32,
    r1c: f32, g1c: f32, b1c: f32, a1c: f32,
) void {
    c.vkvg_add_radial_gradient(ctx, cx0, cy0, r0, cx1, cy1, r1, r0c, g0c, b0c, a0c, r1c, g1c, b1c, a1c);
}

// =============================================================================
// Status String
// =============================================================================
pub fn statusString(status: Status) [*:0]const u8 {
    return c.vkvg_status_string(@intFromEnum(status));
}
