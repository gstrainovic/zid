//! vkvg Modul für vulkan-ed
//!
//! 2D Graphics mit Vulkan-basierter Cairo-ähnlicher API.

pub const bindings = @import("bindings.zig");
pub const Renderer = @import("renderer.zig").Renderer;
pub const Icon = @import("renderer.zig").Icon;
