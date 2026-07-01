const std = @import("std");
const gui = @import("../ui.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Widget = gui.Widget;

const PopupData = struct {
    widget: *Widget,
    x_offs: i32,
    y_offs: i32,
    mouse_released: bool = false,

    fn bounds(self: PopupData, container_bounds: PixelBBox) PixelBBox {
        const left = container_bounds.left + self.x_offs;
        const top = container_bounds.top + self.y_offs;
        return .{
            .left = left,
            .top = top,
            .right = left + self.widget.size.width,
            .bottom = top + self.widget.size.height,
        };
    }
};

inner: ?PopupData = null,
container_size: PixelSize = .{},
widget: Widget,

const Self = @This();

pub fn init() Self {
    return .{
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = update,
                .input = input,
                .render = render,
                .reset = reset,
            },
        },
    };
}

/// Show a popup widget at the given offset from the container's top-left.
/// The widget must already be sized (call widget.update() first if needed).
pub fn set(self: *Self, popup: *Widget, x_offs: i32, y_offs: i32) void {
    self.inner = .{ .widget = popup, .x_offs = x_offs, .y_offs = y_offs };
    self.healOffset();
}

pub fn clear(self: *Self) void {
    self.inner = null;
}

pub fn isOpen(self: *const Self) bool {
    return self.inner != null;
}

fn update(widget: *Widget, container_size: PixelSize, delta_s: f32) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.container_size = container_size;
    self.widget.size = container_size;
    if (self.inner) |*data| {
        try data.widget.update(data.widget.size, delta_s);
        self.healOffset();
    }
}

fn input(widget: *Widget, layer_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    const data = if (self.inner) |*d| d else return;

    const popup_bounds = data.bounds(layer_bounds);
    try data.widget.input(
        popup_bounds,
        popup_bounds.calcIntersection(input_bounds),
        input_state,
    );

    // Prevent mouse events from making it behind the popup
    input_state.consumeScroll();
    input_state.mouse_pressed = false;

    // Dismiss when a new click lands outside the popup, but only after the
    // click that opened it has been released (prevents instant self-close).
    if (data.mouse_released) {
        if (input_state.mouse_down_location) |loc| {
            if (!popup_bounds.containsMousePos(loc)) {
                self.inner = null;
                return;
            }
        }
    }
    // Safe to index inner again — we only return early above, never set to null then continue.
    if (self.inner) |*d| {
        d.mouse_released = d.mouse_released or input_state.mouse_released;
    }
}

fn render(widget: *Widget, layer_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    const data = self.inner orelse return;
    data.widget.render(data.bounds(layer_bounds), window_bounds);
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.inner = null;
}

fn healOffset(self: *Self) void {
    const data = if (self.inner) |*d| d else return;
    const window_bounds = PixelBBox{
        .left = 0,
        .right = self.container_size.width,
        .top = 0,
        .bottom = self.container_size.height,
    };
    const widget_bounds = data.bounds(window_bounds);

    if (widget_bounds.top < 0) data.y_offs -= widget_bounds.top;
    if (widget_bounds.bottom > self.container_size.height) data.y_offs -= widget_bounds.bottom - self.container_size.height;
    if (widget_bounds.left < 0) data.x_offs -= widget_bounds.left;
    if (widget_bounds.right > self.container_size.width) data.x_offs -= widget_bounds.right - self.container_size.width;
}
