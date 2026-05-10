const std = @import("std");
const sphutil = @import("../util.zig");
const ExpansionAlloc = sphutil.ExpansionAlloc;

pub fn AutoHashMap(comptime K: type, comptime V: type) type {
    return HashMap(
        K,
        V,
        std.hash_map.AutoContext(K),
    );
}

pub fn StringHashMap(comptime V: type) type {
    return HashMap(
        []const u8,
        V,
        std.hash_map.StringContext,
    );
}

pub fn HashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
) type {
    return struct {
        buckets: sphutil.RuntimeSegmentedList(std.SinglyLinkedList),
        node_storage: NodeStorage,

        len: usize,
        ctx: Context,

        const Self = @This();

        const NodeStorage = sphutil.RuntimeSegmentedList(ListNode);
        const ListNode = struct {
            node: std.SinglyLinkedList.Node,
            key: K,
            val: V,
        };

        const min_load_percent = 50;
        const max_load_percent = 80;

        pub fn init(
            arena: std.mem.Allocator,
            expansion_alloc: ExpansionAlloc,
            typical_size: usize,
            max_size: usize,
        ) !Self {
            const typical_buckets = typical_size * 100 / max_load_percent;
            const max_buckets = max_size * 100 / max_load_percent;

            var ret = Self{
                .buckets = try .init(arena, expansion_alloc, typical_buckets, max_buckets),
                .node_storage = try .init(arena, expansion_alloc, typical_size, max_size),
                .len = 0,
                .ctx = Context{},
            };

            try ret.buckets.fillBlock(.{});

            return ret;
        }

        const GetOrPutResult = struct {
            found_existing: bool,
            key: *K,
            val: *V,
        };

        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            switch (self.findNode(key)) {
                .found => |n| return .{
                    .found_existing = true,
                    .key = &n.node.key,
                    .val = &n.node.val,
                },
                .missing => |hash| {
                    try self.ensureCapacityForInsertion();

                    const storage_idx = self.node_storage.len;
                    try self.node_storage.append(undefined);
                    const node = self.node_storage.getPtr(storage_idx);
                    node.* = .{
                        .node = .{},
                        .key = key,
                        .val = undefined,
                    };

                    const bucket = self.buckets.getPtr(hash % self.buckets.len);
                    bucket.prepend(&node.node);

                    self.len += 1;

                    return .{
                        .found_existing = false,
                        .key = &node.key,
                        .val = &node.val,
                    };
                },
            }
        }

        pub fn putNoClobber(self: *Self, key: K, val: V) !void {
            const gop = try self.getOrPut(key);

            if (gop.found_existing) {
                return error.AlreadyExists;
            }

            gop.val.* = val;
        }

        pub fn put(self: *Self, key: K, val: V) !void {
            const gop = try self.getOrPut(key);
            gop.val.* = val;
        }

        pub fn contains(self: *const Self, key: K) bool {
            switch (self.findNode(key)) {
                .found => return true,
                .missing => return false,
            }
        }

        pub fn get(self: *const Self, key: K) ?V {
            switch (self.findNode(key)) {
                .found => |n| return n.node.val,
                .missing => return null,
            }
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            switch (self.findNode(key)) {
                .found => |n| return &n.node.val,
                .missing => return null,
            }
        }

        pub fn remove(self: *Self, key: K) ?V {
            const to_remove = switch (self.findNode(key)) {
                .found => |n| n,
                .missing => return null,
            };

            const ret = to_remove.node.val;

            to_remove.from_ptr.* = to_remove.node.node.next;

            const to_pop_idx = self.node_storage.len - 1;

            const to_remove_storage_idx = self.node_storage.indexFromPtr(to_remove.node);
            if (to_remove_storage_idx != to_pop_idx) {
                const to_pop = self.node_storage.getPtr(to_pop_idx);
                const to_pop_linked = self.findNode(to_pop.key).found;
                replaceBStorageWithA(to_remove.node, to_pop_linked.from_ptr, to_pop);
            }

            self.node_storage.shrink(self.node_storage.len - 1);
            self.len -= 1;

            while (self.node_storage.alloc.info.supports_free) {
                const new_num_buckets = self.buckets.blockStartForIdx(self.buckets.len -| 1);
                if (self.len >= new_num_buckets * min_load_percent / 100) {
                    break;
                }

                self.rehash(self.buckets.len, new_num_buckets);
                self.buckets.shrink(new_num_buckets);
            }

            return ret;
        }

        fn replaceBStorageWithA(a: *ListNode, b_from: *?*std.SinglyLinkedList.Node, b: *ListNode) void {
            // B is going to be popped, but A is what we wanted to remove
            //
            // Everything that currently points to B needs to point to A now

            b_from.* = &a.node;
            a.key = b.key;
            a.val = b.val;
            a.node = b.node;
            // Do not swap storage idx as that has not changed
        }

        pub const Iter = struct {
            inner: NodeStorage.Iter,

            const Item = struct {
                key: *K,
                val: *V,
            };

            pub fn next(self: *Iter) ?Item {
                while (true) {
                    const node = self.inner.next() orelse return null;
                    return .{
                        .key = &node.key,
                        .val = &node.val,
                    };
                }
            }
        };

        pub fn iter(self: *Self) Iter {
            return .{
                .inner = self.node_storage.iter(),
            };
        }

        const GetNodeResult = union(enum) {
            found: struct {
                node: *ListNode,
                bucket: *std.SinglyLinkedList,
                from_ptr: *?*std.SinglyLinkedList.Node,
            },
            missing: u64,
        };

        fn findNode(self: *const Self, key: K) GetNodeResult {
            const hash = self.ctx.hash(key);
            const bucket_id = hash % self.buckets.len;
            const bucket = self.buckets.getPtr(bucket_id);

            var from_ptr: *?*std.SinglyLinkedList.Node = &bucket.first;
            var it = bucket.first;
            while (it) |n| {
                const list_node: *ListNode = @fieldParentPtr("node", n);
                if (self.ctx.eql(list_node.key, key)) {
                    return .{
                        .found = .{
                            .node = list_node,
                            .bucket = bucket,
                            .from_ptr = from_ptr,
                        },
                    };
                }
                from_ptr = &n.next;
                it = n.next;
            }

            return .{
                .missing = hash,
            };
        }

        fn ensureCapacityForInsertion(self: *Self) !void {
            const old_num_buckets = self.buckets.len;
            if (self.len < self.noCollisionCapacity()) {
                return;
            }

            while (self.len >= self.noCollisionCapacity()) {
                try self.buckets.fillBlock(.{});
            }

            self.rehash(old_num_buckets, self.buckets.len);
        }

        fn noCollisionCapacity(self: *const Self) usize {
            return self.buckets.len * max_load_percent / 100;
        }

        fn rehash(self: *Self, to_bucket_id: usize, new_num_buckets: usize) void {
            var bucket_it = self.buckets.iter();
            for (0..to_bucket_id) |old_bucket_id| {
                const bucket = bucket_it.next().?;
                var from_ptr: *?*std.SinglyLinkedList.Node = &bucket.first;
                var node = bucket.first;
                while (node) |n| {
                    const data: *ListNode = @fieldParentPtr("node", n);

                    const hash = self.ctx.hash(data.key);
                    const new_bucket_id = hash % new_num_buckets;

                    if (new_bucket_id == old_bucket_id) {
                        from_ptr = &n.next;
                        node = n.next;
                        continue;
                    }

                    from_ptr.* = n.next;
                    node = n.next;
                    self.buckets.getPtr(new_bucket_id).prepend(n);
                }
            }
        }
    };
}

test "HashMap random insertion removal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const expansion_alloc = sphutil.ExpansionAlloc{
        .info = &.{
            .min_expansion_size_log2 = 0,
            .supports_free = false,
        },
        .alloc = arena.allocator(),
    };

    var rng = std.Random.DefaultPrng.init(0);
    const rand = rng.random();

    var ref = std.AutoHashMap(i32, i32).init(arena.allocator());
    var map = try AutoHashMap(i32, i32).init(
        arena.allocator(),
        expansion_alloc,
        20,
        1000,
    );

    for (0..10000) |_| {
        const key = rand.intRangeAtMost(i32, 0, 999);
        const val = rand.int(i32);

        try ref.put(key, val);
        try map.put(key, val);
    }

    for (0..100) |_| {
        const key = rand.intRangeAtMost(i32, 0, 999);

        _ = ref.remove(key);
        _ = map.remove(key);
    }

    try std.testing.expectEqual(ref.count(), map.len);

    var ref_it = ref.iterator();
    while (ref_it.next()) |ref_entry| {
        const val = map.get(ref_entry.key_ptr.*);
        try std.testing.expectEqual(ref_entry.value_ptr.*, val);
    }

    var map_it = map.iter();
    var seen_ids = std.AutoHashMap(i32, void).init(arena.allocator());
    while (map_it.next()) |map_entry| {
        try seen_ids.put(map_entry.key.*, {});
        const val = ref.get(map_entry.key.*);
        try std.testing.expectEqual(val, map_entry.val.*);
    }

    try std.testing.expectEqual(ref.count(), seen_ids.count());
}

test "HashMap page expansion" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const expansion_alloc = ExpansionAlloc{
        .info = &.{
            .min_expansion_size_log2 = 4,
            .supports_free = true,
        },
        .alloc = std.testing.allocator,
    };

    var map = try AutoHashMap(i32, i32).init(
        arena.allocator(),
        expansion_alloc,
        5,
        1000,
    );

    for (0..50) |i| {
        try map.put(@intCast(i), @intCast(i));
    }

    for (0..50) |i| {
        _ = map.remove(@intCast(i));
    }
}
