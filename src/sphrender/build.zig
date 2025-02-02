const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const sphmath = b.dependency("sphmath", .{});
    const sphalloc = b.dependency("sphalloc", .{});
    const sphutil = b.dependency("sphutil", .{});
    const sphrender = b.addModule("sphrender", .{
        .root_source_file = b.path("src/sphrender.zig"),
        .target = target,
    });
    sphrender.link_libc = true;
    sphrender.linkSystemLibrary("GL", .{});
    sphrender.addImport("sphmath", sphmath.module("sphmath"));
    sphrender.addImport("sphalloc", sphalloc.module("sphalloc"));
    sphrender.addImport("sphutil", sphutil.module("sphutil"));
}
