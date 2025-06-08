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
        // Block storage. block[0] is a pre-allocated block on init, blocks
        // 1..N are dynamically allocated.
        //
        // Since the lengths are known, based off the index, we don't have to
        // store them
        //
        // Number of blocks is fixed on initialization, we do not attempt
        // to resize
        blocks: []?[*]T,
        initial_block_len: usize,
        capacity: usize,
        len: usize = 0,

        // Every expansion block doubles in size

        const Self = @This();
        const grow_factor = 2;

        pub const empty = Self{
            .alloc = undefined,
            .blocks = &.{},
            .initial_block_len = 0,
            .capacity = 0,
            .len = 0,
        };

        pub fn init(arena: Allocator, tiny_page_alloc: Allocator, small_size: usize, max_size: usize) !Self {
            const max_idx = max_size - 1;
            const num_blocks = idxToBlockId(small_size, max_idx, firstExpansionSize(small_size)) + 1;
            const blocks = try arena.alloc(?[*]T, num_blocks);
            comptime std.debug.assert(@sizeOf(?[*]T) == @sizeOf(*T));
            @memset(blocks, null);
            blocks[0] = (try arena.alloc(T, small_size)).ptr;

            return .{
                .alloc = tiny_page_alloc,
                .blocks = blocks,
                .initial_block_len = small_size,
                .capacity = max_size,
            };
        }

        pub fn append(self: *Self, elem: T) !void {
            if (self.len >= self.capacity) {
                return error.OutOfMemory;
            }

            const block = idxToBlockId(self.initial_block_len, self.len, firstExpansionSize(self.initial_block_len));
            try self.ensureBlockAllocated(block);
            self.appendToBlock(block, elem);
        }

        pub fn appendSlice(self: *Self, data: []const T) !void {
            if (self.len + data.len > self.capacity) {
                return error.OutOfMemory;
            }

            var remaining = data;
            while (remaining.len > 0) {
                const writeable_area = try self.getWritableArea();
                const copy_len = @min(writeable_area.len, remaining.len);
                @memcpy(writeable_area[0..copy_len], remaining[0..copy_len]);
                remaining = if (copy_len == data.len) &.{} else remaining[copy_len..];
                self.len += copy_len;
            }
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

            const first_expansion_size = firstExpansionSize(self.initial_block_len);
            const block = idxToBlockId(self.initial_block_len, idx, first_expansion_size);
            const block_start = blockStart(self.initial_block_len, block, first_expansion_size);
            return &self.blocks[block].?[idx - block_start];
        }

        pub fn setContents(self: *Self, content: []const T) !void {
            if (content.len >= self.capacity) {
                return error.OutOfMemory;
            }

            self.len = 0; // In case of failure

            defer self.freeUnusedBlocks();

            try self.appendSlice(content);
        }

        pub fn contentMatches(self: Self, content: []const T) bool {
            var it = self.blockIter();
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
            var block_iter = self.blockIter();
            while (block_iter.next()) |s| {
                try ret.appendSlice(s);
            }
            return ret.items;
        }

        pub fn asContiguousSlice(self: *const Self, alloc: Allocator, start: usize, end: usize) ![]T {
            const first_expansion_size = firstExpansionSize(self.initial_block_len);
            const start_block = idxToBlockId(self.initial_block_len, start, first_expansion_size);
            const end_block = idxToBlockId(self.initial_block_len, @max(end - 1, start), first_expansion_size);

            if (start_block == end_block) {
                const block_start = blockStart(self.initial_block_len, start_block, first_expansion_size);
                return self.blocks[start_block].?[start - block_start .. end - block_start];
            }

            var ret = try RuntimeBoundedArray(T).init(alloc, end - start);
            var block_iter = self.blockIter();
            var passed_elems: usize = 0;
            while (block_iter.next()) |s| {
                const s_start = start -| passed_elems;
                const s_end = @min(end -| passed_elems, s.len);
                try ret.appendSlice(s[s_start..s_end]);
                passed_elems += s.len;
            }
            return ret.items;
        }

        // Get the next contiguous block of memory for writing
        pub fn getWritableArea(self: *Self) ![]T {
            if (self.len >= self.capacity) {
                return &.{};
            }

            const first_expansion_size = firstExpansionSize(self.initial_block_len);
            const block = idxToBlockId(self.initial_block_len, self.len, first_expansion_size);
            const block_start = blockStart(self.initial_block_len, block, first_expansion_size);
            const block_size = blockSize(block, self.initial_block_len, first_expansion_size);

            try self.ensureBlockAllocated(block);
            return self.blocks[block].?[self.len - block_start .. block_size];
        }

        // Paired with getWritableArea can be used to flag how much of the
        // writeable area we populated
        pub fn grow(self: *Self, amount: usize) void {
            std.debug.assert(amount <= (self.getWritableArea() catch unreachable).len);
            self.len += amount;
        }

        const UnusedBlocksIt = struct {
            parent: *Self,
            block_idx: usize,

            fn init(parent: *Self) UnusedBlocksIt {
                const block_idx = idxToBlockId(parent.initial_block_len, parent.len - 1, firstExpansionSize(parent.initial_block_len));

                return .{
                    .parent = parent,
                    .block_idx = block_idx + 1,
                };
            }

            const Output = struct {
                idx: usize,
                block: []T,
            };

            fn next(self: *UnusedBlocksIt) ?Output {
                if (self.block_idx >= self.parent.blocks.len) {
                    return null;
                }

                const block = self.parent.blocks[self.block_idx] orelse return null;

                defer self.block_idx += 1;
                const block_size = blockSize(self.block_idx, self.parent.initial_block_len, firstExpansionSize(self.parent.initial_block_len));

                return .{
                    .idx = self.block_idx,
                    .block = block[0..block_size],
                };
            }
        };

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            // NOTE string lists are not serialized as strings. The standard
            // library does this with some members that are not easy for us to
            // yoink out (jw.valueStart() and jw.valueEnd() +
            // encodeJsonStringChars would be nice)

            var it = self.blockIter();

            try jw.beginArray();
            while (it.next()) |s| {
                for (s) |v| {
                    try jw.write(v);
                }
            }
            try jw.endArray();
        }

        pub const Slice = struct {
            parent: *Self,
            start: usize,
            len: usize,

            pub fn get(self: Slice, idx: usize) T {
                return self.parent.get(self.parentIdx(idx));
            }

            pub fn getPtr(self: Slice, idx: usize) *T {
                return self.parent.getPtr(self.parentIdx(idx));
            }

            pub fn iter(self: Slice) Iter {
                return Iter.init(self.parent, self.start, self.start + self.len);
            }

            pub fn blockIter(self: Slice) BlockIter {
                return BlockIter.init(self.parent, self.start, self.start + self.len);
            }

            pub fn reader(self: Slice) Reader {
                var it = BlockIter.init(self.parent, self.start, self.start + self.len);
                const current_slice = it.next() orelse &.{};
                return .{
                    .it = it,
                    .current_slice = current_slice,
                };
            }

            fn parentIdx(self: Slice, idx: usize) usize {
                std.debug.assert(idx < self.len);
                return idx + self.start;
            }
        };

        pub fn slice(self: *Self, start: usize, end: usize) Slice {
            return .{
                .parent = self,
                .start = start,
                .len = end - start,
            };
        }

        const Reader = struct {
            it: BlockIter,
            current_slice: []const u8,

            fn read(self: *Reader, buffer: []u8) anyerror!usize {
                var out = buffer;

                while (true) {
                    const copy_len = @min(out.len, self.current_slice.len);
                    if (copy_len == 0) break;

                    @memcpy(out[0..copy_len], self.current_slice[0..copy_len]);

                    if (copy_len < self.current_slice.len) {
                        self.current_slice = self.current_slice[copy_len..];
                    } else {
                        self.current_slice = self.it.next() orelse &.{};
                    }

                    if (copy_len < out.len) {
                        out = out[copy_len..];
                    } else {
                        out = &.{};
                    }
                }

                return buffer.len - out.len;
            }

            pub fn generic(self: *Reader) std.io.GenericReader(*Reader, anyerror, read) {
                return .{
                    .context = self,
                };
            }
        };

        pub fn reader(self: *Self) Reader {
            var it = BlockIter.init(self, 0, self.len);
            const current_slice = it.next() orelse &.{};
            return .{
                .it = it,
                .current_slice = current_slice,
            };
        }

        fn freeUnusedBlocks(self: *Self) void {
            var unused_block_it = UnusedBlocksIt.init(self);

            while (unused_block_it.next()) |block| {
                self.alloc.free(block.block);
                self.blocks[block.idx] = null;
            }
        }

        fn appendToBlock(self: *Self, block: usize, elem: T) void {
            const first_expansion_size = firstExpansionSize(self.initial_block_len);
            const block_start = blockStart(self.initial_block_len, block, first_expansion_size);
            const block_offs = self.len - block_start;
            std.debug.assert(block_offs < blockSize(block, self.initial_block_len, first_expansion_size));
            self.blocks[block].?[block_offs] = elem;
            self.len += 1;
        }

        fn ensureBlockAllocated(self: *Self, block: usize) !void {
            if (self.blocks[block] == null) {
                self.blocks[block] = (try self.alloc.alloc(T, blockSize(block, self.initial_block_len, firstExpansionSize(self.initial_block_len)))).ptr;
            }
        }

        pub const BlockIter = struct {
            parent: *const Self,
            block_id: usize,
            start: usize,
            end: usize,

            fn init(parent: *const Self, start: usize, end: usize) BlockIter {
                return .{
                    .parent = parent,
                    .block_id = idxToBlockId(parent.initial_block_len, start, firstExpansionSize(parent.initial_block_len)),
                    .start = start,
                    .end = end,
                };
            }

            pub fn next(self: *BlockIter) ?[]T {
                const block_start = blockStart(self.parent.initial_block_len, self.block_id, firstExpansionSize(self.parent.initial_block_len));
                if (block_start >= self.end) {
                    return null;
                }

                defer self.block_id += 1;

                const block = self.parent.blocks[self.block_id] orelse unreachable;

                const block_size = blockSize(self.block_id, self.parent.initial_block_len, firstExpansionSize(self.parent.initial_block_len));
                const start = self.start -| block_start;
                const end = @min(
                    self.end - block_start,
                    block_size,
                );

                return block[start..end];
            }
        };

        pub fn blockIter(self: *const Self) BlockIter {
            return BlockIter.init(self, 0, self.len);
        }

        pub const Iter = struct {
            inner: BlockIter,
            current_slice: []T,
            slice_idx: usize = 0,
            end: usize = 0,

            fn init(parent: *const Self, idx: usize, end: usize) Iter {
                var inner = BlockIter.init(parent, idx, end);
                const current_slice: []T = inner.next() orelse &.{};

                return .{
                    .inner = inner,
                    .current_slice = current_slice,
                    .slice_idx = 0,
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
            return Iter.init(self, 0, self.len);
        }

        pub fn iterFrom(self: *const Self, idx: usize) Iter {
            return Iter.init(self, @min(idx, self.len), self.len);
        }

        fn firstExpansionSize(initial_len: usize) usize {
            if (initial_len == 0) return 0;
            const initial_len_log2: usize = std.math.log2_int_ceil(usize, @sizeOf(T) * initial_len);
            const min_page_size_log2: usize = @max(initial_len_log2, sphalloc.tiny_page_log2);

            return (@as(usize, 1) << @intCast(min_page_size_log2)) / @sizeOf(T);
        }
    };
}

fn idxToBlockId(initial_size: usize, idx: usize, first_expansion_size: usize) usize {
    // First block is special in that the small size does not have to line up
    // with a page boundary
    //
    // The math starts lining up nicely starting with block id 1, which we can
    // call the first expansion slot
    //
    // First expansion slot is first_expansion_size, each successive expansion
    // slot is twice as large as the previous
    //
    //
    // E.g. with an initial slot of 100, first_expansion_size of 500, and expansion slot 2
    // 100 + 500 + 1000 ...
    //
    // We want to go the other way though, we want
    //   [0,100) -> 0
    //   [100,100 + 500) -> 1
    //   [100+500, 100+500+1000) -> 2,
    //   [100+500+1000, ...) -> 3,
    //   ...
    //
    // A function to map block ID to start index could look like
    //
    // n = 0: 0
    // n > 0: initial_slot + first_expansion_size * ( (1 + 2 + 4 + 8 ... + n - 1))
    //
    // Plugging the sum part into wolfram alpha (sum 1..k 2^(k - 1)), we get
    // 2^k - 1, but since we started at 1 our block id is offset. The formula becomes
    //
    // pos = initial_slot + first_expansion_size*((2^(block_id - 1)) - 1)
    //
    // If we want to go from block index to block id, we can just rearrange
    // (pos - initial_slot) / first_expansion_size = 2^(block_id - 1) - 1
    // (pos - initial_slot) / first_expansion_size + 1 = 2^(block_id - 1)
    // log2((pos - initial_slot) / first_expansion_size + 1) = (block_id - 1)
    // log2((pos - initial_slot) / first_expansion_size + 1) + 1 = block_id
    //
    // Then we just have to handle the block_id == 0 case
    if (idx < initial_size or initial_size == 0) return 0;
    const log2_arg = (idx -| initial_size) / first_expansion_size + 1;
    return std.math.log2(log2_arg) + 1;
}

fn blockSize(block: usize, initial_size: usize, first_expansion_size: usize) usize {
    if (block == 0) return initial_size;
    // E_(0..k) 2^k
    return first_expansion_size * (@as(usize, 1) << @intCast(block - 1));
}

test "expansionBlockSize" {
    try std.testing.expectEqual(10, blockSize(0, 10, 100));
    try std.testing.expectEqual(100, blockSize(1, 10, 100));
    try std.testing.expectEqual(200, blockSize(2, 10, 100));
    try std.testing.expectEqual(400, blockSize(3, 10, 100));
}

fn blockStart(initial_size: usize, block: usize, first_expansion_size: usize) usize {
    // See idxToBlockId
    if (block == 0) return 0;
    return initial_size + first_expansion_size * ((@as(usize, 1) << @intCast(block - 1)) - 1);
}

test "RuntimeSegmentedList expansion idx" {
    //  0  100 600 1600 3600 7600
    //
    //  0   1   2    3    4   5
    try std.testing.expectEqual(0, idxToBlockId(100, 0, 500));
    try std.testing.expectEqual(1, idxToBlockId(100, 100, 500));
    try std.testing.expectEqual(1, idxToBlockId(100, 599, 500));
    try std.testing.expectEqual(2, idxToBlockId(100, 600, 500));
    try std.testing.expectEqual(2, idxToBlockId(100, 1599, 500));
    try std.testing.expectEqual(3, idxToBlockId(100, 1600, 500));
    try std.testing.expectEqual(3, idxToBlockId(100, 3599, 500));
    try std.testing.expectEqual(4, idxToBlockId(100, 3600, 500));
    // 0 20 276 788
    try std.testing.expectEqual(2, idxToBlockId(20, 276, 256));
    try std.testing.expectEqual(2, idxToBlockId(20, 286, 256));
    try std.testing.expectEqual(2, idxToBlockId(20, 787, 256));
    try std.testing.expectEqual(3, idxToBlockId(20, 788, 256));
}

test "RuntimeSegmentedList expansion idx slot start" {
    try std.testing.expectEqual(0, blockStart(100, 0, 500));
    try std.testing.expectEqual(100, blockStart(100, 1, 500));
    try std.testing.expectEqual(600, blockStart(100, 2, 500));
    try std.testing.expectEqual(1600, blockStart(100, 3, 500));
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

    var it = list.blockIter();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5 }, it.next().?);
    try std.testing.expectEqual(null, it.next());

    try list.append(6);
    try list.append(7);
    try list.append(8);
    try list.append(9);

    it = list.blockIter();
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

    var it = list.blockIter();
    it = list.blockIter();
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

    try std.testing.expectEqual(null, list.blocks[2]);
    try std.testing.expectEqual(null, list.blocks[3]);
    try std.testing.expectEqual(null, list.blocks[4]);
    try std.testing.expectEqual(null, list.blocks[5]);

    const content3 = "The";
    try list.setContents(content3);
    try std.testing.expect(list.blocks[0] != null);
    try std.testing.expectEqual(null, list.blocks[1]);
    try std.testing.expectEqual(null, list.blocks[2]);
    try std.testing.expectEqual(null, list.blocks[3]);
    try std.testing.expectEqual(null, list.blocks[4]);
    try std.testing.expectEqual(null, list.blocks[5]);
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
        try std.testing.expectEqual(3, next.?.idx);
        try std.testing.expectEqual(1024, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(4, next.?.idx);
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
        try std.testing.expectEqual(1, next.?.idx);
        try std.testing.expectEqual(256, next.?.block.len);
    }

    {
        const next = it.next();
        try std.testing.expectEqual(2, next.?.idx);
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

    // Empty list
    {
        var it = list.iterFrom(0);
        try std.testing.expectEqual(null, it.next());
    }

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

    // Out of range request
    {
        var it = list.iterFrom(list.len + 100);
        try std.testing.expectEqual(null, it.next());
    }
}

test "RuntimeSegmentedList jsonStringify" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    {
        var list = try RuntimeSegmentedList(u16).init(arena.allocator(), std.heap.page_allocator, 20, 500);
        const data = &[_]u16{ 16, 32, 123, 542, 99 };
        try list.setContents(data);
        const s = try std.json.stringifyAlloc(arena.allocator(), list, .{});
        try std.testing.expectEqualStrings("[16,32,123,542,99]", s);
    }
}

test "RuntimeSegmentedList append slice" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 3000);

    // Copying into empty list
    try list.appendSlice("asdf");
    {
        const final = try list.makeContiguous(arena.allocator());
        try std.testing.expectEqualSlices(u8, "asdf", final);
    }

    // Copying into partially populated initial block
    try list.appendSlice("1234");
    {
        const final = try list.makeContiguous(arena.allocator());
        try std.testing.expectEqualSlices(u8, "asdf1234", final);
    }

    // Copying into over initial block -> first expansion boundary
    // 8 bytes so far, 20 bytes in first block, need at least 12 more
    try list.appendSlice("abcdefghijklmnop");
    {
        const final = try list.makeContiguous(arena.allocator());
        try std.testing.expectEqualSlices(u8, "asdf1234abcdefghijklmnop", final);
        try std.testing.expect(list.len > list.initial_block_len);
    }

    // Copy over many expansion boundaries
    // (tiny) page size is 256 bytes
    // First block should be 256, next 512, next 1024
    {
        const big_block = try arena.allocator().alloc(u8, 2048);
        for (0..big_block.len) |i| {
            big_block[i] = @truncate(i);
        }
        const old_len = list.len;
        try list.appendSlice(big_block);
        const final = try list.makeContiguous(arena.allocator());
        try std.testing.expectEqualSlices(u8, "asdf1234abcdefghijklmnop", final[0..old_len]);
        try std.testing.expectEqualSlices(u8, big_block, final[old_len..]);
        try std.testing.expect(list.blocks[0] != null);
        try std.testing.expect(list.blocks[1] != null);
        try std.testing.expect(list.blocks[2] != null);
        try std.testing.expect(list.blocks[3] != null);
    }

    // Perfect boundary
    {
        const remaining_len = list.capacity - list.len;
        const remaining = try arena.allocator().alloc(u8, remaining_len);
        @memset(remaining, 0);
        try list.appendSlice(remaining);
        try std.testing.expectEqual(list.len, list.capacity);
    }

    // Too big
    {
        list.shrink(2500);

        const remaining_len = list.capacity - list.len + 1;
        const remaining = try arena.allocator().alloc(u8, remaining_len);
        @memset(remaining, 0);
        try std.testing.expectError(error.OutOfMemory, list.appendSlice(remaining));
        try std.testing.expectEqual(list.len, 2500);
    }
}

test "RuntimeSegmentedList getWritableArea" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), std.heap.page_allocator, 40, 2000);

    // Initial block
    {
        const writable = try list.getWritableArea();
        try std.testing.expectEqual(writable.ptr, list.blocks[0].?);
        try std.testing.expectEqual(writable.len, list.initial_block_len);
        @memset(writable, 0);
        list.grow(20);
    }

    // After growth should still be initial block, but less of it
    {
        const writable = try list.getWritableArea();
        try std.testing.expectEqual(writable.ptr, list.blocks[0].? + 20);
        try std.testing.expectEqual(writable.len, list.initial_block_len - 20);
        @memset(writable, 0);
        list.grow(writable.len);
    }

    // expansion block
    {
        const writable = try list.getWritableArea();
        try std.testing.expectEqual(writable.ptr, list.blocks[1]);
        try std.testing.expectEqual(writable.len, 256);
        @memset(writable, 0);
        list.grow(writable.len);
    }

    while (list.len < list.capacity) {
        try list.append(0);
    }

    // full
    {
        const writable = try list.getWritableArea();
        try std.testing.expectEqual(0, writable.len);
    }
}

test "RuntimeSegmentedList asContiguousSlice" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 2000);
    try list.setContents("The quick brown fox jumped over the lazy dog");

    // Already contiguous
    {
        const s = try list.asContiguousSlice(arena.allocator(), 5, 10);
        try std.testing.expectEqualStrings("uick ", s);
        try std.testing.expectEqual(list.blocks[0].? + 5, s.ptr);
    }

    // Full block already contiguous
    {
        const s = try list.asContiguousSlice(arena.allocator(), 0, 20);
        try std.testing.expectEqualStrings("The quick brown fox ", s);
    }

    // Make new contiguous
    {
        const s = try list.asContiguousSlice(arena.allocator(), 0, list.len);
        try std.testing.expectEqualStrings("The quick brown fox jumped over the lazy dog", s);
    }
}

test "RuntimeSegmentedList slicing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 2000);
    try list.setContents("The quick brown fox jumped over the lazy dog");

    var slice = list.slice(5, 35);
    try std.testing.expectEqual('u', slice.get(0));
    try std.testing.expectEqual('i', slice.get(1));
    try std.testing.expectEqual('e', slice.get(29));

    try std.testing.expectEqual('u', slice.getPtr(0).*);
    try std.testing.expectEqual('i', slice.getPtr(1).*);
    try std.testing.expectEqual('e', slice.getPtr(29).*);

    {
        var it = slice.iter();
        for ("uick brown fox jumped over the") |c| {
            try std.testing.expectEqual(c, it.next().?.*);
        }
        try std.testing.expectEqual(null, it.next());
    }

    {
        var it = slice.blockIter();
        try std.testing.expectEqualStrings("uick brown fox ", it.next().?);
        try std.testing.expectEqualStrings("jumped over the", it.next().?);
        try std.testing.expectEqual(null, it.next());
    }

    {
        var reader = slice.reader();
        const gr = reader.generic();

        var buf: [1024]u8 = undefined;
        const read_len = try gr.readAll(&buf);
        try std.testing.expectEqualStrings("uick brown fox jumped over the", buf[0..read_len]);
    }
}

test "RuntimeSegmentedList reader" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = try RuntimeSegmentedList(u8).init(arena.allocator(), std.heap.page_allocator, 20, 2000);
    try list.setContents("The quick brown fox jumped over the lazy dog");

    var reader = list.reader();
    const gr = reader.generic();

    var buf: [1024]u8 = undefined;
    const read_len = try gr.readAll(&buf);
    try std.testing.expectEqualStrings("The quick brown fox jumped over the lazy dog", buf[0..read_len]);
}

test "RuntimeSegmentedList empty" {
    var empty: RuntimeSegmentedList(u8) = .empty;

    {
        var it = empty.iter();
        try std.testing.expectEqual(null, it.next());
    }

    {
        var it = empty.blockIter();
        try std.testing.expectEqual(null, it.next());
    }

    try std.testing.expectEqual(0, empty.len);
    try std.testing.expectError(error.OutOfMemory, empty.append(0));
}
