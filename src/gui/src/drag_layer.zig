const gui = @import("gui.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

pub fn DragLayer(comptime Action: type) type {
    return struct {
        data: ?Data = null,
        size: PixelSize = .{},
        last_mouse_x: i32 = 0,
        last_mouse_y: i32 = 0,

        const Data = struct {
            // NOTE: This is expected to be a reference to an existing widget.
            // This means that we do not own the widget ourselves and are not
            // responsible for doing things like updating it or setting its
            // input state
            widget: Widget(Action),
            mouse_offs_x: i32,
            mouse_offs_y: i32,
        };
        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = null,
            .reset = null,
        };

        pub fn asWidget(self: *Self) Widget(Action) {
            return .{
                .ctx = self,
                .name = "drag and drop",
                .vtable = &widget_vtable,
            };
        }

        pub fn set(self: *Self, widget: Widget(Action), offs_x: i32, offs_y: i32) void {
            self.data = .{
                .widget = widget,
                .mouse_offs_x = offs_x,
                .mouse_offs_y = offs_y,
            };
        }

        pub fn reset(self: *Self) void {
            self.data = null;
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            _ = widget_bounds;

            const data = self.data orelse return;

            const left = self.last_mouse_x - data.mouse_offs_x;
            const top = self.last_mouse_y - data.mouse_offs_y;

            const widget_size = data.widget.getSize();
            const inner_bounds = PixelBBox{
                .left = left,
                .top = top,
                .right = left + widget_size.width,
                .bottom = top + widget_size.height,
            };

            data.widget.render(inner_bounds, window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            _ = ctx;

            // Lie to stack widget so that it thinks we cannot consume input.
            // The root stack widget does not scissor, so we are free to just
            // draw outside our widget bounds. This feels like we are
            // exploiting a "bug" or optimization... but maybe its fine
            return .{};
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, _: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.size = available_size;
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            _ = widget_bounds;
            _ = input_bounds;
            self.last_mouse_x = @intFromFloat(input_state.mouse_pos.x);
            self.last_mouse_y = @intFromFloat(input_state.mouse_pos.y);
            return .{};
        }
    };
}
