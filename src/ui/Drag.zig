const sphtud = @import("../sphtud.zig");
const sphmath = sphtud.math;
const gui = @import("../ui.zig");
const SquircleRenderer = @import("../ui/SquircleRenderer.zig");
const util = @import("../ui/util.zig");
const InputState = gui.InputState;
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

pub const Shared = struct {
    squircle_renderer: *const SquircleRenderer,
    event_queue: *gui.EventQueue,
    style: Style,
};

pub const Style = struct {
    size: PixelSize,
    default_color: Color,
    hover_color: Color,
    active_color: Color,
    corner_radius: f32 = 20.0,
};

label: *Widget,
on_drag_start: usize,
on_drag: usize,
shared: *const Shared,
state: enum { default, hovered, dragging } = .default,
drag_delta_px: f32 = 0,
widget: Widget,

const Self = @This();

pub fn init(label: *Widget, on_drag_start: usize, on_drag: usize, shared: *const Shared) Self {
    return .{
        .label = label,
        .on_drag_start = on_drag_start,
        .on_drag = on_drag,
        .shared = shared,
        .widget = .{
            .size = shared.style.size,
            .vtable = &.{
                .update = update,
                .input = input,
                .render = render,
                .reset = null,
            },
            .focused = false,
        },
    };
}

fn update(widget: *Widget, _: PixelSize, delta_s: f32) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    try self.label.update(self.widget.size, delta_s);
}

fn input(widget: *Widget, _: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    if (input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
        const anchor_x = input_state.mouse_down_location.?.x;

        const event = switch (self.state) {
            .dragging => self.on_drag,
            .hovered, .default => self.on_drag_start,
        };
        try self.shared.event_queue.appendBounded(event);

        self.state = .dragging;

        self.drag_delta_px = input_state.mouse_pos.x - anchor_x;
    } else if (input_bounds.containsMousePos(input_state.mouse_pos)) {
        self.state = .hovered;
    } else {
        self.state = .default;
    }
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const color = switch (self.state) {
        .default => self.shared.style.default_color,
        .hovered => self.shared.style.hover_color,
        .dragging => self.shared.style.active_color,
    };

    const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
    self.shared.squircle_renderer.render(color, self.shared.style.corner_radius, widget_bounds, transform);

    const label_bounds = util.centerBoxInBounds(self.label.size, widget_bounds);
    self.label.render(label_bounds, window_bounds);
}
