const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputResponse = gui.InputResponse;
const InputState = gui.InputState;
const Widget = gui.Widget;
const SquircleRenderer = gui.SquircleRenderer;

pub const Shared = struct {
    border_size: u31,
    inner_border_size: u31,
    squircle_renderer: *const SquircleRenderer,
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

            self.inner.render(adjustBounds(self.shared.border_size, widget_bounds), window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const size = self.inner.getSize();
            return .{
                .width = size.width + self.shared.border_size * 2,
                .height = size.height + self.shared.border_size * 2,
            };
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.update(adjustSize(self.shared.border_size, available_size), delta_s);
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setInputState(
                adjustBounds(self.shared.border_size, widget_bounds),
                adjustBounds(self.shared.border_size, input_bounds),
                input_state,
            );
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setFocused(focused);
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.reset();
        }
    };
}

pub fn makeColorableFrame(comptime Action: type, alloc: Allocator, inner: Widget(Action), color_retiever: anytype, shared: *const Shared) !Widget(Action) {
    const T = ColorableFrame(Action, @TypeOf(color_retiever));
    const ctx = try alloc.create(T);

    ctx.* = .{
        .inner = inner,
        .retriever = color_retiever,
        .shared = shared,
    };

    return .{
        .ctx = ctx,
        .name = "colorable frame",
        .vtable = &T.widget_vtable,
    };
}

pub fn ColorableFrame(comptime Action: type, comptime ColorRetriever: type) type {
    return struct {
        inner: Widget(Action),
        retriever: ColorRetriever,
        shared: *const Shared,

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

            if (self.retriever.getColor()) |color| {
                const left = PixelBBox{
                    .left = widget_bounds.left,
                    .right = widget_bounds.left + self.shared.border_size,
                    .top = widget_bounds.top,
                    .bottom = widget_bounds.bottom,
                };

                const right = PixelBBox{
                    .left = widget_bounds.right -| self.shared.border_size,
                    .right = widget_bounds.right,
                    .top = widget_bounds.top,
                    .bottom = widget_bounds.bottom,
                };

                const top = PixelBBox{
                    .left = widget_bounds.left,
                    .right = widget_bounds.right,
                    .top = widget_bounds.top,
                    .bottom = widget_bounds.top + self.shared.border_size,
                };

                const bottom = PixelBBox{
                    .left = widget_bounds.left,
                    .right = widget_bounds.right,
                    .top = widget_bounds.bottom -| self.shared.border_size,
                    .bottom = widget_bounds.bottom,
                };

                const left_inner = PixelBBox{
                    .left = left.right - self.shared.inner_border_size,
                    .right = left.right,
                    .top = top.bottom,
                    .bottom = bottom.top,
                };

                const right_inner = PixelBBox{
                    .left = right.left,
                    .right = right.left + self.shared.inner_border_size,
                    .top = top.bottom,
                    .bottom = bottom.top,
                };

                const top_inner = PixelBBox{
                    .left = left.right,
                    .right = right.left,
                    .top = top.bottom -| self.shared.inner_border_size,
                    .bottom = top.bottom,
                };

                const bottom_inner = PixelBBox{
                    .left = left.right,
                    .right = right.left,
                    .top = bottom.top,
                    .bottom = bottom.top + self.shared.inner_border_size,
                };

                const bounds_list: [4][2]PixelBBox = .{
                    .{ left, left_inner },
                    .{ right, right_inner },
                    .{ top, top_inner },
                    .{ bottom, bottom_inner },
                };

                for (bounds_list) |pair| {
                    {
                        const transform = gui.util.widgetToClipTransform(pair[0], window_bounds);
                        self.shared.squircle_renderer.render(
                            color,
                            0,
                            pair[0],
                            transform,
                        );
                    }

                    {
                        const transform = gui.util.widgetToClipTransform(pair[1], window_bounds);
                        self.shared.squircle_renderer.render(
                            gui.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                            0,
                            pair[1],
                            transform,
                        );
                    }
                }
            }

            self.inner.render(adjustBounds(self.shared.border_size, widget_bounds), window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const size = self.inner.getSize();
            return .{
                .width = size.width + self.shared.border_size * 2,
                .height = size.height + self.shared.border_size * 2,
            };
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.update(adjustSize(self.shared.border_size, available_size), delta_s);
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setInputState(
                adjustBounds(self.shared.border_size, widget_bounds),
                adjustBounds(self.shared.border_size, input_bounds),
                input_state,
            );
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setFocused(focused);
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.reset();
        }
    };
}

fn adjustSize(border_size: u31, size: PixelSize) PixelSize {
    return .{
        .width = size.width -| border_size * 2,
        .height = size.height -| border_size * 2,
    };
}

fn adjustBounds(border_size: u31, bounds: PixelBBox) PixelBBox {
    return .{
        .top = bounds.top + border_size,
        .bottom = bounds.bottom - border_size,
        .left = bounds.left + border_size,
        .right = bounds.right - border_size,
    };
}
