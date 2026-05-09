const sphtud = @import("../sphtud.zig");
const std = @import("std");

const Args = struct {
    in_path: []const u8,
    out_path: []const u8,
    force_linear: bool,
    flip_rg: bool,
    vflip: bool,

    fn parse(io: std.Io, args: std.process.Args) Args {
        var iter = args.iterate();

        // process name
        _ = iter.next();

        const Switch = enum {
            @"--in-path",
            @"--out-path",
            @"--force-linear",
            @"--flip-rg",
            @"--vflip",
        };

        var in_path: ?[]const u8 = null;
        var out_path: ?[]const u8 = null;
        var vflip: bool = false;
        var flip_rg: bool = false;
        var force_linear: bool = false;

        while (iter.next()) |s| {
            const parsed_switch = std.meta.stringToEnum(Switch, s) orelse {
                help(io, "invalid switch: {s}", .{s});
            };

            switch (parsed_switch) {
                .@"--in-path" => {
                    in_path = iter.next() orelse {
                        help(io, "missing argument to --in-path", .{});
                    };
                },
                .@"--out-path" => {
                    out_path = iter.next() orelse {
                        help(io, "missing argument to --out-path", .{});
                    };
                },
                .@"--vflip" => {
                    vflip = true;
                },
                .@"--force-linear" => {
                    force_linear = true;
                },
                .@"--flip-rg" => {
                    flip_rg = true;
                },
            }
        }

        return .{
            .in_path = in_path orelse help(io, "--in-path not provided", .{}),
            .out_path = out_path orelse help(io, "--out-path not provided", .{}),
            .flip_rg = flip_rg,
            .force_linear = force_linear,
            .vflip = vflip,
        };
    }

    fn help(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
        const stderr = std.Io.File.stderr();
        var stderr_w = stderr.writer(io, &.{});
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
            \\--flip-rg: Flip the red and green channels
            \\--force-linear: Do color space conversion from srgb -> linear
            \\
        , .{}) catch {};
        std.process.exit(1);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var io_impl = std.Io.Threaded.init_single_threaded;
    const io = io_impl.io();

    const args = Args.parse(io, init.args);

    const f = try std.Io.Dir.cwd().openFile(io, args.in_path, .{});
    defer f.close(io);

    var reader_buf: [4096]u8 = undefined;
    var reader = f.reader(io, &reader_buf);

    var alloc_buf: [4 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);

    var options: sphtud.img.ImageLoadOptions = .{
        .vflip = args.vflip,
    };

    if (args.force_linear) {
        options.force_transfer_fn = .linear;
    }

    if (args.flip_rg) {
        options.force_color_space = .{ .chroma = .{
            .data = .{
                0.0, 1.0, 0.0,
                1.0, 0.0, 0.0,
                0.0, 0.0, 1.0,
            },
        } };
    }
    const image = try sphtud.img.read(fba.allocator(), fba.allocator(), &reader.interface, options);

    const ppm_f = try std.Io.Dir.cwd().createFile(io, args.out_path, .{});
    defer ppm_f.close(io);

    var writer_buf: [4096]u8 = undefined;
    var writer = ppm_f.writer(io, &writer_buf);
    const w = &writer.interface;

    try sphtud.img.ppm.write(image, w);

    try w.flush();
}
