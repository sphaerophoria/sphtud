const std = @import("std");
const sphtud = @import("../sphtud.zig");

label: *sphtud.ui.Label,
drag: *sphtud.ui.Drag,

const DragInt = @This();

pub fn init(label: *sphtud.ui.Label, drag: *sphtud.ui.Drag, initial_val: i32) !DragInt {
    try updateLabel(label, initial_val);

    return .{
        .label = label,
        .drag = drag,
    };
}

pub fn update(self: DragInt, val: *i32) !bool {
    try updateLabel(self.label, val.*);
    val.* += self.drag.takeDragInt(0.25) orelse return false;
    return true;
}

fn updateLabel(label: *sphtud.ui.Label, val: i32) !void {
    var buf: [10]u8 = undefined;
    try label.setText(try std.fmt.bufPrint(&buf, "{d}", .{val}));
}
