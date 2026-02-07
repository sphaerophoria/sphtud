const std = @import("std");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "");
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphttp = b.addModule("sphttp", .{
        .root_source_file = b.path("src/sphttp.zig"),
    });
    sphttp.addImport("sphalloc", sphalloc);
    sphttp.addImport("sphutil", sphutil);

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sphttp.zig"),
            .target = b.graph.host,
        }),
    });
    test_exe.root_module.addImport("sphalloc", sphalloc);
    test_exe.root_module.addImport("sphutil", sphutil);

    const test_runner = b.addRunArtifact(test_exe);
    test_step.dependOn(&test_runner.step);

    const example = b.addExecutable(.{
        .name = "client_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client_example.zig"),
            .target = target,
            .optimize = opt,
        }),
    });
    example.root_module.addImport("sphttp", sphttp);
    b.installArtifact(example);

    const server_example = b.addExecutable(.{
        .name = "server_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server_example.zig"),
            .target = target,
            .optimize = opt,
        }),
    });
    server_example.root_module.addImport("sphttp", sphttp);
    b.installArtifact(server_example);
}
