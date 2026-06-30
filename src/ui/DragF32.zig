const std = @import("std");
const sphtud = @import("../sphtud.zig");

label: *sphtud.ui.Label,
drag: *sphtud.ui.Drag,

const DragF32 = @This();

pub fn init(label: *sphtud.ui.Label, drag: *sphtud.ui.Drag, initial_val: f32) !DragF32 {
    try updateLabel(label, initial_val);

    return .{
        .label = label,
        .drag = drag,
    };
}

pub fn update(self: DragF32, val: *f32, scale: f32) !void {
    val.* += self.drag.takeDrag() * scale;
    try updateLabel(self.label, val.*);
}

fn updateLabel(label: *sphtud.ui.Label, val: f32) !void {
    var buf: [10]u8 = undefined;
    try label.setText(try std.fmt.bufPrint(&buf, "{d:.3}", .{val}));
}
