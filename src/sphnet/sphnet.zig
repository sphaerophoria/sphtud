const std = @import("std");

const sphnet = @This();

pub fn Stream(read_size: usize, write_size: usize) type {
    return struct {
        stream: std.net.Stream,

        reader_buf: [read_size]u8,
        writer_buf: [write_size]u8,

        stream_reader: if (read_size == 0) void else std.net.Stream.Reader,
        stream_writer: if (write_size == 0) void else std.net.Stream.Writer,

        pub fn fromStd(self: *@This(), std_stream: std.net.Stream) void {
            self.stream = std_stream;

            self.stream_reader = self.stream.reader(&self.reader_buf);
            self.stream_writer = self.stream.writer(&self.writer_buf);
        }

        pub fn close(self: *@This()) void {
            self.stream.close();
        }

        pub fn isWouldBlock(self: *@This(), e: anyerror) bool {
            return sphnet.isWouldBlock(&self.stream_reader, e);
        }

        pub fn handle(self: *@This()) std.posix.fd_t {
            return self.stream.handle;
        }

        pub fn reader(self: *@This()) *std.Io.Reader {
            return self.stream_reader.interface();
        }

        pub fn writer(self: *@This()) *std.Io.Writer {
            return &self.stream_writer.interface;
        }

        pub fn flush(self: *@This()) !void {
            try self.writer().flush();
        }
    };
}

pub fn TlsStream(read_size: usize, write_size: usize) type {
    return struct {
        stream: Stream(tls_buffer_size, tls_buffer_size),

        tls: std.crypto.tls.Client,

        tls_read_buffer: [read_size]u8,
        tls_write_buffer: [write_size]u8,

        const tls_buffer_size = std.crypto.tls.Client.min_buffer_len;

        pub fn initPinned(self: *@This(), std_stream: std.net.Stream, host: []const u8, ca_bundle: std.crypto.Certificate.Bundle) !void {
            self.stream.fromStd(std_stream);

            self.tls = try std.crypto.tls.Client.init(
                self.stream.reader(),
                self.stream.writer(),
                .{
                    .host = .{ .explicit = host },
                    .ca = .{ .bundle = ca_bundle },
                    .ssl_key_log = null,
                    .read_buffer = &self.tls_read_buffer,
                    .write_buffer = &self.tls_write_buffer,
                    // This is appropriate for HTTPS because the HTTP headers contain
                    // the content length which is used to detect truncation attacks.
                    .allow_truncation_attacks = true,
                },
            );
        }

        pub fn close(self: *@This()) void {
            self.stream.close();
        }

        pub fn isWouldBlock(self: *@This(), e: anyerror) bool {
            return self.stream.isWouldBlock(e);
        }

        pub fn handle(self: *@This()) std.posix.fd_t {
            return self.stream.handle();
        }

        pub fn reader(self: *@This()) *std.Io.Reader {
            return &self.tls.reader;
        }

        pub fn writer(self: *@This()) *std.Io.Writer {
            return &self.tls.writer;
        }

        pub fn flush(self: *@This()) !void {
            try self.writer().flush();
            try self.stream.flush();
        }
    };
}

fn isWouldBlock(r: *std.net.Stream.Reader, e: anyerror) bool {
    switch (e) {
        error.ReadFailed => {
            const se = r.getError() orelse return false;
            switch (se) {
                error.WouldBlock => return true,
                else => {},
            }
        },
        else => {},
    }

    return false;
}
