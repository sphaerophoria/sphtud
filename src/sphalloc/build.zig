const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("sphalloc", .{
        .root_source_file = b.path("src/sphalloc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const uts = b.addTest(.{
        .name = "sphalloc",
        .root_source_file = b.path("src/sphalloc.zig"),
    });

    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);
}
