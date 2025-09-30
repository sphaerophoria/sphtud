const std = @import("std");
const sphutil = @import("sphutil_noalloc.zig");

pub fn AutoHashMapConfigurable(
    comptime K: type,
    comptime V: type,
    comptime expansion_alloc_info: sphutil.runtime_segmented_list.ExpansionAllocInfo,
) type {
    return HashMap(
        K,
        V,
        std.hash_map.AutoContext(K),
        expansion_alloc_info,
    );
}

pub fn AutoHashMapLinear(comptime K: type, comptime V: type) type {
    return HashMap(
        K,
        V,
        std.hash_map.AutoContext(K),
        sphutil.runtime_segmented_list.linear_alloc_info,
    );
}

pub fn HashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime expansion_alloc_info: sphutil.runtime_segmented_list.ExpansionAllocInfo,
) type {
    return struct {
        alloc: std.mem.Allocator,
        buckets: sphutil.RuntimeSegmentedListConfigurable(std.SinglyLinkedList, expansion_alloc_info),
        node_storage: NodeStorage,

        len: usize,
        ctx: Context,

        const Self = @This();

        const NodeStorage = sphutil.RuntimeSegmentedListConfigurable(ListNode, expansion_alloc_info);
        const ListNode = struct {
            node: std.SinglyLinkedList.Node,
            key: K,
            val: V,
        };

        const min_load_percent = 50;
        const max_load_percent = 80;

        pub fn init(
            arena: std.mem.Allocator,
            expansion_alloc: std.mem.Allocator,
            typical_size: usize,
            max_size: usize,
        ) !Self {
            const typical_buckets = typical_size * 100 / max_load_percent;
            const max_buckets = max_size * 100 / max_load_percent;

            var ret = Self{
                .alloc = arena,
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

        pub fn put(self: *Self, key: K, val: V) !void {
            const gop = try self.getOrPut(key);
            gop.val.* = val;
        }

        pub fn get(self: *Self, key: K) ?V {
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

        pub fn remove(self: *Self, key: K) !void {
            const to_remove = switch (self.findNode(key)) {
                .found => |n| n,
                .missing => return,
            };

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

            while (expansion_alloc_info.supports_free) {
                const new_num_buckets = self.buckets.blockStartForIdx(self.buckets.len -| 1);
                if (self.len >= new_num_buckets * min_load_percent / 100) {
                    break;
                }

                self.rehash(self.buckets.len, new_num_buckets);
                self.buckets.shrink(new_num_buckets);
            }
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

        fn findNode(self: *Self, key: K) GetNodeResult {
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

    var rng = std.Random.DefaultPrng.init(0);
    const rand = rng.random();

    var ref = std.AutoHashMap(i32, i32).init(arena.allocator());
    var map = try AutoHashMapLinear(i32, i32).init(
        arena.allocator(),
        arena.allocator(),
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
        try map.remove(key);
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

    var map = try AutoHashMapConfigurable(i32, i32, .{
        .min_expansion_size_log2 = 4,
        .supports_free = true,
    }).init(
        arena.allocator(),
        std.testing.allocator,
        5,
        1000,
    );

    for (0..50) |i| {
        try map.put(@intCast(i), @intCast(i));
    }

    for (0..50) |i| {
        try map.remove(@intCast(i));
    }
}
