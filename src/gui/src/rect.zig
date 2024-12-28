const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Color = gui.Color;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub fn Rect(comptime Action: type) type {
    return struct {
        size: PixelSize = .{ .width = 0, .height = 0 },
        corner_radius: f32,
        renderer: *const SquircleRenderer,
        color: Color,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = null,
            .setFocused = null,
            .reset = null,
        };

        pub fn init(
            alloc: Allocator,
            corner_radius: f32,
            color: Color,
            renderer: *const SquircleRenderer,
        ) !Widget(Action) {
            const rect = try alloc.create(Self);
            rect.* = .{
                .corner_radius = corner_radius,
                .color = color,
                .renderer = renderer,
            };

            return .{
                .vtable = &Self.widget_vtable,
                .ctx = @ptrCast(rect),
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.size = available_size;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window);

            self.renderer.render(
                self.color,
                self.corner_radius,
                bounds,
                transform,
            );
        }
    };
}
