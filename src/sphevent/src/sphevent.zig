const std = @import("std");
const sphutil = @import("sphutil");
const sphalloc = @import("sphalloc");
const sphttp = @import("sphttp");

pub const OsHandle = std.posix.fd_t;

pub const PollResult = enum {
    in_progress,
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

pub const Loop = struct {
    fd: i32,
    handler_pool: sphutil.RuntimeSegmentedList(Handler),

    pub fn init(alloc: *sphalloc.Sphalloc) !Loop {
        const fd = try std.posix.epoll_create1(0);
        return .{
            .fd = fd,
            // 1000 connections is a ton, 1 million is insane
            .handler_pool = try .init(
                alloc.arena(),
                alloc.block_alloc.allocator(),
                1024,
                1 * 1024 * 1024,
            ),
        };
    }

    pub fn register(self: *Loop, handler: Handler) !void {
        // Make a stable pointer for epoll to call into
        try self.handler_pool.append(handler);
        const handler_idx = self.handler_pool.len - 1;

        var event = makeEvent(handler_idx);
        try std.posix.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_ADD, handler.fd, &event);
    }

    pub fn shutdown(self: *Loop) void {
        var it = self.handler_pool.iter();
        while (it.next()) |handler| {
            handler.close();
        }
    }

    pub fn wait(self: *Loop, scratch: *sphalloc.ScratchAlloc) !void {
        const num_events = 100;
        var events: [num_events]std.os.linux.epoll_event = undefined;
        const num_fds = std.posix.epoll_wait(self.fd, &events, -1);

        const checkpoint = scratch.checkpoint();
        defer scratch.restore(checkpoint);

        var to_remove = try sphutil.RuntimeBoundedArray(usize).init(scratch.allocator(), 100);

        for (events[0..num_fds]) |event| {
            const handler = self.handler_pool.get(event.data.ptr);
            switch (handler.poll(self)) {
                .in_progress => {},
                .complete => {
                    try to_remove.append(event.data.ptr);
                },
            }
        }

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
                const swapped_handler = self.handler_pool.get(handler_idx);
                var new_event = makeEvent(handler_idx);
                try std.posix.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_MOD, swapped_handler.fd, &new_event);
            }
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
                        self.ctx.serve(&self.http_reader, self.inner) catch |e| {
                            const error_code =
                                if (e == error.FileNotFound)
                                    std.http.Status.not_found
                                else
                                    std.http.Status.internal_server_error;

                            var writer = sphttp.httpWriter(self.inner.writer());
                            try writer.start(.{ .status = error_code, .content_length = 0 });
                            try writer.writeBody("");

                            return e;
                        };
                        return .complete;
                    }
                }
            }

            fn close(ctx: ?*anyopaque) void {
                const self: *Self = @ptrCast(@alignCast(ctx));
                self.inner.close();
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
            .ctx = ctx,
        };

        return ret;
    }
};

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
