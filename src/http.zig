const std = @import("std");
pub const url = @import("http/url.zig");

pub const HttpResponseReader = HttpReaderGeneric(HttpResponseHeader);
pub const HttpRequestReader = HttpReaderGeneric(HttpRequestHeader);

// Simple HTTP get -> body on 200
pub const Simple = struct {
    alloc: std.mem.Allocator,
    body: std.ArrayList(u8),
    http_reader: HttpResponseReader,
    state: union(enum) {
        head,
        body: *std.Io.Reader,
        finished,
    },

    pub const Params = struct {
        // Sometimes we get banned if we don't have a valid useragent
        user_agent: []const u8 = "curl/8.20.0",
    };

    // writer/uri are temporary, but the reader and alloc are stored
    pub fn init(alloc: std.mem.Allocator, r: *std.Io.Reader, w: *std.Io.Writer, uri: std.Uri, params: Params) !Simple {
        var http_writer = HttpWriter.init(w);
        var target_buf: [1024]u8 = undefined;
        var tb_writer = std.Io.Writer.fixed(&target_buf);

        try uri.writeToStream(&tb_writer, .{
            .path = true,
            .query = true,
        });
        try http_writer.startRequest(.{ .method = .GET, .target = tb_writer.buffered(), .content_length = null, .content_type = null });

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        try http_writer.appendHeader("Host", host.bytes);
        try http_writer.appendHeader("Accept", "*/*");
        try http_writer.appendHeader("User-Agent", params.user_agent);
        try http_writer.appendHeader("Connection", "close");
        try http_writer.writeBody("");
        try w.flush();

        return .{
            .alloc = alloc,
            .body = .empty,
            .http_reader = .init(r),
            .state = .head,
        };
    }

    pub fn poll(self: *Simple) ![]const u8 {
        sw: switch (self.state) {
            .head => {
                // Can use empty body buf as we are planning on streaming
                // directly into the writer's buffer
                const res = try self.http_reader.poll(self.alloc, &.{});

                if (res.header.status != .ok) {
                    return error.HttpFail;
                }

                self.state = .{
                    .body = res.body_reader,
                };

                continue :sw self.state;
            },
            .body => |body_r| {
                try body_r.appendRemaining(self.alloc, &self.body, .unlimited);
                self.state = .finished;
                return self.body.items;
            },
            .finished => {
                return self.body.items;
            },
        }
    }
};

fn HttpReaderGeneric(comptime Header: type) type {
    return struct {
        input: *std.Io.Reader,
        body_reader: HttpBodyReader,

        pub const Result = struct {
            header: Header,
            body_reader: *std.Io.Reader,
        };

        const Self = @This();

        pub fn init(r: *std.Io.Reader) Self {
            return .{
                .input = r,
                .body_reader = .none,
            };
        }

        pub fn poll(self: *Self, alloc: std.mem.Allocator, body_buf: []u8) !Result {
            try self.body_reader.discardAll();

            while (true) {
                const tmp_header = try Header.parse(self.input.buffered()) orelse {
                    try safeFillMore(self.input);
                    continue;
                };

                std.debug.assert(self.body_reader == .none);

                try self.body_reader.feedHeader(tmp_header, self.input, body_buf);

                self.input.toss(tmp_header.body_start);

                // Returned reader will invalidate buffer referenced by tmp_header
                const header = try tmp_header.dupe(alloc);

                return .{
                    .header = header,
                    .body_reader = self.body_reader.reader().?,
                };
            }
        }
    };
}

test "HttpReader sanity" {
    const sphalloc = @import("alloc.zig");

    const test_message_content =
        "GET /some_url HTTP/1.1\r\n" ++
        "Content-Length: 11\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: text\r\n" ++
        "X-Custom-Header: custom\r\n" ++
        "\r\n" ++
        "Hello world";

    var scratch_buf: [4096]u8 = undefined;
    var scratch = sphalloc.ScratchAlloc.init(&scratch_buf);

    var reader = std.Io.Reader.fixed(test_message_content);

    var httpr = HttpRequestReader.init(&reader);

    var body_buf: [4096]u8 = undefined;

    reader.end = 10;
    try std.testing.expectError(error.EndOfStream, httpr.poll(scratch.allocator(), &body_buf));

    reader.end = test_message_content.len - 12;
    try std.testing.expectError(error.EndOfStream, httpr.poll(scratch.allocator(), &body_buf));

    // Now we should have the whole header, but the body won't be ready
    reader.end = test_message_content.len - 11;
    const res = try httpr.poll(scratch.allocator(), &body_buf);

    try std.testing.expectError(error.EndOfStream, res.body_reader.take(11));

    reader.end = test_message_content.len - 5;
    try std.testing.expectError(error.EndOfStream, res.body_reader.take(11));

    reader.end = test_message_content.len;
    try std.testing.expectEqualStrings("Hello world", try res.body_reader.take(11));

    // Non-thorough checks, just make sure that that the header is valid
    try std.testing.expectEqual(.GET, res.header.method);
}

pub const HttpRequestHeader = struct {
    method: std.http.Method,
    target: []const u8,
    version: std.http.Version,
    fields: []const u8,
    body_start: usize,

    pub fn parse(content: []const u8) !?HttpRequestHeader {
        const end_of_header = std.mem.indexOf(u8, content, "\r\n\r\n") orelse return null;
        // GET /test/hello HTTP/1.1
        const line_end = std.mem.indexOf(u8, content, "\r\n") orelse unreachable;
        var it = std.mem.splitScalar(u8, content[0..line_end], ' ');
        const method = it.next() orelse return error.NoMethod;
        const target = it.next() orelse return error.NoTarget;
        const version = it.next() orelse return error.NoVersion;

        return HttpRequestHeader{
            .method = std.meta.stringToEnum(std.http.Method, method) orelse return error.InvalidHttpMethod,
            .target = target,
            .version = std.meta.stringToEnum(std.http.Version, version) orelse return error.InvalidVersion,
            .fields = content[line_end + 2 .. end_of_header],
            .body_start = end_of_header + 4,
        };
    }

    pub fn dupe(self: HttpRequestHeader, alloc: std.mem.Allocator) !HttpRequestHeader {
        return .{
            .method = self.method,
            .target = try alloc.dupe(u8, self.target),
            .version = self.version,
            .fields = try alloc.dupe(u8, self.fields),
            .body_start = self.body_start,
        };
    }

    pub fn fieldIter(self: HttpRequestHeader) FieldIter {
        return .init(self.fields);
    }
};

pub const HttpResponseHeader = struct {
    version: std.http.Version,
    status: std.http.Status,
    fields: []const u8,
    body_start: usize,

    pub fn parse(content: []const u8) !?HttpResponseHeader {
        const end_of_header = std.mem.indexOf(u8, content, "\r\n\r\n") orelse return null;

        // HTTP/1.1 200 OK
        const line_end = std.mem.indexOf(u8, content, "\r\n") orelse unreachable;
        var it = std.mem.splitScalar(u8, content[0..line_end], ' ');
        const version = it.next() orelse return error.NoMethod;
        const status = it.next() orelse return error.NoStatus;
        const status_int = try std.fmt.parseInt(u10, status, 10);

        return .{
            .version = std.meta.stringToEnum(std.http.Version, version) orelse return error.InvalidVersion,
            .status = @enumFromInt(status_int),
            .fields = content[line_end + 2 .. end_of_header],
            .body_start = end_of_header + 4,
        };
    }

    pub fn dupe(self: HttpResponseHeader, alloc: std.mem.Allocator) !HttpResponseHeader {
        return .{
            .version = self.version,
            .status = self.status,
            .fields = try alloc.dupe(u8, self.fields),
            .body_start = self.body_start,
        };
    }

    pub fn fieldIter(self: HttpResponseHeader) FieldIter {
        return .init(self.fields);
    }
};

pub const FieldIter = struct {
    line_it: std.mem.SplitIterator(u8, .sequence),

    const Output = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(buf: []const u8) FieldIter {
        return .{
            .line_it = std.mem.splitSequence(u8, buf, "\r\n"),
        };
    }

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

test "HttpHeader sanity" {
    const header_content =
        "GET /some_url HTTP/1.1\r\n" ++
        "X-Some-Header: Hello\r\n" ++
        "Content-Length: 50\r\n" ++
        "Content-Type: text/html\r\n" ++
        "\r\n";

    const header = try HttpRequestHeader.parse(header_content) orelse return error.InvalidHeader;
    var it = header.fieldIter();

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
}

fn safeFillMore(r: *std.Io.Reader) !void {
    if (r.end == r.buffer.len and r.seek == 0) {
        return error.ReadFailed;
    }

    try r.fillMore();
}

fn findHttpLineEnd(r: *std.Io.Reader) !usize {
    while (true) {
        const buf = r.buffered();
        return std.mem.indexOf(u8, buf, "\r\n") orelse {
            try safeFillMore(r);
            continue;
        };
    }
}

const HttpBodyReader = union(enum) {
    chunked: ChunkedReader,
    limited: std.Io.Reader.Limited,
    remaining: *std.Io.Reader,
    none,

    fn init() HttpBodyReader {
        return .none;
    }

    // Header can be a request or response, or anything really, but it needs the fieldIter() fn
    fn feedHeader(self: *HttpBodyReader, header: anytype, r: *std.Io.Reader, body_buf: []u8) !void {
        const transfer_encoding = try extractTransferEncoding(header);
        switch (transfer_encoding) {
            .chunked => {
                self.* = .{ .chunked = ChunkedReader.init(r, body_buf) };
            },
            .length => |content_len| {
                self.* = .{ .limited = .init(r, .limited(content_len), body_buf) };
            },
            .remaining => {
                self.* = .{ .remaining = r };
            },
        }
    }

    fn discardAll(self: *HttpBodyReader) !void {
        switch (self.*) {
            inline .chunked, .limited => |*r| {
                _ = try r.interface.discardRemaining();
                self.* = .none;
            },
            // Internally we never want this, we give the body to callers and
            // if the entire stream is body, we can short circuit actually
            // reading and just call it a day :)
            .remaining => return error.EndOfStream,
            .none => {},
        }
    }

    fn reader(self: *HttpBodyReader) ?*std.Io.Reader {
        switch (self.*) {
            inline .chunked, .limited => |*r| return &r.interface,
            .remaining => |r| return r,
            .none => return null,
        }
    }

    const TransferEncoding = union(enum) {
        chunked,
        remaining,
        length: usize,
    };

    fn extractTransferEncoding(header: anytype) !TransferEncoding {
        var it = header.fieldIter();
        var lower_buf: [4096]u8 = undefined;

        const RelevantHeader = enum {
            @"content-length",
            @"transfer-encoding",
        };

        while (try it.next()) |field| {
            const lower_key = std.ascii.lowerString(&lower_buf, field.key);
            const rh = std.meta.stringToEnum(RelevantHeader, lower_key) orelse continue;
            switch (rh) {
                .@"content-length" => {
                    return .{
                        .length = try std.fmt.parseInt(usize, field.value, 10),
                    };
                },
                .@"transfer-encoding" => {
                    const lower_val = std.ascii.lowerString(&lower_buf, field.value);
                    if (!std.mem.eql(u8, lower_val, "chunked")) {
                        return error.UnsupportedTransferEncoding;
                    }

                    return .chunked;
                },
            }
        }

        return .remaining;
    }
};

// Reader implementing transfer-type: chunked body
const ChunkedReader = struct {
    input: *std.Io.Reader,
    interface: std.Io.Reader,
    chunk_remaining: usize,

    const read_chunk_len_flag = std.math.maxInt(usize);

    pub fn init(r: *std.Io.Reader, body_buf: []u8) ChunkedReader {
        return .{
            .input = r,
            .interface = .{
                .buffer = body_buf,
                .vtable = &.{
                    .stream = stream,
                },
                .seek = 0,
                .end = 0,
            },
            .chunk_remaining = read_chunk_len_flag,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("interface", r);

        if (self.chunk_remaining == 0) {
            // Discard streams and could have partial application, for
            // non-blocking reads we want to make sure that we have idempotent
            // state, so we peek and toss to confirm
            _ = try self.input.peek(2);
            self.chunk_remaining = read_chunk_len_flag;
            self.input.toss(2);
        }

        if (self.chunk_remaining == read_chunk_len_flag) {
            const line_end = try findHttpLineEnd(self.input);
            self.chunk_remaining = std.fmt.parseInt(usize, self.input.buffered()[0..line_end], 16) catch return error.ReadFailed;
            self.input.toss(line_end + 2);
        }

        // If it's still 0 here, it means we got a 0 from the previous if
        // statement which means we're done
        if (self.chunk_remaining == 0) {
            return error.EndOfStream;
        }

        const actual_limit = limit.min(.limited(self.chunk_remaining));

        const read_bytes = try self.input.stream(w, actual_limit);
        self.chunk_remaining -= read_bytes;

        return read_bytes;
    }
};

pub const HttpHeaderParams = struct {
    status: std.http.Status,
    content_length: ?usize,
    content_type: ?[]const u8 = null,
    headers: []const struct { key: []const u8, value: []const u8 } = &.{},
};

pub fn makeHttpHeader(alloc: std.mem.Allocator, params: HttpHeaderParams) ![]const u8 {
    const ret_len = try httpHeaderLen(params);
    const ret = try alloc.alloc(u8, ret_len);
    var fixed = std.Io.Writer.fixed(ret);
    try makeHttpHeaderWriter(params, &fixed);

    return ret;
}

pub fn makeHttpHeaderComptime(comptime params: HttpHeaderParams) []const u8 {
    return comptime blk: {
        var buf: [try httpHeaderLen(params)]u8 = undefined;

        var writer = std.Io.Writer.fixed(&buf);
        try makeHttpHeaderWriter(params, &writer);
        const final = buf;
        break :blk &final;
    };
}

pub fn httpHeaderLen(params: HttpHeaderParams) !usize {
    var discarding_buf: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discarding_buf);
    try makeHttpHeaderWriter(params, &discarding.writer);
    return discarding.count;
}

pub fn makeHttpHeaderWriter(params: HttpHeaderParams, writer: *std.Io.Writer) !void {
    var http_writer = HttpWriter.init(writer);

    try http_writer.startResponse(.{
        .status = params.status,
        .content_length = params.content_length,
        .content_type = params.content_type,
    });

    for (params.headers) |header| {
        try http_writer.appendHeader(header.key, header.value);
    }

    try http_writer.startBody();
    try writer.flush();
}

pub const HttpWriter = struct {
    writer: *std.Io.Writer,

    const Self = @This();

    pub fn init(w: *std.Io.Writer) HttpWriter {
        return .{
            .writer = w,
        };
    }

    pub const RequestParams = struct {
        method: std.http.Method,
        target: []const u8,
        content_length: ?usize,
        content_type: ?[]const u8 = null,
    };

    pub fn startRequest(self: *Self, params: RequestParams) !void {
        try self.writer.print("{t} {s} HTTP/1.1\r\n", .{ params.method, params.target });
        if (params.content_length) |cl| {
            try self.writer.print("Content-Length: {d}\r\n", .{cl});
        }
        if (params.content_type) |t| {
            try self.appendHeader("Content-Type", t);
        }
    }

    pub const ResponseParams = struct {
        status: std.http.Status,
        content_length: ?usize,
        content_type: ?[]const u8 = null,
    };

    pub fn startResponse(self: *Self, params: ResponseParams) !void {
        try self.writer.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(params.status), params.status.phrase() orelse "" });

        if (params.content_length) |l| {
            try self.appendIntHeader("Content-Length", l);
        }

        if (params.content_type) |t| {
            try self.appendHeader("Content-Type", t);
        }
    }

    pub fn appendHeader(self: *Self, key: []const u8, val: []const u8) !void {
        try self.writer.print("{s}: {s}\r\n", .{ key, val });
    }

    pub fn appendIntHeader(self: *Self, key: []const u8, val: anytype) !void {
        try self.writer.print("{s}: {d}\r\n", .{ key, val });
    }

    pub fn writeBody(self: *Self, content: []const u8) !void {
        try self.writer.writeAll("\r\n");
        try self.writer.writeAll(content);
    }

    pub fn startBody(self: *Self) !void {
        try self.writer.writeAll("\r\n");
    }
};

test "HttpWriter response sanity" {
    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();

    var writer = HttpWriter.init(&allocating.writer);

    try writer.startResponse(.{
        .status = .ok,
        .content_length = 0,
    });

    // If this gets too much churn, we might want to do something more intelligent
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 0\r\n", allocating.written());

    allocating.clearRetainingCapacity();

    try writer.startResponse(.{
        .status = .internal_server_error,
        .content_length = 11,
        .content_type = "text",
    });

    try writer.appendHeader("X-Custom-Header", "custom");
    try writer.writeBody("Hello world");

    try std.testing.expectEqualStrings("HTTP/1.1 500 Internal Server Error\r\n" ++
        "Content-Length: 11\r\n" ++
        "Content-Type: text\r\n" ++
        "X-Custom-Header: custom\r\n" ++
        "\r\n" ++
        "Hello world", allocating.written());
}

test "comptime header" {
    const not_found = makeHttpHeaderComptime(.{
        .status = .not_found,
        .headers = &.{
            .{ .key = "test", .value = "value" },
        },
        .content_type = "text/http",
        .content_length = 10,
    });

    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found\r\n" ++
        "Content-Length: 10\r\n" ++
        "Content-Type: text/http\r\n" ++
        "test: value\r\n\r\n", not_found);
}

test {
    std.testing.refAllDecls(@This());
}
