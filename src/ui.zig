const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const sphrender = @import("render.zig");
const sphutil = @import("sphutil");
const sphwindow_events = @import("window_events.zig");

pub const label = @import("ui/label.zig");
pub const drag = @import("ui/drag.zig");
pub const button = @import("ui/button.zig");
pub const layout = @import("ui/layout.zig");
pub const scrollbar = @import("ui/scrollbar.zig");
pub const scroll_view = @import("ui/scroll_view.zig");
pub const color_picker = @import("ui/color_picker.zig");
pub const popup_layer = @import("ui/popup_layer.zig");
pub const stack = @import("ui/stack.zig");
pub const rect = @import("ui/rect.zig");
pub const textbox = @import("ui/textbox.zig");
pub const gui_text = @import("ui/gui_text.zig");
pub const selectable_list = @import("ui/selectable_list.zig");
pub const SquircleRenderer = @import("ui/SquircleRenderer.zig");
pub const widget_factory = @import("ui/widget_factory.zig");
pub const runner = @import("ui/runner.zig");
pub const frame = @import("ui/frame.zig");
pub const null_widget = @import("ui/null.zig");
pub const combo_box = @import("ui/combo_box.zig");
pub const box = @import("ui/box.zig");
pub const checkbox = @import("ui/checkbox.zig");
pub const util = @import("ui/util.zig");
pub const memory_widget = @import("ui/memory_widget.zig");
pub const thumbnail = @import("ui/thumbnail.zig");
pub const grid = @import("ui/grid.zig");
pub const interactable = @import("ui/interactable.zig");
pub const drag_layer = @import("ui/drag_layer.zig");
pub const one_of = @import("ui/one_of.zig");
pub const histogram = @import("ui/histogram.zig");
pub const multi_line_graph = @import("ui/multi_line_graph.zig");
pub const scroll_list = @import("ui/scroll_list.zig");

test {
    std.testing.refAllDecls(@This());
}

pub const Key = sphwindow_events.Key;
pub const KeyEvent = sphwindow_events.KeyEvent;
pub const WindowAction = sphwindow_events.WindowAction;
pub const MousePos = sphwindow_events.MousePos;

pub const KeyTracker = struct {
    const max_pressed_keys = 16;

    gpa: std.mem.Allocator,
    // always lower case
    held_keys: std.ArrayList(Key) = .empty,
    pressed_this_frame: std.ArrayList(KeyEvent),

    pub fn init(gpa: Allocator) !KeyTracker {
        return .{
            .gpa = gpa,
            .held_keys = std.ArrayList(Key).initBuffer(try gpa.alloc(Key, max_pressed_keys)),
            .pressed_this_frame = .empty,
        };
    }

    pub fn isKeyDown(self: KeyTracker, key: Key) bool {
        const lower_key = key.toLower();
        for (self.held_keys.items) |held| {
            if (held.eql(lower_key)) return true;
        }

        return false;
    }

    fn deinit(self: *KeyTracker, alloc: Allocator) void {
        self.pressed_this_frame.deinit(alloc);
    }

    fn startFrame(self: *KeyTracker) void {
        self.pressed_this_frame.clearRetainingCapacity();
    }

    fn pushDown(self: *KeyTracker, key: KeyEvent) !void {
        try self.pressed_this_frame.append(self.gpa, key);

        const lower_key = key.key.toLower();
        for (self.held_keys.items) |held| {
            if (held.eql(lower_key)) {
                std.log.err("Duplicate key down", .{});
                return;
            }
        }

        self.held_keys.appendBounded(lower_key) catch {
            std.log.warn("Too many keys pressed\n", .{});
        };
    }

    fn pushUp(self: *KeyTracker, key: Key) void {
        const lower_key = key.toLower();
        var idx: usize = 0;
        while (idx < self.held_keys.items.len) {
            const held = self.held_keys.items[idx];
            if (held.eql(lower_key)) {
                _ = self.held_keys.swapRemove(idx);
            } else {
                idx += 1;
            }
        }
    }
};

pub const InputState = struct {
    mouse_pos: MousePos = .{ .x = 0, .y = 0 },
    mouse_down_location: ?MousePos = null,

    mouse_right_pressed: bool = false,
    mouse_right_released: bool = false,

    mouse_middle_pressed: bool = false,
    mouse_middle_released: bool = false,

    mouse_pressed: bool = false,
    mouse_released: bool = false,
    frame_scroll: f32 = 0,
    key_tracker: KeyTracker,

    pub fn init(gpa: Allocator) !InputState {
        return .{
            .key_tracker = try KeyTracker.init(gpa),
        };
    }

    pub fn startFrame(self: *InputState) void {
        if (self.mouse_released) {
            self.mouse_down_location = null;
            self.mouse_released = false;
        }
        self.mouse_right_pressed = false;
        self.mouse_right_released = false;
        self.mouse_middle_released = false;
        self.mouse_middle_pressed = false;
        self.mouse_middle_released = false;
        self.mouse_pressed = false;
        self.key_tracker.startFrame();
        self.frame_scroll = 0;
    }

    pub fn consumeScroll(self: *InputState) void {
        self.frame_scroll = 0;
    }

    pub fn pushInput(self: *InputState, action: WindowAction) !void {
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
                try self.key_tracker.pushDown(ev);
            },
            .key_up => |key| {
                self.key_tracker.pushUp(key);
            },
            .middle_down => self.mouse_middle_pressed = true,
            .middle_up => self.mouse_middle_released = true,
            .right_down => self.mouse_right_pressed = true,
            .right_up => self.mouse_right_released = true,
        }
    }
};
pub const PixelSize = struct {
    width: u31 = 0,
    height: u31 = 0,
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

    pub fn offset(self: PixelBBox, x: i32, y: i32) PixelBBox {
        return .{
            .top = self.top + y,
            .bottom = self.bottom + y,
            .left = self.left + x,
            .right = self.right + x,
        };
    }
};

pub const CursorStyle = enum {
    default,
    hidden,
};

pub fn InputResponse(comptime Action: type) type {
    return struct {
        wants_focus: bool = false,
        action: ?Action = null,
        cursor_style: ?CursorStyle = null,
    };
}

pub fn Widget(comptime Action: type) type {
    return struct {
        pub const VTable = struct {
            render: *const fn (ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void,
            getSize: *const fn (ctx: ?*anyopaque) PixelSize,
            update: ?*const fn (ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void,
            setInputState: ?*const fn (ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) InputResponse(Action),
            setFocused: ?*const fn (ctx: ?*anyopaque, focused: bool) void,
            reset: ?*const fn (ctx: ?*anyopaque) void,
        };

        const Self = @This();

        vtable: *const VTable,
        name: []const u8,
        ctx: ?*anyopaque,

        pub fn fromConcrete(val: anytype, comptime name: []const u8) Widget(Action) {
            const T = @TypeOf(val.*);

            const wrappers = struct {
                fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    self.render(widget_bounds, window_bounds);
                }

                fn getSize(ctx: ?*anyopaque) PixelSize {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    return self.getSize();
                }

                fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    return self.update(available_size, delta_s);
                }

                fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) InputResponse(Action) {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    return self.setInputState(widget_bounds, input_bounds, input_state);
                }

                fn setFocused(ctx: ?*anyopaque, focused: bool) void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    self.setFocused(focused);
                }

                fn reset(ctx: ?*anyopaque) void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    self.reset();
                }
            };

            return .{
                .ctx = val,
                .vtable = &.{
                    .render = wrappers.render,
                    .getSize = wrappers.getSize,
                    .update = if (@hasDecl(T, "update")) wrappers.update else null,
                    .setInputState = if (@hasDecl(T, "setInputState")) wrappers.setInputState else null,
                    .setFocused = if (@hasDecl(T, "setFocused")) wrappers.setFocused else null,
                    .reset = if (@hasDecl(T, "reset")) wrappers.reset else null,
                },
                .name = name,
            };
        }

        pub fn getSize(self: Self) PixelSize {
            return self.vtable.getSize(self.ctx);
        }

        pub fn update(self: Self, available_size: PixelSize, delta_s: f32) !void {
            if (self.vtable.update) |u| {
                try u(self.ctx, available_size, delta_s);
            }
        }

        pub fn render(self: Self, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            self.vtable.render(self.ctx, widget_bounds, window_bounds);
        }

        pub fn setInputState(self: Self, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) InputResponse(Action) {
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

    pub const white: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
};

pub const GuiAlloc = sphrender.RenderAlloc;
