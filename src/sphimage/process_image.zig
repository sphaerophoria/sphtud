const img = @import("sphimage.zig");
const std = @import("std");
const sphmath = @import("sphmath");

const Args = struct {
    in_path: []const u8,
    out_path: []const u8,
    vflip: bool,

    fn parse() Args {
        var args = std.process.args();

        // process name
        _ = args.next();

        const Switch = enum {
            @"--in-path",
            @"--out-path",
            @"--vflip",
        };

        var in_path: ?[]const u8 = null;
        var out_path: ?[]const u8 = null;
        var vflip: bool = false;

        while (args.next()) |s| {
            const parsed_switch = std.meta.stringToEnum(Switch, s) orelse {
                help("invalid switch: {s}", .{s});
            };

            switch (parsed_switch) {
                .@"--in-path" => {
                    in_path = args.next() orelse {
                        help("missing argument to --in-path", .{});
                    };
                },
                .@"--out-path" => {
                    out_path = args.next() orelse {
                        help("missing argument to --out-path", .{});
                    };
                },
                .@"--vflip" => {
                    vflip = true;
                },
            }
        }

        return .{
            .in_path = in_path orelse help("--in-path not provided", .{}),
            .out_path = out_path orelse help("--out-path not provided", .{}),
            .vflip = vflip,
        };
    }

    fn help(comptime fmt: []const u8, args: anytype) noreturn {
        const stderr = std.fs.File.stderr();
        var stderr_w = stderr.writer(&.{});
        var w = &stderr_w.interface;

        w.print(fmt, args) catch {};

        w.print(
            \\
            \\Usage: process_image [OPTS]
            \\
            \\Required args:
            \\--in-path [str]: Where to read a png from
            \\--out-path [str]: Where to write a ppm to
            \\
            \\Optional args:
            \\--vflip: Image will be flipped if true
            \\
        , .{}) catch {};
        std.process.exit(1);
    }
};

pub fn main() !void {
    const args = Args.parse();

    const f = try std.fs.cwd().openFile(args.in_path, .{});
    defer f.close();

    var reader_buf: [4096]u8 = undefined;
    var reader = f.reader(&reader_buf);

    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);

    const image = try img.png.read(fba.allocator(), fba.allocator(), &reader.interface, .{
        .vflip = args.vflip,
    });

    const ppm_f = try std.fs.cwd().createFile(args.out_path, .{});
    defer ppm_f.close();

    var writer_buf: [4096]u8 = undefined;
    var writer = ppm_f.writer(&writer_buf);
    const w = &writer.interface;

    try img.ppm.write(image, w);

    try w.flush();
}
