const std = @import("std");
const bit_set = @import("bit_set.zig");
const rsl = @import("runtime_segmented_list.zig");
const util = @import("../util.zig");
const ExpansionAlloc = util.ExpansionAlloc;

pub fn LinearMap(comptime T: type) type {
    return struct {
        objects: rsl.RuntimeSegmentedListUnmanaged(T),
        active: bit_set.BitSet, // True if populated

        const Self = @This();

        pub fn init(
            arena: std.mem.Allocator,
            expansion: util.ExpansionAlloc,
            prealloc_size: usize,
            max_size: usize,
        ) !Self {
            return .{
                .objects = try .init(
                    arena,
                    expansion,
                    prealloc_size,
                    max_size,
                ),
                .active = try .init(
                    arena,
                    expansion,
                    prealloc_size,
                    max_size,
                ),
            };
        }

        pub fn acquire(self: *Self, expansion: ExpansionAlloc, idx: usize) !*T {
            try self.active.grow(expansion, idx + 1, false);
            std.debug.assert(self.active.get(idx) == false);
            while (self.objects.len <= idx) {
                try self.objects.fillBlock(expansion, undefined);
            }

            self.active.set(idx, true);
            return self.objects.getPtr(idx);
        }

        pub fn getPtr(self: *Self, idx: usize) *T {
            std.debug.assert(self.active.get(idx));
            return self.objects.getPtr(idx);
        }

        pub fn release(self: *Self, idx: usize) void {
            std.debug.assert(self.active.get(idx));
            self.active.set(idx, false);
        }

        pub fn reclaimMemoryNoMove(self: *Self, expansion: ExpansionAlloc) void {
            var it = self.tombstones.storage.iter();
            var i: usize = 0;
            var len: usize = 0;
            while (it.next()) |val| {
                defer i += 1;

                if (val.* != 0x00) {
                    len = i * 8;
                }
            }

            if (self.active.bitLen() > len) {
                self.active.shrink(expansion, len);
            }

            if (self.objects.len > len) {
                self.objects.shrink(expansion, len);
            }
        }
    };
}

test "something to compile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const expansion = ExpansionAlloc.linear(arena.allocator());

    var map = try LinearMap(u32).init(alloc, expansion, 10, 100);

    {
        const val = try map.acquire(expansion, 55);
        val.* = 20;
    }

    {
        try std.testing.expectEqual(20, map.getPtr(55).*);
    }

    map.release(55);
}
