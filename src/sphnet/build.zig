const std = @import("std");

pub fn build(b: *std.Build) !void {
    _ = b.addModule("sphnet", .{
        .root_source_file = b.path("sphnet.zig"),
    });
}
