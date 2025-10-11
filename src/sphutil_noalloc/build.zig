const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "");

    _ = b.addModule("sphutil_noalloc", .{
        .root_source_file = b.path("src/sphutil_noalloc.zig"),
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sphutil_noalloc.zig"),
            .target = b.graph.host,
        }),
    });

    b.installArtifact(tests);
    const run_test = b.addRunArtifact(tests);
    test_step.dependOn(&run_test.step);
}
