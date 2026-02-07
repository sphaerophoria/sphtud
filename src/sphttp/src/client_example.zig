const std = @import("std");
const sphttp = @import("sphttp");

pub fn main() !void {
    var scratch_buf: [1 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    const tcp = try std.net.tcpConnectToHost(fba.allocator(), "www.google.com", 80);

    // Cannot accept headers larger than this :)
    var read_buf: [8192]u8 = undefined;
    var reader = tcp.reader(&read_buf);

    var writer_buf: [8192]u8 = undefined;
    var writer = tcp.writer(&writer_buf);

    var http_writer = sphttp.HttpWriter.init(&writer.interface);
    try http_writer.startRequest(.{
        .target = "/",
        .content_length = 0,
        .method = .GET,
    });
    try http_writer.startBody();
    try writer.interface.flush();

    var http_reader = sphttp.HttpResponseReader.init(reader.interface());
    var body_buf: [4096]u8 = undefined;

    while (true) {
        fba.end_index = 0;
        const res = try http_reader.poll(fba.allocator(), &body_buf);

        std.debug.print("status: {t}\n", .{res.header.status});
        while (true) {
            const buf = res.body_reader.peekGreedy(1) catch |e| {
                if (e == error.EndOfStream) return;
                return e;
            };
            std.debug.print("{s}\n", .{buf});
            res.body_reader.toss(buf.len);
        }
    }
}
