const std = @import("std");
const sphutil = @import("sphutil");
const sphalloc = @import("sphalloc");

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
                return b > a;
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

pub const net = struct {
    pub const Server = struct {
        server: std.net.Server,
        connection_generator: ConnectionGenerator,

        pub const ConnectionGenerator = struct {
            ptr: ?*anyopaque,
            generate_fn: *const fn (ctx: ?*anyopaque, connection: std.net.Server.Connection) anyerror!Handler,

            fn generate(self: ConnectionGenerator, connection: std.net.Server.Connection) !Handler {
                return try self.generate_fn(self.ptr, connection);
            }
        };

        pub fn init(server: std.net.Server, connection_generator: ConnectionGenerator) !Server {
            try setNonblock(server.stream);
            return .{
                .server = server,
                .connection_generator = connection_generator,
            };
        }

        const handler_vtable = Handler.VTable{
            .poll = poll,
            .close = close,
        };

        pub fn handler(self: *Server) Handler {
            return .{
                .ptr = self,
                .vtable = &handler_vtable,
                .fd = self.server.stream.handle,
            };
        }

        fn poll(ctx: ?*anyopaque, loop: *Loop) PollResult {
            const self: *Server = @ptrCast(@alignCast(ctx));
            return self.pollError(loop) catch |e| {
                std.log.debug("Failed to accept connection: {s}", .{@errorName(e)});
                return .complete;
            };
        }

        fn pollError(self: *Server, loop: *Loop) !PollResult {
            while (true) {
                const connection = self.server.accept() catch |e| {
                    if (e == error.WouldBlock) return .in_progress;
                    return e;
                };

                const conn_handler = self.connection_generator.generate(connection) catch |e| {
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
            const self: *Server = @ptrCast(@alignCast(ctx));
            self.server.stream.close();
        }
    };
};

fn setNonblock(conn: std.net.Stream) !void {
    var flags = try std.posix.fcntl(conn.handle, std.posix.F.GETFL, 0);
    var flags_s: *std.posix.O = @ptrCast(&flags);
    flags_s.NONBLOCK = true;
    _ = try std.posix.fcntl(conn.handle, std.posix.F.SETFL, flags);
}
