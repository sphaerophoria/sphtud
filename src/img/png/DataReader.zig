// Read the actual image data from the idat segments of the png. Everything
// from the bits in the IDAT segments to pixel data that went into the png
//
// IO pipeline:
// source reader -> idat merger -> decompressor -> filter application -> output

const std = @import("std");
const common = @import("common.zig");
const IDatMerger = @import("IDatMerger.zig");

const PngDataReader = @This();

// Merger buf needs to be big enough for the decompressor to pull header
// data. Everything else should bypass the buffer directly and stream
// directly into the decompressor buf
merger_buf: [10]u8,
merger: IDatMerger,
decompressor_buf: [std.compress.flate.max_window_len]u8,
decompressor: std.compress.flate.Decompress,

reader: std.Io.Reader,

// byte size of scanline without filter type
scanline_size: u32,
pixel_size: u32,
row: u32,

err: ?anyerror,

pub fn initPinned(self: *PngDataReader, header: common.Header, first_chunk_size: usize, r: *std.Io.Reader, buf: []u8) !void {
    self.merger = IDatMerger.init(r, first_chunk_size, &self.merger_buf);
    self.decompressor = std.compress.flate.Decompress.init(&self.merger.reader, .zlib, &self.decompressor_buf);
    self.reader = .{
        .buffer = buf,
        .seek = 0,
        .end = 0,
        .vtable = &.{
            .stream = stream,
            .rebase = rebase,
            // Would be nice  to have a special case to discard all to avoid
            // reading image if caller doesn't want to :)
        },
    };
    self.pixel_size = header.bit_depth / 8 * try header.color_type.components();
    self.scanline_size = self.pixel_size * header.width;
    self.err = null;
    self.row = 0;
}

pub fn finish(self: *PngDataReader) !void {
    // Ensure that all IDAT sections have been consumed including the final CRC
    _ = try self.merger.reader.discardRemaining();
}

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *PngDataReader = @fieldParentPtr("reader", r);

    // Writer is completely unused. We have to buffer our data in our own
    // buffer for future reference anyways, so we just do our work there,
    // and then let the caller pull data out of our buffer as needed
    _ = w;
    _ = limit;

    try self.reader.rebase(self.scanline_size);

    const current_filter_type = std.enums.fromInt(FilterType, try self.decompressor.reader.takeByte()) orelse {
        self.err = error.InvalidFilterType;
        return error.ReadFailed;
    };

    const dest = r.buffer[r.end..][0..self.scanline_size];
    try self.decompressor.reader.readSliceAll(dest);
    r.end += self.scanline_size;

    sw: switch (current_filter_type) {
        .none => {},
        .sub => {
            // first pixel has nothing to reference, so we just leave it in
            // the buffer unmodified
            for (dest[self.pixel_size..]) |*b| {
                b.* = b.* +% leftPx(b, self.pixel_size, r.buffer);
            }
        },
        .up => {
            // If your encoder does this, just use none idiot
            if (self.row == 1) continue :sw .none;

            for (dest) |*b| {
                b.* = b.* +% self.upPx(b, r.buffer);
            }
        },
        .paeth => {
            // Top row special case not yet handled
            if (self.row == 1) {
                self.err = error.Unimplemented;
                return error.ReadFailed;
            }

            for (dest[0..self.pixel_size]) |*b| {
                b.* = b.* +% paethPredictor(0, self.upPx(b, r.buffer), 0);
            }

            for (dest[self.pixel_size..]) |*b| {
                b.* = b.* +% paethPredictor(
                    leftPx(b, self.pixel_size, r.buffer),
                    self.upPx(b, r.buffer),
                    self.upLeftPx(b, r.buffer),
                );
            }
        },
        else => {
            std.log.warn("Unimplemented filter: {t}", .{current_filter_type});
            continue :sw .none;
        },
    }

    return 0;
}

fn rebase(r: *std.Io.Reader, capacity: usize) !void {
    const self: *PngDataReader = @fieldParentPtr("reader", r);
    return self.rebaseInner(capacity);
}

fn rebaseInner(self: *PngDataReader, capacity: usize) void {
    // Basically copy pasted from the decompressor rebase fn in zig 0.15.2

    const history_len = self.scanline_size;
    std.debug.assert(capacity <= self.reader.buffer.len - history_len);
    std.debug.assert(self.reader.end + capacity > self.reader.buffer.len);

    const discard_n = @min(self.reader.seek, self.reader.end - history_len);
    const keep = self.reader.buffer[discard_n..self.reader.end];

    @memmove(self.reader.buffer[0..keep.len], keep);
    self.reader.end = keep.len;
    self.reader.seek -= discard_n;
}

fn offs(b: *u8, amount: usize, valid_data: []u8) u8 {
    const b_a: [*]u8 = @ptrCast(b);
    const other_ptr: [*]u8 = b_a - amount;

    std.debug.assert(@as(usize, @intFromPtr(other_ptr)) >= @as(usize, @intFromPtr(valid_data.ptr)));

    return other_ptr[0];
}

fn leftPx(b: *u8, px_width: usize, valid_data: []u8) u8 {
    return offs(b, px_width, valid_data);
}

fn upPx(self: *const PngDataReader, b: *u8, valid_data: []u8) u8 {
    std.debug.assert(self.row != 1);
    return offs(b, self.scanline_size, valid_data);
}

fn upLeftPx(self: *const PngDataReader, b: *u8, valid_data: []u8) u8 {
    std.debug.assert(self.row != 1);

    return offs(b, self.scanline_size + self.pixel_size, valid_data);
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    // a = left, b = above, c = upper left

    const ai: i16 = a;
    const bi: i16 = b;
    const ci: i16 = c;

    const p = ai + bi - ci; // initial estimate
    const pa = @abs(p - ai); // distances to a, b, c
    const pb = @abs(p - bi);
    const pc = @abs(p - ci);

    // return nearest of a,b,c,
    // breaking ties in order a,b,c.
    if (pa <= pb and pa <= pc) return a else if (pb <= pc) return b else return c;
}

const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};
