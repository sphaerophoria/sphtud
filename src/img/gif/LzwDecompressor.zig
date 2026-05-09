const std = @import("std");

code_reader: CodeReader,

initial_code_size_bits: u8,
code_size_bits: u8,

dict: Dict,
last_code: ?Code = null,

// Dictionary can be at max 2^12 entries, the maximum sequence
// length would be each element referencing the previous element,
// so something on the order of 2^12 seems like a sane size here
buffered_seq_buf: [max_code]u8,
buffered_seq: std.ArrayList(u8),

const LzwDecompressor = @This();

const Code = u12;
const max_code = 1 << 12;

pub fn initPinned(self: *LzwDecompressor, initial_code_len: u8, r: *std.Io.Reader) !void {
    const initial_code_len_shift = std.math.cast(u6, initial_code_len) orelse return error.InvalidCodeLen;

    self.* = .{
        .code_reader = .{
            .input = r,
            .next_byte = 0,
            .bits_remaining = 0,
        },
        .initial_code_size_bits = initial_code_len,
        .code_size_bits = initial_code_len + 1,
        .buffered_seq_buf = undefined,
        .buffered_seq = .initBuffer(&self.buffered_seq_buf),
        .last_code = null,
        .dict = .{
            .item_buf = undefined,
            .inner = .initBuffer(&self.dict.item_buf),
            .offs = (@as(usize, 1) << initial_code_len_shift) + 2,
        },
    };
}

pub fn step(self: *LzwDecompressor) !?u8 {
    while (true) {
        if (self.buffered_seq.pop()) |val| {
            return val;
        }

        const next_code = try self.readCode();

        if (next_code == resetCode(self.initial_code_size_bits)) {
            self.reset();
            continue;
        }

        if (next_code == endCode(self.initial_code_size_bits)) {
            return null;
        }

        defer self.last_code = next_code;

        std.debug.assert(self.buffered_seq.items.len == 0);

        if (self.dict.containsCode(next_code)) {
            // Use existing sequence, but add prev + sequence to the dictionary

            try self.fillBuffer(next_code);

            if (self.last_code) |lc| {
                const last = self.buffered_seq.getLast();
                // Only add entry if we haven't reached the maximum 12-bit code value
                self.updateCodeSize(try self.dict.append(last, lc));
            }
        } else {
            // Use previous sequence with the first value repeated at the
            // end

            const last_code = self.last_code orelse return error.InvalidStream;

            try self.buffered_seq.appendBounded(0);
            try self.fillBuffer(last_code);

            self.buffered_seq.items[0] = self.buffered_seq.getLast();

            const new_code = try self.dict.append(self.buffered_seq.items[0], last_code);
            self.updateCodeSize(new_code);
        }
    }
}

fn resetCode(initial_code_len: u8) Code {
    return @as(u12, 1) << @intCast(initial_code_len);
}

fn endCode(initial_code_len: u8) Code {
    return resetCode(initial_code_len) + 1;
}

fn fillBuffer(self: *LzwDecompressor, start_code: Code) !void {
    var it = self.dict.parentIter(start_code);
    while (try it.next()) |val| {
        try self.buffered_seq.appendBounded(val);
    }
}

fn updateCodeSize(self: *LzwDecompressor, new_code: Code) void {
    if (self.code_size_bits >= std.math.log2(max_code)) return;

    if (new_code + 1 >= @as(Code, 1) << @intCast(self.code_size_bits)) {
        self.code_size_bits += 1;
    }
}

fn reset(self: *LzwDecompressor) void {
    self.dict.reset();
    self.last_code = null;
    self.code_size_bits = self.initial_code_size_bits + 1;
}

fn readCode(self: *LzwDecompressor) !u12 {
    return self.code_reader.readCode(self.code_size_bits);
}

const Dict = struct {
    item_buf: [max_code]DictItem,
    inner: std.ArrayList(DictItem),
    offs: usize,

    const DictItem = struct {
        parent: Code,
        item: u8,
    };

    const QueryRes = struct {
        parent: ?Code,
        item: u8,
    };

    fn query(self: *Dict, code: Code) !QueryRes {
        if (code < self.offs) {
            return .{
                .parent = null,
                .item = std.math.cast(u8, code) orelse return error.InvalidItem,
            };
        }

        const idx = code - self.offs;

        if (idx >= self.inner.items.len) return error.InvalidCode;
        const item = self.inner.items[idx];
        return .{
            .parent = item.parent,
            .item = item.item,
        };
    }

    fn containsCode(self: *Dict, item: Code) bool {
        if (item < self.offs) return true;
        return item - self.offs < self.inner.items.len;
    }

    fn append(self: *Dict, item: u8, parent: Code) !Code {
        std.debug.assert(item < self.offs);
        const idx = self.inner.items.len;
        try self.inner.appendBounded(.{
            .item = item,
            .parent = parent,
        });
        return @intCast(self.offs + idx);
    }

    const ParentIter = struct {
        current: ?Code,
        dict: *Dict,

        pub fn next(self: *ParentIter) !?u8 {
            const current = self.current orelse return null;

            const query_res = try self.dict.query(current);

            self.current = query_res.parent;
            return query_res.item;
        }
    };

    fn parentIter(self: *Dict, item: Code) ParentIter {
        return .{
            .current = item,
            .dict = self,
        };
    }

    fn reset(self: *Dict) void {
        self.inner.clearRetainingCapacity();
    }
};

const CodeReader = struct {
    input: *std.Io.Reader,
    // Buffered byte from input
    next_byte: u8,
    // How many bits are left in the buffered byte
    bits_remaining: u4,

    fn readCode(self: *CodeReader, code_size_bits: u8) !u12 {
        var code_remaining_bits: u8 = code_size_bits;

        var out: u12 = 0;
        var out_shift: u4 = 0;

        while (code_remaining_bits > 0) {
            if (self.bits_remaining == 0) {
                self.next_byte = try self.input.takeByte();
                self.bits_remaining = 8;
            }

            const bits_pulled = @min(code_remaining_bits, self.bits_remaining);

            self.bits_remaining -= bits_pulled;
            code_remaining_bits -= bits_pulled;

            const mask: u8 = @intCast((@as(u16, 1) << bits_pulled) - 1);
            out |= @as(Code, (self.next_byte & mask)) << @intCast(out_shift);
            out_shift += bits_pulled;

            if (bits_pulled < 8) {
                self.next_byte >>= @intCast(bits_pulled);
            }
        }

        return out;
    }
};

test "CodeReader readCode" {
    const input = &.{ 0b11110000, 0b00001111 };

    var r = std.Io.Reader.fixed(input);
    var cr = LzwDecompressor.CodeReader{
        .input = &r,
        .bits_remaining = 0,
        .next_byte = 0,
    };

    try std.testing.expectEqual(0b10000, try cr.readCode(5));
    try std.testing.expectEqual(0b11111, try cr.readCode(5));
    try std.testing.expectEqual(0b11, try cr.readCode(5));
}

test "4 byte lzw decomrpession" {
    const input = &.{ 0x5c, 0x04, 0x05 };
    var r = std.Io.Reader.fixed(input);
    var lzwd: LzwDecompressor = undefined;
    try lzwd.initPinned(2, &r);

    const expected: []const u12 = &.{ 3, 1, 2, 0 };
    var i: usize = 0;
    while (try lzwd.step()) |elem| {
        try std.testing.expectEqual(expected[i], elem);
        i += 1;
    }
}

test "36 byte lzw decomrpession" {
    const input = &.{ 0x44, 0x6c, 0xa7, 0x80, 0xba, 0xd7, 0x52, 0x2c };
    var r = std.Io.Reader.fixed(input);
    var lzwd: LzwDecompressor = undefined;
    try lzwd.initPinned(2, &r);

    const expected: []const u12 = &.{
        0, 1, 0, 1, 0, 1,
        1, 0, 1, 0, 1, 0,
        0, 1, 0, 1, 0, 1,
        1, 0, 1, 0, 1, 0,
        0, 1, 0, 1, 0, 1,
        1, 0, 1, 0, 1, 0,
    };

    var i: usize = 0;
    while (try lzwd.step()) |elem| {
        try std.testing.expectEqual(expected[i], elem);
        i += 1;
    }
}
