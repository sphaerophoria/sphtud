const std = @import("std");

pub const Result = union(enum) {
    allowed,
    wait: std.Io.Duration,
};

const Quarter = struct {
    start_ns: i96 = 0,
    count: u32 = 0,
};

max: u32,
period_ns: i96,
quarters: [4]Quarter,

const RateLimiter = @This();

pub fn init(max: u32, period: std.Io.Duration) RateLimiter {
    return .{
        .max = max,
        .period_ns = period.toNanoseconds(),
        .quarters = @splat(.{}),
    };
}

pub fn notify(self: *RateLimiter, now: std.Io.Timestamp) void {
    const now_ns = now.toNanoseconds();
    const qd = @divFloor(self.period_ns, 4);
    const quarter_idx = @divFloor(now_ns, qd);
    const qstart = quarter_idx * qd;
    const slot: usize = @intCast(@mod(quarter_idx, 4));

    if (self.quarters[slot].start_ns != qstart) {
        self.quarters[slot] = .{ .start_ns = qstart, .count = 0 };
    }
    self.quarters[slot].count += 1;
}

pub fn allowed(self: *RateLimiter, now: std.Io.Timestamp) Result {
    const now_ns = now.toNanoseconds();
    const threshold = now_ns - self.period_ns;

    var total: u32 = 0;
    var oldest_start: i96 = std.math.maxInt(i96);

    for (&self.quarters) |*q| {
        if (q.count == 0) continue;
        if (q.start_ns <= threshold) {
            q.count = 0;
            continue;
        }
        total += q.count;
        if (q.start_ns < oldest_start) {
            oldest_start = q.start_ns;
        }
    }

    if (total < self.max) return .allowed;

    const expires_at = oldest_start + self.period_ns;
    const wait_ns = expires_at - now_ns;
    return .{ .wait = std.Io.Duration.fromNanoseconds(wait_ns) };
}
