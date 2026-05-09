const config = @import("config");

pub const alloc = @import("sphalloc");
pub const math = @import("sphmath");
pub const net = @import("sphnet");
pub const util = @import("sphutil");
pub const http = @import("sphttp");
pub const text = if (config.export_sphrender) @import("text.zig") else void;
pub const render = if (config.export_sphrender) @import("sphrender") else void;
pub const ui = if (config.export_sphrender) @import("ui.zig") else void;
pub const window = if (config.export_sphwindow) @import("window.zig") else void;
pub const xml = @import("sphxml");
pub const img = @import("img.zig");
pub const io = @import("io.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
