pub fn CircularBuffer(comptime T: type) type {
    return struct {
        items: []T,

        head: usize = 0,
        tail: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, val: T) ?T {
            var ret: ?T = null;

            if (self.count() == self.items.len) {
                ret = self.incTail();
            }

            self.items[self.head % self.items.len] = val;
            self.head += 1;
            return ret;
        }

        pub fn count(self: Self) usize {
            return self.head - self.tail;
        }

        pub const Iterator = struct {
            buf: *const Self,
            idx: usize,

            pub fn next(self: *Iterator) ?T {
                if (self.idx >= self.buf.head) {
                    return null;
                }
                defer self.idx += 1;

                return self.buf.items[self.idx % self.buf.items.len];
            }
        };

        /// Iterates from tail to head
        pub fn iter(self: *const Self) Iterator {
            return .{
                .buf = self,
                .idx = self.tail,
            };
        }

        fn incTail(self: *Self) T {
            const ret = self.items[self.tail];
            self.tail += 1;
            if (self.tail >= self.items.len) {
                self.tail -= self.items.len;
                self.head -= self.items.len;
            }
            return ret;
        }
    };
}

test "CircularBuffer" {
    const std = @import("std");
    var buf: [3]i32 = undefined;

    var circular_buf = CircularBuffer(i32){ .items = &buf };
    try std.testing.expectEqual(0, circular_buf.count());

    _ = circular_buf.push(1);
    _ = circular_buf.push(2);
    _ = circular_buf.push(3);
    try std.testing.expectEqual(3, circular_buf.count());

    {
        var it = circular_buf.iter();
        try std.testing.expectEqual(1, it.next());
        try std.testing.expectEqual(2, it.next());
        try std.testing.expectEqual(3, it.next());
        try std.testing.expectEqual(null, it.next());
    }

    try std.testing.expectEqual(1, circular_buf.push(4));
    {
        var it = circular_buf.iter();
        try std.testing.expectEqual(2, it.next());
        try std.testing.expectEqual(3, it.next());
        try std.testing.expectEqual(4, it.next());
        try std.testing.expectEqual(null, it.next());
    }
}
