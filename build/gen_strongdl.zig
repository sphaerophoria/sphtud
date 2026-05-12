const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());

    _ = args.next();

    const fn_list_path = args.next() orelse return error.NoFnList;
    const output_path = args.next() orelse return error.NoOutput;

    const fn_list_f = try std.Io.Dir.cwd().openFile(init.io, fn_list_path, .{});
    defer fn_list_f.close(init.io);

    var fr = fn_list_f.reader(init.io, &.{});
    const fn_list = try fr.interface.allocRemaining(init.arena.allocator(), .unlimited);

    var of = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    var writer_buf: [4096]u8 = undefined;
    var fw = of.writer(init.io, &writer_buf);
    const w = &fw.interface;

    try w.writeAll(
        \\const bindings = @import("bindings");
        \\
    );

    var it = std.mem.splitScalar(u8, fn_list, '\n');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try w.print("{0s}: *const @TypeOf(bindings.{0s}),\n", .{name});
    }

    try w.flush();
}
