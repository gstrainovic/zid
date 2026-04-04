//! Text Rendering Modul für vulkan-ed
//!
//! Platform-spezifisches Text Rendering:
//! - Windows: DirectWrite (ClearType Subpixel-Rendering)
//! - Linux: FreeType + HarfBuzz
//!
//! Beide rendern Glyphen in einen GPU Glyph-Atlas.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.text);

/// Font Konfiguration
pub const FontConfig = struct {
    /// Font-Datei Pfad (z.B. "fonts/JetBrainsMono-Regular.ttf")
    font_path: []const u8,
    size: f32 = 14.0,
    line_height: f32 = 1.5,
};

/// Glyph-Atlas Eintrag
pub const GlyphEntry = struct {
    /// UV-Koordinaten in der Atlas-Textur
    uv_x: f32,
    uv_y: f32,
    uv_width: f32,
    uv_height: f32,
    /// Advance für nächstes Glyph
    advance_x: f32,
    advance_y: f32,
    /// Bounding Box Offset
    bearing_x: f32,
    bearing_y: f32,
    /// Glyph Dimensionen
    width: u32,
    height: u32,
};

/// Text Renderer Interface
pub const TextRenderer = struct {
    allocator: std.mem.Allocator,
    font_config: FontConfig,
    initialized: bool = false,

    // Glyph-Atlas (wird von platform-spezifischem Backend gefüllt)
    atlas_texture: ?[]u8 = null,
    atlas_width: u32 = 0,
    atlas_height: u32 = 0,
    atlas_loaded: bool = false,

    const Self = @This();

    /// Text Renderer initialisieren
    pub fn init(allocator: std.mem.Allocator, font_config: FontConfig) !Self {
        log.info("Initializing text renderer", .{});
        log.info("Platform: {s}", .{@tagName(builtin.os.tag)});
        log.info("Font: {s} size={d}", .{ font_config.font_path, font_config.size });

        // Font-Datei laden
        const font_data = try std.fs.cwd().readFileAlloc(allocator, font_config.font_path, 10 * 1024 * 1024);
        defer allocator.free(font_data);

        log.info("Font loaded: {} bytes", .{font_data.len});

        // TODO: Platform-spezifisches Font Parsing
        // Windows: DirectWrite Font Loader
        // Linux: FreeType FT_New_Memory_Face

        return Self{
            .allocator = allocator,
            .font_config = font_config,
            .initialized = false,
        };
    }

    /// Renderer aufräumen
    pub fn deinit(self: *Self) void {
        log.info("Text renderer shutdown", .{});
        if (self.atlas_texture) |atlas| {
            self.allocator.free(atlas);
        }
    }

    /// Glyph-Atlas bauen (platform-spezifisch)
    pub fn buildAtlas(self: *Self) !void {
        log.info("Building glyph atlas", .{});

        // TODO: Platform-spezifische Glyph-Extraktion
        // Windows: DirectWrite → RGBA Glyphs
        // Linux: FreeType → RGBA Glyphs

        // Placeholder: 256x256 Atlas
        const atlas_size = 256;
        self.atlas_texture = try self.allocator.alloc(u8, atlas_size * atlas_size * 4);
        self.atlas_width = atlas_size;
        self.atlas_height = atlas_size;
        self.atlas_loaded = true;

        // Clear atlas
        @memset(self.atlas_texture.?, 0);

        log.info("Glyph atlas built: {}x{}", .{ self.atlas_width, self.atlas_height });
    }

    /// Text messen (für Layout)
    pub fn measureText(self: *const Self, text: []const u8) struct { width: f32, height: f32 } {
        const approx_width = @as(f32, @floatFromInt(text.len)) * self.font_config.size * 0.6;
        return .{
            .width = approx_width,
            .height = self.font_config.size * self.font_config.line_height,
        };
    }

    /// Glyph für Character holen
    pub fn getGlyph(self: *const Self, char: u21) ?GlyphEntry {
        _ = self;
        _ = char;
        // TODO: Glyph aus Atlas/Cache holen
        return null;
    }

    /// Atlas-Textur für GPU
    pub fn getAtlasTexture(self: *const Self) ?[]const u8 {
        if (self.atlas_loaded) {
            return self.atlas_texture;
        }
        return null;
    }
};
