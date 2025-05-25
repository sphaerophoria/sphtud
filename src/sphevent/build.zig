const std = @import("std");

pub fn build(b: *std.Build) !void {
    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphevent = b.addModule("sphevent", .{
        .root_source_file = b.path("src/sphevent.zig"),
    });
    sphevent.addImport("sphutil", sphutil);
    sphevent.addImport("sphalloc", sphalloc);
}
