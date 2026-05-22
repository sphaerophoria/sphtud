const std = @import("std");
const sphtud = @import("../sphtud.zig");

pub const Order = enum {
    earlier,
    same,
    later,
};

pub fn BinaryHeap(comptime T: type) type {
    return struct {
        storage: Storage,

        const Storage = sphtud.util.RuntimeSegmentedListUnmanaged(T);
        const Self = @This();

        pub fn init(
            arena: std.mem.Allocator,
            expansion: sphtud.util.ExpansionAlloc,
            typical_size: usize,
            max_size: usize,
        ) !Self {
            return .{
                .storage = try .init(
                    arena,
                    expansion,
                    typical_size,
                    max_size,
                ),
            };
        }

        pub fn push(self: *Self, expansion: sphtud.util.ExpansionAlloc, ctx: anytype, elem: T) !void {
            try self.storage.append(expansion, elem);
            self.siftUp(ctx, self.storage.len - 1);
        }

        pub fn peek(self: *Self) ?T {
            if (self.storage.len == 0) return null;
            return self.storage.get(0);
        }

        pub fn pop(self: *Self, expansion: sphtud.util.ExpansionAlloc, ctx: anytype) ?T {
            if (self.storage.len == 0) return null;

            return self.popIdx(expansion, ctx, 0);
        }

        pub fn iter(self: *Self) Storage.Iter {
            return self.storage.iter();
        }

        pub fn popIdx(self: *Self, expansion: sphtud.util.ExpansionAlloc, ctx: anytype, idx: usize) ?T {
            const ret = self.storage.get(idx);
            self.storage.swapRemove(expansion, idx);
            self.siftDown(ctx, idx);

            return ret;
        }

        fn siftUp(self: *Self, ctx: anytype, start_idx: usize) void {
            var pos = TreePosition.fromIdx(start_idx);

            while (pos.calcParent()) |parent_pos| {
                const parent = self.storage.getPtr(parent_pos.idx);
                const current = self.storage.getPtr(pos.idx);

                if (ctx.compare(current.*, parent.*) == .earlier) {
                    std.mem.swap(T, parent, current);
                } else {
                    break;
                }

                pos = parent_pos;
            }
        }

        fn siftDown(self: *Self, ctx: anytype, start_idx: usize) void {
            var pos = TreePosition.fromIdx(start_idx);

            while (pos.idx < self.storage.len) {
                const ca_pos = pos.calcFirstChild();

                if (ca_pos.idx >= self.storage.len) break;
                const cb_idx = ca_pos.idx + 1;

                const ca = self.storage.getPtr(ca_pos.idx);
                const cb = if (cb_idx < self.storage.len) self.storage.getPtr(ca_pos.idx + 1) else null;
                const current = self.storage.getPtr(pos.idx);

                const target = blk: switch (calcSiftDownTarget(ctx, current, ca, cb)) {
                    .a => {
                        pos = ca_pos;
                        break :blk ca;
                    },
                    .b => {
                        pos = .fromIdx(cb_idx);
                        break :blk cb.?;
                    },
                    .none => break,
                };

                std.mem.swap(T, current, target);
            }
        }

        const SiftDownTarget = enum {
            a,
            b,
            none,
        };

        fn calcSiftDownTarget(ctx: anytype, current: *T, ca: *T, cb: ?*T) SiftDownTarget {
            // c[a/b] == child a/b
            const rel_ca = ctx.compare(current.*, ca.*);
            const rel_cb = if (cb) |val| ctx.compare(current.*, val.*) else .earlier;

            if (rel_ca == rel_cb and rel_ca == .later) {
                const a_earlier = ctx.compare(ca.*, cb.?.*) == .earlier;
                return if (a_earlier) .a else .b;
            } else if (rel_ca == .later) {
                return .a;
            } else if (rel_cb == .later) {
                return .b;
            } else {
                return .none;
            }
        }
    };
}

const TestFixture = struct {
    rng_impl: std.Random.DefaultPrng,
    alloc_buf: [1 * 1024 * 1024]u8 = undefined,
    buf_alloc: sphtud.alloc.BufAllocator,
    heap: BinaryHeap(i32),

    pub fn initPinned(self: *TestFixture) !void {
        self.* = .{
            .rng_impl = .init(0),
            .buf_alloc = sphtud.alloc.BufAllocator.init(&self.alloc_buf),
            .heap = try .init(
                self.buf_alloc.allocator(),
                self.buf_alloc.expansion(),
                32,
                1000,
            ),
        };
    }

    fn allocator(self: *TestFixture) std.mem.Allocator {
        return self.buf_alloc.allocator();
    }

    fn expansion(self: *TestFixture) sphtud.util.ExpansionAlloc {
        return self.buf_alloc.expansion();
    }

    fn random(self: *TestFixture) std.Random {
        return self.rng_impl.random();
    }
};

test "BinaryHeap sanity" {
    var fixture: TestFixture = undefined;
    try fixture.initPinned();

    const HeapCtx = struct {
        fn compare(a: i32, b: i32) Order {
            if (a < b) return .earlier;
            if (a == b) return .same;
            return .later;
        }
    };

    var elems = std.ArrayList(i32).initBuffer(try fixture.allocator().alloc(i32, 1000));
    for (0..1000) |_| {
        const val = fixture.random().intRangeAtMost(i32, -1000, 1000);
        try elems.appendBounded(val);
        try fixture.heap.push(fixture.expansion(), HeapCtx, val);
    }

    std.mem.sort(i32, elems.items, {}, struct {
        fn f(_: void, a: i32, b: i32) bool {
            return a < b;
        }
    }.f);

    for (elems.items) |e| {
        try std.testing.expectEqual(e, fixture.heap.pop(fixture.expansion(), HeapCtx));
    }
}

test "BinaryHeap random insertions and removals" {
    var fixture: TestFixture = undefined;
    try fixture.initPinned();

    const HeapCtx = struct {
        fn compare(a: i32, b: i32) Order {
            if (a < b) return .earlier;
            if (a == b) return .same;
            return .later;
        }
    };

    const StdHeap = std.PriorityQueue(i32, void, struct {
        fn f(_: void, a: i32, b: i32) std.math.Order {
            return std.math.order(a, b);
        }
    }.f);

    var std_heap = StdHeap.empty;

    for (0..20) |_| {
        const add_amount = fixture.random().intRangeAtMost(usize, 0, 100);
        for (0..add_amount) |_| {
            const val = fixture.random().intRangeAtMost(i32, -100, 100);
            try std_heap.push(fixture.allocator(), val);
            try fixture.heap.push(fixture.expansion(), HeapCtx, val);
        }

        const remove_amount = fixture.random().intRangeAtMost(usize, 0, add_amount -| 1);

        for (0..remove_amount) |_| {
            const std_val = std_heap.pop();
            const sphtud_val = fixture.heap.pop(fixture.expansion(), HeapCtx);

            try std.testing.expectEqual(std_val, sphtud_val);
            if (std_val == null) break;
        }

        const random_remove_amount = fixture.random().intRangeAtMost(usize, 0, std_heap.items.len -| 1);
        for (0..random_remove_amount) |_| {
            const sphtud_idx = fixture.random().intRangeAtMost(usize, 0, fixture.heap.storage.len -| 1);
            const popped = fixture.heap.popIdx(fixture.expansion(), HeapCtx, sphtud_idx);

            var it = std_heap.iterator();
            var std_idx: usize = 0;
            while (it.next()) |val| {
                if (val == popped) {
                    _ = std_heap.popIndex(std_idx);
                    break;
                }
                std_idx += 1;
            }
        }
    }
}

const TreePosition = struct {
    idx: usize,

    pub fn fromIdx(idx: usize) TreePosition {
        return .{ .idx = idx };
    }

    pub fn calcParent(self: TreePosition) ?TreePosition {
        if (self.idx == 0) return null;

        return .{ .idx = (self.idx - 1) / 2 };
    }

    pub fn calcFirstChild(self: TreePosition) TreePosition {
        return .{ .idx = self.idx * 2 + 1 };
    }
};

test "TreePosition parent" {
    {
        const x = TreePosition.fromIdx(0);
        try std.testing.expectEqual(null, x.calcParent());
    }

    {
        const x = TreePosition.fromIdx(1);
        try std.testing.expectEqual(TreePosition{ .idx = 0 }, x.calcParent());
    }

    {
        const x = TreePosition.fromIdx(2);
        try std.testing.expectEqual(TreePosition{ .idx = 0 }, x.calcParent());
    }

    {
        const x = TreePosition.fromIdx(3);
        try std.testing.expectEqual(TreePosition{ .idx = 1 }, x.calcParent());
    }

    {
        const x = TreePosition.fromIdx(4);
        try std.testing.expectEqual(TreePosition{ .idx = 1 }, x.calcParent());
    }

    {
        const x = TreePosition.fromIdx(5);
        try std.testing.expectEqual(TreePosition{ .idx = 2 }, x.calcParent());
    }

    {
        const x = TreePosition.fromIdx(6);
        try std.testing.expectEqual(TreePosition{ .idx = 2 }, x.calcParent());
    }
}

test "TreePosition child" {
    {
        const x = TreePosition.fromIdx(0);
        try std.testing.expectEqual(TreePosition{ .idx = 1 }, x.calcFirstChild());
    }

    {
        const x = TreePosition.fromIdx(1);
        try std.testing.expectEqual(TreePosition{ .idx = 3 }, x.calcFirstChild());
    }

    {
        const x = TreePosition.fromIdx(2);
        try std.testing.expectEqual(TreePosition{ .idx = 5 }, x.calcFirstChild());
    }

    {
        const x = TreePosition.fromIdx(3);
        try std.testing.expectEqual(TreePosition{ .idx = 7 }, x.calcFirstChild());
    }

    {
        const x = TreePosition.fromIdx(4);
        try std.testing.expectEqual(TreePosition{ .idx = 9 }, x.calcFirstChild());
    }

    {
        const x = TreePosition.fromIdx(5);
        try std.testing.expectEqual(TreePosition{ .idx = 11 }, x.calcFirstChild());
    }

    {
        const x = TreePosition.fromIdx(6);
        try std.testing.expectEqual(TreePosition{ .idx = 13 }, x.calcFirstChild());
    }
}
