const builtin = @import("builtin");
const std = @import("std");

pub const OsHandle = std.posix.fd_t;

pub const Loop2 = struct {
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
        handle: OsHandle,
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

    pub fn unregister(self: *Self, handle: OsHandle) !void {
        try std.posix.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_DEL, handle, null);
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
