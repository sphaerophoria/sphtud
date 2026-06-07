const sphtud = @import("../sphtud.zig");

pub const Action = enum {
    move_left,
    move_right,
    select_all,
    backspace,
    backspace_word,
    delete,
    delete_word,
    none,
};

pub fn lookup(ev: sphtud.ui.KeyEvent) Action {
    if (ev.ctrl) {
        return lookupCtrl(ev.key);
    }

    return lookupNoMods(ev.key);
}

fn lookupCtrl(key: sphtud.ui.Key) Action {
    switch (key) {
        .ascii => |c| {
            switch (c) {
                'a' => return .select_all,
                else => return .none,
            }
        },
        .backspace => return .backspace_word,
        .delete => return .delete_word,
        else => return .none,
    }
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
