const std = @import("std");
const sphtud = @import("sphtud.zig");
const system = std.os.linux;

pub const DnsService = @import("io/DnsService.zig");
pub const TcpSpawner = @import("io/TcpSpawner.zig");
pub const TimerService = @import("io/TimerService.zig");

const invalid_id = std.math.maxInt(usize);

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

pub fn getsockopt(fd: i32, level: i32, optname: u32, noalias optval: [*]u8, noalias optlen: *system.socklen_t) !void {
    const rc = system.getsockopt(fd, level, optname, optval, optlen);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        else => {
            std.log.err("sockopt  on {x} failed with {any}\n", .{ fd, std.posix.errno(rc) });
            return error.GetSockOpt;
        },
    }
}

pub fn socket(domain: u32, typ: u32, proto: u32) !std.posix.fd_t {
    while (true) {
        const rc = system.socket(domain, typ | system.SOCK.NONBLOCK | system.SOCK.CLOEXEC, proto);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.Socket,
        }
    }
}

pub fn bind(sockfd: c_int, addr: std.Io.net.IpAddress) !void {
    var posix_addr: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &posix_addr);
    while (true) {
        const rc = system.bind(sockfd, &posix_addr.any, addr_len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.Bind,
        }
    }
}

pub fn connect(sockfd: c_int, addr: std.Io.net.IpAddress) !bool {
    var posix_addr: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &posix_addr);

    while (true) {
        const rc = system.connect(sockfd, &posix_addr.any, addr_len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return true,
            .INTR => continue,
            .INPROGRESS => return false,
            .ALREADY => return error.AlreadyConnecting,
            .ISCONN => return error.AlreadyConnected,
            else => return error.Connect,
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

    try bind(s, addr);
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
        const buf_ptr: ?[*]const u8 = if (buf.len == 0) null else buf.ptr;
        const rc = system.syscall3(.write, @bitCast(@as(isize, fd)), @intFromPtr(buf_ptr), buf.len);

        switch (std.posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| {
                std.debug.print("io failure {t}\n", .{e});
                return error.IoFailed;
            },
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

// * i moved
// * doorbell rings my phone
// * i don't like the phone
// * SIP client
// * we write our own
// * zig 0.16
// * new io implementation
// * multi-thread DNS Lookup
// * personally disagree with how every single programmer does io in the entire world

pub fn open(path: [:0]const u8, flags: system.O, perm: system.mode_t) !std.posix.fd_t {
    const rc = system.open(path.ptr, flags, perm);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.Open,
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

pub fn epoll_create1() !std.posix.fd_t {
    const rc = std.posix.system.epoll_create1(0);
    const fd = switch (std.posix.errno(rc)) {
        .SUCCESS => rc,
        else => return error.EpollCreate,
    };
    return @intCast(fd);
}

pub fn epoll_ctl(epoll_fd: i32, op: u32, fd: i32, ev: ?*system.epoll_event) !void {
    const rc = std.posix.system.epoll_ctl(epoll_fd, op, fd, ev);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.EpollCtl,
    }
}

pub fn epoll_wait(epoll_fd: i32, events: [*]system.epoll_event, maxevents: u32, timeout: i32) !usize {
    while (true) {
        const rc = system.epoll_wait(epoll_fd, events, maxevents, timeout);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.EpollWait,
        }
    }
}

pub fn timerfd_create(clockid: system.timerfd_clockid_t) !std.posix.fd_t {
    const rc = system.timerfd_create(clockid, .{
        .CLOEXEC = true,
        .NONBLOCK = true,
    });
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.TimerfdCreate,
    }
}

pub fn timerfd_settime(fd: i32, timeout: std.Io.Timestamp) !void {
    const nanoseconds = timeout.toNanoseconds();

    var spec = system.itimerspec{
        .it_interval = .{
            .nsec = 0,
            .sec = 0,
        },
        .it_value = .{
            .sec = @intCast(@divFloor(nanoseconds, std.time.ns_per_s)),
            .nsec = @intCast(@mod(nanoseconds, std.time.ns_per_s)),
        },
    };

    const rc = system.timerfd_settime(fd, .{ .ABSTIME = true }, &spec, null);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.TimerfdSettime,
    }
}

pub fn signalfd(mask: *system.sigset_t) !std.posix.fd_t {
    const rc = system.signalfd(-1, mask, system.SFD.CLOEXEC | system.SFD.NONBLOCK);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.Signalfd,
    }
}

pub fn clock_gettime(clk_id: system.clockid_t) !std.Io.Timestamp {
    var tp: system.timespec = undefined;
    const rc = system.clock_gettime(clk_id, &tp);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            var ret: i96 = tp.sec;
            ret *= std.time.ns_per_s;
            ret += tp.nsec;

            return .{
                .nanoseconds = ret,
            };
        },
        else => return error.ClockGetTime,
    }
}

pub fn sendto(fd: i32, buf: []const u8, flags: u32, addr: std.Io.net.IpAddress) !usize {
    var posix_addr: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &posix_addr);

    while (true) {
        const rc = system.sendto(fd, buf.ptr, buf.len, flags, &posix_addr.any, addr_len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.SendTo,
        }
    }
}

pub fn recvfrom(
    fd: i32,
    buf: []u8,
    flags: u32,
    noalias addr: ?*system.sockaddr,
    noalias alen: ?*system.socklen_t,
) !usize {
    while (true) {
        const rc = system.recvfrom(fd, buf.ptr, buf.len, flags, addr, alen);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.RecvFrom,
        }
    }
}

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

        pub fn contains(self: Range, id: usize) bool {
            return id >= self.start and id <= self.end;
        }

        pub fn offset(self: Range, id: usize) usize {
            return id - self.start;
        }
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

    const Mark = struct {
        parent: *IdAlloc,
        idx: usize,

        pub fn range(self: Mark) Range {
            return .{
                .start = self.idx,
                .end = self.parent.idx - 1,
            };
        }
    };

    pub fn mark(self: *IdAlloc) Mark {
        return .{
            .parent = self,
            .idx = self.idx,
        };
    }
};

pub const Loop = struct {
    fd: i32,
    num_events: usize = 0,
    event_cursor: usize = 0,
    immediate_events: sphtud.util.CircularBuffer(usize),
    buffered_events: [100]std.os.linux.epoll_event = undefined,

    const Self = @This();

    pub fn init(chain_buf: []usize) !Self {
        return .{
            .immediate_events = .{
                .items = chain_buf,
                .head = 0,
                .tail = 0,
            },
            .fd = try epoll_create1(),
        };
    }

    const Registration = struct {
        handle: std.posix.fd_t,
        id: usize,
        read: bool,
        write: bool,
    };

    pub fn register(self: *Self, reg: Registration) !void {
        if (reg.id == invalid_id) return error.InvalidEvent;

        var event = makeEvent(reg.id, reg.read, reg.write);
        switch (std.posix.errno(std.posix.system.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_ADD, reg.handle, &event))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    pub fn clearEvents(self: *Self, id: usize) void {
        var it = self.immediate_events.iter();
        while (it.nextPtr()) |val| {
            if (val.* == id) {
                val.* = invalid_id;
            }
        }

        for (self.buffered_events[self.event_cursor..self.num_events]) |*val| {
            if (val.data.ptr == id) {
                val.data.ptr = invalid_id;
            }
        }
    }

    pub fn unregister(self: *Self, handle: std.posix.fd_t) !void {
        try epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_DEL, handle, null);
    }

    pub fn pushEvent(self: *Self, event: usize) !void {
        if (event == invalid_id) return error.InvalidEvent;

        try self.immediate_events.pushNoClobber(event);
    }

    pub fn poll(self: *Self, timeout: i32) !?usize {
        while (self.immediate_events.pop()) |ev| {
            if (ev == invalid_id) continue;
            return ev;
        }

        if (self.event_cursor >= self.num_events) {
            self.num_events = try epoll_wait(self.fd, &self.buffered_events, self.buffered_events.len, timeout);

            self.event_cursor = 0;
            if (self.num_events == 0) return null;
        }

        while (true) {
            const event = self.buffered_events[self.event_cursor];
            self.event_cursor += 1;
            if (event.data.ptr == invalid_id) continue;
            return event.data.ptr;
        }
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

test {
    std.testing.refAllDecls(@This());
}
