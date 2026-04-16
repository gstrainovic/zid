const std = @import("std");

pub const FileKind = enum {
    text,
    image,
    pdf,
    terminal,
    markdown_preview,
};

pub fn getFileKind(path: []const u8) FileKind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return .pdf;
    const images = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".svg" };
    
    // Einfacher Case-Insensitive Check ohne Buffer-Stress
    for (images) |img_ext| {
        if (std.ascii.eqlIgnoreCase(ext, img_ext)) return .image;
    }
    return .text;
}
