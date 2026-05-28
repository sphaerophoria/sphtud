const std = @import("std");

pub fn CircularBuffer(comptime T: type) type {
    return struct {
        items: []T,

        head: usize = 0,
        tail: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, val: T) ?T {
            var ret: ?T = null;

            if (self.count() == self.items.len) {
                ret = self.items[self.incTail()];
            }

            self.items[self.head % self.items.len] = val;
            self.head += 1;
            return ret;
        }

        pub fn pushNoClobber(self: *Self, val: T) !void {
            if (self.count() == self.items.len) {
                return error.OutOfMemory;
            }

            self.items[self.head % self.items.len] = val;
            self.head += 1;
        }

        pub fn writePastHead(self: *Self, distance: usize, val: T) !void {
            if (self.items.len - self.count() < distance) {
                return error.OutOfMemory;
            }

            const write_pos = (self.head + distance) % self.items.len;
            self.items[write_pos] = val;
        }

        pub fn markWritten(self: *Self, amount: usize) void {
            std.debug.assert(amount < self.items.len);
            self.head += amount;
        }

        pub fn count(self: Self) usize {
            return self.head - self.tail;
        }

        pub const Iterator = struct {
            buf: *const Self,
            idx: usize,

            pub fn next(self: *Iterator) ?T {
                const ret = self.nextPtr() orelse return null;
                return ret.*;
            }

            pub fn nextPtr(self: *Iterator) ?*T {
                if (self.idx >= self.buf.head) {
                    return null;
                }
                defer self.idx += 1;

                return &self.buf.items[self.idx % self.buf.items.len];
            }
        };

        /// Iterates from tail to head
        pub fn iter(self: *const Self) Iterator {
            return .{
                .buf = self,
                .idx = self.tail,
            };
        }

        pub fn pop(self: *Self) ?T {
            if (self.count() == 0) return null;
            return self.items[self.incTail()];
        }

        pub fn popWrite(self: *Self, replacement: T) ?T {
            if (self.count() == 0) return null;
            const idx = self.incTail();
            const ret = self.items[idx];
            self.items[idx] = replacement;
            return ret;
        }

        fn incTail(self: *Self) usize {
            const ret = self.tail;
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
