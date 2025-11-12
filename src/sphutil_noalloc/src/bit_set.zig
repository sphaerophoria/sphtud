const std = @import("std");
const sphutil = @import("sphutil_noalloc.zig");
const rsl = @import("runtime_segmented_list.zig");

pub const BitSet = struct {
    storage: Storage,

    const Storage = rsl.RuntimeSegmentedListUnmanaged(u8);
    const Self = @This();

    pub fn init(prealloc: std.mem.Allocator, expansion_alloc: sphutil.ExpansionAlloc, prealloc_size: usize, max_size: usize) !Self {
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

    pub fn appendByte(self: *Self, expansion_alloc: sphutil.ExpansionAlloc, b: u8) !void {
        try self.storage.append(expansion_alloc, b);
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

    pub fn shrink(self: *Self, expansion_alloc: sphutil.ExpansionAlloc, bit_size: usize) void {
        self.storage.shrink(expansion_alloc, std.mem.alignForward(usize, bit_size, 8) / 8);
    }

    // Rounds up to next 8
    pub fn grow(self: *Self, expansion_alloc: sphutil.ExpansionAlloc, bit_size: usize, fill: bool) !void {
        const byte_fill: u8 = if (fill) 0xff else 0;
        const byte_size = byteFromBitSize(bit_size);
        while (self.storage.len < byte_size) {
            try self.storage.append(expansion_alloc, byte_fill);
        }
    }

    fn byteFromBitSize(bit_size: usize) usize {
        return std.mem.alignForward(usize, bit_size, 8) / 8;
    }

    pub fn iterFrom(self: Self, bit_idx: usize) Iter {
        var storage_iter = self.storage.iterFrom(bit_idx / 8);
        const first_byte = storage_iter.next();
        const first_bit: u8 = if (first_byte != null) @truncate(bit_idx % 8) else 8;

        return .{
            .storage_iter = storage_iter,
            .current_byte = if (first_byte) |b| b.* else 0,
            .bit_idx = first_bit,
        };
    }
};

test "bitset sanity" {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var linear_alloc = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const expansion_alloc = sphutil.ExpansionAlloc.linear(linear_alloc.allocator());
    var bitset = try BitSet.init(
        linear_alloc.allocator(),
        expansion_alloc,
        16,
        128,
    );

    try bitset.grow(expansion_alloc, 3, true);
    try std.testing.expectEqual(8, bitset.bitLen());
    for (0..8) |i| {
        try std.testing.expect(bitset.get(i));
    }

    bitset.set(0, false);
    try std.testing.expect(!bitset.get(0));
    for (1..8) |i| {
        try std.testing.expect(bitset.get(i));
    }

    try bitset.grow(expansion_alloc, 16, false);

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
