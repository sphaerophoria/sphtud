const std = @import("std");
const DnsService = @import("DnsService.zig");
const sphutil = @import("../util.zig");
const sphio = @import("../io.zig");
const system = std.os.linux;

const TcpSpawner = @This();

dns_service: *sphio.DnsService,
// FIXME: Pass in?
expansion_alloc: sphutil.ExpansionAlloc,
pool: sphutil.ObjectPool(Connection, usize),
loop: *sphio.Loop,
service_start_id: usize,

const num_concurrent = 8;
// Hardcode for now, there's probably some sane maximum like
// number of file descriptors allowed at once or something
pub const max_connections = 1024;

pub fn init(arena: std.mem.Allocator, expansion: sphutil.ExpansionAlloc, dns_service: *sphio.DnsService, loop: *sphio.Loop, comptime ids: Ids) !TcpSpawner {
    return .{
        .dns_service = dns_service,
        .expansion_alloc = expansion,
        .pool = try .init(
            arena,
            expansion,
            8,
            max_connections,
        ),
        .loop = loop,
        .service_start_id = ids.total.start,
    };
}

pub const Ids = struct {
    dns_update: sphio.IdAlloc.Range,
    connection_update: sphio.IdAlloc.Range,
    total: sphio.IdAlloc.Range,

    pub fn init(alloc: *sphio.IdAlloc) Ids {
        const start = alloc.mark();
        return .{
            .dns_update = alloc.allocMany(max_connections),
            .connection_update = alloc.allocMany(max_connections * num_concurrent),
            .total = start.range(),
        };
    }

    fn initFromStartId(id: usize) Ids {
        var alloc = sphio.IdAlloc{ .idx = id };
        return Ids.init(&alloc);
    }

    pub fn contians(self: Ids, id: usize) bool {
        return id >= self.dns_update.start and id <= self.connection_update.end;
    }

    pub fn connectionId(self: Ids, idx: usize, sub_idx: u8) usize {
        return self.connection_update.start + idx * num_concurrent + sub_idx;
    }
};

pub const SpawnHandle = struct {
    inner: usize,
};

pub fn spawn(self: *TcpSpawner, host: []const u8, port: u16, on_completed: usize) !SpawnHandle {
    const connection = try self.pool.acquire(self.expansion_alloc);
    errdefer self.pool.release(self.expansion_alloc, connection.handle);

    const ids = Ids.initFromStartId(self.service_start_id);
    connection.val.* = .{
        .result = null,
        .connections = @splat(-1),
        .port = port,
        .query = try self.dns_service.makeQuery(host, ids.dns_update.start + connection.handle),
        .on_connected = on_completed,
    };

    return .{ .inner = connection.handle };
}

pub fn get(self: *TcpSpawner, handle: SpawnHandle) *Connection {
    return self.pool.get(handle.inner);
}

pub fn finish(self: *TcpSpawner, handle: SpawnHandle) !?std.posix.fd_t {
    const connection = self.pool.get(handle.inner);
    const res = connection.result orelse return null;
    connection.deinit(self.dns_service);
    self.pool.release(self.expansion_alloc, handle.inner);

    const ids = Ids.initFromStartId(self.service_start_id);

    self.loop.clearEvents(ids.dns_update.start + handle.inner);
    for (0..num_concurrent) |i| {
        self.loop.clearEvents(ids.connectionId(handle.inner, @intCast(i)));
    }

    return try res;
}

pub fn service(self: *TcpSpawner, id: usize, comptime ids: Ids) !void {
    switch (id) {
        ids.dns_update.start...ids.dns_update.end => {
            const conn_id = id - ids.dns_update.start;
            const connection = self.pool.get(conn_id);
            for (&connection.connections, 0..) |*fd, i| {
                if (fd.* == -1) {
                    if (try self.connectNextIp(conn_id, i, ids)) |res| {
                        try self.loop.pushEvent(res);
                    }
                }
            }
        },
        ids.connection_update.start...ids.connection_update.end => {
            const conn_id = (id - ids.connection_update.start) / num_concurrent;
            const sub_id = (id - ids.connection_update.start) % num_concurrent;
            const connection = self.pool.get(conn_id);
            const fd = &connection.connections[conn_id];

            // FIXME: Any errors here probably should propagate to whoever
            // asked for this connection, not just crash our entire program
            // ding dong

            switch (try isSocketConnected(fd.*)) {
                .connected => {
                    connection.result = fd.*;
                    try self.loop.unregister(fd.*);
                    fd.* = -1;
                    try self.loop.pushEvent(connection.on_connected);
                },
                .in_progress => {},
                .err => {
                    connection.result = error.ConnectionFailed;
                    sphio.close(fd.*);
                    fd.* = -1;
                    try self.loop.pushEvent(connection.on_connected);
                },
            }

            if (try self.connectNextIp(conn_id, sub_id, ids)) |res| {
                try self.loop.pushEvent(res);
            }
        },
        else => unreachable,
    }
}

fn connectNextIp(self: *TcpSpawner, idx: usize, sub_idx: usize, ids: Ids) !?usize {
    const connection = self.pool.get(idx);
    const fd = &connection.connections[sub_idx];
    const query = self.dns_service.get(connection.query);
    const next_ip = switch (try query.next()) {
        .item => |ip| ip,
        .wait, .finished => return null,
    };
    fd.* = try sphio.socket(system.AF.INET, system.SOCK.STREAM, 0);

    const res = try sphio.connect(fd.*, .{
        .ip4 = .{
            .bytes = next_ip,
            .port = connection.port,
        },
    });

    if (res) {
        connection.result = fd.*;
        fd.* = -1;
        return connection.on_connected;
    }

    try self.loop.register(.{
        .handle = fd.*,
        .id = ids.connectionId(idx, @intCast(sub_idx)),
        .read = false,
        .write = true,
    });

    return null;
}

const Connection = struct {
    result: ?anyerror!std.posix.fd_t,

    connections: [num_concurrent]std.posix.fd_t,
    query: sphio.DnsService.Impl.QueryHandle,
    port: u16,
    on_connected: usize,

    fn deinit(self: *Connection, dns_service: *sphio.DnsService) void {
        for (self.connections) |fd| {
            if (fd >= 0) {
                sphio.close(fd);
            }
        }

        dns_service.release(self.query);
    }
};

const SocketConnectedRes = union(enum) {
    connected,
    in_progress,
    err: system.E,
};

fn isSocketConnected(socket: std.posix.fd_t) !SocketConnectedRes {
    // HACK: epoll is informing us that the socket is writeable while the TCP
    // state is still in TCP_SYN_SENT, writes cannot happen until the socket is
    // in TCP_ESTABLISHED. It turns out that the kernel will do this check for
    // us whether or not there is any actual data to send. Sending 0 bytes is
    // non-destructive, so we can check if this would EAGAIN, if it will it's
    // guaranteed that real writes would also return EAGAIN and the socket is
    // not fully ready to go
    //
    // We ignore any other error, as hopefully there's a more interesting error
    // returned by the SO_ERROR lookup below in that case
    _ = sphio.write(&.{}, socket) catch |e| {
        if (e == error.WouldBlock) return .in_progress;
    };

    var err_val: c_int = 0;
    var err_val_len: system.socklen_t = @sizeOf(c_int);
    try sphio.getsockopt(socket, system.SOL.SOCKET, system.SO.ERROR, std.mem.asBytes(&err_val), &err_val_len);
    std.debug.assert(err_val_len == @sizeOf(c_int));

    switch (system.errno(@intCast(err_val))) {
        .SUCCESS => return .connected,
        .INPROGRESS => {
            // AFAICT this is never triggered, see write() test above
            return .in_progress;
        },
        else => |e| return .{ .err = e },
    }
}
