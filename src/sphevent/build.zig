const std = @import("std");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "");

    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphttp = b.dependency("sphttp", .{}).module("sphttp");
    const sphevent = b.addModule("sphevent", .{
        .root_source_file = b.path("src/sphevent.zig"),
    });
    sphevent.addImport("sphutil", sphutil);
    sphevent.addImport("sphalloc", sphalloc);
    sphevent.addImport("sphttp", sphttp);

    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/sphevent.zig"),
    });
    test_exe.root_module.addImport("sphutil", sphutil);
    test_exe.root_module.addImport("sphalloc", sphalloc);
    test_exe.root_module.addImport("sphttp", sphttp);

    const run_test = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_test.step);
}
