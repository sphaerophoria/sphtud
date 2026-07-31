const std = @import("std");
const sphtud = @import("../sphtud.zig");
const sphio = @import("../io.zig");

const LimitedHttpTls = @This();

const time_source: std.posix.system.clockid_t = .BOOTTIME;

alloc: std.mem.Allocator,
uri: std.Uri,
params: sphtud.http.Simple.Params,
tls_spawner: *sphtud.io.tls.Spawner,
timer_service: *sphtud.io.TimerService,
rate_limiter: *sphtud.util.RateLimiter,
timer_handle: ?sphtud.io.TimerService.TimerHandle,
state: union(enum) {
    wait_rate_limit,
    fetching: sphtud.io.SimpleHttpTls,
},

pub fn initPinned(
    self: *LimitedHttpTls,
    alloc: std.mem.Allocator,
    uri: std.Uri,
    params: sphtud.http.Simple.Params,
    tls_spawner: *sphtud.io.tls.Spawner,
    timer_service: *sphtud.io.TimerService,
    rate_limiter: *sphtud.util.RateLimiter,
    service_id: usize,
) !void {
    self.* = .{
        .alloc = alloc,
        .uri = uri,
        .params = params,
        .tls_spawner = tls_spawner,
        .timer_service = timer_service,
        .rate_limiter = rate_limiter,
        .timer_handle = null,
        .state = .wait_rate_limit,
    };

    const now = try sphio.clock_gettime(time_source);
    switch (rate_limiter.allowed(now)) {
        .allowed => {
            rate_limiter.notify(now);
            self.state = .{ .fetching = undefined };
            try self.state.fetching.initPinned(alloc, uri, params, tls_spawner, service_id);
        },
        .wait => |duration| {
            self.timer_handle = try timer_service.add(duration, service_id);
        },
    }
}

pub fn deinit(self: *LimitedHttpTls) void {
    switch (self.state) {
        .wait_rate_limit => {
            if (self.timer_handle) |h| self.timer_service.remove(h);
        },
        .fetching => |*f| f.deinit(),
    }
}

pub fn poll(self: *LimitedHttpTls, loop: *sphtud.io.Loop, service_id: usize) !?[]const u8 {
    switch (self.state) {
        .wait_rate_limit => {
            if (self.timer_handle) |h| self.timer_service.remove(h);
            self.timer_handle = null;

            const now = try sphio.clock_gettime(time_source);
            switch (self.rate_limiter.allowed(now)) {
                .allowed => {
                    self.rate_limiter.notify(now);
                    self.state = .{ .fetching = undefined };
                    try self.state.fetching.initPinned(self.alloc, self.uri, self.params, self.tls_spawner, service_id);
                    return try self.state.fetching.poll(loop, service_id);
                },
                .wait => |duration| {
                    self.timer_handle = try self.timer_service.add(duration, service_id);
                    return null;
                },
            }
        },
        .fetching => |*f| return f.poll(loop, service_id),
    }
}
