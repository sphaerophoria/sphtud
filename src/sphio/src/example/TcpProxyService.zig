const std = @import("std");
const sphio = @import("sphio");
const sphutil = @import("sphutil");
const Impl = @import("TcpProxyImpl.zig");

const TcpFetchProxyService = @This();

pub const max_clients = 100;

pool: sphutil.ObjectPool(Storage, usize),
loop: *sphio.Loop,
listener: std.posix.fd_t,
spawner: *sphio.TcpSpawner,

pub fn init(arena: std.mem.Allocator, loop: *sphio.Loop, spawner: *sphio.TcpSpawner, listen_port: u16, comptime ids: Ids) !TcpFetchProxyService {
    const listener = try sphio.createTcpListener(.{
        .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = listen_port,
        },
    }, 100);
    errdefer sphio.close(listener);

    try loop.register(.{
        .handle = listener,
        .id = ids.new_connection,
        .read = true,
        .write = false,
    });
    errdefer loop.unregister(listener) catch {};

    return .{
        .pool = try .init(arena, .invalid, max_clients, max_clients),
        .loop = loop,
        .spawner = spawner,
        .listener = listener,
    };
}

pub fn service(self: *TcpFetchProxyService, service_id: usize, comptime ids: Ids) !void {
    switch (service_id) {
        ids.new_connection => {
            try self.serviceNewConnection(ids);
        },
        ids.service_elem.start...ids.service_elem.end => {
            const elem_id = ids.service_elem.offset(service_id);
            try self.serviceElem(elem_id, ids);
        },
        ids.connection_ready.start...ids.connection_ready.end => {
            const elem_id = ids.connection_ready.offset(service_id);
            if (!try self.serviceConnectionReady(elem_id, ids)) return;
            try self.serviceElem(elem_id, ids);
        },
        else => unreachable,
    }
}

fn serviceNewConnection(self: *TcpFetchProxyService, comptime ids: Ids) !void {
    while (true) {
        const new_fd = sphio.accept(self.listener) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return e,
        };

        errdefer sphio.close(new_fd);

        const elem = try self.pool.acquire(.invalid);
        errdefer self.pool.release(.invalid, elem.handle);

        elem.val.initPinned(new_fd);
        try self.loop.register(.{
            .handle = new_fd,
            .id = ids.service_elem.start + elem.handle,
            .read = true,
            .write = true,
        });
    }
}

fn serviceElem(self: *TcpFetchProxyService, elem_id: usize, comptime ids: Ids) !void {
    const elem = self.pool.get(elem_id);

    while (true) {
        elem.client_reader.err = null;
        elem.remote_reader.err = null;

        const action = elem.impl.service() catch |e| {
            if (elem.client_reader.isWouldBlock(e)) return;
            if (elem.remote_reader.isWouldBlock(e)) return;

            std.log.err("Error on connection {d}, closing\n", .{elem_id});

            self.closeConnection(elem_id);
            return;
        };

        switch (action) {
            .create_connection => |host| {
                elem.remote = .{ .initializing = try self.spawner.spawn(host, 80, ids.connection_ready.start + elem_id) };
            },
            .close_connection => {
                sphio.close(elem.remote.initialized);
                elem.remote = .none;
                elem.remote_reader = .invalid;
                elem.remote_writer = .invalid;
                sphio.close(elem.socket);
                self.pool.release(.invalid, elem_id);
                return;
            },
            .wait => return,
        }
    }
}

fn serviceConnectionReady(self: *TcpFetchProxyService, elem_id: usize, comptime ids: Ids) !bool {
    const elem = self.pool.get(elem_id);
    errdefer elem.impl.state = .default;

    switch (elem.remote) {
        .initializing => |handle| {
            elem.remote = .{
                .initialized = self.spawner.finish(handle) catch {
                    self.closeConnection(elem_id);
                    return false;
                },
            };
        },
        .initialized => {},
        .none => unreachable,
    }

    const socket = elem.remote.initialized;
    errdefer sphio.close(socket);

    try self.loop.register(.{
        .handle = socket,
        .id = ids.service_elem.start + elem_id,
        .read = true,
        .write = true,
    });

    std.debug.assert(socket >= 0);

    // This is always streamed into the writer, so I don't think
    // buffering would help us here
    elem.remote_reader = .init(socket, &.{});
    elem.remote_writer = .init(socket, &elem.remote_write_buf);

    try elem.impl.onConnectionCreated(.{
        .r = &elem.remote_reader.interface,
        .w = &elem.remote_writer.interface,
    });

    return true;
}

fn closeConnection(self: *TcpFetchProxyService, id: usize) void {
    const elem = self.pool.get(id);
    elem.deinit();
    self.pool.release(.invalid, id);
}

const Storage = struct {
    socket: std.posix.fd_t,

    client_write_buf: [4096]u8,
    client_read_buf: [256]u8,
    client_writer: sphio.Writer,
    client_reader: sphio.Reader,

    impl: Impl,

    remote: union(enum) {
        none,
        initializing: sphio.TcpSpawner.SpawnHandle,
        initialized: std.posix.fd_t,
    },
    remote_write_buf: [4096]u8,
    remote_reader: sphio.Reader,
    remote_writer: sphio.Writer,

    pub fn initPinned(elem: *Storage, socket: std.posix.fd_t) void {
        elem.socket = socket;
        elem.client_write_buf = undefined;
        elem.client_read_buf = undefined;
        elem.client_writer = .init(socket, &elem.client_write_buf);
        elem.client_reader = .init(socket, &elem.client_read_buf);

        elem.remote = .none;
        elem.remote_write_buf = undefined;
        elem.remote_reader = .invalid;
        elem.remote_writer = .invalid;

        elem.impl = .{
            .rw = .{
                .r = &elem.client_reader.interface,
                .w = &elem.client_writer.interface,
            },
            .state = .default,
        };
    }

    pub fn deinit(self: *Storage) void {
        sphio.close(self.socket);
    }
};

pub const Ids = struct {
    new_connection: usize,
    service_elem: sphio.IdAlloc.Range,
    connection_ready: sphio.IdAlloc.Range,
    total: sphio.IdAlloc.Range,

    pub fn init(alloc: *sphio.IdAlloc) Ids {
        const start = alloc.mark();
        return .{
            .new_connection = alloc.allocOne(),
            .service_elem = alloc.allocMany(max_clients),
            .connection_ready = alloc.allocMany(max_clients),
            .total = start.range(),
        };
    }
};
