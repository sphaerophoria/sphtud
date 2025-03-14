const std = @import("std");
const Alignment = std.mem.Alignment;

pub fn alloc(ctx: anytype, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const Ctx = @TypeOf(ctx);
    // Given len, which free list do we want
    const log2_len = std.math.log2_int_ceil(usize, len);
    std.debug.assert(alignment.compare(.lte, @enumFromInt(log2_len)));

    if (log2_len >= Ctx.max_size_log2) {
        return ctx.page_allocator.rawAlloc(len, alignment, ret_addr) orelse {
            return null;
        };
    }

    const list_idx = log2_len -| Ctx.min_block_log2;
    if (ctx.popBlock(list_idx)) |block| {
        return block;
    }

    return splitDown(ctx, list_idx, ret_addr) catch {
        return null;
    };
}

pub fn free(ctx: anytype, buf: []u8, alignment: Alignment, ret_addr: usize) void {
    const Ctx = @TypeOf(ctx);
    if (buf.len >= maxSize(Ctx)) {
        ctx.page_allocator.rawFree(buf, alignment, ret_addr);
        return;
    }

    var idx = std.math.log2_int_ceil(usize, buf.len) -| Ctx.min_block_log2;
    var ptr = buf.ptr;
    while (hasSibling(ctx, buf.ptr, idx)) |sibling_idx| {
        const other = ctx.swapRemove(idx, sibling_idx);
        ptr = @ptrFromInt(@min(
            @as(usize, @intFromPtr(ptr)),
            @as(usize, @intFromPtr(other)),
        ));
        idx += 1;
    }

    if (idx >= numLists(Ctx)) {
        ctx.page_allocator.rawFree(ptr[0..maxSize(Ctx)], @enumFromInt(Ctx.max_size_log2), ret_addr);
    } else {
        // Can't recover :(
        ctx.pushBlock(ptr, idx) catch unreachable;
    }
}

fn maxSize(comptime Ctx: type) usize {
    return 1 << Ctx.max_size_log2;
}

fn numLists(comptime Ctx: type) usize {
    return Ctx.max_size_log2 - Ctx.min_block_log2;
}

fn splitDown(ctx: anytype, output_list: usize, ret_addr: usize) ![*]u8 {
    const Ctx = @TypeOf(ctx);
    var idx = output_list + 1;
    while (idx < numLists(Ctx) and ctx.isListEmpty(idx)) {
        if (ctx.isListFull(idx)) {
            return error.OutOfMemory;
        }
        idx += 1;
    }

    const block = try splitOrAllocBlock(ctx, idx, ret_addr);
    idx -= 1;

    while (idx > output_list) {
        idx -= 1;
        // This should not happen as we checked that all lists were not
        // full on the way up
        ctx.pushBlock(block + listBlockSize(idx, Ctx.min_block_log2), idx) catch unreachable;
    }

    return block;
}

fn splitOrAllocBlock(ctx: anytype, list_idx: usize, ret_addr: usize) ![*]u8 {
    const Ctx = @TypeOf(ctx);
    if (list_idx == numLists(Ctx)) {
        const a = ctx.page_allocator.rawAlloc(maxSize(Ctx), @enumFromInt(Ctx.max_size_log2), ret_addr) orelse return error.OutOfMemory;
        const b = a + maxSize(Ctx) / 2;

        ctx.pushBlock(b, list_idx - 1) catch |e| {
            ctx.page_allocator.rawFree(a[0..maxSize(Ctx)], @enumFromInt(Ctx.max_size_log2), ret_addr);
            return e;
        };

        return a;
    } else {
        const a = ctx.popBlock(list_idx) orelse unreachable;
        const b = a + listBlockSize(list_idx - 1, Ctx.min_block_log2);

        ctx.pushBlock(b, list_idx - 1) catch |e| {
            // This should never happen as a just came from the list
            // that we are trying to put it back into
            ctx.pushBlock(a, list_idx) catch unreachable;
            return e;
        };
        return a;
    }
}

fn hasSibling(ctx: anytype, ptr: [*]u8, list_idx: usize) ?usize {
    const Ctx = @TypeOf(ctx);
    if (list_idx >= numLists(Ctx)) return null;

    // Shift right until we only have the bits that represent our
    // parent. Siblings will have the same leading bits
    const ptr_u = @intFromPtr(ptr);
    const shift_amount = list_idx + Ctx.min_block_log2 + 1;
    const cmp = ptr_u >> @intCast(shift_amount);
    const free_list = ctx.getList(list_idx);

    var ret: ?usize = null;
    for (0..free_list.len) |i| {
        const list_val = @intFromPtr(free_list[i]);
        if (list_val >> @intCast(shift_amount) == cmp) {
            ret = i;
        }

        // Double free protection
        // FIXME: This does not protect against double frees from merged lists
        if (list_val == ptr_u) {
            unreachable;
        }
    }

    return ret;
}

fn listBlockSize(list_idx: usize, min_block_log2: usize) usize {
    return @as(usize, 1) << @intCast(list_idx + min_block_log2);
}

test "block size calc" {
    try std.testing.expectEqual(256, listBlockSize(0, 8));
    try std.testing.expectEqual(512, listBlockSize(1, 8));
    try std.testing.expectEqual(1024, listBlockSize(2, 8));
}
