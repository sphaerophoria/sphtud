const std = @import("std");
const sphtud = @import("sphtud");
const sphttp = sphtud.http;

pub fn main() !void {
    var scratch_buf: [1 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);

    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const addr = std.Io.net.IpAddress{
        .ip4 = .{
            .bytes = .{ 0, 0, 0, 0 },
            .port = 9943,
        },
    };
    var serv = try addr.listen(io, .{
        .reuse_address = true,
    });

    var read_buf: [8192]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    while (true) {
        const conn = try serv.accept(io);

        var reader = conn.reader(io, &read_buf);
        var writer = conn.writer(io, &write_buf);

        var req_reader = sphttp.HttpRequestReader.init(&reader.interface);
        var response = sphttp.HttpWriter.init(&writer.interface);

        while (true) {
            const req = req_reader.poll(fba.allocator(), &body_buf) catch |e| {
                if (e == error.EndOfStream) break;
                return e;
            };

            std.debug.print("Got {t} on {s}\n", .{ req.header.method, req.header.target });

            const body = "hello world";
            try response.startResponse(.{
                .content_length = body.len,
                .content_type = "application/text",
                .status = .ok,
            });
            try response.writeBody(body);
            try writer.interface.flush();
        }
    }
}
