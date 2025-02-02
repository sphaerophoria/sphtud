const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "");
    const sphalloc_dep = b.dependency("sphalloc", .{});

    const mod = b.addModule("sphutil", .{
        .root_source_file = b.path("src/sphutil.zig"),
    });
    mod.addImport("sphalloc", sphalloc_dep.module("sphalloc"));

    const tests = b.addTest(.{
        .root_source_file = b.path("src/sphutil.zig"),
    });
    tests.root_module.addImport("sphalloc", sphalloc_dep.module("sphalloc"));

    const run_test = b.addRunArtifact(tests);
    test_step.dependOn(&run_test.step);
}
