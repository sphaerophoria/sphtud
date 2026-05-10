const config = @import("config");

pub const alloc = @import("alloc.zig");
pub const math = @import("math.zig");
pub const util = @import("util.zig");
pub const http = @import("http.zig");
pub const text = if (config.export_sphrender) @import("text.zig") else void;
pub const render = if (config.export_sphrender) @import("render.zig") else void;
pub const ui = if (config.export_sphrender) @import("ui.zig") else void;
pub const window = if (config.export_sphwindow) @import("window.zig") else void;
pub const xml = @import("xml.zig");
pub const img = @import("img.zig");
pub const io = @import("io.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
