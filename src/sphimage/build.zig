const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "process_image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("process_image.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const sphmath_dep = b.dependency("sphmath", .{});
    const sphmath = sphmath_dep.module("sphmath");
    exe.root_module.addImport("sphmath", sphmath);

    const sphimage = b.addModule(
        "sphimage",
        .{
            .root_source_file = b.path("sphimage.zig"),
        },
    );
    sphimage.addImport("sphmath", sphmath);

    const tests = b.addTest(.{
        .name = "image_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sphimage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("sphmath", sphmath);
    b.installArtifact(tests);
}
