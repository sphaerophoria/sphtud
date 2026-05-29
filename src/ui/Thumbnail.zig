const sphrender = @import("../render.zig");
const gui = @import("../ui.zig");
const util = @import("../ui/util.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

pub const Shared = struct {
    image_renderer: *const sphrender.xyuvt_program.ImageRenderer,
};

texture: sphrender.Texture,
image_size: PixelSize,
shared: *const Shared,
widget: Widget,

const Self = @This();

pub fn init(shared: *const Shared) Self {
    return .{
        .texture = sphrender.Texture.invalid,
        .image_size = .{},
        .shared = shared,
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

    if (self.image_size.width == 0 or self.image_size.height == 0) {
        self.widget.size = available_size;
        return;
    }

    const height_dominant_width = available_size.height * self.image_size.width / self.image_size.height;
    if (height_dominant_width > available_size.width) {
        self.widget.size = .{
            .width = available_size.width,
            .height = available_size.width * self.image_size.height / self.image_size.width,
        };
    } else {
        self.widget.size = .{
            .width = available_size.height * self.image_size.width / self.image_size.height,
            .height = available_size.height,
        };
    }
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    if (self.texture.inner == 0) return;
    const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
    self.shared.image_renderer.renderTexture(self.texture, transform);
}
