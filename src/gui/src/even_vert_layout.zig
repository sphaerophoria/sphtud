const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

pub const Shared = struct {
    border_size: u31,
    border_color: gui.Color,
    corner_radius: f32,
    squircle_renderer: *const gui.SquircleRenderer,
};

pub fn EvenVertLayout(comptime Action: type, comptime max_size: comptime_int) type {
    return struct {
        items: std.BoundedArray(Widget(Action), max_size) = .{},
        container_size: PixelSize = .{ .width = 0, .height = 0 },
        focused_id: ?usize = null,
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

        pub fn init(alloc: Allocator, shared: *const Shared) !*Self {
            const ret = try alloc.create(Self);
            ret.* = .{
                .shared = shared,
            };
            return ret;
        }

        pub fn pushWidget(self: *Self, widget: Widget(Action)) !void {
            try self.items.append(widget);
        }

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .vtable = &widget_vtable,
            };
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const items = self.items.slice();

            for (1..items.len) |i| {
                const border_bounds = borderBounds(
                    widget_bounds,
                    self.shared.border_size,
                    i,
                    items.len,
                );
                const transform = util.widgetToClipTransform(border_bounds, window_bounds);
                self.shared.squircle_renderer.render(
                    self.shared.border_color,
                    self.shared.corner_radius,
                    border_bounds,
                    transform,
                );
            }

            for (0..items.len) |i| {
                const item = items[i];
                const child_bounds = childBounds(
                    widget_bounds,
                    self.shared.border_size,
                    item.getSize(),
                    i,
                    items.len,
                );

                item.render(child_bounds, window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.container_size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.container_size = available_size;

            const items = self.items.slice();
            const child_size = calcChildSize(
                items.len,
                self.container_size,
                self.shared.border_size,
            );
            for (items) |item| {
                try item.update(child_size);
            }
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret = gui.InputResponse(Action){
                .wants_focus = false,
                .action = null,
            };

            const items = self.items.slice();
            for (items, 0..) |item, i| {
                const child_bounds = childBounds(
                    widget_bounds,
                    self.shared.border_size,
                    item.getSize(),
                    i,
                    items.len,
                );

                const frame_area = PixelBBox{
                    .top = child_bounds.top,
                    .bottom = child_bounds.top + @as(i32, @intCast(self.container_size.height / items.len)),
                    .left = widget_bounds.left,
                    .right = widget_bounds.right,
                };

                const input_area = frame_area.calcIntersection(child_bounds).calcIntersection(input_bounds);

                const response = item.setInputState(child_bounds, input_area, input_state);

                if (response.wants_focus) {
                    ret.wants_focus = true;
                    self.focused_id = i;
                }

                if (response.action) |action| {
                    ret.action = action;
                }
            }

            return ret;
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const items = self.items.slice();
            if (self.focused_id) |id| {
                items[id].setFocused(focused);
            }
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const items = self.items.slice();
            for (items) |item| {
                item.reset();
            }
        }
    };
}

fn calcChildSize(num_children: usize, available_size: PixelSize, border_size: u31) PixelSize {
    const frame_width = available_size.width;
    const total_border_height = (num_children -| 1) * border_size;
    var frame_height: u31 = @intCast((available_size.height - total_border_height) / num_children);
    frame_height += @intCast(num_children % 2);

    return .{
        .width = frame_width,
        .height = frame_height,
    };
}

fn borderBounds(layout_bounds: PixelBBox, border_size: u31, idx: usize, num_children: usize) PixelBBox {
    const available_height = layout_bounds.calcHeight() + border_size;
    const bottom = @as(i32, @intCast(available_height * idx / num_children));
    return .{
        .left = layout_bounds.left,
        .right = layout_bounds.right,
        .top = bottom - border_size,
        .bottom = bottom,
    };
}

fn childBounds(layout_bounds: PixelBBox, border_size: u31, widget_size: PixelSize, idx: usize, num_children: usize) PixelBBox {
    // There's no top border on the top element, and no bottom border on the
    // bottom element
    // Each element after the first one starts after a border
    // Add one border height to the total height
    const available_height = layout_bounds.calcHeight() + border_size;
    const top = @as(i32, @intCast(available_height * idx / num_children));
    const left = layout_bounds.left;
    return .{
        .left = left,
        .right = left + widget_size.width,
        .top = top,
        .bottom = top + widget_size.height,
    };
}
