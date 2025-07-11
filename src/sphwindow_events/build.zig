const std = @import("std");

pub fn build(b: *std.Build) !void {
    _ = b.addModule("sphwindow_events", .{
        .root_source_file = b.path("sphwindow_events.zig"),
    });
}
