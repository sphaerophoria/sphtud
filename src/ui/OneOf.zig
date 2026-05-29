const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("../ui.zig");
const sphalloc = @import("../alloc.zig");
const Sphalloc = sphalloc.Sphalloc;
const sphutil = @import("../util.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

options: []*gui.Widget,
selected: usize,
widget: gui.Widget,

const OneOf = @This();

pub fn init(options: []*gui.Widget) !OneOf {
    return .{
        .options = options,
        .selected = 0,
        .widget = .{
            .size = .{},
            .focused = false,
            .vtable = &.{
                .render = render,
                .update = update,
                .input = input,
                .reset = reset,
            },
        },
    };
}

const Self = @This();

fn getSelected(self: *Self) *gui.Widget {
    return self.options[self.selected];
}

fn render(widget: *gui.Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.getSelected().render(widget_bounds, window_bounds);
}

fn update(widget: *gui.Widget, available_size: PixelSize, delta_s: f32) anyerror!void {
    const self: *Self = @fieldParentPtr("widget", widget);

    // Update all widget so that we have accurate size estimates
    for (self.options) |w| {
        try w.update(available_size, delta_s);
    }

    // This seems odd, but the point of this widget is to provide some
    // stability when toggling between options. If this shows up in a
    // scroll view, switching widgets will jump the scroll area around.
    // Ensure we have a stable size by always expanding to the maximum
    // of all children, even if there is no content to show
    var size = PixelSize{};
    for (self.options) |w| {
        const widget_size = w.size;
        size.width = @max(widget_size.width, size.width);
        size.height = @max(widget_size.height, size.height);
    }
    self.widget.size = size;
}

fn input(widget: *gui.Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    return self.getSelected().input(widget_bounds, input_bounds, input_state);
}

fn reset(widget: *gui.Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.getSelected().reset();
}
