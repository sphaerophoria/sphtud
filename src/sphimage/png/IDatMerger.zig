// pngs can have image data split into multiple chunks. This is a helper that
// lets us expose this chunked data as a single byte stream to the decompressor
//
// IDAT segments are guaranteed to be sequential, so once this reader ends we
// should be at the end of the data

const std = @import("std");
const common = @import("common.zig");

const IDatMerger = @This();

input: *std.Io.Reader,
reader: std.Io.Reader,
block_remaining: usize,
hasher: std.hash.Crc32,
finished: bool = false,

// Assume first chunk header has already been read
pub fn init(input: *std.Io.Reader, first_chunk_size: usize, buffer: []u8) IDatMerger {
    var hasher = std.hash.Crc32.init();
    hasher.update("IDAT");
    return .{
        .input = input,
        .block_remaining = first_chunk_size,
        .hasher = hasher,
        .reader = .{
            .vtable = &.{
                .stream = stream,
                .discard = discard,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .finished = false,
    };
}

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *IDatMerger = @fieldParentPtr("reader", r);

    try self.ensureInBlockData();

    const dest = self.clampLimit(limit).slice(try w.writableSliceGreedy(1));
    const written = try self.streamInner(dest);
    w.advance(written);
    return written;
}

fn streamInner(self: *IDatMerger, dest: []u8) !usize {
    const written = try self.input.readSliceShort(dest);
    if (written == 0) return error.EndOfStream;
    self.hasher.update(dest[0..written]);
    self.block_remaining -= written;
    return written;
}

fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    const self: *IDatMerger = @fieldParentPtr("reader", r);

    try self.ensureInBlockData();

    var buf: [4096]u8 = undefined;
    return try self.streamInner(limit.slice(&buf));
}

fn clampLimit(self: *IDatMerger, limit: std.Io.Limit) std.Io.Limit {
    return limit.min(.limited(self.block_remaining));
}

fn ensureInBlockData(self: *IDatMerger) !void {
    if (self.finished) return error.EndOfStream;

    if (!self.blockFinished()) return;

    // Each block ends with a CRC
    common.validateCrc(self.hasher.final(), self.input) catch {
        return error.ReadFailed;
    };
    self.hasher = .init();

    const next_header = try self.peekHeader();
    if (next_header.typ != .IDAT) {
        self.finished = true;
        return error.EndOfStream;
    }

    self.hasher.update("IDAT");

    self.block_remaining = next_header.len;
    self.input.toss(common.ChunkHeader.size);
}

fn blockFinished(self: *IDatMerger) bool {
    return self.block_remaining == 0;
}

fn peekHeader(self: *IDatMerger) !common.ChunkHeader {
    const next_chunk = try self.input.peek(common.ChunkHeader.size);
    var hr = std.Io.Reader.fixed(next_chunk);
    var hasher = std.hash.Crc32.init();
    return try common.ChunkHeader.read(&hr, &hasher);
}
