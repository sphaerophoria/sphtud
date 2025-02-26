const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Widget = gui.Widget;

pub fn makeNull(comptime Action: type) Widget(Action) {
    const vtable = Widget(Action).VTable{
        .render = nullRender,
        .getSize = nullSize,
        .update = null,
        .setFocused = null,
        .setInputState = null,
        .reset = null,
    };

    return .{
        .ctx = null,
        .name = "null",
        .vtable = &vtable,
    };
}

fn nullRender(_: ?*anyopaque, _: gui.PixelBBox, _: gui.PixelBBox) void {}
fn nullSize(_: ?*anyopaque) gui.PixelSize {
    return .{
        .width = 0,
        .height = 0,
    };
}
