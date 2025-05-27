const std = @import("std");
const Allocator = std.mem.Allocator;
const RuntimeBoundedArray = @import("sphutil.zig").RuntimeBoundedArray;
const sphalloc = @import("sphalloc");

/// Very similar in concept to standard library SegmentedList with a few
/// notable differences
/// * Initial block size does not need to be a power of 2
/// * Initial block is runtime allocated
/// * Dynamic segment list is allocated up front (maybe it shouldn't be...)
/// * Dynamic segments are created with a tiny page allocator
pub fn RuntimeSegmentedList(comptime T: type) type {
    return struct {
        alloc: Allocator,
        initial_block: []T,
        // Expansions are our name for blocks that have to be allocated once
        // the initial block is full. Expansions start as size of initial block,
        // and double every expansion.
        //
        // Since the lengths are known, based off the index, we don't have to
        // store them
        //
        // Number of expansions is fixed on initialization, we do not attempt
        // to resize
        expansions: []?[*]T,
        capacity: usize,
        len: usize = 0,

        // Every expansion block doubles in size

        const Self = @This();
        const grow_factor = 2;

        pub fn init(arena: Allocator, tiny_page_alloc: Allocator, small_size: usize, max_size: usize) !Self {
            const initial_block = try arena.alloc(T, small_size);

            const max_idx = max_size - 1;
            const num_expansions = idxToExpansionSlot(small_size, max_idx, firstExpansionSize(small_size)) + 1;
            const expansions = try arena.alloc(?[*]T, num_expansions);
            comptime std.debug.assert(@sizeOf(?[*]T) == @sizeOf(*T));
            @memset(expansions, null);

            return .{
                .alloc = tiny_page_alloc,
                .initial_block = initial_block,
                .expansions = expansions,
                .capacity = max_size,
            };
        }

        pub fn append(self: *Self, elem: T) !void {
            if (self.appendInitial(elem)) {
                return;
            }

            if (self.len >= self.capacity) {
                return error.OutOfMemory;
            }

            const block = idxToExpansionSlot(self.initial_block.len, self.len, firstExpansionSize(self.initial_block.len));
            try self.ensureBlockAllocated(block);
            self.appendToBlock(block, elem);
        }

        pub fn get(self: Self, idx: usize) T {
            return getImpl(self, idx).*;
        }

        pub fn getPtr(self: *Self, idx: usize) *T {
            return getImpl(self.*, idx);
        }

        pub fn shrink(self: *Self, size: usize) void {
            self.len = size;
            self.freeUnusedBlocks();
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.freeUnusedBlocks();
        }

        pub fn swapRemove(self: *Self, idx: usize) void {
            if (self.len - 1 == idx) {
                self.len -= 1;
                return;
            }

            const last = self.get(self.len - 1);
            self.getPtr(idx).* = last;
            self.len -= 1;
        }

        fn getImpl(self: Self, idx: usize) *T {
            if (idx >= self.len) unreachable;

            if (idx < self.initial_block.len) {
                return &self.initial_block[idx];
            }

            const block = idxToExpansionSlot(self.initial_block.len, idx, firstExpansionSize(self.initial_block.len));
            const block_start = expansionSlotStart(self.initial_block.len, block, firstExpansionSize(self.initial_block.len));
            return &self.expansions[block].?[idx - block_start];
        }

        pub fn setContents(self: *Self, content: []const T) !void {
            if (content.len >= self.capacity) {
                return error.OutOfMemory;
            }

            self.len = 0; // In case of failure

            defer self.freeUnusedBlocks();

            const initial_block_len = @min(self.initial_block.len, content.len);
            @memcpy(self.initial_block[0..initial_block_len], content[0..initial_block_len]);

            if (content.len <= self.initial_block.len) {
                self.len = content.len;
                return;
            }

            var block_id: usize = 0;

            while (true) {
                const block_start = expansionSlotStart(self.initial_block.len, block_id, firstExpansionSize(self.initial_block.len));
                const block_size = expansionBlockSize(block_id, firstExpansionSize(self.initial_block.len));
                const block_end = block_start + block_size;

                if (content.len <= block_start) break;

                const content_end = @min(content.len, block_end);
                const expansion_copy_len = content_end - block_start;

                if (expansion_copy_len == 0) {
                    self.len = content.len;
                    break;
                }

                try self.ensureBlockAllocated(block_id);
                @memcpy(self.expansions[block_id].?[0..expansion_copy_len], content[block_start..content_end]);
                block_id += 1;
            }

            self.len = content.len;
        }

        pub fn contentMatches(self: Self, content: []const T) bool {
            var it = self.sliceIter();
            var content_idx: usize = 0;
            while (true) {
                const part = it.next() orelse &.{};

                const remaining_content_len = content.len - content_idx;

                if (part.len == remaining_content_len) {
                    return std.mem.eql(T, content[content_idx..], part);
                }

                if (remaining_content_len < part.len or part.len == 0) {
                    return false;
                }

                if (!std.mem.eql(T, content[content_idx..][0..part.len], part)) {
                    return false;
                }

                content_idx += part.len;
            }
        }

        pub fn makeContiguous(self: *const Self, alloc: Allocator) ![]T {
            var ret = try RuntimeBoundedArray(T).init(alloc, self.len);
            var slice_iter = self.sliceIter();
            while (slice_iter.next()) |s| {
                try ret.appendSlice(s);
            }
            return ret.items;
        }

        const UnusedBlocksIt = struct {
            parent: *Self,
            expansion_idx: usize,

            fn init(parent: *Self) UnusedBlocksIt {
                if (parent.len < parent.initial_block.len) {
                    return .{
                        .parent = parent,
                        .expansion_idx = 0,
                    };
                }

                const expansion_idx = idxToExpansionSlot(parent.initial_block.len, parent.len - 1, firstExpansionSize(parent.initial_block.len));

                return .{
                    .parent = parent,
                    .expansion_idx = expansion_idx + 1,
                };
            }

            const Output = struct {
                idx: usize,
                block: []T,
            };

            fn next(self: *UnusedBlocksIt) ?Output {
                const expansion = self.parent.expansions[self.expansion_idx] orelse return null;
                defer self.expansion_idx += 1;
                const block_size = expansionBlockSize(self.expansion_idx, firstExpansionSize(self.parent.initial_block.len));

                return .{
                    .idx = self.expansion_idx,
                    .block = expansion[0..block_size],
                };
            }
        };

        fn freeUnusedBlocks(self: *Self) void {
            var unused_block_it = UnusedBlocksIt.init(self);

            while (unused_block_it.next()) |block| {
                self.alloc.free(block.block);
                self.expansions[block.idx] = null;
            }
        }

        fn appendInitial(self: *Self, elem: T) bool {
            if (self.len >= self.initial_block.len) {
                return false;
            }

            self.initial_block[self.len] = elem;
            self.len += 1;

            return true;
        }

        fn appendToBlock(self: *Self, block: usize, elem: T) void {
            const block_start = expansionSlotStart(self.initial_block.len, block, firstExpansionSize(self.initial_block.len));
            const expansion_offs = self.len - block_start;
            std.debug.assert(expansion_offs < expansionBlockSize(block, firstExpansionSize(self.initial_block.len)));
            self.expansions[block].?[expansion_offs] = elem;
            self.len += 1;
        }

        fn ensureBlockAllocated(self: *Self, block: usize) !void {
            if (self.expansions[block] == null) {
                self.expansions[block] = (try self.alloc.alloc(T, expansionBlockSize(block, firstExpansionSize(self.initial_block.len)))).ptr;
            }
        }

        pub const SliceIter = struct {
            parent: *const Self,
            first: bool = true,
            block_id: usize = 0,

            fn init(parent: *const Self) SliceIter {
                return .{
                    .parent = parent,
                };
            }

            pub fn next(self: *SliceIter) ?[]T {
                if (self.first) {
                    self.first = false;
                    const len = @min(self.parent.len, self.parent.initial_block.len);
                    return self.parent.initial_block[0..len];
                }

                const block_start = expansionSlotStart(self.parent.initial_block.len, self.block_id, firstExpansionSize(self.parent.initial_block.len));
                if (block_start >= self.parent.len) {
                    return null;
                }

                defer self.block_id += 1;

                const expansion = self.parent.expansions[self.block_id] orelse unreachable;

                const block_size = expansionBlockSize(self.block_id, firstExpansionSize(self.parent.initial_block.len));
                const len = @min(
                    self.parent.len - block_start,
                    block_size,
                );

                return expansion[0..len];
            }
        };

        pub fn sliceIter(self: *const Self) SliceIter {
            return SliceIter.init(self);
        }

        pub const Iter = struct {
            inner: SliceIter,
            current_slice: []T,
            slice_idx: usize = 0,

            fn init(parent: *const Self, idx: usize) Iter {
                if (idx < parent.initial_block.len) {
                    var inner = parent.sliceIter();
                    const current_slice: []T = inner.next() orelse &.{};
                    return .{
                        .inner = inner,
                        .current_slice = current_slice,
                        .slice_idx = idx,
                    };
                }

                const block = idxToExpansionSlot(parent.initial_block.len, idx, firstExpansionSize(parent.initial_block.len));
                const block_start = expansionSlotStart(parent.initial_block.len, block, firstExpansionSize(parent.initial_block.len));
                const block_len = expansionBlockSize(block, firstExpansionSize(parent.initial_block.len));
                const block_offs = idx - block_start;

                const inner = SliceIter{
                    .parent = parent,
                    .first = false,
                    .block_id = block + 1,
                };

                return .{
                    .inner = inner,
                    .current_slice = parent.expansions[block].?[0..block_len],
                    .slice_idx = block_offs,
                };
            }

            pub fn skip(self: *Iter, n: usize) void {
                for (0..n) |_| {
                    _ = self.next();
                }
            }

            pub fn next(self: *Iter) ?*T {
                if (self.slice_idx >= self.current_slice.len) {
                    self.current_slice = self.inner.next() orelse return null;
                    self.slice_idx = 0;
                }

                defer self.slice_idx += 1;

                return &self.current_slice[self.slice_idx];
            }
        };

        pub fn iter(self: *const Self) Iter {
            return Iter.init(self, 0);
        }

        pub fn iterFrom(self: *const Self, idx: usize) Iter {
            return Iter.init(self, idx);
        }

        fn firstExpansionSize(initial_len: usize) usize {
            const initial_len_log2: usize = std.math.log2_int_ceil(usize, @sizeOf(T) * initial_len);
            const min_page_size_log2: usize = @max(initial_len_log2, sphalloc.tiny_page_log2);

            return (@as(usize, 1) << @intCast(min_page_size_log2)) / @sizeOf(T);
        }
    };
}

fn idxToExpansionSlot(initial_size: usize, idx: usize, elems_per_page: usize) usize {
    // First expansion slot is the page size, each successive expansion
    // slot is twice as large as the previous
    //
    // first_slot_size(1 + 2 + 4 + 8)
    //
    // initial_slot + elems_per_page * (1 + 2 + 4 + 8 ... + n)
    //
    // E.g. with an initial slot of 100, elems_per_page of 500, and expansion slot 2
    // 100 + 500 + 1000 ...
    //     ^      ^      ^
    //     0      1      2
    //
    // We want to go the other way though, we want
    //   [0,100+500) -> 0,
    //   [100+500, 100+500+1000) -> 1,
    //   [100+500+1000, ...) -> 2,
    //   ...
    //
    // Plugging the sum part into wolfram alpha (sum 0..k 2^k), we get
    // pos = initial_slot + elems_per_page*(2^(n+1)) - 1)
    //
    // With some algebra
    // (pos - initial_slot) / elems_per_page = 2^(n+1) - 1
    // (pos - initial_slot) / elems_per_page + 1 = 2^(n+1)
    // log2((pos - initial_slot) / elems_per_page + 1) = n+1
    // log2((pos - initial_slot) / elems_per_page + 1) - 1 = n
    //
    // But then we're off by 1, so we drop the - 1 at the end
    const log2_arg = (idx -| initial_size) / elems_per_page + 1;
    if (log2_arg == 0) return 0;
    return std.math.log2(log2_arg);
}

fn expansionBlockSize(block: usize, elems_per_page: usize) usize {
    // E_(0..k) 2^k
    return elems_per_page * (@as(usize, 1) << @intCast(block));
}

test "expansionBlockSize" {
    try std.testing.expectEqual(100, expansionBlockSize(0, 100));
    try std.testing.expectEqual(200, expansionBlockSize(1, 100));
    try std.testing.expectEqual(400, expansionBlockSize(2, 100));
    try std.testing.expectEqual(800, expansionBlockSize(3, 100));
}

fn expansionSlotStart(initial_size: usize, slot: usize, elems_per_page: usize) usize {
    // See idxToExpansionSlot
    return initial_size + elems_per_page * ((@as(usize, 1) << @intCast(slot)) - 1);
}

test "RuntimeSegmentedList expansion idx" {
    // 100 600 1600 3600 7600
    //  ^
    //  0   1   2    3    4
    try std.testing.expectEqual(0, idxToExpansionSlot(100, 0, 500));
    try std.testing.expectEqual(0, idxToExpansionSlot(100, 100, 500));
    try std.testing.expectEqual(0, idxToExpansionSlot(100, 599, 500));
    try std.testing.expectEqual(1, idxToExpansionSlot(100, 600, 500));
    try std.testing.expectEqual(1, idxToExpansionSlot(100, 1599, 500));
    try std.testing.expectEqual(2, idxToExpansionSlot(100, 1600, 500));
    try std.testing.expectEqual(2, idxToExpansionSlot(100, 3599, 500));
    try std.testing.expectEqual(3, idxToExpansionSlot(100, 3600, 500));
    // 20 276 788
    try std.testing.expectEqual(1, idxToExpansionSlot(20, 276, 256));
    try std.testing.expectEqual(1, idxToExpansionSlot(20, 286, 256));
    try std.testing.expectEqual(1, idxToExpansionSlot(20, 787, 256));
    try std.testing.expectEqual(2, idxToExpansionSlot(20, 788, 256));
}

test "RuntimeSegmentedList expansion idx slot start" {
    try std.testing.expectEqual(100, expansionSlotStart(100, 0, 500));
    try std.testing.expectEqual(600, expansionSlotStart(100, 1, 500));
    try std.testing.expectEqual(1600, expansionSlotStart(100, 2, 500));
    try std.testing.expectEqual(3600, expansionSlotStart(100, 3, 500));
}

test "RuntimeSegmentedList append" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(i32).init(
        arena.allocator(),
        std.heap.page_allocator,
        5,
        20000,
    );

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.append(5);

    var it = list.sliceIter();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5 }, it.next().?);
    try std.testing.expectEqual(null, it.next());

    try list.append(6);
    try list.append(7);
    try list.append(8);
    try list.append(9);

    it = list.sliceIter();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5 }, it.next().?);
    try std.testing.expectEqualSlices(i32, &.{ 6, 7, 8, 9 }, it.next().?);
}

test "RuntimeSegmentedList iter" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(usize).init(
        arena.allocator(),
        std.heap.page_allocator,
        5,
        20000,
    );

    for (0..5000) |i| {
        try list.append(i);
    }

    var it = list.iter();
    var i: usize = 0;
    while (it.next()) |elem| {
        try std.testing.expectEqual(i, elem.*);
        i += 1;
    }
}

test "RuntimeSegmentedList setContents" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    const content = "The quick brown fox jumped over the lazy dog " ** 50;
    try list.setContents(content);

    var it = list.sliceIter();
    it = list.sliceIter();
    try std.testing.expectEqualStrings("The quick brown fox ", it.next().?);

    var start: usize = 20;
    var end: usize = start + 256;
    try std.testing.expectEqualStrings(content[start..end], it.next().?);
    start = end;
    end = start + 512;
    try std.testing.expectEqualStrings(content[start..end], it.next().?);
    start = end;
    end = start + 1024;
    try std.testing.expectEqualStrings(content[start..end], it.next().?);
    start = end;
    try std.testing.expectEqualStrings(content[start..], it.next().?);

    const content2 = "The quick brown fox jumped over the lazy dog";
    try list.setContents(content2);

    try std.testing.expectEqual(null, list.expansions[2]);
    try std.testing.expectEqual(null, list.expansions[3]);
    try std.testing.expectEqual(null, list.expansions[4]);
    try std.testing.expectEqual(null, list.expansions[5]);

    const content3 = "The";
    try list.setContents(content3);
    try std.testing.expectEqual(null, list.expansions[0]);
    try std.testing.expectEqual(null, list.expansions[1]);
    try std.testing.expectEqual(null, list.expansions[2]);
    try std.testing.expectEqual(null, list.expansions[3]);
    try std.testing.expectEqual(null, list.expansions[4]);
    try std.testing.expectEqual(null, list.expansions[5]);
}

test "RuntimeSegmentedList UnusedBlockIter" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // FIXME: Double arena seems wrong
    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), arena.allocator(), 20, 1 << 20);

    const content = "The quick brown fox jumped over the lazy dog " ** 50;
    try list.setContents(content);
    list.len = 20 + 256 + 10;

    var it = RuntimeSegmentedList(u8).UnusedBlocksIt.init(&list);

    {
        const next = it.next();
        try std.testing.expectEqual(2, next.?.idx);
        try std.testing.expectEqual(1024, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(3, next.?.idx);
        try std.testing.expectEqual(2048, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(null, next);
    }

    list.len = 3;
    it = RuntimeSegmentedList(u8).UnusedBlocksIt.init(&list);

    {
        const next = it.next();
        try std.testing.expectEqual(0, next.?.idx);
        try std.testing.expectEqual(256, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(1, next.?.idx);
        try std.testing.expectEqual(512, next.?.block.len);
    }
}

test "RuntimeSegmentedList content matches" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    const content = "The quick brown fox jumped over the lazy dog";
    try list.setContents(content);

    try std.testing.expectEqual(false, list.contentMatches("The"));
    try std.testing.expectEqual(true, list.contentMatches("The quick brown fox jumped over the lazy dog"));
    try std.testing.expectEqual(false, list.contentMatches("The quick brown fox jumped over the lazy dog" ** 2));
    try std.testing.expectEqual(false, list.contentMatches("asdf"));
}

test "RuntimeSegmentedList get" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(usize).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    for (0..20000) |i| {
        try list.append(i);
    }

    try std.testing.expectEqual(1, list.get(1));
    try std.testing.expectEqual(0, list.get(0));
    try std.testing.expectEqual(20, list.get(20));
    try std.testing.expectEqual(21, list.get(21));
    try std.testing.expectEqual(17342, list.get(17342));
    try std.testing.expectEqual(579, list.get(579));
}

test "RuntimeSegmentedList makeContiguous" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(usize).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    for (0..20000) |i| {
        try list.append(i);
    }

    const contiguous = try list.makeContiguous(arena.allocator());
    for (0..20000) |i| {
        try std.testing.expectEqual(i, contiguous[i]);
    }
}

test "RuntimeSegmentedList iter offset" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(usize).init(arena.allocator(), std.heap.page_allocator, 20, 1 << 20);

    for (0..20000) |i| {
        try list.append(i);
    }

    {
        var it = list.iterFrom(1);
        try std.testing.expectEqual(1, it.next().?.*);
    }
    {
        var it = list.iterFrom(0);
        try std.testing.expectEqual(0, it.next().?.*);
    }
    {
        var it = list.iterFrom(20);
        try std.testing.expectEqual(20, it.next().?.*);
    }
    {
        var it = list.iterFrom(21);
        try std.testing.expectEqual(21, it.next().?.*);
    }
    {
        var it = list.iterFrom(17342);
        try std.testing.expectEqual(17342, it.next().?.*);
    }
    {
        var it = list.iterFrom(579);
        try std.testing.expectEqual(579, it.next().?.*);
    }
}
