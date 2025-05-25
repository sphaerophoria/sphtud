const std = @import("std");
const sphutil = @import("sphutil");
const sphalloc = @import("sphalloc");
pub const url = @import("url.zig");

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const HttpHeader = struct {
    method: std.http.Method,
    target: Range,
    version: std.http.Version,
    fields: Range,

    // NOTE: While the http reader prefers to store data dis-contiguously. In
    // reality if our HTTP header is long enough that we cannot cheaply keep it
    // contiguous, we should just reject it. No one should be sending us a 3M
    // header :)
    pub fn init(content: []const u8) !HttpHeader {
        // GET /test/hello HTTP/1.1
        const line_end = std.mem.indexOf(u8, content, "\r\n") orelse unreachable;
        var it = std.mem.splitScalar(u8, content[0..line_end], ' ');
        const method = it.next() orelse return error.NoMethod;
        const target = it.next() orelse return error.NoTarget;
        const version = it.next() orelse return error.NoVersion;

        const target_start = target.ptr - content.ptr;
        return HttpHeader{
            .method = @enumFromInt(std.http.Method.parse(method)),
            .target = .{
                .start = target_start,
                .end = target.len + target_start,
            },
            .version = std.meta.stringToEnum(std.http.Version, version) orelse return error.InvalidVersion,
            .fields = .{
                .start = line_end + 2,
                .end = content.len,
            },
        };
    }

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
                    std.mem.trim(u8, line[key_end + 1 ..], &std.ascii.whitespace);

            return .{
                .key = key,
                .value = value,
            };
        }
    };
};

test "HttpHeader sanity" {
    const header_content =
        "GET /some_url HTTP/1.1\r\n" ++
        "X-Some-Header: Hello\r\n" ++
        "Content-Length: 50\r\n" ++
        "Content-Type: text/html\r\n";

    const header = try HttpHeader.init(header_content);
    var it = header.fieldIter(header_content);

    {
        const field = try it.next() orelse return error.MissingField;
        try std.testing.expectEqualStrings("X-Some-Header", field.key);
        try std.testing.expectEqualStrings("Hello", field.value);
    }

    {
        const field = try it.next() orelse return error.MissingField;
        try std.testing.expectEqualStrings("Content-Length", field.key);
        try std.testing.expectEqualStrings("50", field.value);
    }

    {
        const field = try it.next() orelse return error.MissingField;
        try std.testing.expectEqualStrings("Content-Type", field.key);
        try std.testing.expectEqualStrings("text/html", field.value);
    }

    try std.testing.expectEqual(50, try header.findContentLength(header_content));
}

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
                const needle = "\r\n\r\n";

                const search_start = old_len -| needle.len + 1;
                var it = self.buf.iterFrom(search_start);

                var old_offs: usize = 0;
                outer: while (true) {
                    // Copy iterator state to do what is effectively a double
                    // pointer search
                    var it2 = it;
                    for (needle) |a| {
                        const b = it2.next() orelse break :outer;
                        if (a != b.*) {
                            old_offs += 1;
                            _ = it.next();
                            continue :outer;
                        }
                    }
                    try self.finishHeader(scratch, search_start + old_offs);
                    break :outer;
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

        const header_content = try self.buf.asContiguousSlice(scratch.allocator(), 0, header_end);
        self.header = try HttpHeader.init(header_content);

        self.body_start = header_end + 4;
        self.body_len = try self.header.?.findContentLength(header_content);
        self.state = .header_complete;

        // Trigger initial body check
        try self.grow(scratch, 0);
    }
};

test "HttpReader sanity" {
    const test_message_content =
        "GET /some_url HTTP/1.1\r\n" ++
        "Content-Length: 11\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: text\r\n" ++
        "X-Custom-Header: custom\r\n" ++
        "\r\n" ++
        "Hello world";

    var tpa = sphalloc.TinyPageAllocator(100){};
    var root_alloc: sphalloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");
    defer root_alloc.deinit();

    var scratch = sphalloc.ScratchAlloc.init(try root_alloc.arena().alloc(u8, 4096));

    var reader = try HttpReader.init(&root_alloc);

    @memcpy((try reader.getWritableArea())[0..10], test_message_content[0..10]);
    try reader.grow(&scratch, 10);

    @memcpy((try reader.getWritableArea())[0..10], test_message_content[10..20]);
    try reader.grow(&scratch, 10);

    try std.testing.expectEqual(.reading_header, reader.state);

    const remaining = test_message_content.len - 20;
    @memcpy((try reader.getWritableArea())[0..remaining], test_message_content[20..]);
    try reader.grow(&scratch, remaining);

    try std.testing.expectEqual(.body_complete, reader.state);
    try std.testing.expectEqual(11, reader.body_len);
    {
        const body = reader.getBody();
        var body_reader = body.reader();
        var gr = body_reader.generic();
        var buf: [4096]u8 = undefined;

        const bytes_read = gr.readAll(&buf);

        try std.testing.expectEqual(11, bytes_read);
        try std.testing.expectEqualStrings("Hello world", buf[0..11]);
    }

    // Non-thorough checks, just make sure that that the header is valid
    try std.testing.expectEqual(.GET, reader.header.?.method);
}

pub fn HttpWriter(comptime Writer: type) type {
    return struct {
        writer: Writer,

        const Self = @This();

        pub const HttpWriterParams = struct {
            status: std.http.Status,
            content_length: usize,
            content_type: ?[]const u8 = null,
        };

        pub fn start(self: *Self, params: HttpWriterParams) !void {
            try self.writer.print("HTTP/1.1 {d} {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n", .{ @intFromEnum(params.status), params.status.phrase() orelse "", params.content_length });
            if (params.content_type) |t| {
                try self.appendHeader("Content-Type", t);
            }
        }

        pub fn appendHeader(self: *Self, key: []const u8, val: []const u8) !void {
            try self.writer.print("{s}: {s}\r\n", .{ key, val });
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

test "HttpWriter sanity" {
    var content = std.ArrayList(u8).init(std.testing.allocator);
    defer content.deinit();

    var writer = httpWriter(content.writer());

    try writer.start(.{
        .status = .ok,
        .content_length = 0,
    });

    // If this gets too much churn, we might want to do something more intelligent
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 0\r\n" ++
        "Connection: close\r\n", content.items);

    content.clearRetainingCapacity();

    try writer.start(.{
        .status = .internal_server_error,
        .content_length = 11,
        .content_type = "text",
    });

    try writer.appendHeader("X-Custom-Header", "custom");
    try writer.writeBody("Hello world");

    try std.testing.expectEqualStrings("HTTP/1.1 500 Internal Server Error\r\n" ++
        "Content-Length: 11\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: text\r\n" ++
        "X-Custom-Header: custom\r\n" ++
        "\r\n" ++
        "Hello world", content.items);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
