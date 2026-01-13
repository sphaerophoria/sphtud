const std = @import("std");
const img = @import("../sphimage.zig");

pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,

    pub fn read(r: *std.Io.Reader) !Header {
        var hasher = std.hash.Crc32.init();

        const chunk = try ChunkHeader.read(r, &hasher);

        if (chunk.typ != .IHDR) return error.NotHeader;
        if (chunk.len != 13) return error.InvalidHeaderLen;

        var crcr_buf: [16]u8 = undefined;
        var crcr = CrcReader.init(&hasher, r, .limited(chunk.len), &crcr_buf);

        const width = try crcr.interface.takeInt(u32, .big);
        const height = try crcr.interface.takeInt(u32, .big);
        const bit_depth = try crcr.interface.takeByte();

        const color_type = try crcr.interface.takeByte();

        const compression_method = try crcr.interface.takeByte();
        const filter_method = try crcr.interface.takeByte();
        const interlace_method = try crcr.interface.takeByte();

        const res = Header{
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
            .color_type = try std.meta.intToEnum(ColorType, color_type),
            .compression_method = compression_method,
            .filter_method = filter_method,
            .interlace_method = interlace_method,
        };

        try validateCrc(hasher.final(), r);

        return res;
    }

    pub fn pixelFormat(self: Header) !img.PixelFormat {
        switch (self.color_type) {
            .rgb => switch (self.bit_depth) {
                8 => return .rgb_888_packed,
                else => return error.Unimplemented,
            },
            .rgba => switch (self.bit_depth) {
                8 => return .rgba_8888,
                else => return error.Unimplemented,
            },
            else => return error.Unimplemented,
        }
    }
};

pub const ColorType = enum(u8) {
    grey = 0,
    rgb = 2,
    palette = 3,
    grey_alpha = 4,
    rgba = 6,

    pub fn components(self: ColorType) !u8 {
        return switch (self) {
            .grey => 1,
            .palette => return error.UnsupportedColorType,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

pub const ChunkType = union(enum) {
    IHDR,
    pHYs,
    gAMA,
    cHRM,
    sRGB,
    cICP,
    IDAT,
    IEND,
    unknown: [4]u8,
};

pub const ChunkHeader = struct {
    len: u32,
    typ: ChunkType,

    pub const size = 8;

    pub fn read(r: *std.Io.Reader, hasher: *std.hash.Crc32) !ChunkHeader {
        const len = try r.takeInt(u32, .big);
        const typ_s = try r.take(4);

        hasher.update(typ_s);

        const ChunkTypeE = @typeInfo(ChunkType).@"union".tag_type.?;
        const typ: ChunkTypeE = std.meta.stringToEnum(ChunkTypeE, typ_s) orelse .unknown;

        return .{
            .len = len,
            .typ = switch (typ) {
                .unknown => .{ .unknown = typ_s[0..4].* },
                inline else => |t| t,
            },
        };
    }

    pub fn format(self: ChunkHeader, w: *std.Io.Writer) !void {
        switch (self.typ) {
            .unknown => |s| try w.print("({s}?", .{s}),
            inline else => try w.print("({t}", .{self.typ}),
        }
        return w.print(": {d})", .{self.len});
    }
};

pub fn discardCrc(r: *std.Io.Reader) !void {
    try r.discardAll(4);
}

pub fn validateCrc(computed: u32, r: *std.Io.Reader) !void {
    const data_crc = try r.takeInt(u32, .big);
    if (computed != data_crc) return error.InvalidCrc;
}

pub const CrcReader = struct {
    hasher: *std.hash.Crc32,
    limited: std.Io.Reader.Limited,
    interface: std.Io.Reader,

    pub fn init(hasher: *std.hash.Crc32, r: *std.Io.Reader, limit: std.Io.Limit, buf: []u8) CrcReader {
        return .{
            .hasher = hasher,
            // Unbuffered reading should be fine, since we only ever do
            // directly pass through to writer slice
            .limited = r.limited(limit, &.{}),
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                },
                .buffer = buf,
                .end = 0,
                .seek = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CrcReader = @fieldParentPtr("interface", r);
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const written = try self.limited.interface.readSliceShort(dest);
        if (written == 0) return error.EndOfStream;
        w.advance(written);
        self.hasher.update(dest[0..written]);
        return written;
    }
};
