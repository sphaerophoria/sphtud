const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const sphrender = @import("render.zig");
const sphutil = @import("sphutil");
const sphwindow_events = @import("window_events.zig");

pub const scrollbar = @import("ui/scrollbar.zig");
pub const SquircleRenderer = @import("ui/SquircleRenderer.zig");
pub const util = @import("ui/util.zig");

pub const Widget = @import("ui/Widget.zig");
pub const Layout = @import("ui/Layout.zig");
pub const Label = @import("ui/Label.zig");
pub const Button = @import("ui/Button.zig");
pub const Checkbox = @import("ui/Checkbox.zig");
pub const Histogram = @import("ui/Histogram.zig");
pub const Box = @import("ui/Box.zig");
pub const ScrollView = @import("ui/ScrollView.zig");
pub const ComboBox = @import("ui/ComboBox.zig");
pub const Rect = @import("ui/Rect.zig");
pub const Frame = @import("ui/Frame.zig");
pub const ColorableFrame = @import("ui/ColorableFrame.zig");
pub const Stack = @import("ui/Stack.zig");
pub const Drag = @import("ui/Drag.zig");
pub const SelectableList = @import("ui/SelectableList.zig");
pub const PopupLayer = @import("ui/PopupLayer.zig");
pub const DragLayer = @import("ui/DragLayer.zig");
pub const ColorPicker = @import("ui/ColorPicker.zig");
pub const Grid = @import("ui/Grid.zig");
pub const Interactable = @import("ui/Interactable.zig");
pub const MemoryWidget = @import("ui/MemoryWidget.zig");
pub const WidgetState = @import("ui/WidgetState.zig");
pub const WidgetFactory = @import("ui/WidgetFactory.zig");
pub const OneOf = @import("ui/OneOf.zig");
pub const Thumbnail = @import("ui/Thumbnail.zig");
pub const Textbox = @import("ui/Textbox.zig");
pub const Runner = @import("ui/Runner.zig");
pub const Centered = @import("ui/Centered.zig");

pub const EventQueue = std.ArrayList(usize);
pub const key_mapper = @import("ui/key_mapper.zig");

test {
    std.testing.refAllDecls(@This());
}

pub const Key = sphwindow_events.Key;
pub const KeyEvent = sphwindow_events.KeyEvent;
pub const WindowAction = sphwindow_events.WindowAction;
pub const MousePos = sphwindow_events.MousePos;

pub const InputEvent = union(enum) {
    key: KeyEvent,
    codepoint: u32,
};

pub const KeyTracker = struct {
    const max_pressed_keys = 16;

    gpa: std.mem.Allocator,
    // always lower case
    held_keys: std.ArrayList(Key) = .empty,
    pressed_this_frame: std.ArrayList(InputEvent),

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
        try self.pressed_this_frame.append(self.gpa, .{ .key = key });

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

    fn pushCodepoint(self: *KeyTracker, codepoint: u32) !void {
        try self.pressed_this_frame.append(self.gpa, .{ .codepoint = codepoint });
    }

    fn pushRepeat(self: *KeyTracker, key: KeyEvent) !void {
        try self.pressed_this_frame.append(self.gpa, .{ .key = key });
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
            .codepoint => |codepoint| {
                try self.key_tracker.pushCodepoint(codepoint);
            },
            .key_up => |key| {
                self.key_tracker.pushUp(key);
            },
            .key_repeat => |ev| {
                try self.key_tracker.pushRepeat(ev);
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

    pub const empty: PixelBBox = .{
        .left = 0,
        .right = 0,
        .top = 0,
        .bottom = 0,
    };

    pub fn calcSize(self: PixelBBox) PixelSize {
        return .{
            .width = self.calcWidth(),
            .height = self.calcHeight(),
        };
    }

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

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const white: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
};

pub const GuiAlloc = sphrender.RenderAlloc;
