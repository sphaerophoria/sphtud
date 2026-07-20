const std = @import("std");
const sphtud = @import("../sphtud.zig");

const SimpleHttpTls = @This();

alloc: std.mem.Allocator,
uri: std.Uri,
params: sphtud.http.Simple.Params,
state: union(enum) {
    init: sphtud.io.tls.ClientInit,
    fetch: struct {
        tls_read_buf: [4096]u8 = undefined,
        conn: sphtud.io.tls.Connection,
        tls_reader: sphtud.io.tls.Reader,
        fetcher: sphtud.http.Simple,
    },
},

pub fn initPinned(
    self: *SimpleHttpTls,
    alloc: std.mem.Allocator,
    uri: std.Uri,
    params: sphtud.http.Simple.Params,
    tls_spawner: *sphtud.io.tls.Spawner,
    service_id: usize,
) !void {
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buf);

    self.* = .{
        .alloc = alloc,
        .uri = uri,
        .params = params,
        .state = .{
            .init = try tls_spawner.spawn(host.bytes, uri.port orelse 443, service_id),
        },
    };
}

pub fn deinit(self: *SimpleHttpTls) void {
    switch (self.state) {
        .init => |*i| i.deinit(),
        .fetch => |*f| f.conn.deinit(),
    }
}

pub fn poll(self: *SimpleHttpTls, loop: *sphtud.io.Loop, service_id: usize) !?[]const u8 {
    sw: switch (self.state) {
        .init => |*init| {
            const conn = try init.poll() orelse return null;

            var write_buf: [4096]u8 = undefined;
            var w = conn.writer(&write_buf);

            self.state = .{
                .fetch = undefined,
            };
            const f = &self.state.fetch;
            f.conn = conn;
            f.tls_reader = conn.reader(&f.tls_read_buf);
            f.fetcher = try .init(self.alloc, &f.tls_reader.interface, &w.interface, self.uri, self.params);

            try loop.register(.{
                .handle = f.conn.fd,
                .id = service_id,
                .read = true,
                .write = false,
            });
            continue :sw self.state;
        },
        .fetch => |*f| {
            f.tls_reader.err = null;

            return f.fetcher.poll() catch |e| {
                if (f.tls_reader.err) |source| {
                    if (source == error.WouldBlock) return null;
                    return source;
                }
                return e;
            };
        },
    }
}
