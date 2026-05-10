const std = @import("std");

pub const Pipe = struct {
    writer: std.Io.Writer,
    read_head: usize = 0,

    pub fn init(buf: []u8) Pipe {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = Pipe.drain,
                    .flush = std.Io.Writer.noopFlush,
                    .rebase = Pipe.rebase,
                },
                .buffer = buf,
            },
            .read_head = 0,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        try rebase(w, 0, 0);

        if (w.buffer.len == w.end) return error.WriteFailed;

        const write_start = w.end;
        for (data[0 .. data.len - 1]) |slice| {
            const copy_len = @min(slice.len, w.buffer.len - w.end);
            if (copy_len == 0) break;

            @memcpy(w.buffer[w.end..][0..copy_len], slice[0..copy_len]);
            w.end += copy_len;
        }

        const last_segment = data[data.len - 1];
        for (0..splat) |_| {
            const copy_len = @min(last_segment.len, w.buffer.len - w.end);
            @memcpy(w.buffer[w.end..][0..copy_len], last_segment[0..copy_len]);
            w.end += copy_len;
        }

        return w.end - write_start;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) !void {
        const self: *Pipe = @fieldParentPtr("writer", w);

        const preserved_start = w.end - preserve;
        const move_start = @min(self.read_head, preserved_start);

        const len = w.end - move_start;
        if (w.buffer.len - len < capacity) return error.WriteFailed;

        @memmove(w.buffer[0..len], w.buffer[move_start..w.end]);

        self.read_head = self.read_head - move_start;
        w.end = len;
    }

    pub const PipeReader = struct {
        parent: *Pipe,
        interface: std.Io.Reader,

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) !usize {
            const self: *PipeReader = @fieldParentPtr("interface", r);

            const dest = limit.slice(try w.writableSliceGreedy(1));
            const readable_buf = self.parent.writer.buffered()[self.parent.read_head..];

            const copy_len = @min(dest.len, readable_buf.len);

            if (copy_len == 0) return error.ReadFailed;

            @memcpy(dest[0..copy_len], readable_buf[0..copy_len]);

            w.advance(copy_len);
            self.parent.read_head += copy_len;

            return copy_len;
        }
    };

    pub fn reader(self: *Pipe, buf: []u8) PipeReader {
        return .{
            .parent = self,
            .interface = .{
                .buffer = buf,
                .end = 0,
                .seek = 0,
                .vtable = &.{
                    .stream = PipeReader.stream,
                },
            },
        };
    }
};

test "piped writing" {
    var write_buf: [8]u8 = undefined;
    var pipe = Pipe.init(&write_buf);

    try pipe.writer.writeAll("hello");

    var read_buf: [8]u8 = undefined;
    var reader = pipe.reader(&read_buf);

    {
        const s = try reader.interface.take(3);
        try std.testing.expectEqualStrings("hel", s);
    }

    {
        const s = try reader.interface.take(2);
        try std.testing.expectEqualStrings("lo", s);
    }

    {
        const s = reader.interface.take(1);
        try std.testing.expectEqual(error.ReadFailed, s);
    }

    try pipe.writer.writeAll("world");

    {
        const s = try reader.interface.take(5);
        try std.testing.expectEqualStrings("world", s);
    }

    {
        const s = reader.interface.take(3);
        try std.testing.expectEqual(error.ReadFailed, s);
    }

    try std.testing.expectEqual(8, try pipe.writer.write("way too long"));

    {
        const s = try reader.interface.take(8);
        try std.testing.expectEqualStrings("way too ", s);
    }

    {
        const s = reader.interface.take(1);
        try std.testing.expectEqual(error.ReadFailed, s);
    }
}

test "pipe splat" {
    var write_buf: [8]u8 = undefined;
    var pipe = Pipe.init(&write_buf);

    try std.testing.expectEqual(5, try pipe.writer.splatByte('a', 5));

    var read_buf: [8]u8 = undefined;
    var reader = pipe.reader(&read_buf);

    {
        const s = try reader.interface.take(5);
        try std.testing.expectEqualStrings("aaaaa", s);
    }

    {
        const s = reader.interface.take(1);
        try std.testing.expectEqual(error.ReadFailed, s);
    }

    try std.testing.expectEqual(8, try pipe.writer.splatByte('b', 12));

    {
        const s = try reader.interface.take(8);
        try std.testing.expectEqualStrings("bbbbbbbb", s);
    }

    {
        const s = reader.interface.take(1);
        try std.testing.expectEqual(error.ReadFailed, s);
    }
}
