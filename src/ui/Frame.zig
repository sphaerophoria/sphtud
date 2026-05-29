const gui = @import("../ui.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Widget = gui.Widget;

inner: *Widget,
pad: u31,
widget: Widget,

const Self = @This();

pub fn init(inner: *Widget, pad: u31) Self {
    return .{
        .inner = inner,
        .pad = pad,
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
    try self.inner.update(adjustSize(self.pad, available_size), delta_s);
    self.widget.size = .{
        .width = self.inner.size.width + self.pad * 2,
        .height = self.inner.size.height + self.pad * 2,
    };
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.inner.render(adjustBounds(self.pad, widget_bounds), window_bounds);
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const adjusted = adjustBounds(self.pad, widget_bounds);

    try self.inner.input(
        adjusted,
        adjusted.calcIntersection(input_bounds),
        input_state,
    );
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.inner.reset();
}

fn adjustSize(pad: u31, size: PixelSize) PixelSize {
    return .{
        .width = size.width -| pad * 2,
        .height = size.height -| pad * 2,
    };
}

fn adjustBounds(pad: u31, bounds: PixelBBox) PixelBBox {
    return .{
        .top = bounds.top + pad,
        .bottom = bounds.bottom - pad,
        .left = bounds.left + pad,
        .right = bounds.right - pad,
    };
}
