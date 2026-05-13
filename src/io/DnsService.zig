const std = @import("std");
const sphtud = @import("../sphtud.zig");
const system = std.posix.system;
pub const Impl = @import("DnsImpl.zig");

dns_alloc: *sphtud.alloc.Sphalloc,
socket: std.posix.fd_t,
extradata: sphtud.util.AutoHashMap(Impl.QueryHandle, ExtraData),
impl: Impl,
timer: *sphtud.io.TimerService,
timeout_id_start: usize,
loop: *sphtud.io.Loop,

const ExtraData = struct {
    callback_id: usize,
    timer_handle: ?sphtud.io.TimerService.TimerHandle,
};

const Pool = sphtud.util.ObjectPool(Impl.QueryHandle, usize);

const DnsService = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc, loop: *sphtud.io.Loop, timer: *sphtud.io.TimerService, comptime ids: Ids) !DnsService {
    var read_buf: [4096]u8 = undefined;
    const resolv_fd = try sphtud.io.open("/etc/resolv.conf", .{
        .ACCMODE = .RDONLY,
    }, 0);
    defer sphtud.io.close(resolv_fd);

    var resolv_reader = sphtud.io.Reader.init(resolv_fd, &read_buf);
    const resolv_conf = try Impl.ResolvConf.parse(&resolv_reader.interface);

    const hosts_fd = try sphtud.io.open("/etc/hosts", .{
        .ACCMODE = .RDONLY,
    }, 0);
    defer sphtud.io.close(hosts_fd);

    var hosts_reader = sphtud.io.Reader.init(hosts_fd, &read_buf);
    const hosts = try Impl.Hosts.parse(alloc.arena(), &hosts_reader.interface);

    const socket = try sphtud.io.socket(system.AF.INET, system.SOCK.DGRAM, 0);
    try sphtud.io.bind(socket, .{
        .ip4 = .{
            .bytes = .{ 0, 0, 0, 0 },
            .port = 0,
        },
    });

    const max_connections = ids.timeout.end + 1 - ids.timeout.start;
    const impl = try Impl.init(alloc, resolv_conf, hosts, max_connections);

    try loop.register(.{
        .handle = socket,
        .id = ids.dns_packet_received,
        .read = true,
        .write = false,
    });

    return .{
        .dns_alloc = alloc,
        .socket = socket,
        .extradata = try .init(alloc.arena(), alloc.expansion(), 8, max_connections),
        .timer = timer,
        .impl = impl,
        .timeout_id_start = ids.timeout.start,
        .loop = loop,
    };
}

const Self = @This();

pub fn makeQuery(self: *Self, host: []const u8, on_dns_response: usize) !Impl.QueryHandle {
    var action = try self.impl.makeQuery(host);
    errdefer self.impl.release(action.handle);

    try self.sendActionMessages(&action);

    const timer_handle = if (action.timeout) |t|
        try self.timer.add(t, self.timeout_id_start + action.handle.id)
    else
        null;

    try self.extradata.put(action.handle, .{
        .timer_handle = timer_handle,
        .callback_id = on_dns_response,
    });
    errdefer _ = self.extradata.remove(action.handle);

    // Some items may be ready right now
    try self.loop.pushEvent(on_dns_response);

    return action.handle;
}

fn sendActionMessages(self: *Self, action: *Impl.QueryResult) !void {
    while (action.next()) |to_send| {
        const sent = try sphtud.io.sendto(
            self.socket,
            to_send.data,
            system.MSG.NOSIGNAL,
            to_send.ip,
        );
        std.debug.assert(sent == to_send.data.len);
    }
}

pub fn get(self: *Self, handle: Impl.QueryHandle) *Impl.QueryStorage {
    return self.impl.get(handle);
}

pub fn release(self: *Self, handle: Impl.QueryHandle) void {
    const removed = self.extradata.remove(handle);

    if (removed) |extradata| {
        if (extradata.timer_handle) |t| {
            self.timer.remove(t);
        }
    }

    self.loop.clearEvents(self.timeout_id_start + handle.id);
    self.impl.release(handle);
}

pub fn service(self: *Self, id: usize, comptime ids: Ids) !void {
    switch (id) {
        ids.dns_packet_received => try self.serviceIncomingPacket(),
        ids.timeout.start...ids.timeout.end => {
            const idx = id - ids.timeout.start;
            try self.serviceTimeout(idx);
        },
        else => unreachable,
    }
}

fn serviceTimeout(self: *Self, idx: usize) !void {
    const handle = Impl.QueryHandle.fromIdx(idx);
    var action = try self.impl.onTimeout(handle);

    const extradata = self.extradata.getPtr(handle) orelse return error.InvalidHandle;
    switch (action) {
        .finish => {
            try self.loop.pushEvent(extradata.callback_id);
        },
        .retry => |*retry| {
            try self.sendActionMessages(retry);
            if (retry.timeout) |t| {
                // FIXME: Timer id maybe should be owned somewhere so it isn't duped
                extradata.timer_handle = try self.timer.add(t, self.timeout_id_start + handle.id);
            }

            return;
        },
    }
}

fn serviceIncomingPacket(self: *Self) !void {
    while (true) {
        var recv_buf: [4096]u8 = undefined;

        const recv_len = sphtud.io.recvfrom(self.socket, &recv_buf, 0, null, null) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return e,
        };
        const received = recv_buf[0..recv_len];

        const handle = self.impl.onRecv(received) catch |e| {
            std.log.err("Failed to handle incoming dns packet {t}", .{e});
            continue;
        } orelse continue;

        const extradata = self.extradata.get(handle) orelse return error.InvalidHandle;
        try self.loop.pushEvent(extradata.callback_id);
    }
}

pub const Ids = struct {
    dns_packet_received: usize,
    timeout: sphtud.io.IdAlloc.Range,
    total: sphtud.io.IdAlloc.Range,

    pub fn init(alloc: *sphtud.io.IdAlloc, max_connections: usize) Ids {
        const start = alloc.mark();
        return .{
            .dns_packet_received = alloc.allocOne(),
            .timeout = alloc.allocMany(max_connections),
            .total = start.range(),
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
