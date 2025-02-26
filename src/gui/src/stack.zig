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
                item.widget.render(itemBounds(stack_bounds, item.layout, item.widget.getSize()), window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.total_size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.total_size = .{ .width = 0, .height = 0 };

            for (self.items.slice()) |item| {
                if (item.layout.size_policy == .match_siblings) continue;
                try item.widget.update(available_size, delta_s);

                const item_size = item.widget.getSize();
                self.total_size = newTotalSize(self.total_size, item.layout, item_size);
            }

            for (self.items.slice()) |item| {
                if (item.layout.size_policy == .match_siblings) {
                    try item.widget.update(self.total_size, delta_s);
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
                const item_bounds = itemBounds(stack_bounds, item.layout, item.widget.getSize());
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

        fn itemBounds(stack_bounds: PixelBBox, layout: Layout, item_size: PixelSize) PixelBBox {
            const base_left = switch (layout.horizontal_justify) {
                .left => stack_bounds.left,
                .right => stack_bounds.right - item_size.width,
                .center => @divTrunc(stack_bounds.left + stack_bounds.right - item_size.width, 2),
            };

            const base_top = switch (layout.vertical_justify) {
                .top => stack_bounds.top,
                .bottom => stack_bounds.bottom - item_size.height,
                .center => @divTrunc(stack_bounds.top + stack_bounds.bottom - item_size.height, 2),
            };

            const left = base_left + layout.x_offs;
            const top = base_top + layout.y_offs;

            return .{
                .left = left,
                .right = left + item_size.width,
                .top = top,
                .bottom = top + item_size.height,
            };
        }

        fn newTotalSize(old_size: PixelSize, layout: Layout, widget_size: PixelSize) PixelSize {
            const old_bounds = PixelBBox{
                .left = 0,
                .top = 0,
                .right = old_size.width,
                .bottom = old_size.height,
            };
            const item_bounds = itemBounds(old_bounds, layout, widget_size);
            const merged = old_bounds.calcUnion(item_bounds);
            return .{
                .width = merged.calcWidth(),
                .height = merged.calcHeight(),
            };
        }
    };
}

pub const HJustification = enum {
    left,
    right,
    center,
};

pub const VJustification = enum {
    top,
    bottom,
    center,
};

pub const SizePolicy = enum {
    allow_expand,
    match_siblings,
};

pub const Layout = struct {
    x_offs: i32 = 0,
    y_offs: i32 = 0,
    vertical_justify: VJustification = .top,
    horizontal_justify: HJustification = .left,
    size_policy: SizePolicy = .allow_expand,

    pub fn centered() Layout {
        return .{
            .vertical_justify = .center,
            .horizontal_justify = .center,
        };
    }
};
