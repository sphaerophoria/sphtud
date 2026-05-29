const gui = @import("../ui.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;

data: ?Data = null,
last_mouse_x: i32 = 0,
last_mouse_y: i32 = 0,
widget: Widget,

const Data = struct {
    // NOTE: This is expected to be a reference to an existing widget.
    // This means that we do not own the widget ourselves and are not
    // responsible for doing things like updating it or setting its
    // input state
    widget: *Widget,
    mouse_offs_x: i32,
    mouse_offs_y: i32,
};

const Self = @This();

pub fn init() Self {
    return .{
        .widget = .{
            .focused = false,
            // Lie to stack widget so that it thinks we cannot consume input.
            // The root stack widget does not scissor, so we are free to just
            // draw outside our widget bounds. This feels like we are
            // exploiting a "bug" or optimization... but maybe its fine
            .size = .{},
            .vtable = &.{
                .update = null,
                .render = render,
                .input = input,
                .reset = null,
            },
        },
    };
}

pub fn set(self: *Self, widget: *Widget, offs_x: i32, offs_y: i32) void {
    self.data = .{
        .widget = widget,
        .mouse_offs_x = offs_x,
        .mouse_offs_y = offs_y,
    };
}

pub fn reset(self: *Self) void {
    self.data = null;
}

fn render(widget: *Widget, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    _ = widget_bounds;

    const data = self.data orelse return;

    const left = self.last_mouse_x - data.mouse_offs_x;
    const top = self.last_mouse_y - data.mouse_offs_y;

    const inner_bounds = PixelBBox{
        .left = left,
        .top = top,
        .right = left + data.widget.size.width,
        .bottom = top + data.widget.size.height,
    };

    data.widget.render(inner_bounds, window_bounds);
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);
    _ = widget_bounds;
    _ = input_bounds;
    self.last_mouse_x = @intFromFloat(input_state.mouse_pos.x);
    self.last_mouse_y = @intFromFloat(input_state.mouse_pos.y);
}
