const std = @import("std");
const rsl = @import("runtime_segmented_list.zig");

// FIXME: split bitset into own file
pub fn BitSet(comptime expansion_alloc_info: rsl.ExpansionAllocInfo) type {
    return struct {
        storage: Storage,

        const Storage = rsl.RuntimeSegmentedListConfigurable(u8, expansion_alloc_info);
        const Self = @This();

        pub fn init(prealloc: std.mem.Allocator, expansion_alloc: std.mem.Allocator, prealloc_size: usize, max_size: usize) !Self {
            const prealloc_byte_size = byteFromBitSize(prealloc_size);
            const max_byte_size = byteFromBitSize(max_size);

            return .{
                .storage = try .init(
                    prealloc,
                    expansion_alloc,
                    prealloc_byte_size,
                    max_byte_size,
                ),
            };
        }

        pub fn bitLen(self: Self) usize {
            return self.storage.len * 8;
        }

        pub fn get(self: Self, bit_idx: usize) bool {
            const storage_idx = bit_idx / 8;
            const sub_idx: u3 = @truncate(bit_idx);
            const byte = self.storage.get(storage_idx);
            return getBitFromByte(byte, sub_idx);
        }

        fn getBitFromByte(byte: u8, sub_idx: u3) bool {
            return (byte & (@as(u8, 1) << sub_idx)) != 0;
        }

        pub fn set(self: *Self, bit_idx: usize, val: bool) void {
            const storage_idx = bit_idx / 8;
            const sub_idx: u3 = @truncate(bit_idx);
            const byte = self.storage.getPtr(storage_idx);
            const mask = @as(u8, 1) << sub_idx;

            if (val) {
                byte.* |= mask;
            } else {
                byte.* &= ~mask;
            }
        }

        pub fn appendByte(self: *Self, b: u8) !void {
            try self.storage.append(b);
        }

        pub const Iter = struct {
            storage_iter: Storage.Iter,
            current_byte: u8,
            bit_idx: u8,

            pub fn next(self: *Iter) ?bool {
                if (self.bit_idx >= 8) {
                    self.current_byte = if (self.storage_iter.next()) |b| b.* else return null;
                    self.bit_idx = 0;
                }

                defer self.bit_idx += 1;
                // Bit index has to support being larger than a u3 to flag out
                // of range, but getBitFromByte wants a u3 for shifting
                return getBitFromByte(self.current_byte, @truncate(self.bit_idx));
            }
        };

        pub fn iter(self: *Self) Iter {
            var storage_iter = self.storage.iter();
            const first_byte = storage_iter.next();
            const first_bit: u8 = if (first_byte == null) 8 else 0;
            return .{
                .storage_iter = storage_iter,
                .current_byte = if (first_byte) |b| b.* else 0,
                .bit_idx = first_bit,
            };
        }

        pub fn shrink(self: *Self, bit_size: usize) void {
            self.storage.shrink(bit_size / 8);
        }

        // Rounds up to next 8
        pub fn grow(self: *Self, bit_size: usize, fill: bool) !void {
            const byte_fill: u8 = if (fill) 0xff else 0;
            const byte_size = byteFromBitSize(bit_size);
            while (self.storage.len < byte_size) {
                try self.storage.append(byte_fill);
            }
        }

        fn byteFromBitSize(bit_size: usize) usize {
            return std.mem.alignForward(usize, bit_size, 8) / 8;
        }


        pub fn iterFrom(self: *Self, bit_idx: usize) Iter {
            var storage_iter = self.storage.iterFrom(bit_idx / 8);
            const first_byte = storage_iter.next();
            const first_bit = if (first_byte == null) bit_idx % 8 else 0;

            return .{
                .storage_iter = storage_iter,
                .current_byte = first_byte,
                .bit_idx = first_bit,
            };
        }
    };
}

test "bitset sanity" {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var linear_alloc = std.heap.FixedBufferAllocator.init(&alloc_buf);
    var bitset = try BitSet(rsl.linear_alloc_info).init(
        linear_alloc.allocator(),
        linear_alloc.allocator(),
        16,
        128,
    );


    try bitset.grow(3, true);
    try std.testing.expectEqual(8, bitset.bitLen());
    for (0..8) |i| {
        try std.testing.expect(bitset.get(i));
    }

    bitset.set(0, false);
    try std.testing.expect(!bitset.get(0));
    for (1..8) |i| {
        try std.testing.expect(bitset.get(i));
    }

    try bitset.grow(16, false);

    // But the new byte should be false
    for (8..16) |i| {
        try std.testing.expect(!bitset.get(i));
    }

    var it = bitset.iter();
    try std.testing.expectEqual(false, it.next());
    for (1..8) |_| {
        try std.testing.expectEqual(true, it.next());
    }

    for (8..16) |_| {
        try std.testing.expectEqual(false, it.next());
    }
}

fn handleFromIdx(comptime Handle: type, idx: usize) Handle {
    switch (@typeInfo(Handle)) {
        .@"struct" => return .init(idx),
        .int => return @intCast(idx),
        else => comptime unreachable,
    }
}

fn idxFromHandle(handle: anytype) usize {
    switch (@typeInfo(@TypeOf(handle))) {
        .@"struct" => return handle.inner,
        .int => return handle,
        else => comptime unreachable,
    }
}

fn ObjectPoolConfigurable(comptime T: type, comptime Handle: type, comptime expansion_alloc_info: rsl.ExpansionAllocInfo) type {
    return struct{
        expansion_alloc: std.mem.Allocator,
        objects: Objects,
        tombstones: BitSet(expansion_alloc_info), // True on dead
        free_list: rsl.RuntimeSegmentedListConfigurable(usize, expansion_alloc_info),

        const Objects = rsl.RuntimeSegmentedListConfigurable(T, expansion_alloc_info);
        const Self = @This();

        const WithHandle = struct {
            handle: Handle,
            val: *T,
        };

        pub fn acquire(self: *Self) WithHandle {
            if (self.free_list.pop()) |idx| {
                const handle = Handle.init(idx);
                std.debug.assert(self.tombstones.get(idx));
                const ptr = self.objects.getPtr(idx);
                self.tombstones.set(idx, false);

                return .{
                    .handle = handle,
                    .val = ptr,
                };
            }

            const idx = self.objects.len;
            const val = self.objects.addOne(undefined);
            if (idx % 8 == 0) {
                self.tombstones.appendByte(0xff);
            }
            self.tombstones.set(idx, false);

            return .{
                .idx = handleFromIdx(idx),
                .val = val,
            };
        }

        pub fn release(self: *Self, handle: Handle) void {
            const idx = idxFromHandle(handle);
            std.debug.assert(!self.tombstones.get(idx));


            // FIXME: If handle == objects.len it should pop instead of
            // appending to free list

            self.free_list.append(idx) catch unreachable;
            // FIXME: Double check if this is optimized out
            self.objects.getPtr(idx).* = undefined;
            self.tombstones.set(idx, true);
        }

        pub const Iter = struct {
            objects: Objects.Iter,
            tombs: BitSet(expansion_alloc_info).Iter,

            fn next(self: *Iter) ?*T {
                while (true) {
                    const maybe_ret = self.objects.next() orelse return null;
                    const is_dead = self.tombs.next();

                    if (!is_dead) {
                        return maybe_ret;
                    }
                }
            }
        };


        fn relciamMemory(self: *Self, move_ctx: anytype) void {
            if (self.objects.len == 0) return;

            var ts_byte_iter = self.tombstones.storage.iter();

            var holes: usize = 0;
            // 9 elems -> 1 iter
            for (0..self.objects.len / 8) |_| {
                const ts_byte = ts_byte_iter.next().?.*;
                holes += @popCount(ts_byte);
            }

            const remainder = self.objects.len % 8;
            if (remainder != 0) {
                const b = ts_byte_iter.next().?;
                // 00000111
                const mask = (1 << remainder) - 1;
                holes += @popCount(b & mask);
            }

            const last_block_start = self.objects.blockStartForIdx(self.objects.len - 1);
            const after_removal_block_start = self.objects.blockStartForIdx(self.objects.len - holes);

            // FIXME: Should never be greater idiot
            if (after_removal_block_start >= last_block_start) {
                return;
            }

            self.defrag(move_ctx);
        }

        // FIXME: impl defragIfDensityLow


        // Defrag for releasing memory
        //   * Only need to move things IF it results in a block of memory being popped from RSL
        //   * Only need to move things IF expansion alloc supports free
        //
        // Defrag for iteration speed
        //   * Some heuristic on denisty?
        //   * Input ratio of skipped/set objects

        fn defrag(self: *Self, move_ctx: anytype, num_holes: usize) void {
            // Work with indexes for now, despite extra math in RSL to resolve
            // block indexes. Because I'm too stupid :). We can make the
            // argument that defrag is already expensive and should be
            // relatively rare, so whatever :)

            var tail: usize = self.objects.len - 1;
            var head: usize = 0;

            while (head < tail) {
                const to = self.findNextHole(&head) orelse return;
                const from = self.findNextFree(&tail) orelse return;

                to.* = from.*;
                from.* = undefined;
                move_ctx.notifyMoved(head);
                head += 1;
            }

            const new_len = self.objects.len - num_holes;
            self.objects.shrink(new_len);
            self.tombstones.shrink(new_len);
            self.free_list.shrink(0);

            var tomb_iter = self.tombstones.iter();
            while (tomb_iter.next()) |val| {
                val.* = 0;
            }
        }

        fn findNextHole(self: Self, head: *usize) ?*T {
            const tombstone_iter = self.tombstones.iterFrom(head.*);

            while (tombstone_iter.next()) |val| blk: {
                if (val) {
                    break :blk;
                }

                head.* += 1;
            }

            if (head.* >= self.objects.len) return null;
            return self.objects.getPtr(head.*);
        }

        fn findNextFree(self: Self, tail: *usize) ?*T {
            // FIXME: Maybe we should add an reverse iter so that we don't have
            // to do so much block indexing

            while (true) blk: {
                const val = self.tombstones.get(tail);
                if (val) {
                    break :blk;
                }

                if (tail == 0) return null;
                tail.* -= 1;
            }
            return self.objects.getPtr(tail.*);
        }
    };
}

// FIXME: Lots of testing for object pool
