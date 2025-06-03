const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn RuntimeBoundedArray(comptime T: type) type {
    return struct {
        items: []T = &.{},
        capacity: usize = 0,

        const Self = @This();

        pub fn init(alloc: Allocator, capacity: usize) !Self {
            const items = try alloc.alloc(T, capacity);
            return .{
                .items = items.ptr[0..0],
                .capacity = capacity,
            };
        }

        pub fn fromBuf(buf: []T) Self {
            return .{
                .items = buf.ptr[0..0],
                .capacity = buf.len,
            };
        }

        pub fn clear(self: *Self) void {
            self.items = self.items.ptr[0..0];
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.items.len == self.capacity) {
                return error.OutOfMemory;
            }

            self.items = self.items.ptr[0 .. self.items.len + 1];
            self.items[self.items.len - 1] = item;
        }

        pub fn appendSlice(self: *Self, items: []const T) !void {
            const old_len = self.items.len;
            const new_len = old_len + items.len;
            if (new_len > self.capacity) {
                return error.OutOfMemory;
            }
            self.items = self.items.ptr[0..new_len];
            @memcpy(self.items[old_len..new_len], items);
        }

        pub fn setContentsTrunc(self: *Self, content: []const T) void {
            self.clear();
            const len = @min(self.capacity, content.len);
            self.appendSlice(content[0..len]) catch unreachable;
        }

        pub fn resize(self: *Self, len: usize) !void {
            if (len > self.capacity) return error.OutOfMemory;
            self.items = self.items.ptr[0..len];
        }

        pub fn pop(self: *Self) void {
            self.items = self.items.ptr[0 .. self.items.len - 1];
        }

        pub fn popOrNull(self: *Self) ?T {
            if (self.items.len == 0) return null;

            const elem = self.items[self.items.len - 1];
            self.pop();
            return elem;
        }

        const Writer = std.io.Writer(*Self, anyerror, appendWrite);

        pub fn writer(self: *Self) Writer {
            return .{
                .context = self,
            };
        }

        fn appendWrite(self: *Self, m: []const u8) Allocator.Error!usize {
            try self.appendSlice(m);
            return m.len;
        }
    };
}

test "RuntimeBoundedArray" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var al = try RuntimeBoundedArray(i32).init(arena.allocator(), 5);
    try std.testing.expectEqual(0, al.items.len);

    try al.append(1);
    try al.append(2);

    try std.testing.expectEqualSlices(i32, &.{ 1, 2 }, al.items);
    try std.testing.expectError(error.OutOfMemory, al.appendSlice(&.{ 3, 4, 5, 6 }));

    try al.appendSlice(&.{ 3, 4, 5 });
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5 }, al.items);

    al.pop();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, al.items);
}
