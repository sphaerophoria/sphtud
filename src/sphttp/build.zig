const std = @import("std");

pub fn build(b: *std.Build) !void {
    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphttp = b.addModule("sphttp", .{
        .root_source_file = b.path("src/sphttp.zig"),
    });
    sphttp.addImport("sphalloc", sphalloc);
    sphttp.addImport("sphutil", sphutil);
}
