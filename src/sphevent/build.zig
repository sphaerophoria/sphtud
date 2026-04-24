const std = @import("std");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "");

    _ = b.addModule("sphevent", .{
        .root_source_file = b.path("src/sphevent.zig"),
    });

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sphevent.zig"),
            .target = b.graph.host,
        }),
    });

    const run_test = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_test.step);
}
