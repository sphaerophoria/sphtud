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

pub fn Rect(comptime Action: type, comptime ColorRetriever: type) type {
    return struct {
        size: PixelSize = .{ .width = 0, .height = 0 },
        corner_radius: f32,
        renderer: *const SquircleRenderer,
        color: ColorRetriever,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
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
            color: ColorRetriever,
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
                .name = "rect",
                .ctx = @ptrCast(rect),
            };
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, _: f32) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.size = available_size;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window);

            const color = getColor(&self.color) orelse return;
            self.renderer.render(
                color,
                self.corner_radius,
                bounds,
                transform,
            );
        }
    };
}

fn getColor(retriever: anytype) ?Color {
    const Ptr = @TypeOf(retriever);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (T == Color) return retriever.*;
            if (@hasDecl(T, "getColor")) return retriever.getColor();
        },
        else => {},
    }

    @compileError("Color retriever needs to be a gui.Color or struct with getColor() that returns ?gui.Color. Got " ++ @typeName(T));
}
