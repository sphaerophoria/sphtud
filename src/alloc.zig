const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const buddy_impl = @import("alloc/buddy_impl.zig");
const sphutil = @import("util.zig");

pub const MemoryTracker = @import("alloc/MemoryTracker.zig");

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

pub const LinearAllocator = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        checkpoint: *const fn (ctx: ?*anyopaque) usize,
        restore: *const fn (ctx: ?*anyopaque, restore_point: usize) void,
        allocator: *const fn (ctx: ?*anyopaque) std.mem.Allocator,
        makeDoubleEnded: *const fn (ctx: ?*anyopaque) anyerror!DoubleEnded,
        commitDoubleEnded: *const fn (ctx: ?*anyopaque, double_ended: DoubleEnded) void,
    };

    const DoubleEnded = struct {
        preserve: LinearAllocator,
        discard: LinearAllocator,
    };

    pub fn checkpoint(self: LinearAllocator) usize {
        return self.vtable.checkpoint(self.ctx);
    }

    pub fn restore(self: LinearAllocator, restore_point: usize) void {
        return self.vtable.restore(self.ctx, restore_point);
    }

    pub fn allocator(self: LinearAllocator) std.mem.Allocator {
        return self.vtable.allocator(self.ctx);
    }

    pub fn expansion(self: LinearAllocator) sphutil.ExpansionAlloc {
        return .{
            .info = .linear,
            .alloc = self.allocator(),
        };
    }

    // Max out the linear allocator and convert into 2 linear allocators. One
    // from each side of the newly allocated buffer
    pub fn makeDoubleEnded(self: LinearAllocator) !DoubleEnded {
        return self.vtable.makeDoubleEnded(self.ctx);
    }

    // Merge allocations from preserve into parent allocator, dropping
    // allocations from discard
    pub fn commitDoubleEnded(self: LinearAllocator, double_ended: DoubleEnded) void {
        return self.vtable.commitDoubleEnded(self.ctx, double_ended);
    }
};

pub const BufAllocator = struct {
    buf: []u8,
    front_idx: usize,
    back_idx: usize,
    tracer: ?*Tracer,

    pub const Tracer = struct {
        const num_elems = 8;

        buf: []const u8,
        front_history: [num_elems]usize,
        back_history: [num_elems]usize,
        hist_idx: u8,

        pub fn init(buf: []const u8) Tracer {
            return .{
                .buf = buf,
                .front_history = @splat(asUsize(buf.ptr)),
                .back_history = @splat(asUsize(buf.ptr) + buf.len),
                .hist_idx = 0,
            };
        }

        pub fn reclaimUnusedMemory(self: *Tracer) !void {
            const start = self.maxStart();
            const end = self.minEnd();

            const aligned_start = std.mem.alignForward(usize, start, std.heap.pageSize());
            const aligned_end = std.mem.alignBackward(usize, end, std.heap.pageSize());

            const len = aligned_end -| aligned_start;
            if (len != 0) {
                try std.posix.madvise(@ptrFromInt(aligned_start), len, std.os.linux.MADV.DONTNEED);
            }
            self.hist_idx = (self.hist_idx + 1) % num_elems;
            self.resetCurrentVals();
        }

        fn resetCurrentVals(self: *Tracer) void {
            self.front_history[self.hist_idx] = asUsize(self.buf.ptr);
            self.back_history[self.hist_idx] = asUsize(self.buf.ptr) + self.buf.len;
        }

        fn notifyFrontAlloc(self: *Tracer, addr: [*]const u8) void {
            self.front_history[self.hist_idx] = @max(self.front_history[self.hist_idx], asUsize(addr));
        }

        fn notifyBackAlloc(self: *Tracer, addr: [*]const u8) void {
            self.back_history[self.hist_idx] = @min(self.back_history[self.hist_idx], asUsize(addr));
        }

        fn maxStart(self: *Tracer) usize {
            return std.mem.max(usize, &self.front_history);
        }

        fn minEnd(self: *Tracer) usize {
            return std.mem.min(usize, &self.back_history);
        }
    };

    pub fn init(buf: []u8) BufAllocator {
        return .{
            .buf = buf,
            .front_idx = 0,
            .back_idx = buf.len,
            .tracer = null,
        };
    }

    pub fn initWithTracing(buf: []u8, tracer: *Tracer) BufAllocator {
        return .{
            .buf = buf,
            .front_idx = 0,
            .back_idx = buf.len,
            .tracer = tracer,
        };
    }

    pub fn allocator(self: *BufAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &front_vtable,
        };
    }

    pub fn expansion(self: *BufAllocator) sphutil.ExpansionAlloc {
        return .{
            .info = .linear,
            .alloc = self.allocator(),
        };
    }

    pub fn linear(self: *BufAllocator) LinearAllocator {
        return .{
            .ctx = self,
            .vtable = &front_linear_vtable,
        };
    }

    pub fn backAllocator(self: *BufAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &back_vtable,
        };
    }

    pub fn backLinear(self: *BufAllocator) LinearAllocator {
        return .{
            .ctx = self,
            .vtable = &back_linear_vtable,
        };
    }

    pub fn reset(self: *BufAllocator) void {
        @memset(self.buf[0..self.front_idx], undefined);

        if (self.back_idx < self.buf.len) {
            @memset(self.buf[self.back_idx..], undefined);
        }

        self.front_idx = 0;
        self.back_idx = self.buf.len;
    }

    pub const Checkpoint = struct {
        front_idx: usize,
        back_idx: usize,
    };

    pub fn checkpoint(self: BufAllocator) Checkpoint {
        return .{
            .front_idx = self.front_idx,
            .back_idx = self.back_idx,
        };
    }

    pub fn restore(self: *BufAllocator, restore_point: Checkpoint) void {
        self.frontRestore(restore_point.front_idx);
        self.backRestore(restore_point.back_idx);
    }

    pub fn allocMax(self: *ScratchAlloc, comptime T: type) []T {
        return self.allocGreedy(T, std.math.maxInt(usize));
    }

    pub fn allocGreedy(self: *ScratchAlloc, comptime T: type, max: usize) []T {
        const start_addr: usize = @intFromPtr(self.buf.ptr);
        const current_head = start_addr + self.front_idx;
        const alloc_start = std.mem.alignForward(usize, current_head, @alignOf(T));
        const capacity = (self.back_idx -| (alloc_start - start_addr)) / @sizeOf(T);
        const size = @min(capacity, max);
        return self.allocator().alloc(T, size) catch unreachable;
    }

    pub fn shrinkFrontTo(self: *ScratchAlloc, ptr: ?*anyopaque) void {
        const base: usize = @intFromPtr(self.buf.ptr);
        const ptr_u: usize = @intFromPtr(ptr);
        self.frontRestore(ptr_u - base);
    }

    const front_vtable = std.mem.Allocator.VTable{
        .alloc = allocLeft,
        .resize = nullResize,
        .remap = nullRemap,
        .free = nullFree,
    };

    const back_vtable = std.mem.Allocator.VTable{
        .alloc = allocRight,
        .resize = nullResize,
        .remap = nullRemap,
        .free = nullFree,
    };

    const front_linear_vtable = LinearAllocator.VTable{
        .checkpoint = frontCheckpoint,
        .restore = frontRestoreCtx,
        .allocator = frontAllocatorCtx,
        .makeDoubleEnded = frontMakeDoubleEnded,
        .commitDoubleEnded = frontCommitDoubleEnded,
    };

    fn frontAllocatorCtx(ctx: ?*anyopaque) std.mem.Allocator {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        return self.allocator();
    }

    fn frontCheckpoint(ctx: ?*anyopaque) usize {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        return self.front_idx;
    }

    fn frontRestoreCtx(ctx: ?*anyopaque, front_idx: usize) void {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        self.frontRestore(front_idx);
    }

    fn frontRestore(self: *BufAllocator, front_idx: usize) void {
        @memset(self.buf[front_idx..self.front_idx], undefined);
        self.front_idx = front_idx;
    }

    fn frontMakeDoubleEnded(ctx: ?*anyopaque) !LinearAllocator.DoubleEnded {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));

        const child_alloc = try self.backAllocator().create(BufAllocator);

        const old_front = self.front_idx;
        const len = self.back_idx - self.front_idx;
        self.front_idx = self.back_idx;

        child_alloc.* = .{
            .buf = self.buf[old_front..][0..len],
            .front_idx = 0,
            .back_idx = len,
            .tracer = self.tracer,
        };

        return .{
            .preserve = child_alloc.linear(),
            .discard = child_alloc.backLinear(),
        };
    }

    fn frontCommitDoubleEnded(ctx: ?*anyopaque, double_ended: LinearAllocator.DoubleEnded) void {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));

        std.debug.assert(self.front_idx == self.back_idx);
        std.debug.assert(&front_linear_vtable == double_ended.preserve.vtable);
        std.debug.assert(double_ended.preserve.ctx == double_ended.discard.ctx);

        const child_alloc: *BufAllocator = @ptrCast(@alignCast(double_ended.preserve.ctx));

        const child_buf_start: usize = @intFromPtr(child_alloc.buf.ptr);
        const my_buf_start: usize = @intFromPtr(self.buf.ptr);

        std.debug.assert(my_buf_start + self.front_idx == child_buf_start + child_alloc.buf.len);

        const old_front = self.front_idx;
        self.front_idx = self.front_idx - child_alloc.buf.len + child_alloc.front_idx;
        @memset(self.buf[self.front_idx..old_front], undefined);
    }

    const back_linear_vtable = LinearAllocator.VTable{
        .checkpoint = backCheckpoint,
        .restore = backRestoreCtx,
        .allocator = backAllocatorCtx,
        .makeDoubleEnded = backMakeDoubleEnded,
        .commitDoubleEnded = backCommitDoubleEnded,
    };

    fn backAllocatorCtx(ctx: ?*anyopaque) std.mem.Allocator {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        return self.backAllocator();
    }

    fn backCheckpoint(ctx: ?*anyopaque) usize {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        return self.back_idx;
    }

    fn backRestoreCtx(ctx: ?*anyopaque, back_idx: usize) void {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        self.backRestore(back_idx);
    }

    fn backRestore(self: *BufAllocator, back_idx: usize) void {
        if (self.back_idx < self.buf.len) {
            @memset(self.buf[self.back_idx..back_idx], undefined);
        }
        self.back_idx = back_idx;
    }

    fn backMakeDoubleEnded(ctx: ?*anyopaque) !LinearAllocator.DoubleEnded {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));

        const child_alloc = try self.backAllocator().create(BufAllocator);

        const len = self.back_idx - self.front_idx;
        self.back_idx = self.front_idx;

        child_alloc.* = .{
            .buf = self.buf[self.back_idx..][0..len],
            .front_idx = 0,
            .back_idx = len,
            .tracer = self.tracer,
        };

        return .{
            .preserve = child_alloc.backLinear(),
            .discard = child_alloc.linear(),
        };
    }

    fn backCommitDoubleEnded(ctx: ?*anyopaque, double_ended: LinearAllocator.DoubleEnded) void {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));

        std.debug.assert(self.front_idx == self.back_idx);
        std.debug.assert(&back_linear_vtable == double_ended.preserve.vtable);
        std.debug.assert(double_ended.preserve.ctx == double_ended.discard.ctx);

        const child_alloc: *BufAllocator = @ptrCast(@alignCast(double_ended.preserve.ctx));

        const child_buf_start: usize = @intFromPtr(child_alloc.buf.ptr);
        const my_buf_start: usize = @intFromPtr(self.buf.ptr);

        std.debug.assert(my_buf_start + self.back_idx == child_buf_start);

        const old_back = self.back_idx;
        self.back_idx = self.back_idx + child_alloc.buf.len - child_alloc.back_idx;
        @memset(self.buf[old_back..self.back_idx], undefined);
    }

    fn allocLeft(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        const buf_ptr: usize = @intFromPtr(self.buf.ptr);
        const buf_end = buf_ptr + self.back_idx;
        const lower_bound: usize = buf_ptr + self.front_idx;

        const ret_addr = alignment.forward(lower_bound);
        const ret_end = ret_addr + len;

        if (ret_end > buf_end) {
            return null;
        }

        self.front_idx = ret_end - buf_ptr;
        if (self.tracer) |t| {
            t.notifyFrontAlloc(self.buf.ptr + self.front_idx);
        }

        return @ptrFromInt(ret_addr);
    }

    fn allocRight(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *BufAllocator = @ptrCast(@alignCast(ctx));
        const buf_ptr: usize = @intFromPtr(self.buf.ptr);

        const upper_bound: usize = buf_ptr + self.back_idx - len;

        const ret_addr = alignment.backward(upper_bound);

        if (ret_addr < buf_ptr + self.front_idx) {
            return null;
        }

        self.back_idx = ret_addr - buf_ptr;
        if (self.tracer) |t| {
            t.notifyBackAlloc(self.buf.ptr + self.back_idx);
        }
        return @ptrFromInt(ret_addr);
    }
};

pub const ScratchAlloc = BufAllocator;

fn slicePtrBaseUsize(s: anytype) usize {
    return @intFromPtr(s.ptr);
}

test "BufAllocator left allocations" {
    var buf: [100]u8 align(4) = undefined;
    const buf_start: usize = @intFromPtr(&buf);
    var buf_alloc = BufAllocator.init(&buf);

    const alloc = buf_alloc.allocator();
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 101));
    try std.testing.expectEqual(buf_start, slicePtrBaseUsize(try alloc.alloc(u8, 100)));

    buf_alloc.reset();

    try std.testing.expectEqual(buf_start, slicePtrBaseUsize(try alloc.alloc(i32, 4)));
    try std.testing.expectEqual(buf_start + 16, slicePtrBaseUsize(try alloc.alloc(i32, 4)));
}

test "BufAllocator right allocations" {
    var buf: [100]u8 align(4) = undefined;
    const buf_start: usize = @intFromPtr(&buf);
    var buf_alloc = BufAllocator.init(&buf);

    const alloc = buf_alloc.backAllocator();
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 101));
    try std.testing.expectEqual(buf_start, slicePtrBaseUsize(try alloc.alloc(u8, 100)));

    buf_alloc.reset();

    try std.testing.expectEqual(buf_start + 99, slicePtrBaseUsize(try alloc.alloc(u8, 1)));
    try std.testing.expectEqual(buf_start + 92, slicePtrBaseUsize(try alloc.alloc(i32, 1)));
}

test "BufAllocator allocator collision" {
    var buf: [100]u8 align(4) = undefined;
    const buf_start: usize = @intFromPtr(&buf);
    var buf_alloc = BufAllocator.init(&buf);

    const right_alloc = buf_alloc.backAllocator();
    const left_alloc = buf_alloc.allocator();

    // right_idx should be at 75, left at 25
    _ = try right_alloc.alloc(u8, 25);
    _ = try left_alloc.alloc(u8, 25);

    const checkpoint = buf_alloc.checkpoint();

    try std.testing.expectEqual(buf_start + 25, slicePtrBaseUsize(try right_alloc.alloc(u8, 50)));
    buf_alloc.restore(checkpoint);

    try std.testing.expectError(error.OutOfMemory, right_alloc.alloc(u8, 51));
    buf_alloc.restore(checkpoint);

    try std.testing.expectEqual(buf_start + 25, slicePtrBaseUsize(try left_alloc.alloc(u8, 50)));
    buf_alloc.restore(checkpoint);

    try std.testing.expectError(error.OutOfMemory, left_alloc.alloc(u8, 51));
}

test "BufAllocator large read" {
    var buf: [100]u8 align(4) = undefined;
    const buf_start: usize = @intFromPtr(&buf);
    var buf_alloc = BufAllocator.init(&buf);

    const right_alloc = buf_alloc.backAllocator();
    const left_alloc = buf_alloc.allocator();

    // right_idx should be at 75, left at 25
    _ = try right_alloc.alloc(u8, 25);
    _ = try left_alloc.alloc(u8, 25);

    const max_alloc = buf_alloc.allocMax(u8);
    try std.testing.expectEqual(50, max_alloc.len);
    try std.testing.expectEqual(buf_start + 25, slicePtrBaseUsize(max_alloc));
    try std.testing.expectError(error.OutOfMemory, left_alloc.alloc(u8, 1));

    buf_alloc.shrinkFrontTo(max_alloc.ptr + 25);
    try std.testing.expectError(error.OutOfMemory, left_alloc.alloc(u8, 26));
    // This should succeed
    _ = try left_alloc.alloc(u8, 25);
}

test "BufAllocator allocator collision linear allocators" {
    var buf: [100]u8 align(4) = undefined;
    const buf_start: usize = @intFromPtr(&buf);
    var buf_alloc = BufAllocator.init(&buf);

    const right_alloc = buf_alloc.backLinear();
    const left_alloc = buf_alloc.linear();

    // right_idx should be at 75, left at 25
    _ = try right_alloc.allocator().alloc(u8, 25);
    _ = try left_alloc.allocator().alloc(u8, 25);

    const right_checkpoint = right_alloc.checkpoint();
    const left_checkpoint = left_alloc.checkpoint();

    try std.testing.expectEqual(buf_start + 25, slicePtrBaseUsize(try right_alloc.allocator().alloc(u8, 50)));
    right_alloc.restore(right_checkpoint);

    try std.testing.expectError(error.OutOfMemory, right_alloc.allocator().alloc(u8, 51));
    right_alloc.restore(right_checkpoint);

    try std.testing.expectEqual(buf_start + 25, slicePtrBaseUsize(try left_alloc.allocator().alloc(u8, 50)));
    left_alloc.restore(left_checkpoint);

    try std.testing.expectError(error.OutOfMemory, left_alloc.allocator().alloc(u8, 51));
    left_alloc.restore(left_checkpoint);
}

test "BufAllocator tracing" {
    var buf: [256]u8 align(4) = undefined;
    var tracer = BufAllocator.Tracer.init(&buf);
    var buf_alloc = BufAllocator.initWithTracing(&buf, &tracer);

    _ = try buf_alloc.allocator().alloc(u8, 50);
    _ = try buf_alloc.backAllocator().alloc(u8, 30);

    for (0..5) |_| {
        buf_alloc.reset();
        try tracer.reclaimUnusedMemory();

        _ = try buf_alloc.allocator().alloc(u8, 12);
        _ = try buf_alloc.backAllocator().alloc(u8, 14);
    }

    try std.testing.expectEqual(asUsize(&buf) + 50, tracer.maxStart());
    try std.testing.expectEqual(asUsize(&buf) + 256 - 30, tracer.minEnd());

    for (0..5) |_| {
        buf_alloc.reset();
        try tracer.reclaimUnusedMemory();

        _ = try buf_alloc.allocator().alloc(u8, 12);
        _ = try buf_alloc.backAllocator().alloc(u8, 14);
    }

    try std.testing.expectEqual(12, tracer.maxStart() - asUsize(&buf));
    try std.testing.expectEqual(256 - 14, tracer.minEnd() - asUsize(&buf));
}

fn testTypicalScratchPattern(alloc: std.mem.Allocator, scratch: LinearAllocator) !struct { []const u8, []const u8 } {
    const tmp = try scratch.allocator().alloc(u8, 5);
    @memset(tmp, 1);

    const preserved = try alloc.alloc(u8, 5);
    @memset(preserved, 2);

    return .{ preserved, tmp };
}

test "BufAllocator allocator nested linear" {
    var buf: [200]u8 align(4) = undefined;
    var buf_alloc = BufAllocator.init(&buf);

    const a = try buf_alloc.allocator().alloc(u8, 5);
    @memset(a, 'a');

    const b = try buf_alloc.backAllocator().alloc(u8, 5);
    @memset(b, 'b');

    {
        const scratch = buf_alloc.backLinear();

        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const tmp = try scratch.makeDoubleEnded();
        const ret = try testTypicalScratchPattern(tmp.preserve.allocator(), tmp.discard);
        try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1 }, ret[1]);
        scratch.commitDoubleEnded(tmp);
        try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2, 2 }, ret[0]);
        try std.testing.expectEqualSlices(u8, &.{ undefined, undefined, undefined, undefined, undefined }, ret[1]);
    }

    {
        const scratch = buf_alloc.linear();

        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const tmp = try scratch.makeDoubleEnded();
        const ret = try testTypicalScratchPattern(tmp.preserve.allocator(), tmp.discard);
        try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1 }, ret[1]);
        scratch.commitDoubleEnded(tmp);
        try std.testing.expectEqualSlices(u8, &.{ undefined, undefined, undefined, undefined, undefined }, ret[1]);
        try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2, 2 }, ret[0]);
    }

    // Make sure the original pieces are all the same
    try std.testing.expectEqualSlices(u8, "aaaaa", a);
    try std.testing.expectEqualSlices(u8, "bbbbb", b);
}

pub const tiny_page_log2 = 8;
pub const tiny_page_size = 1 << tiny_page_log2;

pub const TinyPageAllocator = struct {
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

    const typical_free_elems = 20;

    const FreeList = sphutil.RuntimeSegmentedList([*]u8);

    alloc_buf: [1536]u8,
    free_lists: [num_lists]FreeList,

    const Self = @This();

    const allocator_vtable: Allocator.VTable = .{
        .alloc = Self.alloc,
        .resize = nullResize,
        .free = Self.free,
        .remap = nullRemap,
    };

    pub fn initPinned(self: *TinyPageAllocator) !void {
        var initial_alloc = BufAllocator.init(&self.alloc_buf);
        for (&self.free_lists) |*fl| {
            fl.* = try FreeList.init(
                initial_alloc.allocator(),
                .system_page,
                typical_free_elems,
                // log2(1G) == 30, which means we need on the order of 30
                // expansion slots, which is ~240 bytes per free list (it's
                // actually smaller because the starting size is already of
                // size 100, but this is a good enough approximation). This is
                // completely reasonable in the context of one TPA per app, we
                // can afford the ~1k bytes for free list tracking (measured
                // it's actually more like 600 bytes)
                //
                // In fact the size is relatively insignificant when comparing
                // to the previous pre-alloc list sizes (100). With lists of
                // 100, we need 100 * @sizeOf(ptr) * num_lists bytes, which on
                // an x86_64 machine with a page size of 4096 is 3.2k. The
                // extra 600 bytes for 10^7 times more room in the list is
                // worthwhile
                //
                // Since our min block size is 256 bytes, this provisions for
                // 256G of insanely fragmented memory. We will run into major
                // performance problems before we run out of room due to the
                // linear search that goes on in this buffer on free
                //
                // Also note that if this was insanely out of hand we'd run out
                // of room in our alloc_buf
                1 * 1024 * 1024 * 1024,
            );
        }
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &allocator_vtable,
        };
    }

    const BuddyAllocImplCtx = struct {
        parent: *Self,
        page_allocator: std.mem.Allocator,

        pub const min_block_log2 = tiny_page_log2;
        pub const max_size_log2 = page_size_log2;

        const Iter = struct {
            inner: FreeList.Iter,

            pub fn next(self: *Iter) ?[*]u8 {
                const val = self.inner.next() orelse return null;
                return val.*;
            }
        };

        pub fn getListIter(self: BuddyAllocImplCtx, list_idx: usize) Iter {
            return .{
                .inner = self.parent.free_lists[list_idx].iter(),
            };
        }

        pub fn isListFull(self: BuddyAllocImplCtx, list_idx: usize) bool {
            const free_list = &self.parent.free_lists[list_idx];
            return free_list.len == free_list.capacity;
        }

        pub fn isListEmpty(self: BuddyAllocImplCtx, list_idx: usize) bool {
            const free_list = &self.parent.free_lists[list_idx];
            return free_list.len == 0;
        }

        pub fn pushBlock(self: BuddyAllocImplCtx, ptr: [*]u8, list_idx: usize) !void {
            const free_list = &self.parent.free_lists[list_idx];
            try free_list.append(ptr);
        }

        pub fn popBlock(self: BuddyAllocImplCtx, list_idx: usize) ?[*]u8 {
            const free_list = &self.parent.free_lists[list_idx];

            if (free_list.len == 0) return null;

            const last = free_list.get(free_list.len - 1);
            free_list.shrink(free_list.len - 1);
            return last;
        }

        pub fn swapRemove(self: BuddyAllocImplCtx, list_idx: usize, sub_idx: usize) [*]u8 {
            const free_list = &self.parent.free_lists[list_idx];
            const removed = free_list.get(sub_idx);
            free_list.swapRemove(sub_idx);
            return removed;
        }
    };

    fn makeBuddyAllocCtx(ctx: *anyopaque) BuddyAllocImplCtx {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return .{
            .parent = self,
            .page_allocator = std.heap.page_allocator,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        return buddy_impl.alloc(makeBuddyAllocCtx(ctx), len, alignment, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        return buddy_impl.free(makeBuddyAllocCtx(ctx), buf, alignment, ret_addr);
    }
};

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

        const Iter = struct {
            list: [][*]u8,
            i: usize = 0,

            pub fn next(self: *Iter) ?[*]u8 {
                if (self.i >= self.list.len) return null;
                defer self.i += 1;

                return self.list[self.i];
            }
        };

        pub fn getListIter(self: BuddyAllocImplCtx, list_idx: usize) Iter {
            return .{
                .list = self.parent.free_lists[list_idx].items,
            };
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

fn compareListLens(expected: []const usize, lists: []const TinyPageAllocator.FreeList) !void {
    try std.testing.expectEqual(expected.len, lists.len);

    for (expected, lists) |expected_len, list| {
        try std.testing.expectEqual(expected_len, list.len);
    }
}
test "TinyPageAlloc alloc sanity" {
    var page_alloc: TinyPageAllocator = undefined;
    try page_alloc.initPinned();

    const alloc = page_alloc.allocator();
    const block5 = try alloc.alloc(u8, 256);
    try compareListLens(&.{ 1, 1, 1, 1 }, &page_alloc.free_lists);
    const block4 = try alloc.alloc(u8, 256);
    try compareListLens(&.{ 0, 1, 1, 1 }, &page_alloc.free_lists);
    const block3 = try alloc.alloc(u8, 256);
    try compareListLens(&.{ 1, 0, 1, 1 }, &page_alloc.free_lists);

    const block2 = try alloc.alloc(u8, 1024);
    try compareListLens(&.{ 1, 0, 0, 1 }, &page_alloc.free_lists);

    const block = try alloc.alloc(u8, 512);
    try compareListLens(&.{ 1, 1, 1, 0 }, &page_alloc.free_lists);

    alloc.free(block);
    try compareListLens(&.{ 1, 0, 0, 1 }, &page_alloc.free_lists);

    alloc.free(block2);
    try compareListLens(&.{ 1, 0, 1, 1 }, &page_alloc.free_lists);

    alloc.free(block4);
    alloc.free(block5);
    alloc.free(block3);
    try compareListLens(&.{ 0, 0, 0, 0 }, &page_alloc.free_lists);
}

pub const SphallocListNode = struct {
    node: std.SinglyLinkedList.Node,
    data: Sphalloc,
};

pub const SphallocChildIter = struct {
    node: ?*std.SinglyLinkedList.Node,

    pub fn next(self: *SphallocChildIter) ?*Sphalloc {
        const node = self.node orelse return null;
        defer self.node = node.next;
        return self.current();
    }

    fn current(self: SphallocChildIter) ?*Sphalloc {
        const node = self.node orelse return null;
        const sphalloc_node: *SphallocListNode = @fieldParentPtr("node", node);
        return &sphalloc_node.data;
    }
};

pub const Sphalloc = struct {
    block_alloc: BlockAllocator,
    name: []const u8,

    // Owned by our own gpa
    children: std.SinglyLinkedList = .{},
    parent: ?*Sphalloc = null,

    storage: struct {
        general: GeneralPurposeAllocator,
        arena: BumpAlloc,
    },

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

    pub fn childIter(self: *Sphalloc) SphallocChildIter {
        return .{
            .node = self.children.first,
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

    fn popChildNode(self: *Sphalloc, child: *Sphalloc) *SphallocListNode {
        var it = self.children.first;
        var last: *std.SinglyLinkedList.Node = undefined;

        if (it) |node| {
            const sphalloc_node: *SphallocListNode = @fieldParentPtr("node", node);
            if (&sphalloc_node.data == child) {
                self.children.first = node.next;
                return sphalloc_node;
            }
            last = node;
            it = node.next;
        }

        while (it) |node| {
            const sphalloc_node: *SphallocListNode = @fieldParentPtr("node", node);
            if (&sphalloc_node.data == child) {
                last.next = node.next;
                return sphalloc_node;
            }
            last = node;
            it = node.next;
        }

        unreachable;
    }

    fn freeAllMemory(self: *Sphalloc) void {
        var it = self.children.first;
        while (it) |node| {
            const sphalloc_node: *SphallocListNode = @fieldParentPtr("node", node);
            sphalloc_node.data.freeAllMemory();
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

    pub fn expansion(self: *Sphalloc) sphutil.ExpansionAlloc {
        return .{
            .info = &.{
                .min_expansion_size_log2 = tiny_page_log2,
                .supports_free = true,
            },
            .alloc = self.block_alloc.allocator(),
        };
    }

    pub fn makeSubAlloc(self: *Sphalloc, comptime name: []const u8) !*Sphalloc {
        // General purpose allocator is important here. The child node needs to
        // be valid as long as we live, but we may delete the child node early
        // if it's attached to a shorter lifetime
        const node = try self.general().create(SphallocListNode);
        errdefer self.general().destroy(node);

        node.* = .{
            .node = .{},
            .data = undefined,
        };
        try node.data.initPinned(self.block_alloc.page_alloc, name);
        node.data.parent = self;
        self.children.prepend(&node.node);
        return &node.data;
    }

    pub fn totalMemoryAllocated(self: *Sphalloc) usize {
        var total_memory_allocated: usize = self.block_alloc.allocated();

        var it: ?*std.SinglyLinkedList.Node = self.children.first;
        while (it) |node| {
            const sphalloc_node: *SphallocListNode = @fieldParentPtr("node", node);
            total_memory_allocated += sphalloc_node.data.totalMemoryAllocated();
            it = node.next;
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

    const io = std.testing.io;

    var initial_state_buf: [4096]u8 = undefined;
    const initial_state = try test_helpers.getMaps(io, &initial_state_buf);

    var tiny_page_alloc: TinyPageAllocator = undefined;
    try tiny_page_alloc.initPinned();

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
    const end_state = try test_helpers.getMaps(io, &end_state_buf);
    try std.testing.expectEqualStrings(initial_state, end_state);
}

test "Sphalloc singleChildRemoval" {
    const io = std.testing.io;

    var initial_state_buf: [4096]u8 = undefined;
    const initial_state = try test_helpers.getMaps(io, &initial_state_buf);

    var tiny_page_alloc: TinyPageAllocator = undefined;
    try tiny_page_alloc.initPinned();

    var sphalloc: Sphalloc = undefined;
    try sphalloc.initPinned(tiny_page_alloc.allocator(), "root");

    const child1 = try sphalloc.makeSubAlloc("child1");
    _ = try child1.arena().alloc(u8, 100);
    child1.deinit();

    sphalloc.deinit();

    var end_state_buf: [4096]u8 = undefined;
    const end_state = try test_helpers.getMaps(io, &end_state_buf);
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

    pub fn getMaps(io: std.Io, buf: []u8) ![]const u8 {
        const f = try std.Io.Dir.openFileAbsolute(io, "/proc/self/maps", .{});
        defer f.close(io);

        var reader = f.reader(io, &.{});
        const size = try reader.interface.readSliceShort(buf);
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

fn asUsize(p: [*]const u8) usize {
    return @intFromPtr(p);
}
test {
    std.testing.refAllDecls(@This());
}
