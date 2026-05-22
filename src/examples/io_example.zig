const std = @import("std");
const sphtud = @import("sphtud");
const TcpProxyService = @import("io_example/TcpProxyService.zig");

const max_dns_connections = 1024;

const ids = Ids.init();
const Ids = struct {
    tcp_proxy_service: TcpProxyService.Ids,
    dns_service: sphtud.io.DnsService.Ids,
    tcp_spawner: sphtud.io.TcpSpawner.Ids,
    timer_service: usize,
    counter: usize,

    fn init() Ids {
        var alloc = sphtud.io.IdAlloc{ .idx = 0 };
        return .{
            .tcp_proxy_service = .init(&alloc),
            .dns_service = .init(&alloc, max_dns_connections),
            .tcp_spawner = .init(&alloc),
            .timer_service = alloc.allocOne(),
            .counter = alloc.allocOne(),
        };
    }
};

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var alloc: sphtud.alloc.Sphalloc = undefined;
    try alloc.initPinned(tpa.allocator(), "root");

    var chain_buf: [256]usize = undefined;
    var loop = try sphtud.io.Loop.init(&chain_buf);

    var timer = try sphtud.io.TimerService.init(alloc.arena(), alloc.expansion(), &loop, ids.timer_service);
    _ = try timer.add(.fromSeconds(1), ids.counter);

    var dns_service = try sphtud.io.DnsService.init(&alloc, &loop, &timer, ids.dns_service);
    var tcp_spawner = try sphtud.io.TcpSpawner.init(
        alloc.arena(),
        alloc.expansion(),
        &dns_service,
        &loop,
        ids.tcp_spawner,
    );

    var tcp_fetch_proxy = try TcpProxyService.init(alloc.arena(), &loop, &tcp_spawner, 8080, ids.tcp_proxy_service);

    while (true) {
        const event = try loop.poll(-1);
        const id = event orelse continue;

        switch (id) {
            ids.tcp_proxy_service.total.start...ids.tcp_proxy_service.total.end => {
                try tcp_fetch_proxy.service(id, ids.tcp_proxy_service);
            },
            ids.dns_service.total.start...ids.dns_service.total.end => {
                try dns_service.service(id, ids.dns_service);
            },
            ids.tcp_spawner.total.start...ids.tcp_spawner.total.end => {
                try tcp_spawner.service(id, ids.tcp_spawner);
            },
            ids.timer_service => {
                try timer.service(&loop);
            },
            ids.counter => {
                _ = try timer.add(.fromSeconds(1), ids.counter);
                std.debug.print("hello\n", .{});
            },
            else => unreachable,
        }
    }
}
