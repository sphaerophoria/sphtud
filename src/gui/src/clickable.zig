const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

pub fn clickable(comptime Action: type, arena: Allocator, inner: gui.Widget(Action), action: Action) !gui.Widget(Action) {
    const ctx = try arena.create(Clickable(Action));
    ctx.* = .{
        .inner = inner,
        .action = action,
    };

    return .{
        .ctx = ctx,
        .name = "clickable",
        .vtable = &Clickable(Action).widget_vtable,
    };
}

pub fn Clickable(comptime Action: type) type {
    return struct {
        inner: Widget(Action),
        action: Action,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.render(widget_bounds, window_bounds);
        }
        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.getSize();
        }
        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            try self.inner.update(available_size, delta_s);
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = widget_bounds;

            if (input_state.mouse_pressed and input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                return .{
                    .action = self.action,
                };
            }

            return .{};
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.setFocused(focused);
        }
        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.reset();
        }
    };
}
