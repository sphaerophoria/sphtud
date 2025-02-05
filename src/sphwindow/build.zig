const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const sphui_dep = b.dependency("sphui", .{});
    const sphui = sphui_dep.module("sphui");
    const mod = b.addModule("sphwindow", .{
        .root_source_file = b.path("sphwindow.zig"),
        .target = target,
    });
    mod.linkSystemLibrary("glfw", .{});
    mod.link_libc = true;

    mod.addImport("sphui", sphui);
}
