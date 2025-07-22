const builtin = @import("builtin");
const std = @import("std");
const sphutil = @import("sphutil");
const sphalloc = @import("sphalloc");
const sphttp = @import("sphttp");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "sphevent_options")) root.sphevent_options else .{};
pub const Options = struct {
    tcp_send_buffer_size: ?c_int = if (builtin.is_test) 500 else null,
};

pub const OsHandle = std.posix.fd_t;

pub const PollResult = union(enum) {
    in_progress,
    replace_handler: Handler,
    complete,
};

pub const Handler = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,
    fd: OsHandle,

    pub const VTable = struct {
        poll: *const fn (ctx: ?*anyopaque, loop: *Loop) PollResult,
        close: *const fn (ctx: ?*anyopaque) void,
    };

    pub fn poll(self: Handler, loop: *Loop) PollResult {
        return self.vtable.poll(self.ptr, loop);
    }

    pub fn close(self: Handler) void {
        self.vtable.close(self.ptr);
    }
};

pub fn ConnectionStateMachine(comptime CompletionCtx: type) type {
    return struct {
        handlers: []const Handler,
        handler_idx: usize,
        completion_ctx: CompletionCtx,

        const vtable = Handler.VTable{
            .poll = poll,
            .close = close,
        };

        const Self = @This();

        fn poll(ctx: ?*anyopaque, loop: *Loop) PollResult {
            const self: *Self = @ptrCast(@alignCast(ctx));

            std.debug.assert(self.handler_idx < self.handlers.len);

            switch (self.handlers[self.handler_idx].poll(loop)) {
                .in_progress => return .in_progress,
                .replace_handler => unreachable,
                .complete => {
                    self.handler_idx += 1;
                    if (self.handler_idx >= self.handlers.len) {
                        return .complete;
                    }
                    return .{
                        .replace_handler = .{
                            .ptr = self,
                            .vtable = &vtable,
                            .fd = self.handlers[self.handler_idx].fd,
                        },
                    };
                },
            }
        }

        fn close(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // This is called for every iteration, we only free at the end
            if (self.handler_idx < self.handlers.len) return;

            for (self.handlers) |handler| {
                handler.close();
            }
            self.completion_ctx.notify();
        }
    };
}

pub fn connectionStateMachine(alloc: std.mem.Allocator, handlers: []const Handler, completion_ctx: anytype) !Handler {
    const RetT = ConnectionStateMachine(@TypeOf(completion_ctx));
    const ret = try alloc.create(RetT);
    std.debug.assert(handlers.len > 0);
    ret.* = .{
        .handlers = try alloc.dupe(Handler, handlers),
        .handler_idx = 0,
        .completion_ctx = completion_ctx,
    };

    return .{
        .ptr = ret,
        .vtable = &RetT.vtable,
        .fd = handlers[0].fd,
    };
}

pub const SendFile = struct {
    src: OsHandle,
    dst: OsHandle,
    offs: usize = 0,
    len: usize,

    const vtable = Handler.VTable{
        .poll = poll,
        .close = close,
    };

    pub fn init(alloc: std.mem.Allocator, src: OsHandle, dst: OsHandle, len: usize) !*SendFile {
        switch (builtin.mode) {
            .Debug, .ReleaseSafe => {
                std.debug.assert(try getNonblock(src) == false);
                std.debug.assert(try getNonblock(dst) == true);
            },
            else => {},
        }

        const ret = try alloc.create(SendFile);
        ret.* = .{
            .src = src,
            .dst = dst,
            .len = len,
        };
        return ret;
    }

    pub fn handler(self: *SendFile) Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .fd = self.dst,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *Loop) PollResult {
        const self: *SendFile = @ptrCast(@alignCast(ctx));
        while (true) {
            self.offs += std.posix.sendfile(self.dst, self.src, self.offs, self.len, &.{}, &.{}, 0) catch |e| {
                if (e == error.WouldBlock) return .in_progress;

                std.log.err("Failed to send file: {s}", .{@errorName(e)});
                return .complete;
            };
            if (self.offs >= self.len) return .complete;
        }
    }

    fn close(_: ?*anyopaque) void {}
};

pub const FdRefBufsWriter = struct {
    fd: OsHandle,
    bufs: []const []const u8,
    buf_idx: usize = 0,
    char_idx: usize = 0,

    const vtable = Handler.VTable{
        .poll = poll,
        .close = finish,
    };

    pub fn init(alloc: std.mem.Allocator, fd: OsHandle, bufs: []const []const u8) !FdRefBufsWriter {
        return .{
            .fd = fd,
            .bufs = try alloc.dupe([]const u8, bufs),
        };
    }

    pub fn handler(self: *FdRefBufsWriter) Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .fd = self.fd,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *Loop) PollResult {
        const self: *FdRefBufsWriter = @ptrCast(@alignCast(ctx));

        while (true) {
            if (self.buf_idx >= self.bufs.len) return .complete;

            if (self.char_idx >= self.bufs[self.buf_idx].len) {
                self.buf_idx += 1;
                self.char_idx = 0;
                continue;
            }

            // pwritev would be better
            const amount_written = std.posix.write(
                self.fd,
                self.bufs[self.buf_idx][self.char_idx..],
            ) catch |e| {
                if (e == error.WouldBlock) {
                    return .in_progress;
                }

                std.log.err("Failed to write buffer: {s}", .{@errorName(e)});
                return .complete;
            };

            self.char_idx += amount_written;
        }
    }

    fn finish(_: ?*anyopaque) void {}
};

pub const Loop = struct {
    fd: i32,
    force_poll: sphutil.RuntimeSegmentedList(usize),
    handler_pool: sphutil.RuntimeSegmentedList(Handler),

    pub fn init(alloc: *sphalloc.Sphalloc) !Loop {
        const fd = try std.posix.epoll_create1(0);

        // 1000 connections is a ton, 1 million is insane
        const typical_size = 1024;
        const max_size = 1 * 1024 * 1024;

        return .{
            .fd = fd,
            .force_poll = try .init(
                alloc.arena(),
                alloc.block_alloc.allocator(),
                typical_size,
                max_size,
            ),
            .handler_pool = try .init(
                alloc.arena(),
                alloc.block_alloc.allocator(),
                typical_size,
                max_size,
            ),
        };
    }

    pub fn register(self: *Loop, handler: Handler) !void {
        // Make a stable pointer for epoll to call into
        try self.handler_pool.append(handler);
        const handler_idx = self.handler_pool.len - 1;

        var event = makeEvent(handler_idx);
        try std.posix.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_ADD, handler.fd, &event);

        try self.force_poll.append(handler_idx);
    }

    pub fn shutdown(self: *Loop) void {
        var it = self.handler_pool.iter();
        while (it.next()) |handler| {
            handler.close();
        }
    }

    pub fn wait(self: *Loop, scratch: *sphalloc.ScratchAlloc) !void {
        const checkpoint = scratch.checkpoint();
        defer scratch.restore(checkpoint);

        const num_events = 100;
        const max_update_size = num_events + self.force_poll.len;

        var to_remove = try sphutil.RuntimeBoundedArray(usize).init(scratch.allocator(), max_update_size);
        var to_add = try sphutil.RuntimeBoundedArray(Handler).init(scratch.allocator(), max_update_size);

        try self.pollForced(scratch, &to_remove, &to_add);

        var events: [num_events]std.os.linux.epoll_event = undefined;

        var num_fds: usize = 0;
        if (to_remove.items.len == 0 and to_add.items.len == 0) {
            num_fds = std.posix.epoll_wait(self.fd, &events, -1);
        }

        for (events[0..num_fds]) |event| {
            try self.pollHandler(event.data.ptr, &to_remove, &to_add, null);
        }

        try self.pollForced(scratch, &to_remove, &to_add);

        // We need to remove in reverse order so that swapRemove is always
        // looking at the right guy
        std.mem.sort(usize, to_remove.items, {}, struct {
            fn f(_: void, a: usize, b: usize) bool {
                return a > b;
            }
        }.f);

        for (to_remove.items) |handler_idx| {
            const handler = self.handler_pool.getPtr(handler_idx);

            // Remove from epoll so it doesn't call with an invalid handler
            try std.posix.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_DEL, handler.fd, null);

            // Remove and cleanup
            handler.close();
            handler.* = undefined;
            self.handler_pool.swapRemove(handler_idx);

            // After a swap remove the element that used to be on the end is pointing to the wrong handler
            if (handler_idx < self.handler_pool.len) {
                std.debug.assert(self.force_poll.len == 0);
                const swapped_handler = self.handler_pool.get(handler_idx);
                var new_event = makeEvent(handler_idx);
                try std.posix.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_MOD, swapped_handler.fd, &new_event);
            }
        }

        for (to_add.items) |handler| {
            try self.register(handler);
        }
    }

    fn pollForced(self: *Loop, scratch: *sphalloc.BufAllocator, to_remove: *sphutil.RuntimeBoundedArray(usize), to_add: *sphutil.RuntimeBoundedArray(Handler)) !void {
        while (self.force_poll.len > 0) {
            const cp = scratch.checkpoint();
            defer scratch.restore(cp);

            var to_force = try sphutil.RuntimeBoundedArray(usize).init(scratch.allocator(), self.force_poll.len);

            var it = self.force_poll.iter();
            while (it.next()) |idx| {
                try self.pollHandler(idx.*, to_remove, to_add, &to_force);
            }
            self.force_poll.clear();
            try self.force_poll.appendSlice(to_force.items);
        }
    }

    fn pollHandler(self: *Loop, idx: usize, to_remove: *sphutil.RuntimeBoundedArray(usize), to_add: *sphutil.RuntimeBoundedArray(Handler), to_force: ?*sphutil.RuntimeBoundedArray(usize)) !void {
        const handler = self.handler_pool.getPtr(idx);
        switch (handler.poll(self)) {
            .in_progress => {},
            .replace_handler => |new_handler| {
                if (new_handler.fd != handler.fd) {
                    // Will be polled on addition
                    try to_add.append(new_handler);
                    try to_remove.append(idx);
                } else {
                    handler.close();
                    handler.* = new_handler;
                    if (to_force) |tf| {
                        try tf.append(idx);
                    } else {
                        try self.force_poll.append(idx);
                    }
                }
            },
            .complete => {
                try to_remove.append(idx);
            },
        }
    }

    fn makeEvent(handler_idx: usize) std.os.linux.epoll_event {
        return std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ET | std.os.linux.EPOLL.HUP,
            .data = .{ .ptr = handler_idx },
        };
    }
};

pub fn SignalHandler(comptime Ctx: type) type {
    return struct {
        fd: OsHandle,
        ctx: Ctx,

        const Self = @This();

        const handler_vtable = Handler.VTable{
            .poll = poll,
            .close = close,
        };

        pub fn handler(self: *Self) Handler {
            return .{
                .ptr = self,
                .vtable = &handler_vtable,
                .fd = self.fd,
            };
        }

        fn poll(ctx: ?*anyopaque, _: *Loop) PollResult {
            const self: *Self = @ptrCast(@alignCast(ctx));
            while (true) {
                var info: std.os.linux.signalfd_siginfo = undefined;
                const read_bytes = std.posix.read(self.fd, std.mem.asBytes(&info)) catch |e| {
                    if (e == error.WouldBlock) return .in_progress;
                    std.log.err("Failed to read signalfd: {s}", .{@errorName(e)});
                    return .complete;
                };

                if (read_bytes == 0) return .complete;

                self.ctx.poll(info);
            }
        }

        fn close(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.ctx.close();
        }
    };
}

pub fn signalHandler(comptime signals: []const comptime_int, ctx: anytype) !SignalHandler(@TypeOf(ctx)) {
    var set: std.os.linux.sigset_t = @splat(0);
    inline for (signals) |signal| {
        std.os.linux.sigaddset(&set, signal);
    }

    const ret: isize = @bitCast(std.os.linux.sigprocmask(std.os.linux.SIG.BLOCK, &set, null));
    if (ret != 0) {
        return error.BlockSignals;
    }

    const fd = try std.posix.signalfd(-1, &set, std.os.linux.SFD.NONBLOCK);

    return .{
        .fd = fd,
        .ctx = ctx,
    };
}

pub const net = struct {
    pub fn Server(comptime Ctx: type) type {
        return struct {
            inner: std.net.Server,
            ctx: Ctx,

            const Self = @This();

            const handler_vtable = Handler.VTable{
                .poll = poll,
                .close = close,
            };

            pub fn handler(self: *Self) Handler {
                return .{
                    .ptr = self,
                    .vtable = &handler_vtable,
                    .fd = self.inner.stream.handle,
                };
            }

            fn poll(ctx: ?*anyopaque, loop: *Loop) PollResult {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.pollError(loop) catch |e| {
                    std.log.debug("Failed to accept connection: {s}", .{@errorName(e)});
                    return .complete;
                };
            }

            fn pollError(self: *Self, loop: *Loop) !PollResult {
                while (true) {
                    const connection = self.inner.accept() catch |e| {
                        if (e == error.WouldBlock) return .in_progress;
                        return e;
                    };

                    const conn_handler = self.ctx.generate(connection) catch |e| {
                        connection.stream.close();
                        return e;
                    };
                    errdefer conn_handler.close();

                    if (options.tcp_send_buffer_size) |s| {
                        var send_buf_size: c_int = s;
                        try std.posix.setsockopt(
                            connection.stream.handle,
                            std.posix.SOL.SOCKET,
                            std.posix.SO.SNDBUF,
                            std.mem.asBytes(&send_buf_size),
                        );

                        std.log.debug("Set send buffer size to {d}\n", .{s});
                    }

                    // Intentionally a little late so errdefers all work themselves out :)
                    try setNonblock(connection.stream);

                    try loop.register(conn_handler);
                }
            }

            fn close(ctx: ?*anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ctx));
                self.ctx.close();
                self.inner.stream.close();
            }
        };
    }

    pub fn server(s: std.net.Server, ctx: anytype) !Server(@TypeOf(ctx)) {
        try setNonblock(s.stream);
        return .{
            .inner = s,
            .ctx = ctx,
        };
    }

    pub fn HttpConnection(comptime Ctx: type) type {
        return struct {
            alloc: *sphalloc.Sphalloc, // owned
            scratch: *sphalloc.ScratchAlloc,
            inner: std.net.Stream,
            http_reader: sphttp.HttpReader,
            ctx: Ctx,
            state: union(enum) {
                read,
                handed_off,
                send_error: struct {
                    buf: []const u8,
                    offs: usize,
                },
            },

            const Self = @This();

            pub fn handler(self: *Self) Handler {
                return .{
                    .ptr = self,
                    .vtable = &handler_vtable,
                    .fd = self.inner.handle,
                };
            }

            const handler_vtable = Handler.VTable{
                .poll = poll,
                .close = close,
            };

            fn poll(ctx: ?*anyopaque, _: *Loop) PollResult {
                const self: *Self = @ptrCast(@alignCast(ctx));
                return self.pollError() catch |e| {
                    std.log.debug("Connection failure: {s} {}", .{ @errorName(e), @errorReturnTrace().? });
                    return .complete;
                };
            }

            fn pollError(self: *Self) !PollResult {
                switch (self.state) {
                    .read => return try self.pollRead(),
                    .handed_off => return .complete,
                    .send_error => return try self.pollWriteError(),
                }
            }

            fn pollWriteError(self: *Self) !PollResult {
                const data = switch (self.state) {
                    .send_error => |*data| data,
                    else => unreachable,
                };

                while (data.offs < data.buf.len) {
                    data.offs += self.inner.write(data.buf[data.offs..]) catch |e| {
                        if (e == error.WouldBlock) return .in_progress;
                        return e;
                    };
                }
                return .complete;
            }

            fn pollRead(self: *Self) !PollResult {
                while (true) {
                    const write_buf = try self.http_reader.getWritableArea();
                    const bytes_read = self.inner.read(write_buf) catch |e| {
                        if (e == error.WouldBlock) return .in_progress;
                        return e;
                    };

                    // State of HTTP parser will not change if there is no data, so no
                    // need to do one final run of anything below
                    if (bytes_read == 0) {
                        return .complete;
                    }

                    try self.http_reader.grow(self.scratch, bytes_read);

                    if (self.http_reader.state == .body_complete) {
                        const ret = self.ctx.serve(&self.http_reader, self.inner) catch |e| {
                            const not_found = sphttp.makeHttpHeaderComptime(.{
                                .status = .not_found,
                                .content_length = 0,
                            });

                            const internal_error = sphttp.makeHttpHeaderComptime(.{
                                .status = .internal_server_error,
                                .content_length = 0,
                            });

                            const response_buf =
                                if (e == error.FileNotFound) not_found else internal_error;

                            self.state = .{
                                .send_error = .{
                                    .buf = response_buf,
                                    .offs = 0,
                                },
                            };
                            return self.pollWriteError();
                        };
                        std.debug.assert(ret == .replace_handler);
                        self.state = .handed_off;
                        return ret;
                    }
                }
            }

            fn close(ctx: ?*anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ctx));
                switch (self.state) {
                    .send_error => self.inner.close(),
                    .read => self.inner.close(),
                    .handed_off => {},
                }
                self.alloc.deinit();
            }
        };
    }

    pub fn httpConnection(
        parent_alloc: *sphalloc.Sphalloc,
        scratch: *sphalloc.ScratchAlloc,
        inner: std.net.Stream,
        ctx: anytype,
    ) !*HttpConnection(@TypeOf(ctx)) {
        const alloc = try parent_alloc.makeSubAlloc("http_connection");
        errdefer alloc.deinit();

        const ret = try alloc.arena().create(HttpConnection(@TypeOf(ctx)));
        ret.* = .{
            .alloc = alloc,
            .scratch = scratch,
            .inner = inner,
            .http_reader = try .init(alloc),
            .state = .read,
            .ctx = ctx,
        };

        return ret;
    }
};

fn getNonblock(handle: OsHandle) !bool {
    var flags = try std.posix.fcntl(handle, std.posix.F.GETFL, 0);
    const flags_s: *std.posix.O = @ptrCast(&flags);

    return flags_s.NONBLOCK;
}

fn setNonblock(conn: std.net.Stream) !void {
    var flags = try std.posix.fcntl(conn.handle, std.posix.F.GETFL, 0);
    var flags_s: *std.posix.O = @ptrCast(&flags);
    flags_s.NONBLOCK = true;
    _ = try std.posix.fcntl(conn.handle, std.posix.F.SETFL, flags);
}

const TestConnection = struct {
    inner: std.net.Server.Connection,
    state: *State,

    const State = struct {
        alloc: std.mem.Allocator,
        received_data: [4096]u8 = undefined,
        received_len: usize = 0,

        fn deinit(self: *State) void {
            self.received_data.deinit();
        }
    };

    const vtable = Handler.VTable{
        .poll = poll,
        .close = close,
    };

    fn handler(self: *TestConnection) Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .fd = self.inner.stream.handle,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *Loop) PollResult {
        const self: *TestConnection = @ptrCast(@alignCast(ctx));
        self.state.received_len += self.inner.stream.read(self.state.received_data[self.state.received_len..]) catch unreachable;
        return .complete;
    }

    fn close(ctx: ?*anyopaque) void {
        const self: *TestConnection = @ptrCast(@alignCast(ctx));
        self.inner.stream.close();
        self.state.alloc.destroy(self);
    }
};

const TestConnectionGenerator = struct {
    state: *TestConnection.State,
    is_closed: bool = false,

    pub fn generate(self: *TestConnectionGenerator, conn: std.net.Server.Connection) !Handler {
        const ret = try self.state.alloc.create(TestConnection);
        ret.* = .{
            .state = self.state,
            .inner = conn,
        };
        return ret.handler();
    }

    pub fn close(self: *TestConnectionGenerator) void {
        self.is_closed = true;
    }
};

test "TCP loopback" {
    var tpa = sphalloc.TinyPageAllocator(100){};
    var root_alloc: sphalloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");
    defer root_alloc.deinit();

    var scratch = sphalloc.ScratchAlloc.init(try root_alloc.arena().alloc(u8, 4096));

    const addy = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 42069);
    const std_server = try addy.listen(.{
        .reuse_port = true,
    });

    var state = TestConnection.State{
        .alloc = std.testing.allocator,
        .received_data = undefined,
    };

    var connection_gen = TestConnectionGenerator{ .state = &state };
    var async_server = try net.server(std_server, &connection_gen);

    const thread_handle = try std.Thread.spawn(.{}, struct {
        fn f(conn_addy: std.net.Address) !void {
            const conn = try std.net.tcpConnectToAddress(conn_addy);
            defer conn.close();
            try conn.writeAll("Hello world");
        }
    }.f, .{addy});
    thread_handle.detach();

    var loop = try Loop.init(&root_alloc);
    try loop.register(async_server.handler());

    while (state.received_len == 0) {
        try loop.wait(&scratch);
    }

    loop.shutdown();

    try std.testing.expectEqual(11, state.received_len);
    try std.testing.expectEqualStrings("Hello world", state.received_data[0..11]);
    try std.testing.expectEqual(true, connection_gen.is_closed);
}
