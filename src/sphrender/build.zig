const std = @import("std");
const process_include_paths = @import("build/process_include_paths.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gl_zig = b.addTranslateC(.{
        .root_source_file = b.path("src/gl.h"),
        .target = target,
        .optimize = optimize,
    });
    var include_it = try process_include_paths.IncludeIter.init(b.allocator);
    while (include_it.next()) |p| {
        gl_zig.addSystemIncludePath(std.Build.LazyPath{ .cwd_relative = p });
    }
    const gl = gl_zig.createModule();

    gl.linkSystemLibrary("GL", .{});

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
    sphrender.addImport("gl", gl);
}
