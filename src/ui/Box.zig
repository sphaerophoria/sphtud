const gui = @import("../ui.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Widget = gui.Widget;

pub const FillStyle = enum {
    fill_none,
    fill_width,
    fill_height,
};

inner: *Widget,
fill_style: FillStyle,
widget: Widget,

const Self = @This();

pub fn init(inner: *Widget, size: PixelSize, fill_style: FillStyle) Self {
    return .{
        .inner = inner,
        .fill_style = fill_style,
        .widget = .{
            .focused = false,
            .size = size,
            .vtable = &.{
                .update = update,
                .render = render,
                .input = input,
                .reset = reset,
            },
        },
    };
}

fn update(widget: *Widget, available: PixelSize, delta_s: f32) anyerror!void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const inner_available: PixelSize = switch (self.fill_style) {
        .fill_none => self.widget.size,
        .fill_width => .{ .width = available.width, .height = self.widget.size.height },
        .fill_height => .{ .width = self.widget.size.width, .height = available.height },
    };

    try self.inner.update(inner_available, delta_s);
    self.widget.size = self.inner.size;
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.inner.render(widget_bounds, window_bounds);
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    try self.inner.input(widget_bounds, input_bounds, input_state);
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.inner.reset();
}
