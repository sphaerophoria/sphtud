const gui = @import("../ui.zig");
const util = @import("util.zig");
const SquircleRenderer = gui.SquircleRenderer;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Widget = gui.Widget;
const Color = gui.Color;

pub const Shared = struct {
    border_size: u31,
    inner_border_size: u31,
    squircle_renderer: *const SquircleRenderer,
};

inner: *Widget,
color: ?Color = null,
shared: *const Shared,
widget: Widget,

const Self = @This();

pub fn init(inner: *Widget, shared: *const Shared) Self {
    return .{
        .inner = inner,
        .shared = shared,
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

    try self.inner.update(adjustSize(self.shared.border_size, available_size), delta_s);

    self.widget.size = .{
        .width = self.inner.size.width + self.shared.border_size * 2,
        .height = self.inner.size.height + self.shared.border_size * 2,
    };
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    if (self.color) |color| {
        const left = PixelBBox{
            .left = widget_bounds.left,
            .right = widget_bounds.left + self.shared.border_size,
            .top = widget_bounds.top,
            .bottom = widget_bounds.bottom,
        };

        const right = PixelBBox{
            .left = widget_bounds.right -| self.shared.border_size,
            .right = widget_bounds.right,
            .top = widget_bounds.top,
            .bottom = widget_bounds.bottom,
        };

        const top = PixelBBox{
            .left = widget_bounds.left,
            .right = widget_bounds.right,
            .top = widget_bounds.top,
            .bottom = widget_bounds.top + self.shared.border_size,
        };

        const bottom = PixelBBox{
            .left = widget_bounds.left,
            .right = widget_bounds.right,
            .top = widget_bounds.bottom -| self.shared.border_size,
            .bottom = widget_bounds.bottom,
        };

        const left_inner = PixelBBox{
            .left = left.right - self.shared.inner_border_size,
            .right = left.right,
            .top = top.bottom,
            .bottom = bottom.top,
        };

        const right_inner = PixelBBox{
            .left = right.left,
            .right = right.left + self.shared.inner_border_size,
            .top = top.bottom,
            .bottom = bottom.top,
        };

        const top_inner = PixelBBox{
            .left = left.right,
            .right = right.left,
            .top = top.bottom -| self.shared.inner_border_size,
            .bottom = top.bottom,
        };

        const bottom_inner = PixelBBox{
            .left = left.right,
            .right = right.left,
            .top = bottom.top,
            .bottom = bottom.top + self.shared.inner_border_size,
        };

        const bounds_list: [4][2]PixelBBox = .{
            .{ left, left_inner },
            .{ right, right_inner },
            .{ top, top_inner },
            .{ bottom, bottom_inner },
        };

        for (bounds_list) |pair| {
            {
                const transform = gui.util.widgetToClipTransform(pair[0], window_bounds);
                self.shared.squircle_renderer.render(
                    color,
                    0,
                    pair[0],
                    transform,
                );
            }

            {
                const transform = gui.util.widgetToClipTransform(pair[1], window_bounds);
                self.shared.squircle_renderer.render(
                    gui.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                    0,
                    pair[1],
                    transform,
                );
            }
        }
    }

    self.inner.render(adjustBounds(self.shared.border_size, widget_bounds), window_bounds);
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    return self.inner.input(
        adjustBounds(self.shared.border_size, widget_bounds),
        adjustBounds(self.shared.border_size, input_bounds),
        input_state,
    );
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.inner.reset();
}

fn adjustSize(border_size: u31, size: PixelSize) PixelSize {
    return .{
        .width = size.width -| border_size * 2,
        .height = size.height -| border_size * 2,
    };
}

fn adjustBounds(border_size: u31, bounds: PixelBBox) PixelBBox {
    return .{
        .top = bounds.top + border_size,
        .bottom = bounds.bottom - border_size,
        .left = bounds.left + border_size,
        .right = bounds.right - border_size,
    };
}
