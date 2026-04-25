const std = @import("std");
const sphutil = @import("sphutil");
const system = std.posix.system;

pub const Reader = struct {
    fd: std.posix.fd_t,
    interface: std.Io.Reader,
    err: ?anyerror,

    pub const invalid = Reader{
        .fd = -1,
        .interface = .{
            .buffer = &.{},
            .vtable = &vtable,
            .seek = 0,
            .end = 0,
        },
        .err = null,
    };

    const vtable = std.Io.Reader.VTable{
        .stream = stream,
    };

    pub fn init(fd: std.posix.fd_t, buf: []u8) Reader {
        return .{
            .fd = fd,
            .interface = .{
                .buffer = buf,
                .vtable = &vtable,
                .seek = 0,
                .end = 0,
            },
            .err = null,
        };
    }

    pub fn isWouldBlock(self: Reader, e: anyerror) bool {
        const source = self.err orelse return false;
        return e == error.ReadFailed and source == error.WouldBlock;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Reader = @fieldParentPtr("interface", r);

        const write_buf = limit.slice(try w.writableSliceGreedy(1));

        const n = std.posix.read(self.fd, write_buf) catch |e| {
            self.err = e;
            return error.ReadFailed;
        };

        if (n == 0) return error.EndOfStream;

        w.advance(n);
        return n;
    }
};

pub const Writer = struct {
    fd: std.posix.fd_t,
    interface: std.Io.Writer,

    pub const invalid = Writer{
        .fd = -1,
        .interface = .{
            .buffer = &.{},
            .vtable = &vtable,
            .end = 0,
        },
    };

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
    };

    pub fn init(fd: std.posix.fd_t, buf: []u8) Writer {
        return .{
            .fd = fd,
            .interface = .{
                .buffer = buf,
                .end = 0,
                .vtable = &vtable,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const self: *Writer = @fieldParentPtr("interface", w);

        var iovs: [std.Io.Threaded.max_iovecs_len]std.posix.iovec_const = undefined;
        var builder = WritevBuilder.init(&iovs);
        _ = builder.pushVec(w.buffered());
        builder.pushData(data, splat);

        const n = try pwritev2(self.fd, builder.getIovs(), -1, 0);
        return w.consume(n);
    }
};

const WritevBuilder = struct {
    iovs: []std.posix.iovec_const,
    next_iov: usize,

    fn init(iovs: []std.posix.iovec_const) WritevBuilder {
        std.debug.assert(iovs.len > 0);
        return .{
            .iovs = iovs,
            .next_iov = 0,
        };
    }

    fn getIovs(self: *WritevBuilder) []std.posix.iovec_const {
        return self.iovs[0..self.next_iov];
    }

    // return true if we are out of room
    fn pushVec(self: *WritevBuilder, data: []const u8) bool {
        if (self.next_iov >= self.iovs.len) return true;

        if (data.len == 0) return false;

        self.iovs[self.next_iov] = .{ .base = data.ptr, .len = data.len };
        self.next_iov += 1;

        return false;
    }

    fn pushData(b: *WritevBuilder, data: []const []const u8, splat: usize) void {
        const segmented = WritevBuilder.segment(data);

        for (segmented.simple) |v| {
            if (b.pushVec(v)) break;
        }

        switch (splat) {
            0 => {},
            1 => _ = b.pushVec(segmented.to_splat),
            // Splat parameter definition is sitting around std.Io.Writer's vtable
            // A good place to look would be in netWrite in std.Io.Threaded, on last look we found there are 3 cases
            // * A single character splat optimization that pre-memsets a
            //   larger buffer to be appended many times to the iovec
            // * A 0 character splat, which resulted in nothing
            // * A 2+ character splat which just appends many times
            else => @panic("TODO handle splat"),
        }
    }

    const Segmented = struct {
        simple: []const []const u8,
        to_splat: []const u8,
    };

    fn segment(data: []const []const u8) Segmented {
        const last_idx = data.len -| 1;
        return .{
            .simple = data[0..last_idx],
            .to_splat = data[last_idx],
        };
    }
};

pub fn fcntl(fd: std.posix.fd_t, op: c_int, param: c_int) !c_int {
    while (true) {
        const rc = system.fcntl(fd, op, @as(u32, @bitCast(param)));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| {
                return std.posix.unexpectedErrno(err);
            },
        }
    }
}

pub fn socket(domain: u32, typ: u32, proto: u32) !std.posix.fd_t {
    while (true) {
        const rc = system.socket(domain, typ, proto);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.Socket,
        }
    }
}

pub fn bind(sockfd: c_int, sockaddr: *const system.sockaddr, addr_len: system.socklen_t) !void {
    while (true) {
        const rc = system.bind(sockfd, sockaddr, addr_len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.Bind,
        }
    }
}

pub fn listen(sockfd: c_int, backlog: u32) !void {
    while (true) {
        const rc = system.listen(sockfd, backlog);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.Listen,
        }
    }
}

pub fn createTcpListener(addr: std.Io.net.IpAddress, backlog: u32) !std.posix.fd_t {
    const SOCK = std.posix.SOCK;
    const AF = std.posix.AF;

    const s = try socket(AF.INET, SOCK.STREAM | SOCK.NONBLOCK | SOCK.CLOEXEC, 0);
    errdefer close(s);

    try setsockopt(s, system.SOL.SOCKET, system.SO.REUSEADDR, 1);
    try setsockopt(s, system.SOL.SOCKET, system.SO.REUSEPORT, 1);

    var posix_addr: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &posix_addr);
    try bind(s, &posix_addr.any, addr_len);
    try listen(s, backlog);
    return s;
}

pub fn setsockopt(fd: std.posix.fd_t, level: i32, opt_name: u32, option: u32) !void {
    const o: []const u8 = @ptrCast(&option);
    while (true) {
        const rc = system.setsockopt(fd, level, opt_name, o.ptr, @intCast(o.len));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SetSockOpt,
        }
    }
}

pub fn accept(fd: std.posix.fd_t) !std.posix.fd_t {
    const SOCK = system.SOCK;
    while (true) {
        const rc = system.accept4(fd, null, null, SOCK.CLOEXEC | SOCK.NONBLOCK);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.AcceptFailed,
        }
    }
}

pub fn writeAll(buf: []const u8, fd: std.posix.fd_t) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const to_write = buf[written..];
        written += try write(to_write, fd);
    }
}

pub fn write(buf: []const u8, fd: std.posix.fd_t) !usize {
    return while (true) {
        const rc = system.write(
            fd,
            buf.ptr,
            buf.len,
        );

        switch (std.posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => return error.IoFailed,
        }
    };
}

pub fn pwritev2(fd: i32, iov: []const std.posix.iovec_const, offset: i64, flags: system.kernel_rwf) !usize {
    while (true) {
        const rc = system.pwritev2(fd, iov.ptr, iov.len, offset, flags);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

pub fn setNonblock(fd: std.posix.fd_t) !void {
    var flags: system.O = @bitCast(try fcntl(fd, system.F.GETFL, 0));
    flags.NONBLOCK = true;
    _ = try fcntl(fd, system.F.SETFL, @bitCast(flags));
}

pub fn close(fd: std.posix.fd_t) void {
    // What would we even do if we failed :)
    _ = system.close(fd);
}

pub fn read(fd: std.posix.fd_t, buf: []u8) !usize {
    while (true) {
        const rc = system.read(fd, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.ReadFailed,
        }
    }
}

pub fn eventfd() !std.posix.fd_t {
    while (true) {
        const EFD = system.EFD;
        const rc = system.eventfd(0, EFD.CLOEXEC | EFD.NONBLOCK);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.EventFd,
        }
    }
}

// An unfortunate evil for now. If I want to connect to www.google.com, I need
// to do a DNS lookup. libc has one, but we might not always link it. The zig
// stdlib has one, but we are forced to use std.Io to use it
//
// Since sphio generally is opting out of std.io, this is a way to dispatch the
// request to a different thread and be notified when it's complete
pub const ConnectionSpawner = struct {
    // FIXME: deinit to join all threads
    //
    io: std.Io,

    threads: sphutil.ObjectPool(ThreadStorage, usize),

    event: std.posix.fd_t,

    const ThreadStorage = struct {
        handle: std.Thread,
        completion_id: usize,
        complete: std.atomic.Value(bool),
        host_buf: [1024]u8 = undefined,
    };

    pub fn init(arena: std.mem.Allocator, io: std.Io, max_clients: usize) !ConnectionSpawner {
        return .{
            .io = io,
            .threads = try .init(
                arena,
                .invalid,
                max_clients,
                max_clients,
            ),
            .event = try eventfd(),
        };
    }

    pub fn spawn(self: *ConnectionSpawner, tmp_host: []const u8, port: u16, res: *anyerror!std.posix.fd_t, completion_id: usize) !void {
        const ts = try self.threads.acquire(.invalid);
        errdefer self.threads.release(.invalid, ts.handle);

        if (tmp_host.len > ts.val.host_buf.len) return error.HostTooLong;
        const saved_host = ts.val.host_buf[0..tmp_host.len];
        @memcpy(saved_host, tmp_host);

        ts.val.* = .{
            .handle = undefined,
            .completion_id = completion_id,
            .complete = .init(false),
        };

        ts.val.handle = try std.Thread.spawn(.{}, tcpConnectToHost, .{ self.io, saved_host, port, &ts.val.complete, self.event, res });
    }

    // Returns the next event to chain if there is one
    pub fn service(self: *ConnectionSpawner) ?usize {
        // FIXME: Maybe move read to the bottom so we don't tank the syscall in a hot loop idiot
        // Clear event
        {
            var val: u64 = 0;
            _ = read(self.event, std.mem.asBytes(&val)) catch {};
        }

        // In reality we shouldn't have many of these to iterate
        // FIXME: This is stupid cause we return every time we find one, better
        // queue needed
        var it = self.threads.iter();
        while (it.next()) |ts| {
            if (ts.val.complete.load(.monotonic)) {
                ts.val.handle.join();
                const completion_id = ts.val.completion_id;
                self.threads.release(.invalid, ts.handle);
                return completion_id;
            }
        }

        return null;
    }

    fn tcpConnectToHost(io: std.Io, host: []const u8, port: u16, complete_flag: *std.atomic.Value(bool), on_complete: std.posix.fd_t, ret: *anyerror!std.posix.fd_t) void {
        ret.* = tryTcpConnectToHost(io, host, port);

        complete_flag.store(true, .monotonic);

        const val: u64 = 1;
        writeAll(std.mem.asBytes(&val), on_complete) catch {
            std.log.err("Failed to notify connection ready\n", .{});
        };
    }

    fn tryTcpConnectToHost(io: std.Io, host: []const u8, port: u16) !std.posix.fd_t {
        const hostname = try std.Io.net.HostName.init(host);
        const s = try hostname.connect(io, port, .{
            .mode = .stream,
            .protocol = .tcp,
        });

        try setNonblock(s.socket.handle);

        return s.socket.handle;
    }
};

/// This is more of a utility thing, but pretty tied to our typical usage of
/// the sphio event loop. Each service gets allocated a block of IDs that are
/// globally unique and used as callback handles in the event loop, this is
/// just a nice lil helper to make that easy
pub const IdAlloc = struct {
    idx: usize,

    pub const init: IdAlloc = .{ .idx = 0 };

    // inclusive
    pub const Range = struct {
        start: usize,
        end: usize,
    };

    pub fn allocOne(self: *IdAlloc) usize {
        defer self.idx += 1;
        return self.idx;
    }

    pub fn allocMany(self: *IdAlloc, amount: usize) Range {
        defer self.idx += amount;
        return .{
            .start = self.idx,
            .end = self.idx + amount - 1,
        };
    }
};

pub const Loop = struct {
    fd: i32,
    num_events: usize = 0,
    event_cursor: usize = 0,
    buffered_events: [100]std.os.linux.epoll_event = undefined,

    const Self = @This();

    pub fn init() !Self {
        const rc = std.posix.system.epoll_create1(0);
        const fd = switch (std.posix.errno(rc)) {
            .SUCCESS => rc,
            else => |err| return std.posix.unexpectedErrno(err),
        };
        return .{
            .fd = @intCast(fd),
        };
    }

    const Registration = struct {
        handle: std.posix.fd_t,
        id: usize,
        read: bool,
        write: bool,
    };

    pub fn register(self: *Self, reg: Registration) !void {
        var event = makeEvent(reg.id, reg.read, reg.write);
        switch (std.posix.errno(std.posix.system.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_ADD, reg.handle, &event))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    pub fn unregister(self: *Self, handle: std.posix.fd_t) !void {
        switch (std.posix.errno(std.posix.system.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_DEL, handle, null))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    pub fn poll(self: *Self, timeout: i32) !?usize {
        if (self.event_cursor >= self.num_events) {
            const buffered_events_ptr = &self.buffered_events;
            const rc = std.posix.system.epoll_wait(self.fd, buffered_events_ptr, buffered_events_ptr.len, timeout);

            self.num_events = switch (std.posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                else => |err| return std.posix.unexpectedErrno(err),
            };

            self.event_cursor = 0;
            if (self.num_events == 0) return null;
        }

        const event = self.buffered_events[self.event_cursor];
        self.event_cursor += 1;
        return event.data.ptr;
    }

    fn makeEvent(
        handler_idx: usize,
        wants_read: bool,
        wants_write: bool,
    ) std.os.linux.epoll_event {
        var events = std.os.linux.EPOLL.ET | std.os.linux.EPOLL.HUP;
        if (wants_read) events |= std.os.linux.EPOLL.IN;
        if (wants_write) events |= std.os.linux.EPOLL.OUT;
        return std.os.linux.epoll_event{
            .events = events,
            .data = .{ .ptr = handler_idx },
        };
    }
};
