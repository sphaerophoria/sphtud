const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const gui_text = @import("gui_text.zig");
const util = @import("util.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

pub fn makeLabel(comptime Action: type, alloc: gui.GuiAlloc, text_retriever: anytype, shared: *const gui_text.SharedState) !Widget(Action) {
    const T = Label(@TypeOf(text_retriever));

    const ctx = try alloc.heap.arena().create(T);
    const text = try gui_text.guiText(alloc, shared, text_retriever);

    ctx.* = .{
        .text = text,
    };

    return .{
        .vtable = T.widgetVTable(Action),
        .ctx = ctx,
    };
}

pub fn Label(comptime TextRetriever: type) type {
    return struct {
        text: gui_text.GuiText(TextRetriever),

        const Self = @This();

        fn widgetVTable(comptime Action: type) *const Widget(Action).VTable {
            return &Widget(Action).VTable{
                .render = Self.render,
                .getSize = Self.getSize,
                .update = Self.update,
                .setInputState = null,
                .reset = null,
                .setFocused = null,
            };
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.text.update(available_size.width);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.text.size();
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window);
            self.text.render(transform);
        }
    };
}
