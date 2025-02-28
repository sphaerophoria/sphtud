const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const sphutil = @import("sphutil");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

pub fn oneOf(comptime Action: type, arena: Allocator, retriever: anytype, options: []const Widget(Action)) !Widget(Action) {
    const T = OneOf(Action, @TypeOf(retriever));

    const ctx = try arena.create(T);
    ctx.* = .{
        .options = try arena.dupe(Widget(Action), options),
        .selected = retriever,
    };

    return .{
        .ctx = ctx,
        .name = "one_of",
        .vtable = &T.widget_vtable,
    };
}

pub fn OneOf(comptime Action: type, comptime Selected: type) type {
    return struct {
        options: []Widget(Action),
        selected: Selected,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .name = "one_of",
                .vtable = &widget_vtable,
            };
        }

        pub fn pushWidget(self: *Self, widget: Widget(Action)) !void {
            try self.options.append(widget);
        }

        pub fn setSelected(self: *Self, idx: usize) void {
            self.selected = idx;
        }

        fn getSelected(self: *Self) Widget(Action) {
            return self.options[self.selected.get()];
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.getSelected().render(widget_bounds, window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var ret = PixelSize{};

            // This seems odd, but the point of this widget is to provide some
            // stability when toggling between options. If this shows up in a
            // scroll view, switching widgets will jump the scroll area around.
            // Ensure we have a stable size by always expanding to the maximum
            // of all children, even if there is no content to show
            for (self.options) |w| {
                const widget_size = w.getSize();
                ret.width = @max(widget_size.width, ret.width);
                ret.height = @max(widget_size.height, ret.height);
            }
            return ret;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Update all widget so that we have accurate size estimates
            for (self.options) |w| {
                try w.update(available_size, delta_s);
            }
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.getSelected().setInputState(widget_bounds, input_bounds, input_state);
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.getSelected().setFocused(focused);
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.getSelected().reset();
        }
    };
}
