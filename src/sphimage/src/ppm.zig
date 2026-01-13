const img = @import("sphimage.zig");
const std = @import("std");

pub const Writer = struct {
    output: *std.Io.Writer,

    pub fn init(width: usize, height: usize, w: *std.Io.Writer) !Writer {
        try w.print(
            \\P6
            \\{d} {d}
            \\255
            \\
        , .{ width, height });

        return .{
            .output = w,
        };
    }

    pub fn writePx(self: Writer, px: anytype) !void {
        try self.output.writeByte(px.r);
        try self.output.writeByte(px.g);
        try self.output.writeByte(px.b);
    }
};

pub fn write(image: img.Image, w: *std.Io.Writer) !void {
    var ppmw = try Writer.init(image.width, image.calcHeight(), w);
    switch (image.data) {
        inline else => |d| {
            var it = d.iter();
            while (it.next()) |px| {
                try ppmw.writePx(px);
            }
        },
    }
}
