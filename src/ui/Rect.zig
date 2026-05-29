const gui = @import("../ui.zig");
const SquircleRenderer = @import("../ui/SquircleRenderer.zig");
const util = @import("../ui/util.zig");
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

color: Color,
corner_radius: f32,
squircle_renderer: *const SquircleRenderer,
widget: Widget,

const Self = @This();

pub fn init(color: Color, corner_radius: f32, squircle_renderer: *const SquircleRenderer) Self {
    return .{
        .color = color,
        .corner_radius = corner_radius,
        .squircle_renderer = squircle_renderer,
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = update,
                .render = render,
                .input = null,
                .reset = null,
            },
        },
    };
}

fn update(widget: *Widget, available_size: PixelSize, _: f32) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.widget.size = available_size;
}

fn render(widget: *Widget, bounds: PixelBBox, window: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    const transform = util.widgetToClipTransform(bounds, window);
    self.squircle_renderer.render(self.color, self.corner_radius, bounds, transform);
}
