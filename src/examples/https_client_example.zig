const std = @import("std");
const sphtud = @import("sphtud");
const sphttp = sphtud.http;

const host = "www.google.com";
const max_dns_connections = 1024;

const ids = Ids.init();
const Ids = struct {
    runtime: sphtud.io.Runtime.Ids,
    request: usize,

    fn init() Ids {
        var alloc = sphtud.io.IdAlloc{ .idx = 0 };
        return .{
            .runtime = .init(&alloc),
            .request = alloc.allocOne(),
        };
    }
};

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var alloc: sphtud.alloc.Sphalloc = undefined;
    try alloc.initPinned(tpa.allocator(), "root");

    var io: sphtud.io.Runtime = undefined;
    try io.initPinned(&alloc, ids.runtime);

    var fetch: sphtud.io.SimpleHttpTls = undefined;
    try fetch.initPinned(alloc.arena(), try .parse("https://www.google.com"), &io.tls_spawner, ids.request);
    defer fetch.deinit();

    while (true) {
        const event = try io.service(ids.runtime);

        switch (event) {
            ids.request => {
                const res = try fetch.poll(&io.loop, ids.request) orelse continue;
                std.debug.print("{s}\n", .{res});
                return;
            },
            else => unreachable,
        }
    }
}
