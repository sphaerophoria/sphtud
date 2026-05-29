const gui = @import("../ui.zig");
const SquircleRenderer = @import("../ui/SquircleRenderer.zig");
const util = @import("../ui/util.zig");
const Color = gui.Color;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Widget = gui.Widget;

pub const Shared = struct {
    squircle_renderer: *const SquircleRenderer,
    event_queue: *gui.EventQueue,
    style: Style,
};

pub const Style = struct {
    highlight_color: Color,
    hover_color: Color,
    background_color: Color,
    corner_radius: f32,
    item_pad: u31,
    min_item_height: u31,
};

selected_idx: usize = 0,
on_click: usize,

items: []const *Widget = &.{},
hover_idx: ?usize = null,
shared: *const Shared,
widget: Widget,

const Self = @This();

pub fn init(on_click: usize, shared: *const Shared) Self {
    return .{
        .on_click = on_click,
        .shared = shared,
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = update,
                .input = input,
                .render = render,
                .reset = null,
            },
        },
    };
}

pub fn setItems(self: *Self, items: []const *Widget) void {
    self.items = items;
}

fn rowHeight(self: *const Self, item: *const Widget) u31 {
    return @max(item.size.height, self.shared.style.min_item_height) + self.shared.style.item_pad;
}

fn itemRowBounds(self: *const Self, widget_bounds: PixelBBox, idx: usize) PixelBBox {
    var y: i32 = widget_bounds.top;
    for (self.items, 0..) |item, i| {
        const rh: i32 = self.rowHeight(item);
        if (i == idx) {
            return .{
                .top = y,
                .bottom = y + rh,
                .left = widget_bounds.left,
                .right = widget_bounds.right,
            };
        }
        y += rh;
    }
    unreachable;
}

fn totalHeight(self: *const Self) u31 {
    var h: u31 = 0;
    for (self.items) |item| {
        h += self.rowHeight(item);
    }
    // Remove trailing pad if any items exist
    if (self.items.len > 0) h -|= self.shared.style.item_pad;
    return @max(h, self.shared.style.min_item_height);
}

fn update(widget: *Widget, available_space: PixelSize, delta_s: f32) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    for (self.items) |item| {
        try item.update(.{ .width = available_space.width, .height = available_space.height }, delta_s);
    }

    self.widget.size = .{
        .width = available_space.width,
        .height = self.totalHeight(),
    };
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    self.hover_idx = null;

    for (self.items, 0..) |_, idx| {
        const row = self.itemRowBounds(widget_bounds, idx);
        const row_input = row.calcIntersection(input_bounds);

        if (input_state.mouse_pressed and row_input.containsOptMousePos(input_state.mouse_down_location)) {
            self.selected_idx = idx;
            try self.shared.event_queue.appendBounded(self.on_click);
        }

        if (row_input.containsMousePos(input_state.mouse_pos)) {
            self.hover_idx = idx;
        }
    }
}

fn render(widget: *Widget, bounds: PixelBBox, window: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    {
        const transform = util.widgetToClipTransform(bounds, window);
        self.shared.squircle_renderer.render(self.shared.style.background_color, self.shared.style.corner_radius, bounds, transform);
    }

    for (self.items, 0..) |item, idx| {
        const row = self.itemRowBounds(bounds, idx);

        const row_color: ?Color = if (self.hover_idx == idx)
            self.shared.style.hover_color
        else if (self.selected_idx == idx)
            self.shared.style.highlight_color
        else
            null;

        if (row_color) |color| {
            const transform = util.widgetToClipTransform(row, window);
            self.shared.squircle_renderer.render(color, self.shared.style.corner_radius, row, transform);
        }

        const item_top = row.top + @divTrunc((@as(i32, @max(item.size.height, self.shared.style.min_item_height)) - @as(i32, item.size.height)), 2);
        const item_bounds = PixelBBox{
            .top = item_top,
            .bottom = item_top + item.size.height,
            .left = row.left,
            .right = row.left + item.size.width,
        };

        item.render(item_bounds, window);
    }
}
