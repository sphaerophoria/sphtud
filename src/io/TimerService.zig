const std = @import("std");
const sphio = @import("../io.zig");

fd: std.posix.fd_t,
gpa: std.mem.Allocator,
queue: std.PriorityQueue(Elem, void, Elem.compare),
next_id: u64,

const Elem = struct {
    timestamp: std.Io.Timestamp,
    id: u64,
    callback: usize,

    fn compare(_: void, a: Elem, b: Elem) std.math.Order {
        return std.math.order(a.timestamp.toNanoseconds(), b.timestamp.toNanoseconds());
    }
};

// One list of times, register the next timeout

const TimerService = @This();

const timerfd_time_source: std.posix.system.timerfd_clockid_t = .BOOTTIME;
const time_source: std.posix.system.clockid_t = .BOOTTIME;

pub fn init(gpa: std.mem.Allocator, loop: *sphio.Loop, service_id: usize) !TimerService {
    const fd = try sphio.timerfd_create(timerfd_time_source);

    try loop.register(.{
        .handle = fd,
        .id = service_id,
        .read = true,
        .write = false,
    });

    return .{
        .fd = fd,
        .gpa = gpa,
        .queue = .empty,
        .next_id = 0,
    };
}

pub const TimerHandle = struct {
    id: u64,
};

pub fn add(self: *TimerService, timeout: std.Io.Duration, callback: usize) !TimerHandle {
    // add() is expected to be called willy nilly from the rest of the system.
    // If clock_gettime was expensive, we might consider pre-fetching the time
    // and storing it as a member of TimerService to avoid the syscall. HOWEVER
    // clock_gettime is special in that the linux kernel exposes a userspace
    // accessible chunk of memory through the linux vdso, so this is basically
    // an extern fn call instead of an expensive syscall
    //
    // Screw it, we check every time
    const now = try sphio.clock_gettime(time_source);

    const timestamp = now.addDuration(timeout);

    if (self.queue.peek()) |prev_min| {
        if (timestamp.toNanoseconds() < prev_min.timestamp.toNanoseconds()) {
            try sphio.timerfd_settime(self.fd, timestamp);
        }
    } else {
        try sphio.timerfd_settime(self.fd, timestamp);
    }

    defer self.next_id +%= 1;

    try self.queue.push(self.gpa, .{
        .timestamp = timestamp,
        .id = self.next_id,
        .callback = callback,
    });

    return .{
        .id = self.next_id,
    };
}

pub fn remove(self: *TimerService, id: TimerHandle) void {
    var it = self.queue.iterator();
    var idx: usize = 0;

    while (it.next()) |elem| {
        defer idx += 1;
        if (elem.id == id.id) {
            _ = self.queue.popIndex(idx);
            return;
        }
    }
}

pub fn service(self: *TimerService, loop: *sphio.Loop) !void {
    const now = try sphio.clock_gettime(time_source);

    const next = self.queue.peek() orelse {
        try self.clearTimer();
        return;
    };

    if (next.timestamp.toNanoseconds() < now.toNanoseconds()) {
        _ = self.queue.pop();
        try loop.pushEvent(next.callback);
    }

    try sphio.timerfd_settime(self.fd, next.timestamp);
}

fn clearTimer(self: *TimerService) !void {
    var buf: [8]u8 = undefined;
    _ = try sphio.read(self.fd, &buf);
}
