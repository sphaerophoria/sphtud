const std = @import("std");
const sphio = @import("../io.zig");
const sphtud = @import("../sphtud.zig");

fd: std.posix.fd_t,
expansion: sphtud.util.ExpansionAlloc,
queue: sphtud.util.BinaryHeap(TimerHandle),
pool: Pool,
next_id: u64,

const Pool = sphtud.util.ObjectPool(Elem, TimerHandle);

const Elem = struct {
    timestamp: std.Io.Timestamp,
    id: u64,
    callback: usize,
};

const QueueCtx = struct {
    pool: *Pool,

    pub fn compare(self: QueueCtx, a_handle: TimerHandle, b_handle: TimerHandle) sphtud.util.binary_heap.Order {
        const a = self.pool.get(a_handle);
        const b = self.pool.get(b_handle);
        return switch (std.math.order(a.timestamp.toNanoseconds(), b.timestamp.toNanoseconds())) {
            .lt => .earlier,
            .gt => .later,
            .eq => .same,
        };
    }
};

const TimerService = @This();

const timerfd_time_source: std.posix.system.timerfd_clockid_t = .BOOTTIME;
const time_source: std.posix.system.clockid_t = .BOOTTIME;

pub fn init(arena: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc, loop: *sphio.Loop, service_id: usize) !TimerService {
    const fd = try sphio.timerfd_create(timerfd_time_source);

    try loop.register(.{
        .handle = fd,
        .id = service_id,
        .read = true,
        .write = false,
    });

    return .{
        .fd = fd,
        .pool = try .init(
            arena,
            expansion,
            16,
            1024,
        ),
        .expansion = expansion,
        .queue = try .init(
            arena,
            expansion,
            16,
            1024,
        ),
        .next_id = 0,
    };
}

pub const TimerHandle = struct {
    id: u64,

    pub fn toIdx(self: TimerHandle) usize {
        return self.id;
    }

    pub fn fromIdx(idx: usize) TimerHandle {
        return .{ .id = idx };
    }
};

pub fn add(self: *TimerService, timeout: std.Io.Duration, callback: usize) !TimerHandle {
    const timer = try self.pool.acquire(self.expansion);
    errdefer self.pool.release(self.expansion, timer.handle);

    timer.val.* = .{
        // This will be set by the upcoming rearm
        .timestamp = .zero,
        .id = self.next_id,
        .callback = callback,
    };
    self.next_id +%= 1;

    try self.rearm(timer.handle, timeout);

    return timer.handle;
}

pub fn rearm(self: *TimerService, id: TimerHandle, timeout: std.Io.Duration) !void {
    // add() is expected to be called willy nilly from the rest of the system.
    // If clock_gettime was expensive, we might consider pre-fetching the time
    // and storing it as a member of TimerService to avoid the syscall. HOWEVER
    // clock_gettime is special in that the linux kernel exposes a userspace
    // accessible chunk of memory through the linux vdso, so this is basically
    // an extern fn call instead of an expensive syscall
    //
    // Screw it, we check every time
    const now = try sphio.clock_gettime(time_source);
    const timer = self.pool.get(id);

    timer.timestamp = now.addDuration(timeout);

    if (self.timestampIsSoonest(timer.timestamp)) {
        try sphio.timerfd_settime(self.fd, timer.timestamp);
    }

    try self.queue.push(self.expansion, self.queueCtx(), id);
}

fn queueCtx(self: *TimerService) QueueCtx {
    return .{
        .pool = &self.pool,
    };
}

fn timestampIsSoonest(self: *TimerService, timestamp: std.Io.Timestamp) bool {
    const prev_min_handle = self.queue.peek() orelse return true;

    const prev_min = self.pool.get(prev_min_handle);
    return timestamp.toNanoseconds() < prev_min.timestamp.toNanoseconds();
}

pub fn remove(self: *TimerService, id: TimerHandle) void {
    var it = self.queue.iter();
    var idx: usize = 0;

    const queue_ctx = self.queueCtx();
    while (it.next()) |elem| {
        defer idx += 1;
        if (elem.id == id.id) {
            _ = self.queue.popIdx(self.expansion, queue_ctx, idx);
            break;
        }
    }

    self.pool.release(self.expansion, id);
}

pub fn service(self: *TimerService, loop: *sphio.Loop) !void {
    const now = try sphio.clock_gettime(time_source);

    const next_handle = self.queue.peek() orelse {
        try self.clearTimer();
        return;
    };

    const next = self.pool.get(next_handle);

    if (next.timestamp.toNanoseconds() < now.toNanoseconds()) {
        _ = self.queue.pop(self.expansion, self.queueCtx());
        try loop.pushEvent(next.callback);
    }

    try sphio.timerfd_settime(self.fd, next.timestamp);
}

fn clearTimer(self: *TimerService) !void {
    var buf: [8]u8 = undefined;
    _ = try sphio.read(self.fd, &buf);
}
