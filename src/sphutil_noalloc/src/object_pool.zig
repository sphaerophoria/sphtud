const std = @import("std");
const rsl = @import("runtime_segmented_list.zig");
const bit_set = @import("bit_set.zig");

fn handleFromIdx(comptime Handle: type, idx: usize) Handle {
    switch (@typeInfo(Handle)) {
        .@"struct" => return .fromIdx(idx),
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

pub fn ObjectPoolLinear(comptime T: type, comptime Handle: type) type {
    return ObjectPoolConfigurable(T, Handle, rsl.linear_alloc_info);
}

pub fn ObjectPoolConfigurable(comptime T: type, comptime Handle: type, comptime expansion_alloc_info: rsl.ExpansionAllocInfo) type {
    return struct {
        objects: Objects,
        tombstones: bit_set.BitSet(expansion_alloc_info), // True on dead
        free_list: rsl.RuntimeSegmentedListConfigurableUnmanaged(usize, expansion_alloc_info),

        const Objects = rsl.RuntimeSegmentedListConfigurableUnmanaged(T, expansion_alloc_info);
        const Self = @This();

        const WithHandle = struct {
            handle: Handle,
            val: *T,
        };

        pub fn init(
            prealloc_alloc: std.mem.Allocator,
            prealloc_size: usize,
            max_size: usize,
        ) !Self {
            return .{
                .objects = try .init(prealloc_alloc, prealloc_size, max_size),
                .tombstones = try .init(prealloc_alloc, prealloc_size, max_size),
                .free_list = try .init(prealloc_alloc, prealloc_size, max_size),
            };
        }

        pub fn acquire(self: *Self, expansion_alloc: std.mem.Allocator) !WithHandle {
            if (self.free_list.pop(expansion_alloc)) |idx| {
                const handle = handleFromIdx(Handle, idx);
                std.debug.assert(self.tombstones.get(idx));
                const ptr = self.objects.getPtr(idx);
                self.tombstones.set(idx, false);

                return .{
                    .handle = handle,
                    .val = ptr,
                };
            }

            const idx = self.objects.len;
            const val = try self.objects.addOne(expansion_alloc);
            if (idx % 8 == 0) {
                try self.tombstones.appendByte(expansion_alloc, 0xff);
            }
            self.tombstones.set(idx, false);

            return .{
                .handle = handleFromIdx(Handle, idx),
                .val = val,
            };
        }

        pub fn release(self: *Self, expansion_alloc: std.mem.Allocator, handle: Handle) void {
            const idx = idxFromHandle(handle);
            std.debug.assert(!self.tombstones.get(idx));

            // FIXME: If handle == objects.len it should pop instead of
            // appending to free list

            self.free_list.append(expansion_alloc, idx) catch unreachable;
            // FIXME: Double check if this is optimized out
            self.objects.getPtr(idx).* = undefined;
            self.tombstones.set(idx, true);
        }

        pub fn get(self: Self, handle: Handle) *T {
            return self.objects.getPtr(idxFromHandle(handle));
        }

        pub const Iter = struct {
            idx: usize,
            objects: Objects.Iter,
            tombs: bit_set.BitSet(expansion_alloc_info).Iter,

            pub fn next(self: *Iter) ?WithHandle {
                while (true) {
                    const maybe_ret = self.objects.next() orelse return null;
                    const is_dead = self.tombs.next() orelse unreachable;
                    defer self.idx += 1;

                    if (!is_dead) {
                        return .{
                            .handle = handleFromIdx(Handle, self.idx),
                            .val = maybe_ret,
                        };
                    }
                }
            }
        };

        pub fn iter(self: *Self) Iter {
            return .{
                .idx = 0,
                .objects = self.objects.iter(),
                .tombs = self.tombstones.iter(),
            };
        }

        pub fn relciamMemory(self: *Self, expansion_alloc: std.mem.Allocator, move_ctx: anytype) void {
            if (self.needsMemoryReclamation()) {
                self.defrag(expansion_alloc, move_ctx);
            }
        }

        fn needsMemoryReclamation(self: *const Self) bool {
            if (self.objects.len == 0) return false;

            const last_block_start = self.objects.blockStartForIdx(self.objects.len - 1);
            const after_removal_block_start = self.objects.blockStartForIdx(self.objects.len - self.free_list.len - 1);

            std.debug.assert(after_removal_block_start <= last_block_start);

            return after_removal_block_start < last_block_start;
        }

        pub fn defragIfDensityLow(self: *Self, expansion_alloc: std.mem.Allocator, density_thresh: f32, move_ctx: anytype) void {
            if (self.isLowDensity(density_thresh)) {
                self.defrag(expansion_alloc, move_ctx);
            }
        }

        fn isLowDensity(self: *const Self, thresh: f32) bool {
            const free_list_len: f32 = @floatFromInt(self.free_list.len);
            const allocated_objects: f32 = @floatFromInt(self.objects.len);

            return 1.0 - free_list_len / allocated_objects < thresh;
        }

        pub fn defrag(self: *Self, expansion_alloc: std.mem.Allocator, move_ctx: anytype) void {
            // Work with indexes for now, despite extra math in RSL to resolve
            // block indexes. Because I'm too stupid :). We can make the
            // argument that defrag is already expensive and should be
            // relatively rare, so whatever :)

            var tail: usize = self.objects.len - 1;
            var head: usize = 0;

            while (true) {
                const to = self.findNextHole(&head) orelse break;
                const from = self.findNextPresent(&tail) orelse break;
                if (head >= tail) break;

                to.* = from.*;
                from.* = undefined;
                move_ctx.notifyMoved(handleFromIdx(Handle, tail), handleFromIdx(Handle, head));
                head += 1;
                tail -= 1;
            }

            const new_len = self.objects.len - self.free_list.len;
            self.objects.shrink(expansion_alloc, new_len);
            self.tombstones.shrink(expansion_alloc, new_len);
            self.free_list.shrink(expansion_alloc, 0);

            var tomb_iter = self.tombstones.storage.iter();
            while (tomb_iter.next()) |val| {
                val.* = 0;
            }
        }

        fn findNextHole(self: Self, head: *usize) ?*T {
            var tombstone_iter = self.tombstones.iterFrom(head.*);

            while (tombstone_iter.next()) |val| {
                if (val) {
                    break;
                }

                head.* += 1;
            }

            if (head.* >= self.objects.len) return null;
            return self.objects.getPtr(head.*);
        }

        fn findNextPresent(self: Self, tail: *usize) ?*T {
            // FIXME: Maybe we should add an reverse iter so that we don't have
            // to do so much block indexing

            while (true) {
                const val = self.tombstones.get(tail.*);
                if (!val) {
                    break;
                }

                if (tail.* == 0) return null;
                tail.* -= 1;
            }
            return self.objects.getPtr(tail.*);
        }

        pub fn scramble(self: *Self, expansion_alloc: std.mem.Allocator, scratch_alloc: std.mem.Allocator, random: std.Random, move_ctx: anytype) !void {
            var it = self.iter();

            var indices = std.ArrayList(usize).initBuffer(try scratch_alloc.alloc(usize, self.objects.len - self.free_list.len));

            while (it.next()) |item| {
                try indices.appendBounded(idxFromHandle(item.handle));
            }

            random.shuffle(usize, indices.items);

            var extra = try self.getOrMakeHole(expansion_alloc);

            // Sanity check that we don't have to handle any error cases below.
            // Once we start moving everything succeeds, no rollback
            errdefer comptime unreachable;

            for (indices.items) |to_move| {
                std.debug.assert(self.tombstones.get(extra) == true);
                std.debug.assert(self.tombstones.get(to_move) == false);

                const from_ptr = self.objects.getPtr(to_move);
                const to_ptr = self.objects.getPtr(extra);
                to_ptr.* = from_ptr.*;
                from_ptr.* = undefined;

                self.tombstones.set(to_move, true);
                self.tombstones.set(extra, false);

                move_ctx.notifyMoved(handleFromIdx(Handle, to_move), handleFromIdx(Handle, extra));

                extra = to_move;
            }
        }

        fn getOrMakeHole(self: *Self, expansion_alloc: std.mem.Allocator) !usize {
            var head: usize = 0;
            if (self.findNextHole(&head)) |_| {
                return head;
            }

            const ret = idxFromHandle((try self.acquire(expansion_alloc)).handle);
            // Intentionally immediately set tombstone as we are trying to make
            // a hole, not a valid object like normal
            self.tombstones.set(ret, true);
            try self.free_list.append(expansion_alloc, ret);
            return ret;
        }
    };
}

const TrackedPool = struct {
    expansion_alloc: std.mem.Allocator,
    pool: ObjectPoolLinear(usize, Handle),
    map: std.AutoHashMap(Handle, void),

    const Handle = struct {
        inner: usize,

        fn fromIdx(val: usize) @This() {
            return .{
                .inner = val,
            };
        }
    };

    const MoveCtx = struct {
        tracked_pool: *TrackedPool,
        failed: bool,

        pub fn notifyMoved(self: *@This(), from: TrackedPool.Handle, to: TrackedPool.Handle) void {
            // Discard removed value as we want each element to match it's own index
            _ = self.tracked_pool.map.fetchRemove(from) orelse {
                std.log.err("Value at {d} is not in map\n", .{from.inner});
                self.failed = true;
                return;
            };
            self.tracked_pool.pool.get(to).* = to.inner;
            self.tracked_pool.map.put(to, {}) catch {
                self.failed = true;
            };
        }
    };

    pub fn init(alloc: std.mem.Allocator) !TrackedPool {
        const pool = try ObjectPoolLinear(usize, Handle).init(
            alloc,
            16,
            1024,
        );

        const map = std.AutoHashMap(Handle, void).init(alloc);

        return .{
            .expansion_alloc = alloc,
            .pool = pool,
            .map = map,
        };
    }

    pub fn insertIfMissing(self: *TrackedPool) !void {
        const item = self.pool.acquire(self.expansion_alloc) catch |e| {
            if (e == error.OutOfMemory) return;
            return e;
        };
        item.val.* = @intCast(item.handle.inner);
        try self.map.put(item.handle, {});
    }

    pub fn removeIfPresent(self: *TrackedPool, idx: usize) void {
        const handle = Handle.fromIdx(idx);
        if (!self.map.remove(handle)) {
            return;
        }

        self.pool.release(self.expansion_alloc, handle);
    }

    pub fn checkMapMatchesPool(self: *TrackedPool, alloc: std.mem.Allocator) !void {
        var seen_handles = std.AutoHashMap(TrackedPool.Handle, void).init(alloc);
        defer seen_handles.deinit();

        var it = self.pool.iter();
        while (it.next()) |item| {
            _ = self.map.get(item.handle) orelse {
                std.debug.print("{d} missing\n", .{item.handle.inner});
                return error.MissingElement;
            };

            const gop = try seen_handles.getOrPut(item.handle);
            try std.testing.expectEqual(false, gop.found_existing);
        }

        try std.testing.expectEqual(self.map.count(), seen_handles.count());
    }

    pub fn moveCtx(self: *TrackedPool) MoveCtx {
        return .{
            .tracked_pool = self,
            .failed = false,
        };
    }
};

test "ObjectPool sanity" {
    var fba_buf: [1 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const alloc = fba.allocator();

    var testing_pool = try TrackedPool.init(alloc);

    for (0..50) |_| {
        // Initialize pool with incrementing u32s, track them in map as well for
        // comparison later after defrag
        for (0..1000) |_| {
            try testing_pool.insertIfMissing();
        }

        var rng = std.Random.DefaultPrng.init(0);
        const random = rng.random();

        for (0..500) |_| {
            const to_remove = random.intRangeAtMost(u32, 0, 1000);
            testing_pool.removeIfPresent(to_remove);
        }

        try testing_pool.checkMapMatchesPool(std.testing.allocator);

        var move_ctx = testing_pool.moveCtx();
        testing_pool.pool.defrag(testing_pool.expansion_alloc, &move_ctx);

        try std.testing.expectEqual(false, move_ctx.failed);
        try testing_pool.checkMapMatchesPool(std.testing.allocator);
    }
}

test "ObjectPool memory reclaimable" {
    var fba_buf: [1 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const alloc = fba.allocator();

    var pool = try ObjectPoolConfigurable(u32, u32, rsl.linear_alloc_info).init(alloc, 4, 10);

    for (0..5) |i| {
        const item = try pool.acquire(alloc);
        // Note that this is not a test expectation, but if this assertion
        // fails the test itself is broken. We are assuming we know the
        // underlying storage patterns here
        std.debug.assert(i == item.handle);
    }

    try std.testing.expectEqual(false, pool.needsMemoryReclamation());
    pool.release(alloc, 3);

    try std.testing.expectEqual(true, pool.needsMemoryReclamation());
}

test "ObjectPool low density" {
    var fba_buf: [1 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const alloc = fba.allocator();

    var pool = try ObjectPoolConfigurable(u32, u32, rsl.linear_alloc_info).init(alloc, 4, 10);

    for (0..5) |i| {
        const item = try pool.acquire(alloc);
        // Note that this is not a test expectation, but if this assertion
        // fails the test itself is broken. We are assuming we know the
        // underlying storage patterns here
        std.debug.assert(i == item.handle);
    }

    pool.release(alloc, 3);
    pool.release(alloc, 1);

    try std.testing.expectEqual(true, pool.isLowDensity(1.0));
    try std.testing.expectEqual(true, pool.isLowDensity(0.61));
    try std.testing.expectEqual(false, pool.isLowDensity(0.59));
}

test "ObjectPool scramble" {
    var fba_buf: [1 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const alloc = fba.allocator();

    var testing_pool = try TrackedPool.init(alloc);

    // Initialize pool with incrementing u32s, track them in map as well for
    // comparison later after defrag
    for (0..1000) |_| {
        try testing_pool.insertIfMissing();
    }

    var rng = std.Random.DefaultPrng.init(0);
    const random = rng.random();

    for (0..500) |_| {
        const to_remove = random.intRangeAtMost(u32, 0, 1000);
        testing_pool.removeIfPresent(to_remove);
    }

    try testing_pool.checkMapMatchesPool(std.testing.allocator);

    var move_ctx = testing_pool.moveCtx();
    for (0..20) |_| {
        try testing_pool.pool.scramble(testing_pool.expansion_alloc, alloc, random, &move_ctx);
    }

    try std.testing.expectEqual(false, move_ctx.failed);
    try testing_pool.checkMapMatchesPool(std.testing.allocator);
}
