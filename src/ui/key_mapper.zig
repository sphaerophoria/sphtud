const sphtud = @import("../sphtud.zig");

pub const Action = enum {
    move_left,
    move_right,
    backspace,
    delete,
    none,
};

pub fn lookup(ev: sphtud.ui.KeyEvent) Action {
    if (ev.ctrl) {
        return .none;
    }

    return lookupNoMods(ev.key);
}

fn lookupNoMods(key: sphtud.ui.Key) Action {
    return switch (key) {
        .left_arrow => .move_left,
        .right_arrow => .move_right,
        .backspace => .backspace,
        .delete => .delete,
        else => .none,
    };
}
