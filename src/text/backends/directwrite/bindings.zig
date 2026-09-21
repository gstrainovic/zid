//! DirectWrite/Direct2D Bindings for Zig
//! Based on mdview-zig and expanded for low-level glyph access.

const std = @import("std");
const windows = std.os.windows;

pub const GUID = windows.GUID;
pub const HRESULT = windows.HRESULT;
pub const BOOL = windows.BOOL;

pub const IID_IDWriteFactory = GUID{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
pub const IID_IDWriteFontFileLoader = GUID{ .Data1 = 0x727cad59, .Data2 = 0xd6af, .Data3 = 0x4c9e, .Data4 = .{ 0x8a, 0x08, 0xd6, 0x95, 0xb1, 0x1c, 0xa4, 0x9e } };
pub const IID_IDWriteFontCollectionLoader = GUID{ .Data1 = 0xcca92483, .Data2 = 0x9d14, .Data3 = 0x4d78, .Data4 = .{ 0xbf, 0x7f, 0x03, 0xee, 0x19, 0x2b, 0x5d, 0xf0 } };

pub const DWRITE_FACTORY_TYPE = enum(u32) {
    SHARED = 0,
    ISOLATED = 1,
};

pub const DWRITE_FONT_FILE_TYPE = enum(u32) {
    UNKNOWN,
    CFF,
    TRUETYPE,
    TRUETYPE_COLLECTION,
    TYPE1_PBM,
    TYPE1_PFM,
    VECTOR,
    BITMAP,
};

pub const DWRITE_FONT_FACE_TYPE = enum(u32) {
    CFF,
    TRUETYPE,
    TRUETYPE_COLLECTION,
    TYPE1,
    VECTOR,
    BITMAP,
    UNKNOWN,
    RAW_CFF,
};

pub const DWRITE_FONT_SIMULATIONS = enum(u32) {
    NONE = 0,
    BOLD = 1,
    OBLIQUE = 2,
};

pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: u16,
    ascent: u16,
    descent: u16,
    lineGap: i16,
    capHeight: u16,
    xHeight: u16,
    underlinePosition: i16,
    underlineThickness: u16,
    strikethroughPosition: i16,
    strikethroughThickness: u16,
};

pub const DWRITE_GLYPH_METRICS = extern struct {
    leftSideBearing: i32,
    advanceWidth: u32,
    rightSideBearing: i32,
    topSideBearing: i32,
    advanceHeight: u32,
    bottomSideBearing: i32,
    verticalOriginY: i32,
};

pub const DWRITE_GLYPH_RUN = extern struct {
    fontFace: ?*anyopaque,
    fontEmSize: f32,
    glyphCount: u32,
    glyphIndices: [*]const u16,
    glyphAdvances: ?[*]const f32,
    glyphOffsets: ?[*]const DWRITE_GLYPH_OFFSET,
    isSideways: BOOL,
    bidiLevel: u32,
};

pub const DWRITE_GLYPH_OFFSET = extern struct {
    advanceOffset: f32,
    ascenderOffset: f32,
};

pub const DWRITE_MEASURING_MODE = enum(u32) {
    NATURAL = 0,
    GDI_CLASSIC = 1,
    GDI_NATURAL = 2,
};

pub const DWRITE_RENDERING_MODE = enum(u32) {
    DEFAULT = 0,
    ALIASED = 1,
    GDI_CLASSIC = 2,
    GDI_NATURAL = 3,
    NATURAL = 4,
    NATURAL_SYMMETRIC = 5,
    OUTLINE = 6,
};

pub const IDWriteFactory_VTable = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IDWriteFactory
    GetSystemFontCollection: *const anyopaque,
    CreateCustomFontCollection: *const anyopaque,
    RegisterFontCollectionLoader: *const anyopaque,
    UnregisterFontCollectionLoader: *const anyopaque,
    CreateFontFileReference: *const fn (*anyopaque, [*:0]const u16, ?*const windows.FILETIME, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateCustomFontFileReference: *const anyopaque,
    CreateFontFace: *const fn (*anyopaque, DWRITE_FONT_FACE_TYPE, u32, [*]const ?*anyopaque, u32, DWRITE_FONT_SIMULATIONS, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateRenderingParams: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateMonitorRenderingParams: *const anyopaque,
    CreateCustomRenderingParams: *const anyopaque,
    RegisterFontFileLoader: *const anyopaque,
    UnregisterFontFileLoader: *const anyopaque,
    CreateTextFormat: *const fn (*anyopaque, [*:0]const u16, ?*anyopaque, u32, u32, u32, f32, [*:0]const u16, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateTypography: *const anyopaque,
    CreateGdiInterop: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateTextLayout: *const fn (*anyopaque, [*]const u16, u32, *anyopaque, f32, f32, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateGdiCompatibleTextLayout: *const anyopaque,
    CreateEllipsisTrimmingSign: *const anyopaque,
    CreateTextAnalyzer: *const anyopaque,
    CreateNumberSubstitution: *const anyopaque,
    CreateGlyphRunAnalysis: *const anyopaque,
};

/// IDWriteFactory2 (Windows 8.1+): Farbschriften. Die Methoden von IDWriteFactory und
/// IDWriteFactory1 stehen davor, in dieser Reihenfolge (dwrite_2.h).
pub const IID_IDWriteFactory2 = GUID{ .Data1 = 0x0439fc60, .Data2 = 0xca44, .Data3 = 0x4994, .Data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec } };

pub const IDWriteFactory2_VTable = extern struct {
    base: IDWriteFactory_VTable,
    // IDWriteFactory1
    GetEudcFontCollection: *const anyopaque,
    CreateCustomRenderingParams1: *const anyopaque,
    // IDWriteFactory2
    GetSystemFontFallback: *const anyopaque,
    CreateFontFallbackBuilder: *const anyopaque,
    TranslateColorGlyphRun: *const fn (
        *anyopaque,
        f32, // baselineOriginX
        f32, // baselineOriginY
        *const DWRITE_GLYPH_RUN,
        ?*const anyopaque, // DWRITE_GLYPH_RUN_DESCRIPTION
        DWRITE_MEASURING_MODE,
        ?*const anyopaque, // DWRITE_MATRIX (worldToDeviceTransform)
        u32, // colorPaletteIndex
        *?*anyopaque, // IDWriteColorGlyphRunEnumerator**
    ) callconv(.winapi) HRESULT,
    CreateCustomRenderingParams2: *const anyopaque,
    CreateGlyphRunAnalysis2: *const anyopaque,
};

/// Rückgabe von TranslateColorGlyphRun, wenn der Glyph keine Farbschichten hat.
pub const DWRITE_E_NOCOLOR: HRESULT = @bitCast(@as(u32, 0x8898500C));

pub const DWRITE_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };

pub const DWRITE_COLOR_GLYPH_RUN = extern struct {
    glyphRun: DWRITE_GLYPH_RUN,
    glyphRunDescription: ?*anyopaque,
    baselineOriginX: f32,
    baselineOriginY: f32,
    runColor: DWRITE_COLOR_F,
    /// 0xFFFF: Schicht in Textfarbe (runColor gilt dann nicht)
    paletteIndex: u16,
};

pub const IDWriteColorGlyphRunEnumerator_VTable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    MoveNext: *const fn (*anyopaque, *BOOL) callconv(.winapi) HRESULT,
    GetCurrentRun: *const fn (*anyopaque, **const DWRITE_COLOR_GLYPH_RUN) callconv(.winapi) HRESULT,
};

pub const IDWriteFontFace_VTable = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IDWriteFontFace
    GetType: *const anyopaque,
    GetFiles: *const anyopaque,
    GetIndex: *const anyopaque,
    GetSimulations: *const anyopaque,
    IsSymbolFont: *const anyopaque,
    GetMetrics: *const fn (*anyopaque, *DWRITE_FONT_METRICS) callconv(.winapi) void,
    GetGlyphCount: *const fn (*anyopaque) callconv(.winapi) u16,
    GetDesignGlyphMetrics: *const fn (*anyopaque, [*]const u16, u32, [*]DWRITE_GLYPH_METRICS, BOOL) callconv(.winapi) HRESULT,
    GetGlyphIndices: *const fn (*anyopaque, [*]const u32, u32, [*]u16) callconv(.winapi) HRESULT,
    // ... more methods omitted for brevity, adding only what we need
};

pub const IDWriteGdiInterop_VTable = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IDWriteGdiInterop
    CreateFontFromLOGFONT: *const anyopaque,
    ConvertFontToLOGFONT: *const anyopaque,
    ConvertFontFaceToLOGFONT: *const anyopaque,
    CreateFontFaceFromHdc: *const anyopaque,
    CreateBitmapRenderTarget: *const fn (*anyopaque, ?windows.HDC, u32, u32, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const DWRITE_TEXT_ANTIALIAS_MODE = enum(u32) {
    CLEARTYPE = 0,
    GRAYSCALE = 1,
    ALIASED = 2,
};

pub const IDWriteBitmapRenderTarget_VTable = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    // IDWriteBitmapRenderTarget
    DrawGlyphRun: *const fn (*anyopaque, f32, f32, DWRITE_MEASURING_MODE, *const DWRITE_GLYPH_RUN, ?*anyopaque, u32, ?*windows.RECT) callconv(.winapi) HRESULT,
    GetMemoryDC: *const fn (*anyopaque) callconv(.winapi) windows.HDC,
    GetPixelsPerDip: *const anyopaque,
    SetPixelsPerDip: *const anyopaque,
    GetCurrentTransform: *const anyopaque,
    SetCurrentTransform: *const anyopaque,
    GetSize: *const anyopaque,
    Resize: *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT,
    SetTextAntialiasMode: *const fn (*anyopaque, DWRITE_TEXT_ANTIALIAS_MODE) callconv(.winapi) HRESULT,
    GetTextAntialiasMode: *const anyopaque,
    SetTextRenderingParams: *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
    GetTextRenderingParams: *const anyopaque,
};

pub const IUnknown_VTable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

pub fn Release(obj: *anyopaque) u32 {
    return vtable(IUnknown_VTable, obj).Release(obj);
}

pub fn vtable(comptime T: type, obj: *anyopaque) *const T {
    const pp: *const *const T = @ptrCast(@alignCast(obj));
    return pp.*;
}

pub const HDC = windows.HANDLE;
pub const HDC_OR_HWND = windows.HANDLE;
pub const COLORREF = u32;

pub extern "user32" fn PatBlt(hdc: ?HDC, x: i32, y: i32, w: i32, h: i32, rop: u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn GetCurrentObject(hdc: ?HDC, @"type": u32) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn GetObjectW(h: ?*anyopaque, c: i32, pv: ?*anyopaque) callconv(.winapi) i32;
pub extern "gdi32" fn SetTextColor(hdc: ?HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn SetBkMode(hdc: ?HDC, mode: i32) callconv(.winapi) i32;

pub const BITMAP = extern struct {
    bmType: i32,
    bmWidth: i32,
    bmHeight: i32,
    bmWidthBytes: i32,
    bmPlanes: u16,
    bmBitsPixel: u16,
    bmBits: ?*anyopaque,
};

pub extern "dwrite" fn DWriteCreateFactory(factoryType: u32, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;
