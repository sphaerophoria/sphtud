const std = @import("std");
const sphtud = @import("sphtud.zig");
const config = @import("config");
pub const system = std.os.linux;

pub const DnsService = @import("io/DnsService.zig");
pub const TcpSpawner = @import("io/TcpSpawner.zig");
pub const TimerService = @import("io/TimerService.zig");
pub const tls = if (config.has_ssl) @import("io/tls.zig") else void;
pub const SimpleHttpTls = if (config.has_ssl) @import("io/SimpleHttpTls.zig") else void;
pub const LimitedHttpTls = if (config.has_ssl) @import("io/LimitedHttpTls.zig") else void;

const invalid_id = std.math.maxInt(usize);

pub const Runtime = struct {
    dns_service: DnsService,
    timer_service: TimerService,
    tcp_spawner: TcpSpawner,
    tls_spawner: if (config.has_ssl) tls.Spawner else void,
    chain_buf: [256]usize,
    loop: sphtud.io.Loop,

    pub const Ids = struct {
        dns_service: sphtud.io.DnsService.Ids,
        tcp_spawner: sphtud.io.TcpSpawner.Ids,
        timer: usize,
        total: sphtud.util.IdAlloc.Range,

        pub fn init(alloc: *sphtud.io.IdAlloc) Ids {
            const start = alloc.mark();
            return .{
                .dns_service = .init(alloc, 1024),
                .tcp_spawner = .init(alloc),
                .timer = alloc.allocOne(),
                .total = start.range(),
            };
        }
    };

    pub fn initPinned(self: *Runtime, alloc: *sphtud.alloc.Sphalloc, comptime ids: Ids) !void {
        self.loop = try Loop.init(&self.chain_buf);
        self.timer_service = try .init(alloc.arena(), alloc.expansion(), &self.loop, ids.timer);
        self.dns_service = try .init(alloc, &self.loop, &self.timer_service, ids.dns_service);
        self.tcp_spawner = try .init(
            alloc.arena(),
            alloc.expansion(),
            &self.dns_service,
            &self.loop,
            ids.tcp_spawner,
        );

        self.tls_spawner = if (config.has_ssl) try .init(
            &self.tcp_spawner,
            &self.loop,
        ) else {};
    }

    pub fn service(self: *Runtime, comptime ids: Ids) !usize {
        while (true) {
            const event = try self.loop.poll(-1);
            const id = event orelse continue;

            switch (id) {
                ids.dns_service.total.start...ids.dns_service.total.end => {
                    try self.dns_service.service(id, ids.dns_service);
                },
                ids.tcp_spawner.total.start...ids.tcp_spawner.total.end => {
                    try self.tcp_spawner.service(id, ids.tcp_spawner);
                },
                ids.timer => {
                    try self.timer_service.service(&self.loop);
                },
                else => return id,
            }
        }
    }
};

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

    pub fn seekTo(self: *Reader, pos: i64) !void {
        self.interface.end = 0;
        self.interface.seek = 0;
        _ = try lseek(self.fd, pos, system.SEEK.SET);
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
        var splat_buf: [4096]u8 = undefined;
        var builder = WritevBuilder.init(&iovs, &splat_buf);
        _ = builder.pushVec(w.buffered());
        builder.pushData(data, splat);

        const n = try pwritev2(self.fd, builder.getIovs(), -1, 0);
        return w.consume(n);
    }
};

const WritevBuilder = struct {
    iovs: []std.posix.iovec_const,
    splat_buf: []u8,
    next_iov: usize,

    fn init(iovs: []std.posix.iovec_const, splat_buf: []u8) WritevBuilder {
        std.debug.assert(iovs.len > 0);
        return .{
            .iovs = iovs,
            .splat_buf = splat_buf,
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

        // memset style optimization
        if (segmented.to_splat.len == 1) {
            const per_buf_splat = @min(b.splat_buf.len, splat);
            const buf = b.splat_buf[0..per_buf_splat];
            @memset(buf, segmented.to_splat[0]);
            var remaining = splat;
            while (remaining > 0) {
                const this_buf_len = @min(remaining, per_buf_splat);
                if (b.pushVec(buf[0..this_buf_len])) break;
                remaining -= this_buf_len;
            }
        } else {
            for (0..splat) |_| {
                if (b.pushVec(segmented.to_splat)) break;
            }
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

test "WritevBuilder standard" {
    const data: []const []const u8 = &.{
        "hello",
        "world",
    };

    var iov_buf: [std.Io.Threaded.max_iovecs_len]std.posix.iovec_const = undefined;
    var splat_buf: [4096]u8 = undefined;
    var b = WritevBuilder.init(&iov_buf, &splat_buf);
    b.pushData(data, 1);
    const iovs = b.getIovs();

    try std.testing.expectEqual(2, iovs.len);
    try std.testing.expectEqualStrings("hello", iovs[0].base[0..iovs[0].len]);
    try std.testing.expectEqualStrings("world", iovs[1].base[0..iovs[1].len]);
}

test "WritevBuilder splat" {
    const data: []const []const u8 = &.{
        "hello",
        "world",
    };

    var iov_buf: [std.Io.Threaded.max_iovecs_len]std.posix.iovec_const = undefined;
    var splat_buf: [4096]u8 = undefined;
    var b = WritevBuilder.init(&iov_buf, &splat_buf);
    b.pushData(data, 4);
    const iovs = b.getIovs();

    try std.testing.expectEqual(5, iovs.len);
    try std.testing.expectEqualStrings("hello", iovs[0].base[0..iovs[0].len]);
    try std.testing.expectEqualStrings("world", iovs[1].base[0..iovs[1].len]);
    try std.testing.expectEqualStrings("world", iovs[2].base[0..iovs[2].len]);
    try std.testing.expectEqualStrings("world", iovs[3].base[0..iovs[3].len]);
    try std.testing.expectEqualStrings("world", iovs[4].base[0..iovs[4].len]);
}

test "WritevBuilder overflow" {
    const data: []const []const u8 = &.{
        "hello",
        "world",
    };

    var iov_buf: [1]std.posix.iovec_const = undefined;
    var splat_buf: [4096]u8 = undefined;
    var b = WritevBuilder.init(&iov_buf, &splat_buf);
    b.pushData(data, 4);
    const iovs = b.getIovs();

    try std.testing.expectEqual(1, iovs.len);
    try std.testing.expectEqualStrings("hello", iovs[0].base[0..iovs[0].len]);
}

test "WritevBuilder splat single char" {
    const data: []const []const u8 = &.{
        "hello",
        "world",
        "a",
    };

    var iov_buf: [std.Io.Threaded.max_iovecs_len]std.posix.iovec_const = undefined;
    var splat_buf: [4096]u8 = undefined;
    var b = WritevBuilder.init(&iov_buf, &splat_buf);
    b.pushData(data, 8000);
    const iovs = b.getIovs();

    try std.testing.expectEqual(4, iovs.len);
    try std.testing.expectEqualStrings("hello", iovs[0].base[0..iovs[0].len]);
    try std.testing.expectEqualStrings("world", iovs[1].base[0..iovs[1].len]);
    try std.testing.expectEqualStrings("a" ** 4096, iovs[2].base[0..iovs[2].len]);
    try std.testing.expectEqualStrings("a" ** 3904, iovs[3].base[0..iovs[3].len]);
}

pub fn fcntl(fd: std.posix.fd_t, op: c_int, param: c_int) !c_int {
    while (true) {
        const rc = system.fcntl(fd, op, @as(u32, @bitCast(param)));
        switch (system.errno(rc)) {
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
    switch (system.errno(rc)) {
        .SUCCESS => return,
        else => {
            std.log.err("sockopt  on {x} failed with {any}\n", .{ fd, system.errno(rc) });
            return error.GetSockOpt;
        },
    }
}

pub const BlockMode = enum {
    block,
    nonblock,
};

pub fn setBlockMode(fd: std.posix.fd_t, block_mode: BlockMode) !void {
    const flags = try fcntl(fd, system.F.GETFL, 0);
    var flags_o: system.O = @bitCast(flags);
    flags_o.NONBLOCK = if (block_mode == .block) false else true;
    _ = try fcntl(fd, system.F.SETFL, @bitCast(flags_o));
}

pub fn socket(domain: u32, typ: u32, proto: u32) !std.posix.fd_t {
    while (true) {
        const rc = system.socket(domain, typ | system.SOCK.NONBLOCK | system.SOCK.CLOEXEC, proto);
        switch (system.errno(rc)) {
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
        switch (system.errno(rc)) {
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
        switch (system.errno(rc)) {
            .SUCCESS => return true,
            .INTR => continue,
            .INPROGRESS => return false,
            .ALREADY => return error.AlreadyConnecting,
            .ISCONN => return error.AlreadyConnected,
            else => return error.Connect,
        }
    }
}

pub fn bindUnix(sockfd: c_int, addr: std.Io.net.UnixAddress) !void {
    var posix_addr: UnixAddress = undefined;
    const addr_len = addressUnixToPosix(&addr, &posix_addr);
    while (true) {
        const rc = system.bind(sockfd, &posix_addr.any, addr_len);
        switch (system.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ADDRINUSE => return error.AddressInUse,
            else => return error.Bind,
        }
    }
}
pub fn connectUnix(sockfd: c_int, addr: std.Io.net.UnixAddress) !void {
    var posix_addr: UnixAddress = undefined;
    const addr_len = addressUnixToPosix(&addr, &posix_addr);

    while (true) {
        const rc = system.connect(sockfd, &posix_addr.any, addr_len);
        switch (system.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ALREADY => return error.AlreadyConnecting,
            .ISCONN => return error.AlreadyConnected,
            else => return error.Connect,
        }
    }
}

const UnixAddress = extern union {
    any: system.sockaddr,
    un: system.sockaddr.un,
};

fn addressUnixToPosix(a: *const std.Io.net.UnixAddress, storage: *UnixAddress) system.socklen_t {
    storage.un.family = system.AF.UNIX;

    var path_len = a.path.len;

    // With the AFD API, `sockaddr.un` is purely informational, so
    // use a suffix which is usually the most relevant part of a path.
    @memcpy(storage.un.path[0..path_len], a.path);
    if (storage.un.path.len - path_len > 0) {
        @branchHint(.likely);
        storage.un.path[path_len] = 0;
        path_len += 1;
    }

    return @intCast(@offsetOf(system.sockaddr.un, "path") + path_len);
}

pub fn listen(sockfd: c_int, backlog: u32) !void {
    while (true) {
        const rc = system.listen(sockfd, backlog);
        switch (system.errno(rc)) {
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
        switch (system.errno(rc)) {
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
        switch (system.errno(rc)) {
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

        switch (system.errno(rc)) {
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
        switch (system.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

pub fn close(fd: std.posix.fd_t) void {
    // What would we even do if we failed :)
    _ = system.close(fd);
}

pub fn unlink(path: [:0]const u8) !void {
    const rc = system.unlink(path);
    switch (system.errno(rc)) {
        .SUCCESS => return,
        else => return error.Unlink,
    }
}

pub fn read(fd: std.posix.fd_t, buf: []u8) !usize {
    while (true) {
        const rc = system.read(fd, buf.ptr, buf.len);
        switch (system.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.ReadFailed,
        }
    }
}

pub fn open(path: [:0]const u8, flags: system.O, perm: system.mode_t) !std.posix.fd_t {
    const rc = system.open(path.ptr, flags, perm);
    switch (system.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.Open,
    }
}

pub fn openat(dir: std.posix.fd_t, path: [:0]const u8, flags: system.O, perm: system.mode_t) !std.posix.fd_t {
    const rc = system.openat(dir, path.ptr, flags, perm);
    switch (system.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.Open,
    }
}

pub fn ioctl(fd: std.posix.fd_t, req: u32, arg: usize) !usize {
    while (true) {
        const res = system.ioctl(fd, req, arg);
        switch (system.errno(res)) {
            .SUCCESS => return res,
            .INTR => continue,
            .INVAL => return error.Invalid,
            else => return error.Ioctl,
        }
    }
}

pub const DirIter = struct {
    fd: std.posix.fd_t,
    buffer: []align(@alignOf(usize)) u8,
    seek: usize,
    end: usize,

    pub fn init(dir_fd: std.posix.fd_t, buf: []align(@alignOf(usize)) u8) DirIter {
        return .{
            .fd = dir_fd,
            .buffer = buf,
            .seek = 0,
            .end = 0,
        };
    }

    pub const Entry = struct {
        name: [:0]const u8,
        kind: std.Io.File.Kind,
        inode: std.Io.File.INode,
    };

    pub fn next(self: *DirIter) !?Entry {
        if (self.bufferedEntry()) |e| return e;

        const rc = system.getdents64(self.fd, self.buffer.ptr, self.buffer.len);
        const len_bytes: usize = switch (system.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => return error.GetDents,
        };
        self.seek = 0;
        self.end = len_bytes;

        return self.bufferedEntry();
    }

    fn bufferedEntry(self: *DirIter) ?Entry {
        if (self.end - self.seek < @sizeOf(system.dirent64)) return null;
        const header = std.mem.bytesAsValue(system.dirent64, self.buffer[self.seek..self.end]);

        const name_ptr: [*]const u8 = &header.name;
        var name_len: usize = header.reclen - @offsetOf(system.dirent64, "name");
        name_len = std.mem.findScalar(u8, name_ptr[0..name_len], 0).?;
        self.seek += header.reclen;

        return .{
            .name = name_ptr[0..name_len :0],
            .kind = switch (header.type) {
                system.DT.BLK => .block_device,
                system.DT.CHR => .character_device,
                system.DT.DIR => .directory,
                system.DT.FIFO => .named_pipe,
                system.DT.LNK => .sym_link,
                system.DT.REG => .file,
                system.DT.SOCK => .unix_domain_socket,
                system.DT.UNKNOWN => .unknown,
                // FIXME: Should this be an error??
                else => .unknown,
            },
            .inode = header.ino,
        };
    }
};

pub fn lseek(fd: std.posix.fd_t, offs: i64, whence: usize) !usize {
    const rc = system.lseek(fd, offs, whence);
    switch (system.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.LSeek,
    }
}

pub fn statx(dir_fd: std.posix.fd_t, path: [:0]const u8, flags: u32, mask: system.STATX) !system.Statx {
    var ret: system.Statx = undefined;
    switch (system.errno(system.statx(dir_fd, path, flags, mask, &ret))) {
        .SUCCESS => return ret,
        else => return error.Statx,
    }
}

pub fn eventfd() !std.posix.fd_t {
    while (true) {
        const EFD = system.EFD;
        const rc = system.eventfd(0, EFD.CLOEXEC | EFD.NONBLOCK);
        switch (system.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.EventFd,
        }
    }
}

pub fn epoll_create1() !std.posix.fd_t {
    const rc = system.epoll_create1(0);
    const fd = switch (system.errno(rc)) {
        .SUCCESS => rc,
        else => return error.EpollCreate,
    };
    return @intCast(fd);
}

pub fn epoll_ctl(epoll_fd: i32, op: u32, fd: i32, ev: ?*system.epoll_event) !void {
    const rc = system.epoll_ctl(epoll_fd, op, fd, ev);
    switch (system.errno(rc)) {
        .SUCCESS => {},
        else => return error.EpollCtl,
    }
}

pub fn epoll_wait(epoll_fd: i32, events: [*]system.epoll_event, maxevents: u32, timeout: i32) !usize {
    while (true) {
        const rc = system.epoll_wait(epoll_fd, events, maxevents, timeout);
        switch (system.errno(rc)) {
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
    switch (system.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.TimerfdCreate,
    }
}

pub const Timeout = union(enum) {
    abs: std.Io.Timestamp,
    rel: std.Io.Duration,

    pub fn toNanoseconds(self: Timeout) i96 {
        switch (self) {
            inline else => |v| return v.toNanoseconds(),
        }
    }
};

pub fn timerfd_settime(fd: i32, timeout: Timeout, interval: std.Io.Duration) !void {
    const timeout_ns = timeout.toNanoseconds();
    const interval_ns = interval.toNanoseconds();

    var spec = system.itimerspec{
        .it_interval = .{
            .sec = @intCast(@divFloor(interval_ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(interval_ns, std.time.ns_per_s)),
        },
        .it_value = .{
            .sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
        },
    };

    const flags: system.TFD.TIMER = switch (timeout) {
        .abs => .{ .ABSTIME = true },
        .rel => .{ .ABSTIME = false },
    };
    const rc = system.timerfd_settime(fd, flags, &spec, null);
    switch (system.errno(rc)) {
        .SUCCESS => return,
        else => return error.TimerfdSettime,
    }
}

pub fn signalfd(mask: *const system.sigset_t) !std.posix.fd_t {
    const rc = system.signalfd(-1, mask, system.SFD.CLOEXEC | system.SFD.NONBLOCK);
    switch (system.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.Signalfd,
    }
}

pub fn clock_gettime(clk_id: system.clockid_t) !std.Io.Timestamp {
    var tp: system.timespec = undefined;
    const rc = system.clock_gettime(clk_id, &tp);
    switch (system.errno(rc)) {
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

pub fn nanosleep(timeout: std.Io.Duration) !void {
    const timeout_ns = timeout.toNanoseconds();
    var timespec: system.timespec = .{
        .sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s)),
    };

    while (true) {
        switch (system.errno(system.nanosleep(&timespec, &timespec))) {
            .INTR => {
                continue;
            },
            else => break,
        }
    }
}

pub fn getrandom(buf: []u8) !void {
    while (true) {
        const rc = system.getrandom(buf.ptr, buf.len, 0);
        switch (system.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.GetRandom,
        }
    }
}

pub fn sendto(fd: i32, buf: []const u8, flags: u32, addr: std.Io.net.IpAddress) !usize {
    var posix_addr: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &posix_addr);

    while (true) {
        const rc = system.sendto(fd, buf.ptr, buf.len, flags, &posix_addr.any, addr_len);
        switch (system.errno(rc)) {
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
        switch (system.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.RecvFrom,
        }
    }
}

// Copy pasted from musl #define makedev
pub fn makeDev(x: u32, y: u32) u64 {
    const x_64: u64 = @intCast(x);
    const y_64: u64 = @intCast(y);
    return (((x_64) & 0xfffff000) << 32) |
        (((x_64) & 0x00000fff) << 8) |
        (((y_64) & 0xffffff00) << 12) |
        (((y_64) & 0x000000ff));
}

pub fn fork() !std.posix.pid_t {
    const res = system.fork();
    switch (system.errno(res)) {
        .SUCCESS => return @intCast(res),
        else => return error.Fork,
    }
}

pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !noreturn {
    _ = system.execve(path, argv, envp);
    return error.Execve;
}

pub fn waitpid(pid: system.pid_t, flags: u32) !system.pid_t {
    var discard: u32 = 0;
    const res = system.waitpid(pid, &discard, flags);
    switch (system.errno(res)) {
        .SUCCESS => return @intCast(res),
        else => return error.WaitPid,
    }
}

pub const IdAlloc = @import("util.zig").IdAlloc;

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
        switch (system.errno(system.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_ADD, reg.handle, &event))) {
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

        while (true) {
            if (self.event_cursor >= self.num_events) {
                self.num_events = try epoll_wait(self.fd, &self.buffered_events, self.buffered_events.len, timeout);
                self.event_cursor = 0;

                if (self.num_events < self.buffered_events.len) {
                    @memset(self.buffered_events[self.num_events..], undefined);
                }

                if (self.num_events == 0) return null;
            }

            while (self.event_cursor < self.num_events) {
                const event = self.buffered_events[self.event_cursor];
                self.event_cursor += 1;
                if (event.data.ptr == invalid_id) continue;
                return event.data.ptr;
            }
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
