const std = @import("std");
const sphtud = @import("../sphtud.zig");
const gui = sphtud.ui;

pub const Layout = @This();

expansion: sphtud.util.ExpansionAlloc,
cursor: Cursor,
items: sphtud.util.RuntimeSegmentedListUnmanaged(LayoutItem),
item_pad: u31,
widget: gui.Widget,
focused_id: ?usize,
// If layout is vertical, this is horizontal and vice versa
max_perpendicular_length: u31,

const LayoutItem = struct {
    widget: *gui.Widget,
    bounds: gui.PixelBBox,
};

pub fn init(arena: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc, item_pad: u31) !Layout {
    return .{
        .expansion = expansion,
        .cursor = .{},
        .items = try .init(
            arena,
            expansion,
            32,
            1024,
        ),
        .widget = .{
            .size = .{},
            .focused = false,
            .vtable = &.{
                .update = update,
                .render = render,
                .input = input,
                .reset = reset,
            },
        },
        .item_pad = item_pad,
        .focused_id = null,
        .max_perpendicular_length = 0,
    };
}

pub fn append(self: *Layout, widget: *gui.Widget) !void {
    const bounds = self.cursor.push(widget.size, self.item_pad);
    try self.items.append(self.expansion, .{ .bounds = bounds, .widget = widget });
    self.updatePerpendicularLength(widget.size);
}

pub fn clear(self: *Layout) void {
    self.items.clear(self.expansion);
}

fn update(widget: *gui.Widget, container_size: gui.PixelSize, delta_s: f32) !void {
    const self: *Layout = @fieldParentPtr("widget", widget);

    self.cursor.reset();
    self.max_perpendicular_length = 0;

    var item_it = self.items.iter();
    while (item_it.next()) |item| {
        try item.widget.update(self.availableSize(container_size), delta_s);
        item.bounds = self.cursor.push(item.widget.size, self.item_pad);
        self.updatePerpendicularLength(item.widget.size);
    }

    switch (self.cursor.direction) {
        .right_to_left => {
            self.invertWidgetsHorizontally(container_size);
        },
        .left_to_right, .top_to_bottom => {},
    }

    switch (self.cursor.direction) {
        .left_to_right, .right_to_left => {
            self.widget.size = .{
                .width = self.cursor.offs -| self.item_pad,
                .height = self.max_perpendicular_length,
            };
        },
        .top_to_bottom => {
            self.widget.size = .{
                .width = self.max_perpendicular_length,
                .height = self.cursor.offs -| self.item_pad,
            };
        },
    }
}

fn invertWidgetsHorizontally(self: *Layout, container_size: gui.PixelSize) void {
    var item_it = self.items.iter();
    while (item_it.next()) |item| {
        const new_right = container_size.width - item.bounds.left;
        const new_left = container_size.width - item.bounds.right;
        item.bounds.left = new_left;
        item.bounds.right = new_right;
    }
}

fn availableSize(self: *Layout, container_size: gui.PixelSize) gui.PixelSize {
    return .{
        .width = container_size.width -| self.cursor.x_offs(),
        .height = container_size.height -| self.cursor.y_offs(),
    };
}

fn input(widget: *gui.Widget, bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) !void {
    const self: *Layout = @fieldParentPtr("widget", widget);

    var item_it = self.items.iter();
    var idx: usize = 0;
    while (item_it.next()) |item| {
        defer idx += 1;
        const child_bounds = childBounds(item.bounds, bounds);

        try item.widget.input(
            child_bounds,
            child_bounds.calcIntersection(input_bounds),
            input_state,
        );

        if (widget.focused) {
            self.focused_id = idx;
            self.widget.focused = true;
        }
    }
}

fn render(widget: *gui.Widget, bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *Layout = @fieldParentPtr("widget", widget);

    var item_it = self.items.iter();
    while (item_it.next()) |item| {
        const child_bounds = childBounds(item.bounds, bounds);
        item.widget.render(child_bounds, window_bounds);
    }
}

fn reset(widget: *gui.Widget) void {
    const self: *Layout = @fieldParentPtr("widget", widget);

    var item_it = self.items.iter();
    while (item_it.next()) |item| {
        item.widget.reset();
    }
}

fn updatePerpendicularLength(self: *Layout, size: gui.PixelSize) void {
    const new_length = switch (self.cursor.direction) {
        .left_to_right, .right_to_left => size.height,
        .top_to_bottom => size.width,
    };

    self.max_perpendicular_length = @max(self.max_perpendicular_length, new_length);
}

fn childBounds(bounds_rel_layout: gui.PixelBBox, layout_bounds: gui.PixelBBox) gui.PixelBBox {
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

    fn push(self: *Cursor, size: gui.PixelSize, padding: u31) gui.PixelBBox {
        const bounds = gui.PixelBBox{
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
