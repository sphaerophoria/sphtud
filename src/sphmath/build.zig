const std = @import("std");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "");

    _ = b.addModule("sphmath", .{
        .root_source_file = b.path("sphmath.zig"),
    });

    const uts = b.addTest(.{
        .name = "sphmath_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sphmath.zig"),
            .target = b.graph.host,
        }),
    });

    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);
}
