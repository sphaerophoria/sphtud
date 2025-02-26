const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Scrollbar = gui.scrollbar.Scrollbar;
const SquircleRenderer = @import("SquircleRenderer.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

pub fn Layout(comptime Action: type) type {
    return struct {
        alloc: Allocator,
        cursor: Cursor,
        items: std.SegmentedList(LayoutItem, 32),
        item_pad: u31,
        focused_id: ?usize,
        // If layout is vertical, this is horizontal and vice versa
        max_perpendicular_length: u31,

        const LayoutItem = struct {
            widget: Widget(Action),
            bounds: PixelBBox,
        };

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.resetWidgets,
        };

        pub fn init(arena: Allocator, item_pad: u31) !*Self {
            const layout = try arena.create(Self);
            layout.* = .{
                .alloc = arena,
                .cursor = .{},
                .items = .{},
                .item_pad = item_pad,
                .focused_id = null,
                .max_perpendicular_length = 0,
            };
            return layout;
        }

        pub fn clear(self: *Self) void {
            self.items.clearRetainingCapacity();
            self.cursor.reset();
            self.focused_id = null;
            self.max_perpendicular_length = 0;
        }

        pub fn pushWidget(self: *Self, widget: Widget(Action)) !void {
            const size = widget.getSize();
            const bounds = self.cursor.push(size, self.item_pad);
            try self.items.append(self.alloc, .{ .bounds = bounds, .widget = widget });
            self.updatePerpendicularLength(size);
        }

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .name = "layout",
                .vtable = &widget_vtable,
            };
        }

        pub fn update(ctx: ?*anyopaque, container_size: PixelSize, delta_s: f32) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.cursor.reset();
            self.max_perpendicular_length = 0;

            var item_it = self.items.iterator(0);
            while (item_it.next()) |item| {
                try item.widget.update(self.availableSize(container_size), delta_s);
                const widget_size = item.widget.getSize();
                item.bounds = self.cursor.push(widget_size, self.item_pad);
                self.updatePerpendicularLength(widget_size);
            }

            switch (self.cursor.direction) {
                .right_to_left => {
                    self.invertWidgetsHorizontally(container_size);
                },
                .left_to_right, .top_to_bottom => {},
            }
        }

        fn invertWidgetsHorizontally(self: *Self, container_size: PixelSize) void {
            var item_it = self.items.iterator(0);
            while (item_it.next()) |item| {
                const new_right = container_size.width - item.bounds.left;
                const new_left = container_size.width - item.bounds.right;
                item.bounds.left = new_left;
                item.bounds.right = new_right;
            }
        }

        fn availableSize(self: *Self, container_size: PixelSize) PixelSize {
            return .{
                .width = container_size.width -| self.cursor.x_offs(),
                .height = container_size.height -| self.cursor.y_offs(),
            };
        }

        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var ret = gui.InputResponse(Action){
                .wants_focus = false,
                .action = null,
            };

            var item_it = self.items.iterator(0);
            var idx: usize = 0;
            while (item_it.next()) |item| {
                defer idx += 1;
                const child_bounds = childBounds(item.bounds, bounds);

                const input_response = item.widget.setInputState(
                    child_bounds,
                    child_bounds.calcIntersection(input_bounds),
                    input_state,
                );

                if (input_response.wants_focus) {
                    if (self.focused_id) |id| {
                        self.items.at(id).widget.setFocused(false);
                    }
                    self.focused_id = idx;
                    ret.wants_focus = true;
                }

                if (input_response.action) |action| {
                    ret.action = action;
                }
            }

            return ret;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var item_it = self.items.iterator(0);
            while (item_it.next()) |item| {
                const child_bounds = childBounds(item.bounds, bounds);
                item.widget.render(child_bounds, window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (self.cursor.direction) {
                .left_to_right, .right_to_left => {
                    return .{
                        .width = self.cursor.offs -| self.item_pad,
                        .height = self.max_perpendicular_length,
                    };
                },
                .top_to_bottom => {
                    return .{
                        .width = self.max_perpendicular_length,
                        .height = self.cursor.offs -| self.item_pad,
                    };
                },
            }
        }

        fn resetWidgets(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var item_it = self.items.iterator(0);
            while (item_it.next()) |item| {
                item.widget.reset();
            }
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.focused_id) |id| {
                self.items.at(id).widget.setFocused(focused);
            }
        }

        fn updatePerpendicularLength(self: *Self, size: PixelSize) void {
            const new_length = switch (self.cursor.direction) {
                .left_to_right, .right_to_left => size.height,
                .top_to_bottom => size.width,
            };

            self.max_perpendicular_length = @max(self.max_perpendicular_length, new_length);
        }
    };
}

fn childBounds(bounds_rel_layout: PixelBBox, layout_bounds: PixelBBox) PixelBBox {
    return .{
        .top = layout_bounds.top + bounds_rel_layout.top,
        .bottom = layout_bounds.top + bounds_rel_layout.bottom,
        .left = layout_bounds.left + bounds_rel_layout.left,
        .right = layout_bounds.left + bounds_rel_layout.right,
    };
}

const Cursor = struct {
    offs: u31 = 0,

    direction: enum {
        left_to_right,
        right_to_left,
        top_to_bottom,
    } = .top_to_bottom,

    fn reset(self: *Cursor) void {
        self.offs = 0;
    }

    fn x_offs(self: Cursor) u31 {
        return switch (self.direction) {
            .left_to_right, .right_to_left => self.offs,
            .top_to_bottom => 0,
        };
    }

    fn y_offs(self: Cursor) u31 {
        return switch (self.direction) {
            .left_to_right, .right_to_left => 0,
            .top_to_bottom => self.offs,
        };
    }

    fn push(self: *Cursor, size: PixelSize, padding: u31) PixelBBox {
        const bounds = PixelBBox{
            .left = self.x_offs(),
            .right = self.x_offs() + size.width,
            .top = self.y_offs(),
            .bottom = self.y_offs() + size.height,
        };

        switch (self.direction) {
            .top_to_bottom => self.offs += size.height + padding,
            .left_to_right, .right_to_left => self.offs += size.width + padding,
        }

        return bounds;
    }
};
