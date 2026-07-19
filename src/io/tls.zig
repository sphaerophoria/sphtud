const std = @import("std");
const sphutil = @import("../util.zig");
const TcpSpawner = @import("TcpSpawner.zig");
const sphio = @import("../io.zig");

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const Spawner = struct {
    ctx: *c.SSL_CTX,
    tcp_spawner: *TcpSpawner,
    loop: *sphio.Loop,

    pub fn init(
        tcp_spawner: *TcpSpawner,
        loop: *sphio.Loop,
    ) !Spawner {
        const ctx: *c.SSL_CTX = c.SSL_CTX_new(c.TLS_client_method()) orelse return error.InitSsl;
        errdefer c.SSL_CTX_free(ctx);

        c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);

        if (c.SSL_CTX_set_default_verify_paths(ctx) == 0) return error.InitSsl;
        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) == 0) return error.InitSsl;

        return .{
            .ctx = ctx,
            .loop = loop,
            .tcp_spawner = tcp_spawner,
        };
    }

    pub fn deinit(self: *Spawner) void {
        c.SSL_CTX_free(self.ctx);
    }

    pub fn spawn(self: *Spawner, host: []const u8, port: u16, service_id: usize) !ClientInit {
        if (host.len >= ClientInit.max_host_len - 1) return error.HostTooLong;

        const tcp_spawn_handle = try self.tcp_spawner.spawn(host, port, service_id);

        var ret = ClientInit{
            .spawner = self,
            .service_id = service_id,
            .data = .{ .spawning = tcp_spawn_handle },
            .host_buf = undefined,
        };
        @memcpy(ret.host_buf[0..host.len], host);
        ret.host_buf[host.len] = 0;

        return ret;
    }
};

pub const Connection = struct {
    ssl: *c.SSL,
    fd: c_int,

    pub fn deinit(self: Connection) void {
        c.SSL_free(self.ssl);
        sphio.close(self.fd);
    }

    pub fn reader(self: Connection, buf: []u8) Reader {
        return .{
            .err = null,
            .ssl = self.ssl,
            .interface = .{
                .buffer = buf,
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = Reader.stream,
                },
            },
        };
    }

    pub fn writer(self: Connection, buf: []u8) Writer {
        return .{
            .err = null,
            .ssl = self.ssl,
            .interface = .{
                .buffer = buf,
                .end = 0,
                .vtable = &.{
                    .drain = Writer.drain,
                },
            },
        };
    }
};

pub const Reader = struct {
    ssl: *c.SSL,
    interface: std.Io.Reader,
    err: ?anyerror,

    pub fn isWouldBlock(self: Reader, e: anyerror) bool {
        const source = self.err orelse return false;
        return e == error.ReadFailed and source == error.WouldBlock;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Reader = @fieldParentPtr("interface", r);

        const write_buf = limit.slice(try w.writableSliceGreedy(1));

        var n: usize = 0;
        const res = c.SSL_read_ex(self.ssl, write_buf.ptr, write_buf.len, &n);
        switch (c.SSL_get_error(self.ssl, res)) {
            c.SSL_ERROR_NONE => {},
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {
                self.err = error.WouldBlock;
                return error.ReadFailed;
            },
            else => {
                self.err = error.Ssl;
                return error.ReadFailed;
            },
        }

        if (n == 0) return error.EndOfStream;

        w.advance(n);
        return n;
    }
};

pub const Writer = struct {
    err: ?anyerror,
    interface: std.Io.Writer,
    ssl: *c.SSL,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const self: *Writer = @fieldParentPtr("interface", w);

        var n: usize = 0;

        n += try self.writeImpl(w.buffered());

        for (0..data.len -| 1) |idx| {
            n += try self.writeImpl(data[idx]);
        }

        for (0..splat) |_| {
            n += try self.writeImpl(data[data.len - 1]);
        }

        return w.consume(n);
    }

    fn writeImpl(self: *Writer, buf: []const u8) !usize {
        var n: usize = 0;

        const res = c.SSL_write_ex(self.ssl, buf.ptr, buf.len, &n);

        switch (c.SSL_get_error(self.ssl, res)) {
            c.SSL_ERROR_NONE => {},
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {
                self.err = error.WouldBlock;
                return error.WriteFailed;
            },
            else => {
                self.err = error.Ssl;
                return error.WriteFailed;
            },
        }

        return n;
    }
};

pub const ClientInit = struct {
    spawner: *Spawner,
    host_buf: [max_host_len]u8,
    service_id: usize,

    data: union(enum) {
        spawning: TcpSpawner.SpawnHandle,
        ssl_init: Connection,
        none,
    },

    // This is just kinda made up, if you need this to be larger don't feel
    // like it was picked for a reason
    const max_host_len = 255;

    pub fn deinit(self: *ClientInit) void {
        switch (self.data) {
            .spawning => |h| self.spawner.tcp_spawner.cancel(h),
            .ssl_init => |*con| con.deinit(),
            .none => {},
        }
    }

    pub fn poll(self: *ClientInit) !?Connection {
        sw: switch (self.data) {
            .spawning => |h| {
                const connection = try self.onTcpReady(h) orelse return null;
                errdefer connection.deinit();

                try self.spawner.loop.register(.{
                    .handle = connection.fd,
                    .id = self.service_id,
                    .read = true,
                    .write = true,
                });

                self.data = .{ .ssl_init = connection };
                continue :sw self.data;
            },
            .ssl_init => |*con| {
                if (try serviceSsl(con)) {
                    try self.spawner.loop.unregister(con.fd);
                    const ret = con.*;
                    self.data = .none;
                    return ret;
                }
                return null;
            },
            // If someone has received the connection they should advance their
            // state machine such that this doesn't get called again
            .none => unreachable,
        }
    }

    fn onTcpReady(self: *ClientInit, tcp_handle: TcpSpawner.SpawnHandle) !?Connection {
        const fd = try self.spawner.tcp_spawner.finish(tcp_handle) orelse return null;
        errdefer sphio.close(fd);

        const ssl = c.SSL_new(self.spawner.ctx) orelse return error.SslInit;
        errdefer c.SSL_free(ssl);

        if (c.SSL_set_fd(ssl, fd) == 0) return error.SslInit;

        if (c.SSL_set_tlsext_host_name(ssl, &self.host_buf) == 0) return error.SslInit;
        if (c.SSL_set1_host(ssl, &self.host_buf) == 0) return error.SslInit;

        return .{ .fd = fd, .ssl = ssl };
    }

    fn serviceSsl(con: *Connection) !bool {
        const res = c.SSL_connect(con.ssl);

        switch (c.SSL_get_error(con.ssl, res)) {
            c.SSL_ERROR_NONE => {
                return true;
            },
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => {
                return false;
            },
            else => return error.SslError,
        }
    }
};
