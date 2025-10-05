const std = @import("std");
const process_include_paths = @import("build/process_include_paths.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gl_extensions = b.option([]const []const u8, "gl_extensions", "") orelse &.{};

    const gl_zig = b.addTranslateC(.{
        .root_source_file = b.path("src/gl.h"),
        .target = target,
        .optimize = optimize,
    });
    var include_it = try process_include_paths.IncludeIter.init(b.allocator);
    while (include_it.next()) |p| {
        gl_zig.addSystemIncludePath(std.Build.LazyPath{ .cwd_relative = p });
    }

    const sphmath = b.dependency("sphmath", .{});
    const sphalloc = b.dependency("sphalloc", .{});
    const sphutil = b.dependency("sphutil", .{});
    const sphxml = b.dependency("sphxml", .{});

    const loader_gen = b.addExecutable(.{
        .name = "inject_loader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/inject_loader.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    loader_gen.root_module.addImport("sphalloc", sphalloc.module("sphalloc"));
    loader_gen.root_module.addImport("sphutil", sphutil.module("sphutil"));
    loader_gen.root_module.addImport("sphxml", sphxml.module("sphxml"));

    const run_loader_gen = b.addRunArtifact(loader_gen);
    run_loader_gen.addFileArg(gl_zig.getOutput());
    const gl_with_loader = run_loader_gen.addOutputFileArg("gl.zig");

    for (gl_extensions) |extension| {
        run_loader_gen.addArg(extension);
    }

    const gl = b.createModule(.{
        .root_source_file = gl_with_loader,
        .target = target,
    });
    gl.linkSystemLibrary("GL", .{});

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
