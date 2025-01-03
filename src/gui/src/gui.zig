const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");

pub const label = @import("label.zig");
pub const drag_float = @import("drag_float.zig");
pub const button = @import("button.zig");
pub const layout = @import("layout.zig");
pub const scrollbar = @import("scrollbar.zig");
pub const scroll_view = @import("scroll_view.zig");
pub const color_picker = @import("color_picker.zig");
pub const popup_layer = @import("popup_layer.zig");
pub const stack = @import("stack.zig");
pub const rect = @import("rect.zig");
pub const textbox = @import("textbox.zig");
pub const gui_text = @import("gui_text.zig");
pub const selectable_list = @import("selectable_list.zig");
pub const SquircleRenderer = @import("SquircleRenderer.zig");
pub const widget_factory = @import("widget_factory.zig");
pub const runner = @import("runner.zig");
pub const even_vert_layout = @import("even_vert_layout.zig");
pub const frame = @import("frame.zig");
pub const property_list = @import("property_list.zig");
pub const null_widget = @import("null.zig");
pub const combo_box = @import("combo_box.zig");
pub const box = @import("box.zig");
pub const checkbox = @import("checkbox.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const Key = union(enum) {
    ascii: u8,
    left_arrow,
    right_arrow,
    backspace,
    delete,
};
pub const KeyEvent = struct { key: Key, ctrl: bool };

pub const WindowAction = union(enum) {
    key_down: KeyEvent,
    mouse_move: MousePos,
    mouse_down,
    mouse_up,
    middle_down,
    middle_up,
    right_click,
    scroll: f32,
};

pub const MousePos = struct { x: f32, y: f32 };

pub const InputState = struct {
    mouse_pos: MousePos = .{ .x = 0, .y = 0 },
    mouse_down_location: ?MousePos = null,

    mouse_right_pressed: bool = false,

    mouse_middle_pressed: bool = false,
    mouse_middle_released: bool = false,

    mouse_pressed: bool = false,
    mouse_released: bool = false,
    frame_scroll: f32 = 0,
    frame_keys: std.ArrayListUnmanaged(KeyEvent) = .{},

    pub fn deinit(self: *InputState, alloc: Allocator) void {
        self.frame_keys.deinit(alloc);
    }

    pub fn startFrame(self: *InputState) void {
        if (self.mouse_released) {
            self.mouse_down_location = null;
            self.mouse_released = false;
        }
        self.mouse_right_pressed = false;
        self.mouse_middle_pressed = false;
        self.mouse_middle_released = false;
        self.mouse_pressed = false;
        self.frame_keys.clearRetainingCapacity();
        self.frame_scroll = 0;
    }

    pub fn pushInput(self: *InputState, alloc: Allocator, action: WindowAction) !void {
        switch (action) {
            .mouse_move => |pos| {
                self.mouse_pos = pos;
            },
            .mouse_down => {
                self.mouse_down_location = self.mouse_pos;
                self.mouse_pressed = true;
            },
            .mouse_up => {
                self.mouse_released = true;
            },
            .scroll => |amount| {
                self.frame_scroll += amount;
            },
            .key_down => |ev| {
                try self.frame_keys.append(alloc, ev);
            },
            .middle_down => self.mouse_middle_pressed = true,
            .middle_up => self.mouse_middle_released = true,
            .right_click => self.mouse_right_pressed = true,
        }
    }
};
pub const PixelSize = struct {
    width: u31,
    height: u31,
};

pub const PixelBBox = struct {
    left: i32,
    right: i32,
    top: i32,
    bottom: i32,

    pub fn contains(self: PixelBBox, x: i32, y: i32) bool {
        return x >= self.left and x <= self.right and y <= self.bottom and y >= self.top;
    }

    pub fn calcWidth(self: PixelBBox) u31 {
        return @intCast(@max(self.right - self.left, 0));
    }

    pub fn calcHeight(self: PixelBBox) u31 {
        return @intCast(@max(self.bottom - self.top, 0));
    }

    pub fn cx(self: PixelBBox) f32 {
        const val: f32 = @floatFromInt(self.left + self.right);
        return val / 2.0;
    }

    pub fn cy(self: PixelBBox) f32 {
        const val: f32 = @floatFromInt(self.top + self.bottom);
        return val / 2.0;
    }

    pub fn containsMousePos(self: PixelBBox, mouse_pos: MousePos) bool {
        return self.contains(@intFromFloat(@round(mouse_pos.x)), @intFromFloat(@round(mouse_pos.y)));
    }

    pub fn containsOptMousePos(self: PixelBBox, mouse_pos: ?MousePos) bool {
        const pos = mouse_pos orelse return false;
        return self.containsMousePos(pos);
    }

    pub fn calcUnion(a: PixelBBox, b: PixelBBox) PixelBBox {
        return .{
            .left = @min(a.left, b.left),
            .right = @max(a.right, b.right),
            .top = @min(a.top, b.top),
            .bottom = @max(a.bottom, b.bottom),
        };
    }

    pub fn calcIntersection(a: PixelBBox, b: PixelBBox) PixelBBox {
        return .{
            .left = @max(a.left, b.left),
            .right = @min(a.right, b.right),
            .top = @max(a.top, b.top),
            .bottom = @min(a.bottom, b.bottom),
        };
    }
};

pub fn InputResponse(comptime Action: type) type {
    return struct {
        wants_focus: bool = false,
        action: ?Action = null,
    };
}

pub fn Widget(comptime Action: type) type {
    return struct {
        pub const VTable = struct {
            deinit: *const fn (ctx: ?*anyopaque, alloc: Allocator) void,
            render: *const fn (ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void,
            getSize: *const fn (ctx: ?*anyopaque) PixelSize,
            update: ?*const fn (ctx: ?*anyopaque, available_size: PixelSize) anyerror!void,
            setInputState: ?*const fn (ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action),
            setFocused: ?*const fn (ctx: ?*anyopaque, focused: bool) void,
            reset: ?*const fn (ctx: ?*anyopaque) void,
        };

        const Self = @This();

        vtable: *const VTable,
        ctx: ?*anyopaque,

        pub fn deinit(self: Self, alloc: Allocator) void {
            self.vtable.deinit(self.ctx, alloc);
        }

        pub fn getSize(self: Self) PixelSize {
            return self.vtable.getSize(self.ctx);
        }

        pub fn update(self: Self, available_size: PixelSize) !void {
            if (self.vtable.update) |u| {
                try u(self.ctx, available_size);
            }
        }

        pub fn render(self: Self, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            self.vtable.render(self.ctx, widget_bounds, window_bounds);
        }

        pub fn setInputState(self: Self, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            if (self.vtable.setInputState) |setState| {
                return setState(self.ctx, widget_bounds, input_bounds, input_state);
            }
            return .{
                .wants_focus = false,
                .action = null,
            };
        }

        pub fn setFocused(self: Self, focused: bool) void {
            if (self.vtable.setFocused) |f| {
                f(self.ctx, focused);
            }
        }

        pub fn reset(self: Self) void {
            if (self.vtable.reset) |f| {
                f(self.ctx);
            }
        }
    };
}

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};
