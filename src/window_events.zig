const std = @import("std");

pub const Key = union(enum) {
    ascii: u8,
    left_arrow,
    right_arrow,
    backspace,
    delete,
    escape,
    home,
    end,

    pub fn eql(self: Key, other: Key) bool {
        return std.meta.eql(self, other);
    }

    pub fn toLower(self: Key) Key {
        return switch (self) {
            .ascii => |v| .{ .ascii = std.ascii.toLower(v) },
            inline else => |_, t| t,
        };
    }

    pub fn fromOther(other: anytype) ?Key {
        // Can't just switch on it like we'd want... If they have more fields
        // than us we need an else case to return null. If they have less we
        // have to omit from the switch, etc. etc.
        //
        // Instead we just loop over their options and check if they're any of our options

        const Keynum = std.meta.Tag(Key);
        inline for (std.meta.fields(@TypeOf(other))) |f| {
            const tag = std.meta.stringToEnum(Keynum, f.name);
            if (tag) |t| switch (t) {
                .ascii => return .{ .ascii = other.ascii },
                inline else => |t2| return t2,
            };
        }
        return null;
    }
};

pub const KeyEvent = struct { key: Key, ctrl: bool, shift: bool };

pub const MousePos = struct { x: f32, y: f32 };

pub const WindowAction = union(enum) {
    key_down: KeyEvent,
    key_up: Key,
    key_repeat: KeyEvent,
    codepoint: u32,
    mouse_move: MousePos,
    mouse_down,
    mouse_up,
    middle_down,
    middle_up,
    right_down,
    right_up,
    scroll: f32,
};
