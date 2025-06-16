const config = @import("config");

pub const alloc = @import("sphalloc");
pub const math = @import("sphmath");
pub const util = @import("sphutil");
pub const http = @import("sphttp");
pub const text = if (config.export_sphrender) @import("sphtext") else void;
pub const render = if (config.export_sphrender) @import("sphrender") else void;
pub const ui = if (config.export_sphrender) @import("sphui") else void;
pub const window = if (config.export_sphwindow) @import("sphwindow") else void;
pub const event = @import("sphevent");
