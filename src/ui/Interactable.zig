const gui = @import("../ui.zig");

pub const Interactable = @This();

inner: *gui.Widget,
on_click: usize,
event_queue: *gui.EventQueue,
widget: gui.Widget,

pub fn init(inner: *gui.Widget, on_click: usize, event_queue: *gui.EventQueue) Interactable {
    return .{
        .inner = inner,
        .on_click = on_click,
        .event_queue = event_queue,
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

fn update(widget: *gui.Widget, available_size: gui.PixelSize, delta_s: f32) !void {
    const self: *Interactable = @fieldParentPtr("widget", widget);
    try self.inner.update(available_size, delta_s);
    self.widget.size = self.inner.size;
}

fn render(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *Interactable = @fieldParentPtr("widget", widget);
    self.inner.render(widget_bounds, window_bounds);
}

fn input(widget: *gui.Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) !void {
    const self: *Interactable = @fieldParentPtr("widget", widget);
    try self.inner.input(widget_bounds, input_bounds, input_state);

    const held_in_box = input_bounds.containsOptMousePos(input_state.mouse_down_location);
    const cursor_in_box = input_bounds.containsMousePos(input_state.mouse_pos);
    if (held_in_box and cursor_in_box and input_state.mouse_pressed) {
        try self.event_queue.appendBounded(self.on_click);
    }
}

fn reset(widget: *gui.Widget) void {
    const self: *Interactable = @fieldParentPtr("widget", widget);
    self.inner.reset();
}
