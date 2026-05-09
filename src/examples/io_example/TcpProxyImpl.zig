const std = @import("std");
const sphtud = @import("sphtud");
const TcpProxyImpl = @This();

pub const IoRw = struct {
    r: *std.Io.Reader,
    w: *std.Io.Writer,
};

rw: IoRw,
state: union(enum) {
    default,
    waiting_connection,
    fetching: *std.Io.Reader,
},

pub fn onConnectionCreated(client: *TcpProxyImpl, rw: IoRw) !void {
    if (client.state != .waiting_connection) return error.InvalidState;

    errdefer client.state = .default;

    var http_w = sphtud.http.HttpWriter.init(rw.w);
    try http_w.startRequest(.{
        .method = .GET,
        .target = "/",
        .content_length = 0,
    });
    try http_w.appendHeader("Connection", "close");
    try http_w.writeBody("");
    try rw.w.flush();

    client.state = .{ .fetching = rw.r };
}

const Action = union(enum) {
    create_connection: []const u8,
    close_connection,
    wait,
};

pub fn service(client: *TcpProxyImpl) !Action {
    while (true) {
        switch (client.state) {
            .default => {
                const line = try client.rw.r.takeDelimiter('\n') orelse continue;
                const command, const args = std.mem.cut(u8, line, " ") orelse .{ line, "" };

                if (std.mem.eql(u8, command, "fetch")) {
                    const host = std.mem.trim(u8, args, &std.ascii.whitespace);
                    client.state = .waiting_connection;
                    return .{
                        .create_connection = host,
                    };
                }
            },
            .waiting_connection => return .wait,
            .fetching => |r| {
                while (true) {
                    _ = try r.streamRemaining(client.rw.w);
                    client.state = .default;
                    try client.rw.w.flush();
                    return .close_connection;
                }
            },
        }
    }
}
