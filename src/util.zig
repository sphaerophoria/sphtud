const std = @import("std");

pub const CircularBuffer = @import("util/circular_buffer.zig").CircularBuffer;
pub const RuntimeBoundedArray = @import("util/runtime_bounded_array.zig").RuntimeBoundedArray;
pub const runtime_segmented_list = @import("util/runtime_segmented_list.zig");
pub const hash_map = @import("util/hash_map.zig");
pub const object_pool = @import("util/object_pool.zig");
pub const bit_set = @import("util/bit_set.zig");
pub const linear_map = @import("util/linear_map.zig");
pub const binary_heap = @import("util/binary_heap.zig");
pub const BinarySearch = @import("util/BinarySearch.zig");

pub const RuntimeSegmentedList = runtime_segmented_list.RuntimeSegmentedList;
pub const RuntimeSegmentedListUnmanaged = runtime_segmented_list.RuntimeSegmentedListUnmanaged;

pub const AutoHashMap = hash_map.AutoHashMap;
pub const StringHashMap = hash_map.StringHashMap;

pub const LinearMap = linear_map.LinearMap;

pub const ObjectPool = object_pool.ObjectPool;

pub const BitSet = bit_set.BitSet;

pub const IoPipe = @import("util/io_pipe.zig").Pipe;

pub const ExpansionAlloc = @import("util/ExpansionAlloc.zig");

pub const BinaryHeap = binary_heap.BinaryHeap;

/// Monotonic counter for allocating globally-unique event/callback IDs.
pub const IdAlloc = struct {
    idx: usize,

    pub const init: IdAlloc = .{ .idx = 0 };

    // inclusive
    pub const Range = struct {
        start: usize,
        end: usize,

        pub fn contains(self: Range, id: usize) bool {
            return id >= self.start and id <= self.end;
        }

        pub fn offset(self: Range, id: usize) usize {
            return id - self.start;
        }
    };

    pub fn allocOne(self: *IdAlloc) usize {
        defer self.idx += 1;
        return self.idx;
    }

    pub fn allocMany(self: *IdAlloc, amount: usize) Range {
        defer self.idx += amount;
        return .{
            .start = self.idx,
            .end = self.idx + amount - 1,
        };
    }

    const Mark = struct {
        parent: *IdAlloc,
        idx: usize,

        pub fn range(self: Mark) Range {
            return .{
                .start = self.idx,
                .end = self.parent.idx - 1,
            };
        }
    };

    pub fn mark(self: *IdAlloc) Mark {
        return .{
            .parent = self,
            .idx = self.idx,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
