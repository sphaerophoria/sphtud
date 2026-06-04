const gui = @import("../ui.zig");

const Centered = @This();

inner: *gui.Widget,
widget: gui.Widget,

pub fn init(inner: *gui.Widget) Centered {
    return .{
        .inner = inner,
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

fn update(widget: *gui.Widget, available: gui.PixelSize, delta_s: f32) anyerror!void {
    const self: *Centered = @fieldParentPtr("widget", widget);
    try self.inner.update(available, delta_s);
    self.widget.size = available;
}

fn render(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *Centered = @fieldParentPtr("widget", widget);

    const inner_bounds = gui.util.centerBoxInBounds(self.inner.size, widget_bounds);
    self.inner.render(inner_bounds, window_bounds);
}

fn input(widget: *gui.Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) anyerror!void {
    const self: *Centered = @fieldParentPtr("widget", widget);

    const inner_bounds = gui.util.centerBoxInBounds(self.inner.size, widget_bounds);
    try self.inner.input(inner_bounds, inner_bounds.calcIntersection(input_bounds), input_state);
}

fn reset(widget: *gui.Widget) void {
    const self: *Centered = @fieldParentPtr("widget", widget);
    self.inner.reset();
}
