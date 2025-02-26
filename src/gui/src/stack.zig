const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

pub fn Stack(comptime Action: type, max_elems: comptime_int) type {
    return struct {
        alloc: Allocator,
        items: std.BoundedArray(StackItem, max_elems) = .{},
        total_size: PixelSize = .{ .width = 0, .height = 0 },
        focused_id: ?usize = null,

        const Self = @This();

        pub const Layout = union(enum) {
            centered,
            offset: struct {
                x_offs: i32,
                y_offs: i32,
            },
            fill,
        };

        const StackItem = struct {
            layout: Layout,
            widget: Widget(Action),
        };

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        pub fn init(alloc: Allocator) !*Self {
            const stack = try alloc.create(Self);
            stack.* = .{
                .alloc = alloc,
            };
            return stack;
        }

        pub fn pushWidget(self: *Self, widget: Widget(Action), layout: Layout) !void {
            try self.items.append(.{
                .layout = layout,
                .widget = widget,
            });

            const item_size = widget.getSize();
            self.total_size = newTotalSize(self.total_size, layout, item_size);
        }

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .name = "stack",
                .vtable = &widget_vtable,
            };
        }

        fn render(ctx: ?*anyopaque, stack_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.items.slice()) |item| {
                item.widget.render(itemBounds(stack_bounds, item.layout, item.widget), window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.total_size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.total_size = .{ .width = 0, .height = 0 };

            for (self.items.slice()) |item| {
                if (item.layout == .fill) continue;
                try item.widget.update(available_size);

                const item_size = item.widget.getSize();
                self.total_size = newTotalSize(self.total_size, item.layout, item_size);
            }

            for (self.items.slice()) |item| {
                if (item.layout == .fill) {
                    try item.widget.update(self.total_size);
                }
            }
        }

        fn setInputState(ctx: ?*anyopaque, stack_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret = gui.InputResponse(Action){
                .wants_focus = false,
                .action = null,
            };

            const items = self.items.slice();
            var i: usize = items.len;
            while (i > 0) {
                i -= 1;

                const item = items[i];
                const item_bounds = itemBounds(stack_bounds, item.layout, item.widget);
                const item_input_bounds = item_bounds.calcIntersection(input_bounds);

                ret = item.widget.setInputState(item_bounds, item_input_bounds, input_state);
                if (ret.wants_focus) {
                    self.focused_id = i;
                }

                if (ret.wants_focus or util.itemConsumesInput(item_input_bounds, input_state)) {
                    break;
                }
            }

            return ret;
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.focused_id) |id| {
                self.items.slice()[id].widget.setFocused(focused);
            }
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.items.slice()) |item| {
                item.widget.reset();
            }
        }

        fn itemBounds(stack_bounds: PixelBBox, layout: Layout, widget: Widget(Action)) PixelBBox {
            switch (layout) {
                .centered => return util.centerBoxInBounds(widget.getSize(), stack_bounds),
                .offset => |offs| {
                    const item_size = widget.getSize();
                    const left = stack_bounds.left + offs.x_offs;
                    const top = stack_bounds.top + offs.y_offs;
                    return .{
                        .left = left,
                        .right = left + item_size.width,
                        .top = top,
                        .bottom = top + item_size.height,
                    };
                },
                .fill => {
                    const item_size = widget.getSize();
                    return .{
                        .left = stack_bounds.left,
                        .right = stack_bounds.left + item_size.width,
                        .top = stack_bounds.top,
                        .bottom = stack_bounds.top + item_size.height,
                    };
                },
            }
        }

        fn newTotalSize(old_size: PixelSize, layout: Layout, widget_size: PixelSize) PixelSize {
            var new_size = old_size;
            switch (layout) {
                .centered => {
                    new_size.width = @max(new_size.width, widget_size.width);
                    new_size.height = @max(new_size.height, widget_size.height);
                },
                .offset => |offs| {
                    new_size.width = @max(new_size.width, widget_size.width + offs.x_offs);
                    new_size.height = @max(new_size.height, widget_size.height + offs.y_offs);
                },
                .fill => {},
            }
            return new_size;
        }
    };
}
