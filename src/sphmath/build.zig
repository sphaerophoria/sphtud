const std = @import("std");

pub fn build(b: *std.Build) !void {
    _ = b.addModule("sphmath", .{
        .root_source_file = b.path("sphmath.zig"),
    });
}
