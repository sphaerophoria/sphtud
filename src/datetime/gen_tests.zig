const std = @import("std");

const TestResult = struct {
    input: u32,
    output: []const u8,
};

fn genTzOverrideEnv(alloc: std.mem.Allocator, env: std.process.Environ) !std.process.Environ.Map {
    var map = try env.createMap(alloc);
    try map.put("TZ", "Vancouver_TZ_sample");
    try map.put("TZDIR", ".");
    return map;
}

fn makeDateArg(alloc: std.mem.Allocator, timestamp: u32) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "--date=@{d}", .{timestamp});
}

const date_fmt = "+%Y-%m-%d %H:%M:%S";

fn genUtcTest(alloc: std.mem.Allocator, scratch: std.mem.Allocator, io: std.Io, timestamp: u32) !TestResult {
    const res = try std.process.run(
        scratch,
        io,
        .{
            .argv = &.{ "date", "-u", try makeDateArg(scratch, timestamp), date_fmt },
        },
    );

    return .{
        .input = timestamp,
        .output = try alloc.dupe(u8, std.mem.trim(u8, res.stdout, &std.ascii.whitespace)),
    };
}

fn genLocalTest(alloc: std.mem.Allocator, scratch: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, timestamp: u32) !TestResult {
    const res = try std.process.run(
        scratch,
        io,
        .{
            .argv = &.{ "date", try makeDateArg(scratch, timestamp), date_fmt },
            .environ_map = env,
        },
    );

    return .{
        .input = timestamp,
        .output = try alloc.dupe(u8, std.mem.trim(u8, res.stdout, &std.ascii.whitespace)),
    };
}

fn writeTests(io: std.Io, path: []const u8, tests: []TestResult) !void {
    var out_f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out_f.close(io);

    var out_buf: [4096]u8 = undefined;
    var out_w = out_f.writer(io, &out_buf);

    var s = std.json.Stringify{
        .writer = &out_w.interface,
        .options = .{
            .whitespace = .indent_2,
        },
    };
    try s.write(tests);
    try out_w.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var alloc = std.heap.FixedBufferAllocator.init(try std.heap.page_allocator.alloc(u8, 1 * 1024 * 1024));
    var scratch = std.heap.FixedBufferAllocator.init(try std.heap.page_allocator.alloc(u8, 1 * 1024 * 1024));

    const io = init.io;

    var rng = std.Random.DefaultPrng.init(0);
    const rand = rng.random();

    const num_tests = 10000;
    var utc_tests = try std.ArrayList(TestResult).initCapacity(alloc.allocator(), num_tests);

    // 2070 me can fix any future problems
    const max_epoch = 100 * 365 * 24 * 60 * 60;

    for (0..num_tests) |_| {
        scratch.end_index = 0;
        const t = try genUtcTest(alloc.allocator(), scratch.allocator(), io, rand.intRangeAtMost(u32, 0, max_epoch));
        utc_tests.appendBounded(t) catch unreachable;
    }

    try writeTests(io, "utc_tests.json", utc_tests.items);

    var vancouver_tests = try std.ArrayList(TestResult).initCapacity(alloc.allocator(), num_tests);
    const env = try genTzOverrideEnv(alloc.allocator(), init.minimal.environ);
    for (0..num_tests) |_| {
        scratch.end_index = 0;
        const t = try genLocalTest(alloc.allocator(), scratch.allocator(), io, &env, rand.intRangeAtMost(u32, 0, max_epoch));
        vancouver_tests.appendBounded(t) catch unreachable;
    }

    try writeTests(io, "vancouver_tests.json", vancouver_tests.items);
}
