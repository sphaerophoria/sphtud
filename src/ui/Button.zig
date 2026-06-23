const std = @import("std");
const Allocator = std.mem.Allocator;
const sphtud = @import("../sphtud.zig");
const sphmath = sphtud.math;
const sphrender = sphtud.render;
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

    pub fn render(self: Shared, color: Color, widget_bounds: PixelBBox, transform: sphmath.Transform) void {
        self.squircle_renderer.render(color, self.style.corner_radius, widget_bounds, transform);
    }
};

pub const Style = struct {
    default_color: Color,
    hover_color: Color,
    click_color: Color,
    corner_radius: f32 = 20.0,
    width: u31,
    height: u31,
    pad: u31,
};

label: *Widget,
on_click: usize,
shared: *const Shared,
state: enum { none, hovered, clicked } = .none,
widget: Widget,

const Self = @This();

pub fn init(label: *Widget, on_click: usize, shared: *const Shared) !Self {
    return .{
        .label = label,
        .on_click = on_click,
        .shared = shared,
        .widget = .{
            .size = .{
                .width = shared.style.width,
                .height = shared.style.height,
            },
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
    const label_available = gui.PixelSize{
        .height = self.shared.style.height - self.shared.style.pad * 2,
        .width = self.shared.style.width - self.shared.style.pad * 2,
    };
    try self.label.update(label_available, delta_s);
    self.widget.size.height = @max(self.shared.style.height, self.label.size.height + self.shared.style.pad * 2);
}

fn input(widget: *Widget, _: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const mouse_pressed_in_box = input_bounds.containsOptMousePos(input_state.mouse_down_location);
    const cursor_in_box = input_bounds.containsMousePos(input_state.mouse_pos);

    if (mouse_pressed_in_box and cursor_in_box) {
        if (input_state.mouse_pressed) {
            self.state = .clicked;
        }
        if (self.state == .clicked and input_state.mouse_released) {
            self.state = .none;
            try self.shared.event_queue.appendBounded(self.on_click);
        }
    } else if (cursor_in_box) {
        self.state = .hovered;
    } else {
        self.state = .none;
    }
}

fn render(widget: *Widget, bounds: PixelBBox, window: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const color = switch (self.state) {
        .none => self.shared.style.default_color,
        .hovered => self.shared.style.hover_color,
        .clicked => self.shared.style.click_color,
    };

    const transform = util.widgetToClipTransform(bounds, window);
    self.shared.render(color, bounds, transform);

    const label_bounds = util.centerBoxInBounds(self.label.size, bounds);
    self.label.render(label_bounds, window);
}
