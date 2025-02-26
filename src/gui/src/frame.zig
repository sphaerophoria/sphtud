const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputResponse = gui.InputResponse;
const InputState = gui.InputState;
const Widget = gui.Widget;

pub const Shared = struct {
    border_size: u31,
};

pub fn Options(comptime Action: type) type {
    return struct {
        inner: Widget(Action),
        shared: *const Shared,
    };
}

pub fn makeFrame(comptime Action: type, alloc: Allocator, options: Options(Action)) !Widget(Action) {
    const ctx = try alloc.create(Frame(Action));

    ctx.* = .{
        .inner = options.inner,
        .shared = options.shared,
    };

    return .{
        .ctx = ctx,
        .name = "frame",
        .vtable = &Frame(Action).widget_vtable,
    };
}

pub fn Frame(comptime Action: type) type {
    return struct {
        inner: Widget(Action),
        shared: *const Shared,

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        const Self = @This();

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.inner.render(self.adjustBounds(widget_bounds), window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const size = self.inner.getSize();
            return .{
                .width = size.width + self.shared.border_size * 2,
                .height = size.height + self.shared.border_size * 2,
            };
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.update(self.adjustSize(available_size));
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setInputState(self.adjustBounds(widget_bounds), self.adjustBounds(input_bounds), input_state);
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setFocused(focused);
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.reset();
        }

        fn adjustSize(self: Self, size: PixelSize) PixelSize {
            return .{
                .width = size.width - self.shared.border_size * 2,
                .height = size.height - self.shared.border_size * 2,
            };
        }

        fn adjustBounds(self: Self, bounds: PixelBBox) PixelBBox {
            return .{
                .top = bounds.top + self.shared.border_size,
                .bottom = bounds.bottom - self.shared.border_size,
                .left = bounds.left + self.shared.border_size,
                .right = bounds.right - self.shared.border_size,
            };
        }
    };
}
