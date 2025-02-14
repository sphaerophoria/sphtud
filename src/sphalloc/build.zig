const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sphutil_noalloc_dep = b.dependency("sphutil_noalloc", .{});

    const mod = b.addModule("sphalloc", .{
        .root_source_file = b.path("src/sphalloc.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("sphutil_noalloc", sphutil_noalloc_dep.module("sphutil_noalloc"));

    const uts = b.addTest(.{
        .name = "sphalloc",
        .root_source_file = b.path("src/sphalloc.zig"),
    });

    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);
}
