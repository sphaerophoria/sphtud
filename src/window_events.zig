const std = @import("std");

pub const Key = union(enum) {
    ascii: u8,
    left_arrow,
    right_arrow,
    backspace,
    delete,
    escape,

    pub fn eql(self: Key, other: Key) bool {
        return std.meta.eql(self, other);
    }

    pub fn toLower(self: Key) Key {
        return switch (self) {
            .ascii => |v| .{ .ascii = std.ascii.toLower(v) },
            inline else => |_, t| t,
        };
    }
};

pub const KeyEvent = struct { key: Key, ctrl: bool };

pub const MousePos = struct { x: f32, y: f32 };

pub const WindowAction = union(enum) {
    key_down: KeyEvent,
    key_up: Key,
    mouse_move: MousePos,
    mouse_down,
    mouse_up,
    middle_down,
    middle_up,
    right_down,
    right_up,
    scroll: f32,
};
