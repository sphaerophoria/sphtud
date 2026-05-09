const std = @import("std");

input: *std.Io.Reader,
interface: std.Io.Reader,
block_remaining_len: u8,
finished: bool,

const SubDataReader = @This();

pub fn init(r: *std.Io.Reader, buffer: []u8) SubDataReader {
    return .{
        .input = r,
        .interface = .{
            .seek = 0,
            .end = 0,
            .buffer = buffer,
            .vtable = &.{
                .stream = stream,
            },
        },
        .block_remaining_len = 0,
        .finished = false,
    };
}

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *SubDataReader = @fieldParentPtr("interface", r);

    if (self.finished) return error.EndOfStream;

    if (self.block_remaining_len == 0) {
        self.block_remaining_len = try self.input.takeByte();
        if (self.block_remaining_len == 0) {
            self.finished = true;
            return error.EndOfStream;
        }
    }

    const merged_limit = limit.min(.limited(self.block_remaining_len));
    const read_bytes = try self.input.stream(w, merged_limit);
    self.block_remaining_len -= @intCast(read_bytes);

    return read_bytes;
}
