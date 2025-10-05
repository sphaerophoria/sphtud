const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const mod = b.addModule("sphxml", .{
        .root_source_file = b.path("sphxml.zig"),
        .target = target,
    });

    const t = b.addTest(.{
        .root_module = mod,
    });
    const test_step = b.step("test", "");
    const test_run = b.addRunArtifact(t);
    test_step.dependOn(&test_run.step);
}
