//! Theme System für vulkan-ed
//!
//! Catppuccin Light/Dark Themes für UI Components.
//! Verwendet 0-255 Bereich für Clay Kompatibilität.

const std = @import("std");
const clay = @import("clay");

pub const Theme = struct {
    // Background colors
    bg: clay.Color,
    surface: clay.Color,
    overlay: clay.Color,

    // Accent colors
    primary: clay.Color,
    secondary: clay.Color,
    accent: clay.Color,
    success: clay.Color,
    warning: clay.Color,
    danger: clay.Color,

    // Text colors
    text: clay.Color,
    subtext: clay.Color,
    muted: clay.Color,
    text_on_primary: clay.Color,
    text_on_accent: clay.Color,

    // Border colors
    border: clay.Color,
    border_focus: clay.Color,

    // Radius
    radius_sm: f32 = 4.0,
    radius_md: f32 = 8.0,
    radius_lg: f32 = 16.0,

    // Font
    font_size_base: u16 = 14,

    const Self = @This();

    /// Catppuccin Latte (Light Theme)
    pub fn light() Self {
        return Self{
            .bg = .{ 239, 241, 245, 255 },
            .surface = .{ 220, 224, 232, 255 },
            .overlay = .{ 188, 194, 208, 255 },

            .primary = .{ 30, 102, 245, 255 },
            .secondary = .{ 108, 112, 134, 255 },
            .accent = .{ 137, 67, 255, 255 },
            .success = .{ 64, 160, 43, 255 },
            .warning = .{ 223, 142, 29, 255 },
            .danger = .{ 210, 15, 57, 255 },

            .text = .{ 76, 79, 105, 255 },
            .subtext = .{ 92, 96, 122, 255 },
            .muted = .{ 127, 132, 156, 255 },
            .text_on_primary = .{ 255, 255, 255, 255 },
            .text_on_accent = .{ 255, 255, 255, 255 },

            .border = .{ 188, 194, 208, 255 },
            .border_focus = .{ 30, 102, 245, 255 },
        };
    }

    /// Catppuccin Macchiato (Dark Theme)
    pub fn dark() Self {
        return Self{
            .bg = .{ 36, 39, 58, 255 },
            .surface = .{ 49, 54, 74, 255 },
            .overlay = .{ 69, 71, 90, 255 },

            .primary = .{ 138, 173, 244, 255 },
            .secondary = .{ 128, 132, 154, 255 },
            .accent = .{ 199, 146, 234, 255 },
            .success = .{ 166, 209, 137, 255 },
            .warning = .{ 238, 190, 118, 255 },
            .danger = .{ 237, 135, 150, 255 },

            .text = .{ 202, 211, 245, 255 },
            .subtext = .{ 165, 173, 206, 255 },
            .muted = .{ 108, 112, 134, 255 },
            .text_on_primary = .{ 30, 30, 46, 255 },
            .text_on_accent = .{ 30, 30, 46, 255 },

            .border = .{ 69, 71, 90, 255 },
            .border_focus = .{ 138, 173, 244, 255 },
        };
    }
};
