const std = @import("std");

// Completion marked by left > right
// Right is inclusive, or else the right boundary and left boundary behavior is
// asymmetric
left: usize,
right: usize,

const BinarySearch = @This();

const finished = BinarySearch{
    .left = 1,
    .right = 0,
};

pub fn init(len: usize) BinarySearch {
    if (len == 0) return .finished;

    return .{
        .left = 0,
        .right = len - 1,
    };
}

pub fn step(self: *BinarySearch) ?usize {
    if (self.left > self.right) return null;
    return (self.left + self.right) / 2;
}

pub fn moveLeft(self: *BinarySearch, idx: usize) void {
    if (self.right == idx or idx == 0) {
        self.* = .finished;
    } else {
        self.right = idx - 1;
    }
}

pub fn moveRight(self: *BinarySearch, idx: usize) void {
    self.left = idx + 1;
}

fn searchI32s(vals: []const i32, val: i32) ?usize {
    var bs = BinarySearch.init(vals.len);

    while (bs.step()) |idx| {
        if (val < vals[idx]) bs.moveLeft(idx) else if (val > vals[idx]) bs.moveRight(idx) else return idx;
    }

    return null;
}

test "binary search sanity" {
    const vals: []const i32 = &.{ -3, -1, 1, 2, 3, 7, 11, 25 };

    for (vals, 0..) |v, i| {
        try std.testing.expectEqual(i, searchI32s(vals, v));
    }

    for (vals[0 .. vals.len - 1], 0..) |v, i| {
        try std.testing.expectEqual(i, searchI32s(vals, v));
    }

    try std.testing.expectEqual(null, searchI32s(vals, -5));
    try std.testing.expectEqual(null, searchI32s(vals[0 .. vals.len - 1], -5));

    try std.testing.expectEqual(null, searchI32s(vals, 35));
    try std.testing.expectEqual(null, searchI32s(vals[0 .. vals.len - 1], 35));

    try std.testing.expectEqual(null, searchI32s(vals, 0));
    try std.testing.expectEqual(null, searchI32s(vals[0 .. vals.len - 1], 0));
}
