const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;

pub fn PopupLayer(comptime Action: type) type {
    return struct {
        inner: ?Data = null,
        container_size: PixelSize = .{ .width = 0, .height = 0 },

        const Data = struct {
            alloc: Allocator,
            widget: Widget(Action),
            x_offs: i32,
            y_offs: i32,
            mouse_released: bool = false,

            fn bounds(self: Data, container_bounds: PixelBBox) PixelBBox {
                const item_size = self.widget.getSize();
                const left = container_bounds.left + self.x_offs;
                const top = container_bounds.top + self.y_offs;

                return .{
                    .left = left,
                    .top = top,
                    .right = left + item_size.width,
                    .bottom = top + item_size.height,
                };
            }
        };

        const widget_vtable = Widget(Action).VTable{
            .deinit = Self.widgetDeinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.resetWidget,
        };

        const Self = @This();

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .vtable = &widget_vtable,
            };
        }

        fn widgetDeinit(ctx: ?*anyopaque, _: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.reset();
        }

        pub fn reset(self: *Self) void {
            if (self.inner) |*d| d.widget.deinit(d.alloc);
            self.inner = null;
        }

        pub fn set(
            self: *Self,
            alloc: Allocator,
            widget: Widget(Action),
            x_offs: i32,
            y_offs: i32,
        ) void {
            self.reset();
            self.inner = .{
                .alloc = alloc,
                .widget = widget,
                .x_offs = x_offs,
                .y_offs = y_offs,
            };
            self.healOffset();
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.inner) |_| {
                return self.container_size;
            } else {
                return .{ .width = 0, .height = 0 };
            }
        }

        pub fn setInputState(ctx: ?*anyopaque, layer_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const data = if (self.inner) |*i| i else return .{
                .wants_focus = false,
                .action = null,
            };
            const item_bounds = data.bounds(layer_bounds);
            const ret = data.widget.setInputState(
                item_bounds,
                input_bounds.calcIntersection(item_bounds),
                input_state,
            );

            if (input_state.mouse_down_location) |loc| {
                if (data.mouse_released and !item_bounds.containsMousePos(loc)) {
                    self.reset();
                }
            }
            data.mouse_released = data.mouse_released or input_state.mouse_released;

            return ret;
        }

        pub fn update(ctx: ?*anyopaque, container_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.container_size = container_size;
            if (self.inner) |*data| {
                try data.widget.update(container_size);
                self.healOffset();
            }
        }

        pub fn render(ctx: ?*anyopaque, layer_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const data = self.inner orelse return;
            data.widget.render(data.bounds(layer_bounds), window_bounds);
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (self.inner) |d| {
                d.widget.setFocused(focused);
            }
        }

        fn resetWidget(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (self.inner) |d| {
                d.widget.reset();
            }
        }

        fn healOffset(self: *Self) void {
            if (self.inner) |*data| {
                const window_bounds = PixelBBox{
                    .left = 0,
                    .right = self.container_size.width,
                    .top = 0,
                    .bottom = self.container_size.height,
                };
                const widget_bounds = data.bounds(window_bounds);

                if (widget_bounds.top < 0) {
                    data.y_offs -= widget_bounds.top;
                }

                if (widget_bounds.bottom >= self.container_size.height) {
                    data.y_offs -= widget_bounds.bottom - self.container_size.height;
                }

                if (widget_bounds.left < 0) {
                    data.x_offs -= widget_bounds.left;
                }

                if (widget_bounds.right >= self.container_size.width) {
                    data.x_offs -= widget_bounds.right - self.container_size.width;
                }
            }
        }
    };
}
