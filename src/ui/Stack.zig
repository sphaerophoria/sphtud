const gui = @import("../ui.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Widget = gui.Widget;

pub const StackItem = struct {
    widget: *Widget,
    /// If true, this item is updated with the size of non-match_siblings items
    /// and rendered filling the full stack bounds. Use for backgrounds.
    match_siblings: bool = false,
};

items: []const StackItem,
widget: Widget,

const Self = @This();

pub fn init(items: []const StackItem) Self {
    return .{
        .items = items,
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = update,
                .render = render,
                .input = input,
                .reset = reset,
            },
        },
    };
}

fn update(widget: *Widget, available_size: PixelSize, delta_s: f32) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    var total_size = PixelSize{ .width = 0, .height = 0 };

    for (self.items) |item| {
        if (item.match_siblings) continue;
        try item.widget.update(available_size, delta_s);
        total_size.width = @max(total_size.width, item.widget.size.width);
        total_size.height = @max(total_size.height, item.widget.size.height);
    }

    for (self.items) |item| {
        if (!item.match_siblings) continue;
        try item.widget.update(total_size, delta_s);
    }

    self.widget.size = total_size;
}

fn itemBounds(stack_bounds: PixelBBox, item: StackItem) PixelBBox {
    if (item.match_siblings) return stack_bounds;
    return .{
        .top = stack_bounds.top,
        .left = stack_bounds.left,
        .right = stack_bounds.left + item.widget.size.width,
        .bottom = stack_bounds.top + item.widget.size.height,
    };
}

fn render(widget: *Widget, stack_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    for (self.items) |item| {
        item.widget.render(itemBounds(stack_bounds, item), window_bounds);
    }
}

fn input(widget: *Widget, stack_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    var i = self.items.len;
    while (i > 0) {
        i -= 1;
        const item = self.items[i];
        const ib = itemBounds(stack_bounds, item);
        try item.widget.input(ib, ib.calcIntersection(input_bounds), input_state);
    }
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    for (self.items) |item| {
        item.widget.reset();
    }
}
