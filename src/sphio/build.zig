const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphttp = b.dependency("sphttp", .{}).module("sphttp");

    const sphio = b.addModule("sphio", .{
        .root_source_file = b.path("src/sphio.zig"),
    });

    sphio.addImport("sphutil", sphutil);
    sphio.addImport("sphalloc", sphalloc);

    const sphio_test = b.addTest(.{
        .name = "sphio_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sphio.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    sphio_test.root_module.addImport("sphutil", sphutil);
    sphio_test.root_module.addImport("sphalloc", sphalloc);

    b.installArtifact(sphio_test);

    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example/sphio_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("sphalloc", sphalloc);
    example.root_module.addImport("sphttp", sphttp);
    example.root_module.addImport("sphio", sphio);
    example.root_module.addImport("sphutil", sphutil);

    b.installArtifact(example);
}
