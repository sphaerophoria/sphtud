const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const sphwindow_events_dep = b.dependency("sphwindow_events", .{});
    const sphwindow_events = sphwindow_events_dep.module("sphwindow_events");
    const mod = b.addModule("sphwindow", .{
        .root_source_file = b.path("sphwindow.zig"),
        .target = target,
    });
    mod.linkSystemLibrary("glfw", .{});
    mod.link_libc = true;

    mod.addImport("sphwindow_events", sphwindow_events);
}
