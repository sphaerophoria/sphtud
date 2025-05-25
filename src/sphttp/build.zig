const std = @import("std");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "");

    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphttp = b.addModule("sphttp", .{
        .root_source_file = b.path("src/sphttp.zig"),
    });
    sphttp.addImport("sphalloc", sphalloc);
    sphttp.addImport("sphutil", sphutil);

    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/sphttp.zig"),
    });
    test_exe.root_module.addImport("sphalloc", sphalloc);
    test_exe.root_module.addImport("sphutil", sphutil);

    const test_runner = b.addRunArtifact(test_exe);
    test_step.dependOn(&test_runner.step);
}
