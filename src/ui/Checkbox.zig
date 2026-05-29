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
    outer_size: u31,
    inner_size: u31,
    outer_color: Color,
    inner_color: Color,
    outer_hover_color: Color,
    inner_hover_color: Color,
    corner_radius: f32 = 5.0,
};

checked: bool,
on_toggle: usize,
hovered: bool = false,
shared: *const Shared,
widget: Widget,

const Self = @This();

pub fn init(checked: bool, on_toggle: usize, shared: *const Shared) Self {
    return .{
        .checked = checked,
        .on_toggle = on_toggle,
        .shared = shared,
        .widget = .{
            .size = .{
                .width = shared.style.outer_size,
                .height = shared.style.outer_size,
            },
            .vtable = &.{
                .update = null,
                .input = input,
                .render = render,
                .reset = null,
            },
            .focused = false,
        },
    };
}

fn input(widget: *Widget, _: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    self.hovered = input_bounds.containsMousePos(input_state.mouse_pos);

    if (input_bounds.containsOptMousePos(input_state.mouse_down_location) and input_state.mouse_pressed) {
        self.checked = !self.checked;
        try self.shared.event_queue.appendBounded(self.on_toggle);
    }
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const outer_color = if (self.hovered)
        self.shared.style.outer_hover_color
    else
        self.shared.style.outer_color;

    const outer_bounds = checkboxBounds(widget_bounds, self.shared.style.outer_size);
    const outer_transform = util.widgetToClipTransform(outer_bounds, window_bounds);
    self.shared.squircle_renderer.render(
        outer_color,
        self.shared.style.corner_radius,
        outer_bounds,
        outer_transform,
    );

    if (self.checked) {
        const inner_color = if (self.hovered)
            self.shared.style.inner_hover_color
        else
            self.shared.style.inner_color;

        const inner_bounds = innerBounds(
            widget_bounds,
            self.shared.style.outer_size,
            self.shared.style.inner_size,
        );
        const inner_transform = util.widgetToClipTransform(inner_bounds, window_bounds);
        self.shared.squircle_renderer.render(
            inner_color,
            self.shared.style.corner_radius,
            inner_bounds,
            inner_transform,
        );
    }
}

fn checkboxBounds(widget_bounds: PixelBBox, size: u31) PixelBBox {
    return .{
        .top = widget_bounds.top,
        .left = widget_bounds.left,
        .right = widget_bounds.left + size,
        .bottom = widget_bounds.top + size,
    };
}

fn innerBounds(widget_bounds: PixelBBox, outer_size: u31, inner_size: u31) PixelBBox {
    const offs = (outer_size - inner_size) / 2;
    return .{
        .top = widget_bounds.top + offs,
        .left = widget_bounds.left + offs,
        .right = widget_bounds.right - offs,
        .bottom = widget_bounds.bottom - offs,
    };
}
