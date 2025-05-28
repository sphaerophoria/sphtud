const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const buddy_impl = @import("buddy_impl.zig");

pub const MemoryTracker = @import("MemoryTracker.zig");

const Block = []u8;

/// A simple bump allocator
///
/// We have to track almost nothing. Note that this is designed to be used with
/// the tracking block allocator below. Resets are tracked at the page level.
/// All we have to do is get aligned allocations in the current block. If they
/// don't fit, we get a new block. Easy
///
/// Expected to be used with the tiny page allocator, warms up to approach real
/// page size allocations, but starts small
const BumpAlloc = struct {
    block_alloc: Allocator,
    alloc_size_log2: u8,
    current_block: []u8 = &.{},
    cursor: usize = 0,

    const allocator_vtable = std.mem.Allocator.VTable{
        .alloc = BumpAlloc.alloc,
        .resize = nullResize,
        .free = nullFree,
        .remap = nullRemap,
    };

    fn allocator(self: *BumpAlloc) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BumpAlloc = @ptrCast(@alignCast(ctx));

        {
            const alloc_start = alignment.forward(self.cursor);
            const alloc_end = alloc_start + len;

            if (alloc_end <= self.current_block.len) {
                self.cursor = alloc_end;
                return self.current_block[alloc_start..alloc_end].ptr;
            }
        }

        const block_len = std.mem.alignForward(usize, len, self.pageSize());
        const new_block = self.block_alloc.rawAlloc(block_len, alignment, ret_addr) orelse return null;
        self.alloc_size_log2 = @min(
            comptime std.math.log2_int(usize, std.heap.pageSize()),
            @max(self.alloc_size_log2 + 1, std.math.log2_int_ceil(usize, block_len)),
        );
        self.current_block = new_block[0..block_len];
        self.cursor = len;
        return self.current_block.ptr;
    }

    fn pageSize(self: *BumpAlloc) usize {
        return @as(usize, 1) << @intCast(self.alloc_size_log2);
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {}
};

fn nullRemap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn nullResize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    return false;
}

fn nullFree(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {}

const BlockAllocator = struct {
    allocated_blocks: std.ArrayListUnmanaged(Block),
    page_alloc: Allocator,

    const allocator_vtable: Allocator.VTable = .{
        .alloc = BlockAllocator.alloc,
        .resize = nullResize,
        .free = BlockAllocator.free,
        .remap = nullRemap,
    };

    fn init(page_alloc: Allocator) !BlockAllocator {
        return .{
            .page_alloc = page_alloc,
            .allocated_blocks = try std.ArrayListUnmanaged(Block).initCapacity(page_alloc, @sizeOf(Block) / tiny_page_size),
        };
    }

    fn deinit(self: *BlockAllocator) void {
        for (self.allocated_blocks.items) |block| {
            self.page_alloc.free(block);
        }

        self.allocated_blocks.deinit(self.page_alloc);
    }

    pub fn allocator(self: *BlockAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    fn allocated(self: *BlockAllocator) usize {
        var ret: usize = 0;
        for (self.allocated_blocks.items) |block| {
            ret += block.len;
        }

        return ret;
    }

    fn fullBlockLen(len: usize) usize {
        // This feels like it should somehow leverage existing code in the tiny
        // page allocator, however it turns out that this logic does not
        // actually exist in the allocation at all. Some of it lives in the
        // real page allocator, some lives in the buddy allocator impl for the
        // small pages.
        //
        // So we just do it here. Not ideal, but good enough for now
        if (len < std.heap.pageSize()) {
            const full_block_len_log2 = std.math.log2_int_ceil(usize, len);
            return @as(usize, 1) << @intCast(full_block_len_log2);
        } else {
            return std.mem.alignForward(usize, len, std.heap.pageSize());
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BlockAllocator = @ptrCast(@alignCast(ctx));

        const full_block_len = fullBlockLen(len);

        const ret = self.page_alloc.rawAlloc(full_block_len, alignment, ret_addr) orelse {
            return null;
        };

        std.debug.assert(alignment.compare(.lte, .fromByteUnits(std.heap.pageSize())));

        self.allocated_blocks.append(self.page_alloc, @alignCast(ret[0..full_block_len])) catch unreachable;
        return ret;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *BlockAllocator = @ptrCast(@alignCast(ctx));

        if (self.findBlock(buf)) |idx| {
            _ = self.allocated_blocks.swapRemove(idx);
            std.debug.assert(self.findBlock(buf) == null);
            self.page_alloc.rawFree(buf, alignment, ret_addr);
        } else {
            unreachable;
        }
    }

    fn findBlock(self: *BlockAllocator, buf: []u8) ?usize {
        for (self.allocated_blocks.items, 0..) |elem, i| {
            if (buf.ptr == elem.ptr) {
                if (elem.len > fullBlockLen(buf.len)) {
                    unreachable;
                }
                return i;
            }
        }

        return null;
    }
};

pub const ScratchAlloc = struct {
    backing: std.heap.FixedBufferAllocator,

    pub fn init(buf: []u8) ScratchAlloc {
        return .{
            .backing = std.heap.FixedBufferAllocator.init(buf),
        };
    }

    pub fn allocator(self: *ScratchAlloc) Allocator {
        return self.backing.allocator();
    }

    pub fn reset(self: *ScratchAlloc) void {
        @memset(self.backing.buffer, undefined);
        self.backing.reset();
    }

    pub fn allocMax(self: *ScratchAlloc, comptime T: type) []T {
        return self.allocGreedy(T, std.math.maxInt(usize));
    }

    pub fn allocGreedy(self: *ScratchAlloc, comptime T: type, max: usize) []T {
        const start_addr: usize = @intFromPtr(self.backing.buffer.ptr);
        const current_head = start_addr + self.backing.end_index;
        const alloc_start = std.mem.alignForward(usize, current_head, @alignOf(T));
        const capacity = (self.backing.buffer.len -| (alloc_start - start_addr)) / @sizeOf(T);
        const size = @min(capacity, max);
        return self.backing.allocator().alloc(T, size) catch unreachable;
    }

    pub fn shrinkTo(self: *ScratchAlloc, ptr: ?*anyopaque) void {
        const base: usize = @intFromPtr(self.backing.buffer.ptr);
        const ptr_u: usize = @intFromPtr(ptr);
        self.backing.end_index = ptr_u - base;
    }

    pub const Checkpoint = usize;

    pub fn checkpoint(self: *ScratchAlloc) Checkpoint {
        return self.backing.end_index;
    }

    pub fn restore(self: *ScratchAlloc, restore_point: Checkpoint) void {
        @memset(self.backing.buffer[restore_point..self.backing.end_index], undefined);
        self.backing.end_index = restore_point;
    }

    pub fn restoreCheckpointAndPreserve(self: *ScratchAlloc, comptime T: type, alloc: Allocator, content: []const T, restore_point_base: Checkpoint) ![]T {
        var restore_point = restore_point_base;
        // NOTE: restore_point is VARIABLE. The initial value is as far back as
        // we want to go, but if we have content to restore, it will likely be
        // further down
        defer self.restore(restore_point);

        const my_alloc = self.backing.allocator();
        const is_same = my_alloc.vtable == alloc.vtable and my_alloc.ptr == alloc.ptr;
        if (!is_same) {
            return try alloc.dupe(T, content);
        }

        std.debug.assert(self.isPartOfUs(@ptrCast(content)));

        const base_ptr: usize = @intFromPtr(self.backing.buffer.ptr);
        const unaligned_alloc_start: usize = base_ptr + restore_point_base;
        const aligned_alloc_start = std.mem.alignForward(usize, unaligned_alloc_start, @alignOf(T));
        const alloc_end = aligned_alloc_start + @sizeOf(T) * content.len;

        restore_point = alloc_end - base_ptr;

        const out_buf: [*]T = @ptrFromInt(aligned_alloc_start);
        const ret = out_buf[0..content.len];

        std.mem.copyForwards(T, ret, content);
        return ret;
    }

    fn isPartOfUs(self: *ScratchAlloc, content: [*]const u8) bool {
        const buf_start_usize: usize = @intFromPtr(self.backing.buffer.ptr);
        const content_usize: usize = @intFromPtr(content);
        return content_usize >= buf_start_usize and content_usize < buf_start_usize + self.backing.buffer.len;
    }

    test "restoreCheckpointAndPreserve same allocator" {
        var buf: [4096]u8 = undefined;
        var scratch = ScratchAlloc.init(&buf);

        // Initial state, intentionally unaligned
        _ = try scratch.allocator().alloc(u8, 1009);

        const content = blk: {
            const restore_point = scratch.checkpoint();
            // Pretend we did some work
            _ = try scratch.allocator().alloc(i32, 10);
            _ = try scratch.allocator().alloc(u8, 5);
            const to_keep = try scratch.allocator().alloc(i32, 4);
            for (0..4) |i| {
                to_keep[i] = @intCast(i);
            }
            break :blk try scratch.restoreCheckpointAndPreserve(i32, scratch.allocator(), to_keep, restore_point);
        };

        const new_content = try scratch.allocator().alloc(u8, 10);
        @memset(new_content, 0xff);

        try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3 }, content);
        const new_content_ptr: usize = @intFromPtr(new_content.ptr);
        try std.testing.expect(new_content_ptr >= @as(usize, @intFromPtr(content.ptr + content.len)));

        const allocator_base_address: usize = @intFromPtr(&buf);
        const original_content_ptr: usize = @intFromPtr(content.ptr);
        const expected_new_content_addr = allocator_base_address + std.mem.alignForward(usize, 1009, @alignOf(i32));
        try std.testing.expectEqual(expected_new_content_addr, original_content_ptr);
    }
};

pub const tiny_page_log2 = 8;
pub const tiny_page_size = 1 << tiny_page_log2;

pub fn TinyPageAllocator(comptime max_free_elems: comptime_int) type {
    return struct {
        // Some expected constraints...
        //
        // Blocks of sizes 2^small - 2^12
        // One of these for the whole program
        // Allocations will only be powers of 2
        // Frees should be relatively rare
        // Allocations may happen more often
        // We do not have a more granular allocator yet

        const page_size_log2 = std.math.log2(std.heap.pageSize());
        const num_lists = page_size_log2 - tiny_page_log2;

        page_allocator: Allocator = std.heap.page_allocator,
        free_lists: [num_lists][max_free_elems][*]u8 = undefined,
        list_lens: [num_lists]usize = [1]usize{0} ** num_lists,

        const Self = @This();

        const allocator_vtable: Allocator.VTable = .{
            .alloc = Self.alloc,
            .resize = nullResize,
            .free = Self.free,
            .remap = nullRemap,
        };

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &allocator_vtable,
            };
        }

        const BuddyAllocImplCtx = struct {
            parent: *Self,
            page_allocator: Allocator,

            pub const min_block_log2 = tiny_page_log2;
            pub const max_size_log2 = page_size_log2;

            pub fn getList(self: BuddyAllocImplCtx, list_idx: usize) [][*]u8 {
                return self.parent.free_lists[list_idx][0..self.parent.list_lens[list_idx]];
            }

            pub fn isListFull(self: BuddyAllocImplCtx, list_idx: usize) bool {
                return self.parent.list_lens[list_idx] == max_free_elems;
            }

            pub fn isListEmpty(self: BuddyAllocImplCtx, list_idx: usize) bool {
                return self.parent.list_lens[list_idx] == 0;
            }

            pub fn pushBlock(self: BuddyAllocImplCtx, ptr: [*]u8, list_idx: usize) !void {
                const free_list = &self.parent.free_lists[list_idx];
                const len = &self.parent.list_lens[list_idx];
                if (len.* == max_free_elems) return error.OutOfMemory;

                free_list[len.*] = ptr;
                len.* += 1;
            }

            pub fn popBlock(self: BuddyAllocImplCtx, list_idx: usize) ?[*]u8 {
                const free_list = &self.parent.free_lists[list_idx];
                const len = &self.parent.list_lens[list_idx];

                if (len.* == 0) return null;

                len.* -= 1;
                defer free_list[len.*] = undefined;
                return free_list[len.*];
            }

            pub fn swapRemove(self: BuddyAllocImplCtx, list_idx: usize, sub_idx: usize) [*]u8 {
                const free_list = &self.parent.free_lists[list_idx];
                const len = &self.parent.list_lens[list_idx];

                const ret = free_list[sub_idx];
                len.* -= 1;
                free_list[sub_idx] = free_list[len.*];
                return ret;
            }
        };

        fn makeBuddyAllocCtx(ctx: *anyopaque) BuddyAllocImplCtx {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .parent = self,
                .page_allocator = self.page_allocator,
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            return buddy_impl.alloc(makeBuddyAllocCtx(ctx), len, alignment, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
            return buddy_impl.free(makeBuddyAllocCtx(ctx), buf, alignment, ret_addr);
        }
    };
}

const GeneralPurposeAllocator = struct {
    const min_block_log2 = 3;
    const num_lists = tiny_page_log2 - min_block_log2;

    // It turns out that we can implement this in almost exactly the same
    // way as the TinyPageAllocator. Intuition is that many of the constraints
    // will be very similar, except we'll have lots of these kicking around
    //
    // Take the existing TinyPageAllocator, but use array lists for our
    // free lists instead of a fixed capacity on the stack.

    page_allocator: Allocator,
    // ArrayLists may initially seem like a bad idea when the backing store
    // is a page allocator, but we are careful to initialize the initial
    // capacity to be ~1 tiny page, so there isn't much wasted space
    free_lists: [num_lists]std.ArrayListUnmanaged([*]u8) = @splat(.empty),

    const Self = @This();

    const allocator_vtable: Allocator.VTable = .{
        .alloc = Self.alloc,
        .resize = nullResize,
        .free = Self.free,
        .remap = nullRemap,
    };

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    const BuddyAllocImplCtx = struct {
        parent: *Self,
        page_allocator: Allocator,

        pub const min_block_log2 = Self.min_block_log2;
        pub const max_size_log2 = tiny_page_log2;

        pub fn getList(self: BuddyAllocImplCtx, list_idx: usize) [][*]u8 {
            return self.parent.free_lists[list_idx].items;
        }

        pub fn isListFull(_: BuddyAllocImplCtx, _: usize) bool {
            return false;
        }

        pub fn isListEmpty(self: BuddyAllocImplCtx, list_idx: usize) bool {
            return self.parent.free_lists[list_idx].items.len == 0;
        }

        pub fn pushBlock(self: BuddyAllocImplCtx, ptr: [*]u8, list_idx: usize) !void {
            if (self.parent.free_lists[list_idx].capacity == 0) {
                try self.parent.free_lists[list_idx].ensureTotalCapacity(self.parent.page_allocator, (1 << tiny_page_log2) / @sizeOf([*]u8));
            }

            try self.parent.free_lists[list_idx].append(self.parent.page_allocator, ptr);
        }

        pub fn popBlock(self: BuddyAllocImplCtx, list_idx: usize) ?[*]u8 {
            const ret = self.parent.free_lists[list_idx].pop();
            if (self.parent.free_lists[list_idx].items.len == 0) {
                self.parent.free_lists[list_idx].clearAndFree(self.parent.page_allocator);
            }
            return ret;
        }

        pub fn swapRemove(self: BuddyAllocImplCtx, list_idx: usize, sub_idx: usize) [*]u8 {
            return self.parent.free_lists[list_idx].swapRemove(sub_idx);
        }
    };

    fn makeBuddyAllocCtx(ctx: *anyopaque) BuddyAllocImplCtx {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .parent = self,
            .page_allocator = self.page_allocator,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        return buddy_impl.alloc(makeBuddyAllocCtx(ctx), len, alignment, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        return buddy_impl.free(makeBuddyAllocCtx(ctx), buf, alignment, ret_addr);
    }
};

test "TinyPageAlloc alloc sanity" {
    const TestType = TinyPageAllocator(100);
    var page_alloc = TestType{ .page_allocator = std.heap.page_allocator };
    const alloc = page_alloc.allocator();
    const block5 = try alloc.alloc(u8, 256);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1, 1 }, &page_alloc.list_lens);
    const block4 = try alloc.alloc(u8, 256);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 1, 1 }, &page_alloc.list_lens);
    const block3 = try alloc.alloc(u8, 256);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 1, 1 }, &page_alloc.list_lens);

    const block2 = try alloc.alloc(u8, 1024);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 0, 1 }, &page_alloc.list_lens);

    const block = try alloc.alloc(u8, 512);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1, 0 }, &page_alloc.list_lens);

    alloc.free(block);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 0, 1 }, &page_alloc.list_lens);

    alloc.free(block2);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 1, 1 }, &page_alloc.list_lens);

    alloc.free(block4);
    alloc.free(block5);
    alloc.free(block3);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 0, 0 }, &page_alloc.list_lens);
}

pub const Sphalloc = struct {
    block_alloc: BlockAllocator,
    name: []const u8,
    // Owned by our own gpa
    children: Children = .{},
    parent: ?*Sphalloc = null,

    storage: struct {
        general: GeneralPurposeAllocator,
        arena: BumpAlloc,
    },

    const Children = std.SinglyLinkedList(Sphalloc);

    // Self reference requires that sphalloc has a stable location
    pub fn initPinned(self: *Sphalloc, page_alloc: Allocator, comptime name: []const u8) !void {
        self.* = .{
            .block_alloc = try BlockAllocator.init(page_alloc),
            .name = name,
            .storage = .{
                .arena = .{
                    .block_alloc = self.block_alloc.allocator(),
                    .alloc_size_log2 = tiny_page_log2,
                },
                .general = .{
                    .page_allocator = self.block_alloc.allocator(),
                },
            },
        };
    }

    pub fn deinit(self: *Sphalloc) void {
        self.freeAllMemory();
        self.removeFromParent();
    }

    fn removeFromParent(self: *Sphalloc) void {
        if (self.parent) |p| {
            const node = p.popChildNode(self);
            p.general().destroy(node);
        }
    }

    fn popChildNode(self: *Sphalloc, child: *Sphalloc) *Children.Node {
        var it = self.children.first;
        var last: *Children.Node = undefined;
        if (it) |node| {
            if (&node.data == child) {
                self.children.first = node.next;
                return node;
            }
            last = node;
            it = node.next;
        }

        while (it) |node| {
            if (&node.data == child) {
                last.next = node.next;
                return node;
            }
            last = node;
            it = node.next;
        }

        unreachable;
    }

    fn freeAllMemory(self: *Sphalloc) void {
        var it = self.children.first;
        while (it) |node| {
            node.data.freeAllMemory();
            it = node.next;
        }

        self.block_alloc.deinit();
    }

    pub fn reset(self: *Sphalloc) !void {
        const page_alloc = self.block_alloc.page_alloc;
        self.freeAllMemory();
        self.children = .{};
        self.block_alloc = try BlockAllocator.init(page_alloc);
        self.storage = .{
            .arena = .{
                .block_alloc = self.block_alloc.allocator(),
                .alloc_size_log2 = tiny_page_log2,
            },
            .general = .{
                .page_allocator = self.block_alloc.allocator(),
            },
        };
    }

    pub fn arena(self: *Sphalloc) Allocator {
        return self.storage.arena.allocator();
    }

    pub fn general(self: *Sphalloc) Allocator {
        return self.storage.general.allocator();
    }

    pub fn makeSubAlloc(self: *Sphalloc, comptime name: []const u8) !*Sphalloc {
        // General purpose allocator is important here. The child node needs to
        // be valid as long as we live, but we may delete the child node early
        // if it's attached to a shorter lifetime
        const node = try self.general().create(Children.Node);
        errdefer self.general().destroy(node);

        node.* = .{
            .next = self.children.first,
            .data = undefined,
        };
        try node.data.initPinned(self.block_alloc.page_alloc, name);
        node.data.parent = self;
        self.children.prepend(node);
        return &node.data;
    }

    pub fn totalMemoryAllocated(self: *Sphalloc) usize {
        var total_memory_allocated: usize = self.block_alloc.allocated();

        var it: ?*Children.Node = self.children.first;
        while (it) |val| {
            total_memory_allocated += val.data.totalMemoryAllocated();
            it = val.next;
        }
        return total_memory_allocated;
    }
};

test "Sphalloc sanity" {
    // Sanity test that
    // * Spawns a root alloc
    // * Makes a couple children
    // * Spams some allocations and de-allocations using both the arena and the
    //   general allocators
    // * Frees some children through the root, some directly
    // * Ensures all memory used is freed

    var initial_state_buf: [4096]u8 = undefined;
    const initial_state = try test_helpers.getMaps(&initial_state_buf);

    var tiny_page_alloc = TinyPageAllocator(100){
        .page_allocator = std.heap.page_allocator,
    };

    var sphalloc: Sphalloc = undefined;
    try sphalloc.initPinned(tiny_page_alloc.allocator(), "root");

    var child1 = try sphalloc.makeSubAlloc("child1");
    var child2 = try sphalloc.makeSubAlloc("child2");

    var rng = std.Random.DefaultPrng.init(0);
    const rand = rng.random();

    const child1_alloations = try child1.arena().alloc(test_helpers.Allocation, 100);
    for (child1_alloations) |*allocation| {
        allocation.* = try test_helpers.randAlloc(child1.general(), rand);
    }

    {
        const child2_alloations = try child2.arena().alloc(test_helpers.Allocation, 100);
        for (child2_alloations) |*allocation| {
            allocation.* = try test_helpers.randAlloc(child2.general(), rand);
        }
        try child2.reset();
    }

    const child2_alloations = try child2.arena().alloc(test_helpers.Allocation, 100);
    for (child2_alloations) |*allocation| {
        allocation.* = try test_helpers.randAlloc(child2.general(), rand);
    }

    try test_helpers.cycleRandAllocations(child1.general(), child1_alloations, rand);
    try test_helpers.cycleRandAllocations(child2.general(), child2_alloations, rand);

    child2.deinit();
    sphalloc.deinit();

    var end_state_buf: [4096]u8 = undefined;
    const end_state = try test_helpers.getMaps(&end_state_buf);
    try std.testing.expectEqualStrings(initial_state, end_state);
}

const test_helpers = struct {
    const AllocType = enum {
        u8,
        u16,
        u32,
        u64,

        fn toType(comptime self: AllocType) type {
            return switch (self) {
                .u8 => u8,
                .u16 => u16,
                .u32 => u32,
                .u64 => u64,
            };
        }
    };

    const Allocation = union(AllocType) {
        u8: []u8,
        u16: []u16,
        u32: []u32,
        u64: []u64,

        fn deinit(self: Allocation, alloc: std.mem.Allocator) void {
            switch (self) {
                inline else => |d| {
                    alloc.free(d);
                },
            }
        }
    };

    fn randAlloc(alloc: std.mem.Allocator, rand: std.Random) !Allocation {
        const alloc_type = rand.enumValue(AllocType);
        const alloc_size = rand.intRangeAtMost(usize, 1, 1000);
        switch (alloc_type) {
            inline else => |t| {
                const data = try alloc.alloc(t.toType(), alloc_size);
                for (0..data.len) |i| {
                    data[i] = @intCast(i % std.math.maxInt(t.toType()));
                }
                return @unionInit(Allocation, @tagName(t), data);
            },
        }
    }

    fn RollingBuffer(comptime T: type) type {
        return struct {
            items: []T,
            idx: usize = 0,

            const Self = @This();

            fn push(self: *const Self, elem: T) T {
                const ret = self.items[self.idx];
                self.items[self.idx] = elem;
                return ret;
            }
        };
    }

    fn cycleRandAllocations(alloc: Allocator, allocations_buf: []Allocation, rand: std.Random) !void {
        const allocations = RollingBuffer(Allocation){ .items = allocations_buf };
        for (0..5000) |_| {
            const evicted = allocations.push(try randAlloc(alloc, rand));
            switch (evicted) {
                inline else => |e, t| {
                    for (0..e.len) |i| {
                        if (e[i] != i % std.math.maxInt(t.toType())) unreachable;
                    }
                },
            }
            evicted.deinit(alloc);
        }
    }

    pub fn getMaps(buf: []u8) ![]const u8 {
        const f = try std.fs.openFileAbsolute("/proc/self/maps", .{});
        defer f.close();

        const size = try f.readAll(buf);
        return buf[0..size];
    }
};

fn failingAlloc(_: *anyopaque, _: usize, _: Alignment, _: usize) ?[*]u8 {
    return null;
}

const failing_vtable = std.mem.Allocator.VTable{
    .alloc = failingAlloc,
    .free = nullFree,
    .remap = nullRemap,
    .resize = nullResize,
};

pub const failing_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &failing_vtable,
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
