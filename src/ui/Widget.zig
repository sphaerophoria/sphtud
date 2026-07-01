const gui = @import("../ui.zig");

pub const Widget = @This();

pub const VTable = struct {
    update: ?*const fn (widget: *Widget, available: gui.PixelSize, delta_s: f32) anyerror!void,
    render: *const fn (widget: *Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void,
    input: ?*const fn (widget: *Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) anyerror!void,
    reset: ?*const fn (widget: *Widget) void,
};

focused: bool,
size: gui.PixelSize,
vtable: *const VTable,

pub fn asWidget(container: anytype) *Widget {
    const T = @TypeOf(container);
    switch (@typeInfo(T)) {
        .pointer => |pi| {
            const child_info = @typeInfo(pi.child);
            if (child_info == .@"struct" and @hasField(pi.child, "widget")) {
                return &container.widget;
            }
        },
        else => {},
    }
    @compileError("widget should be a pointer to a struct with a widget field, found " ++ @typeName(T));
}

pub fn update(self: *Widget, available: gui.PixelSize, delta_s: f32) !void {
    if (self.vtable.update) |u| return u(self, available, delta_s);
}

pub fn render(self: *Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    self.vtable.render(self, widget_bounds, window_bounds);
}

pub fn input(self: *Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) !void {
    if (self.vtable.input) |i| try i(self, widget_bounds, input_bounds, input_state);
}

pub fn reset(self: *Widget) void {
    if (self.vtable.reset) |r| r(self);
}
