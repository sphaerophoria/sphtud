const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const gui_text = @import("gui_text.zig");
const util = @import("util.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

pub fn makeLabel(comptime Action: type, alloc: Allocator, text_retriever: anytype, shared: *const gui_text.SharedState) !Widget(Action) {
    const T = Label(@TypeOf(text_retriever));

    const ctx = try alloc.create(T);
    errdefer alloc.destroy(ctx);

    const text = try gui_text.guiText(alloc, shared, text_retriever);

    ctx.* = .{
        .alloc = alloc,
        .text = text,
    };

    return .{
        .vtable = T.widgetVTable(Action),
        .ctx = ctx,
    };
}

pub fn Label(comptime TextRetriever: type) type {
    return struct {
        alloc: Allocator,
        text: gui_text.GuiText(TextRetriever),

        const Self = @This();

        fn widgetVTable(comptime Action: type) *const Widget(Action).VTable {
            return &Widget(Action).VTable{
                .render = Self.render,
                .getSize = Self.getSize,
                .deinit = Self.deinit,
                .update = Self.update,
                .setInputState = null,
                .reset = null,
                .setFocused = null,
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.text.deinit(alloc);
            alloc.destroy(self);
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.text.update(self.alloc, available_size.width);
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
