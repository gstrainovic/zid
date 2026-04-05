//! Theme System für vulkan-ed
//!
//! Catppuccin Light/Dark Themes für UI Components.

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
            .bg = .{ 239.0/255.0, 241.0/255.0, 245.0/255.0, 1.0 },
            .surface = .{ 220.0/255.0, 224.0/255.0, 232.0/255.0, 1.0 },
            .overlay = .{ 188.0/255.0, 194.0/255.0, 208.0/255.0, 1.0 },

            .primary = .{ 30.0/255.0, 102.0/255.0, 245.0/255.0, 1.0 },
            .secondary = .{ 108.0/255.0, 112.0/255.0, 134.0/255.0, 1.0 },
            .accent = .{ 137.0/255.0, 67.0/255.0, 255.0/255.0, 1.0 },
            .success = .{ 64.0/255.0, 160.0/255.0, 43.0/255.0, 1.0 },
            .warning = .{ 223.0/255.0, 142.0/255.0, 29.0/255.0, 1.0 },
            .danger = .{ 210.0/255.0, 15.0/255.0, 57.0/255.0, 1.0 },

            .text = .{ 76.0/255.0, 79.0/255.0, 105.0/255.0, 1.0 },
            .subtext = .{ 92.0/255.0, 96.0/255.0, 122.0/255.0, 1.0 },
            .muted = .{ 127.0/255.0, 132.0/255.0, 156.0/255.0, 1.0 },

            .border = .{ 188.0/255.0, 194.0/255.0, 208.0/255.0, 1.0 },
            .border_focus = .{ 30.0/255.0, 102.0/255.0, 245.0/255.0, 1.0 },
        };
    }

    /// Catppuccin Macchiato (Dark Theme)
    pub fn dark() Self {
        return Self{
            .bg = .{ 36.0/255.0, 39.0/255.0, 58.0/255.0, 1.0 },
            .surface = .{ 49.0/255.0, 54.0/255.0, 74.0/255.0, 1.0 },
            .overlay = .{ 69.0/255.0, 71.0/255.0, 90.0/255.0, 1.0 },

            .primary = .{ 138.0/255.0, 173.0/255.0, 244.0/255.0, 1.0 },
            .secondary = .{ 128.0/255.0, 132.0/255.0, 154.0/255.0, 1.0 },
            .accent = .{ 199.0/255.0, 146.0/255.0, 234.0/255.0, 1.0 },
            .success = .{ 166.0/255.0, 209.0/255.0, 137.0/255.0, 1.0 },
            .warning = .{ 238.0/255.0, 190.0/255.0, 118.0/255.0, 1.0 },
            .danger = .{ 237.0/255.0, 135.0/255.0, 150.0/255.0, 1.0 },

            .text = .{ 202.0/255.0, 211.0/255.0, 245.0/255.0, 1.0 },
            .subtext = .{ 165.0/255.0, 173.0/255.0, 206.0/255.0, 1.0 },
            .muted = .{ 108.0/255.0, 112.0/255.0, 134.0/255.0, 1.0 },

            .border = .{ 69.0/255.0, 71.0/255.0, 90.0/255.0, 1.0 },
            .border_focus = .{ 138.0/255.0, 173.0/255.0, 244.0/255.0, 1.0 },
        };
    }
};
