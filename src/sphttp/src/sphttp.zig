const std = @import("std");
const sphutil = @import("sphutil");
const sphalloc = @import("sphalloc");

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const HttpHeader = struct {
    method: std.http.Method,
    target: Range,
    version: std.http.Version,
    fields: Range,

    pub fn findContentLength(self: HttpHeader, content: []const u8) !usize {
        var field_it = self.fieldIter(content);
        while (try field_it.next()) |field| {
            // FIXME: Lowercase?
            if (std.mem.eql(u8, field.key, "Content-Length")) {
                const content_len = std.fmt.parseInt(usize, field.value, 0) catch return 0;
                return content_len;
            }
        }
        return 0;
    }


    pub fn fieldIter(self: HttpHeader, content: []const u8) FieldIter {
        return .{
            .line_it = std.mem.splitSequence(u8, content[self.fields.start..self.fields.end], "\r\n"),
        };
    }

    pub const FieldIter = struct {
        line_it: std.mem.SplitIterator(u8, .sequence),

        const Output = struct {
            key: []const u8,
            value: []const u8,
        };

        pub fn next(self: *FieldIter) !?Output {
            const line = self.line_it.next() orelse return null;

            const key_end = std.mem.indexOfScalar(u8, line, ':') orelse return error.NoKeyEnd;
            const key = std.mem.trim(u8, line[0..key_end], &std.ascii.whitespace);

            const value =
                if (key_end + 1 > line.len)
                    ""
                else
                    std.mem.trim(u8, line[key_end + 1..], &std.ascii.whitespace);

            return .{
                .key = key,
                .value = value,
            };
        }

    };
};

pub const HttpReader = struct {
    state: State = .reading_header,
    buf: sphutil.RuntimeSegmentedList(u8),
    header: ?HttpHeader = null,
    body_start: usize = 0,
    body_len: usize = 0,

    const State = enum {
        reading_header,
        header_complete,
        body_complete,
    };

    pub fn init(alloc: *sphalloc.Sphalloc) !HttpReader {
        return .{
            .buf = try .init(alloc.arena(), alloc.block_alloc.allocator(), 256, 1 * 1024 * 1024),
        };
    }

    pub fn getTarget(self: *HttpReader, alloc: std.mem.Allocator) !?[]const u8 {
        const header = self.header orelse return null;
        return try self.buf.asContiguousSlice(alloc, header.target.start, header.target.end);
    }

    pub fn getBody(self: *HttpReader) sphutil.RuntimeSegmentedList(u8).Slice {
        if (self.body_start >= self.buf.len) return self.buf.slice(0, 0);

        return self.buf.slice(self.body_start, self.buf.len);
    }

    pub fn getWritableArea(self: *HttpReader) ![]u8 {
        return self.buf.getWritableArea();
    }

    pub fn grow(self: *HttpReader, scratch: *sphalloc.ScratchAlloc, amount: usize) !void {
        std.debug.assert(amount <= (try self.buf.getWritableArea()).len);
        const old_len = self.buf.len;
        self.buf.grow(amount);

        switch (self.state) {
            .reading_header => {
                // First check boundary
                // \r\n\r\n
                // [   ]  [\n   ]
                //   ^       ^
                const needle = "\r\n\r\n";

                // FIXME: Boundary check needs to be cleaned up a little
                var overlap_buf: [needle.len * 2 - 1]u8 = undefined;
                @memset(&overlap_buf, 0);
                var it = self.buf.iterFrom(old_len);
                var i: usize = 0;
                while (it.next()) |b| {
                    if (i >= overlap_buf.len) break;
                    overlap_buf[i] = b.*;
                    i += 1;
                }

                if (std.mem.indexOf(u8, &overlap_buf, needle)) |p| {
                    // FIXME: ew
                    try self.finishHeader(scratch, old_len - needle.len + 1 + p);

                } else {
                    // New data
                    const new_data = self.buf.asContiguousSlice(sphalloc.failing_allocator, old_len, self.buf.len) catch unreachable;
                    if (std.mem.indexOf(u8, new_data, needle)) |p| {
                        try self.finishHeader(scratch, old_len + p);
                    }
                }
            },
            .header_complete => {
                if (self.buf.len >= self.body_len + self.body_start) {
                    self.state = .body_complete;
                }
            },
            .body_complete => {},
        }
    }

    fn finishHeader(self: *HttpReader, scratch: *sphalloc.ScratchAlloc, header_end: usize) anyerror!void {
        const checkpoint = scratch.checkpoint();
        defer scratch.restore(checkpoint);

        const header = try self.buf.asContiguousSlice(scratch.allocator(), 0, header_end);

        // GET /test/hello HTTP/1.1
        const line_end = std.mem.indexOf(u8, header, "\r\n") orelse unreachable;
        var it = std.mem.splitScalar(u8, header[0..line_end], ' ');
        const method = it.next() orelse return error.NoMethod;
        const target = it.next() orelse return error.NoTarget;
        const version = it.next() orelse return error.NoVersion;

        const target_start = target.ptr - header.ptr;
        self.header = HttpHeader {
            .method = @enumFromInt(std.http.Method.parse(method)),
            .target = .{
                .start = target_start,
                .end = target.len + target_start,
            },
            .version = std.meta.stringToEnum(std.http.Version, version) orelse return error.InvalidVersion,
            .fields = .{
                .start = line_end + 2,
                .end = header_end,
            },
        };


        self.body_start = header_end + 4;
        self.body_len = try self.header.?.findContentLength(header);
        self.state = .header_complete;

        // Trigger initial body check
        try self.grow(scratch, 0);
    }
};

pub fn HttpWriter(comptime Writer: type) type {
    return  struct {
        writer: Writer,

        const Self = @This();

        pub fn start(self: *Self, status: std.http.Status, content_len: usize) !void {
            try self.writer.print(
                "HTTP/1.1 {d} {s}\r\n" ++
                "Content-Length: {d}\r\n"
                , .{@intFromEnum(status), status.phrase() orelse "", content_len});
        }

        pub fn appendHeader(self: *Self, key: []const u8, val: []const u8) !void {
            try self.writer.print("{s}: {s}\r\n", .{key, val});
        }

        pub fn writeBody(self: *Self, content: []const u8) !void {
            try self.writer.writeAll("\r\n");
            try self.writer.writeAll(content);
        }
    };
}

pub fn httpWriter(writer: anytype) HttpWriter(@TypeOf(writer)) {
    return .{
        .writer = writer,
    };
}

