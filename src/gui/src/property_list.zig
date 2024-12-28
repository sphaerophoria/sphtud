const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputResponse = gui.InputResponse;
const InputState = gui.InputState;

pub const Style = struct {
    value_width: u31,
    item_pad: u31,
};

// Key value list where value has a fixed width. You may think that this is a
// standard table. Keep in mind that layout of key/value boxes is specialized
// such that the key is left justified and the value is center justified. If
// you replace this make sure each column can be individually justified
pub fn PropertyList(comptime Action: type) type {
    return struct {
        items: std.ArrayListUnmanaged(Item) = .{},
        // If key ever needs focus, this needs to be updated to indicate
        // whether the key/value is focused
        focused_id: ?usize = null,
        style: *const Style,
        size: PixelSize = .{ .width = 0, .height = 0 },

        const Self = @This();

        const Item = struct {
            key: Widget(Action),
            value: Widget(Action),
        };

        const widget_vtable = Widget(Action).VTable{
            .deinit = Self.widgetDeinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        pub fn init(alloc: Allocator, style: *const Style) !*Self {
            const ret = try alloc.create(Self);
            ret.* = .{ .style = style };
            return ret;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.key.deinit(alloc);
                item.value.deinit(alloc);
            }
            self.items.deinit(alloc);
            alloc.destroy(self);
        }

        pub fn pushWidgets(self: *Self, alloc: Allocator, key: Widget(Action), value: Widget(Action)) !void {
            try self.items.append(alloc, .{
                .key = key,
                .value = value,
            });
        }

        pub fn clear(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.key.deinit(alloc);
                item.value.deinit(alloc);
            }
            self.items.clearAndFree(alloc);
            self.focused_id = null;
            self.size = .{ .width = 0, .height = 0 };
        }

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .vtable = &widget_vtable,
            };
        }

        fn widgetDeinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit(alloc);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var it = BoundsIter(Action){
                .items = self.items.items,
                .widget_width = widget_bounds.calcWidth(),
                .widget_left = widget_bounds.left,
                .value_width = self.style.value_width,
                .item_pad = self.style.item_pad,
                .y_offs = widget_bounds.top,
            };

            while (it.next()) |item| {
                item.key.render(item.key_box, window_bounds);
                item.value.render(item.value_box, window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const value_available = PixelSize{
                .width = self.style.value_width,
                .height = available_size.height,
            };

            const key_available = PixelSize{
                .width = available_size.width -| (self.style.value_width + self.style.item_pad),
                .height = available_size.height,
            };

            var height: u31 = 0;

            for (self.items.items) |item| {
                try item.key.update(key_available);
                try item.value.update(value_available);

                const key_size = item.key.getSize();
                const value_size = item.value.getSize();

                height += @max(key_size.height, value_size.height) + self.style.item_pad;
            }

            self.size = .{
                .width = available_size.width,
                // We have over-counted by 1
                .height = height -| self.style.item_pad,
            };
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret = InputResponse(Action){
                .wants_focus = false,
                .action = null,
            };

            var it = BoundsIter(Action){
                .items = self.items.items,
                .widget_width = widget_bounds.calcWidth(),
                .widget_left = widget_bounds.left,
                .value_width = self.style.value_width,
                .item_pad = self.style.item_pad,
                .y_offs = widget_bounds.top,
            };

            while (it.next()) |item| {
                const key_response = item.key.setInputState(
                    item.key_box,
                    item.key_box.calcIntersection(input_bounds),
                    input_state,
                );
                mergeInputResponse(Action, key_response, &ret);

                const value_response = item.value.setInputState(
                    item.value_box,
                    item.value_box.calcIntersection(input_bounds),
                    input_state,
                );
                mergeInputResponse(Action, value_response, &ret);

                if (value_response.wants_focus) {
                    self.focused_id = item.idx;
                }
            }

            return ret;
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.focused_id) |id| {
                self.items.items[id].value.setFocused(focused);
            }
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.items.items) |item| {
                item.key.reset();
                item.value.reset();
            }
        }
    };
}

fn mergeInputResponse(comptime Action: type, new_response: InputResponse(Action), output: *InputResponse(Action)) void {
    if (new_response.wants_focus) {
        output.wants_focus = true;
    }

    if (new_response.action) |action| {
        output.action = action;
    }
}

fn BoundsIter(comptime Action: type) type {
    return struct {
        items: []const PropertyList(Action).Item,
        // widget == property list total bounds
        widget_width: u31,
        widget_left: i32,
        value_width: u31,
        item_pad: u31,
        y_offs: i32,

        idx: usize = 0,

        const Self = @This();
        const Output = struct {
            key_box: PixelBBox,
            value_box: PixelBBox,
            key: Widget(Action),
            value: Widget(Action),
            idx: usize,
        };

        fn next(self: *Self) ?Output {
            if (self.idx >= self.items.len) {
                return null;
            }
            defer self.idx += 1;

            const item = self.items[self.idx];

            const key_size = item.key.getSize();
            const value_size = item.value.getSize();

            const row_height = @max(key_size.height, value_size.height) + self.item_pad;
            defer self.y_offs += row_height;

            const split_width = self.widget_width -| self.value_width;

            const key_area = PixelBBox{
                .top = self.y_offs,
                .bottom = self.y_offs + row_height,
                .left = self.widget_left,
                .right = self.widget_left + split_width - self.item_pad / 2,
            };

            const value_area = PixelBBox{
                .top = self.y_offs,
                .bottom = self.y_offs + row_height,
                .left = self.widget_left + split_width + self.item_pad / 2,
                .right = self.widget_width,
            };

            const cy: i32 = @intFromFloat(key_area.cy());
            const half_key_height = key_size.height / 2;
            const key_box = PixelBBox{
                .left = self.widget_left,
                .right = self.widget_left + key_size.width,
                .top = cy - half_key_height,
                .bottom = cy + half_key_height + key_size.height % 2,
            };

            return .{
                .key_box = key_box,
                .value_box = util.centerBoxInBounds(value_size, value_area),
                .key = item.key,
                .value = item.value,
                .idx = self.idx,
            };
        }
    };
}
