const std = @import("std");

pub const Result = union(enum) {
    allowed,
    wait: std.Io.Duration,
};

pub const max_buckets = 16;

const Bucket = struct {
    start_ns: i96 = 0,
    count: u32 = 0,
};

max: u32,
num_buckets: u32,
period_ns: i96,
buckets: [max_buckets]Bucket,

const RateLimiter = @This();

pub fn init(max: u32, period: std.Io.Duration, num_buckets: u32) RateLimiter {
    std.debug.assert(num_buckets > 0 and num_buckets <= max_buckets);
    return .{
        .max = max,
        .num_buckets = num_buckets,
        .period_ns = period.toNanoseconds(),
        .buckets = @splat(.{}),
    };
}

pub fn notify(self: *RateLimiter, now: std.Io.Timestamp) void {
    const now_ns = now.toNanoseconds();
    const bucket_dur = @divFloor(self.period_ns, self.num_buckets);
    const bucket_idx = @divFloor(now_ns, bucket_dur);
    const bstart = bucket_idx * bucket_dur;
    const slot: usize = @intCast(@mod(bucket_idx, self.num_buckets));

    if (self.buckets[slot].start_ns != bstart) {
        self.buckets[slot] = .{ .start_ns = bstart, .count = 0 };
    }
    self.buckets[slot].count += 1;
}

pub fn allowed(self: *RateLimiter, now: std.Io.Timestamp) Result {
    const now_ns = now.toNanoseconds();
    const bucket_dur = @divFloor(self.period_ns, self.num_buckets);
    const threshold = now_ns - self.period_ns;

    // Per-bucket limit: ceil(max / num_buckets)
    const bucket_max = (self.max +| (self.num_buckets - 1)) / self.num_buckets;
    const current_bucket_idx = @divFloor(now_ns, bucket_dur);
    const current_bstart = current_bucket_idx * bucket_dur;
    const current_slot: usize = @intCast(@mod(current_bucket_idx, self.num_buckets));

    if (self.buckets[current_slot].start_ns == current_bstart and
        self.buckets[current_slot].count >= bucket_max)
    {
        const next_bucket_start = (current_bucket_idx + 1) * bucket_dur;
        const wait_ns = next_bucket_start - now_ns;
        return .{ .wait = std.Io.Duration.fromNanoseconds(wait_ns) };
    }

    var total: u32 = 0;
    var oldest_start: i96 = std.math.maxInt(i96);

    for (self.buckets[0..@as(usize, self.num_buckets)]) |*b| {
        if (b.count == 0) continue;
        if (b.start_ns <= threshold) {
            b.count = 0;
            continue;
        }
        total += b.count;
        if (b.start_ns < oldest_start) {
            oldest_start = b.start_ns;
        }
    }

    if (total < self.max) return .allowed;

    const expires_at = oldest_start + self.period_ns;
    const wait_ns = expires_at - now_ns;
    return .{ .wait = std.Io.Duration.fromNanoseconds(wait_ns) };
}
