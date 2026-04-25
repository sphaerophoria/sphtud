const std = @import("std");

pub fn build(b: *std.Build) !void {
    const sphutil = b.dependency("sphutil", .{}).module("sphutil_noalloc");

    const sphio = b.addModule("sphio", .{
        .root_source_file = b.path("src/sphio.zig"),
    });

    sphio.addImport("sphutil", sphutil);
}
