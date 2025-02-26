const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const sphrender = @import("sphrender");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;

pub const Shared = struct {
    image_renderer: *const sphrender.xyuvt_program.ImageRenderer,
};

pub fn makeThumbnail(comptime Action: type, arena: Allocator, retriever: anytype, shared: *const Shared) !gui.Widget(Action) {
    const T = Thumbnail(Action, @TypeOf(retriever));

    const ctx = try arena.create(T);
    ctx.* = .{
        .retriever = retriever,
        .shared = shared,
    };

    return .{
        .ctx = ctx,
        .name = "thumbnail",
        .vtable = &T.widget_vtable,
    };
}

pub fn Thumbnail(comptime Action: type, comptime Retriever: type) type {
    return struct {
        retriever: Retriever,
        size: PixelSize = .{ .width = 0, .height = 0 },
        shared: *const Shared,

        const Self = @This();

        const widget_vtable = gui.Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = null,
            .setFocused = null,
            .reset = null,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const texture = self.retriever.getTexture();
            const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);
            self.shared.image_renderer.renderTexture(texture, transform);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, _: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const image_dims = self.retriever.getSize();

            const height_dominant_width = available_size.height * image_dims.width / image_dims.height;
            if (height_dominant_width > available_size.width) {
                self.size.width = available_size.width;
                self.size.height = available_size.width * image_dims.height / image_dims.width;
            } else {
                self.size.width = available_size.height * image_dims.width / image_dims.height;
                self.size.height = available_size.height;
            }
        }
    };
}

const ImageDim = enum {
    width,
    height,
};

fn dominantImageDim(dims: PixelSize) ImageDim {
    if (dims.width > dims.height) {
        return .width;
    } else {
        return .height;
    }
}
