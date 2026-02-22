const std = @import("std");
const img = @import("sphimage.zig");
const color = @import("color.zig");
const sphmath = @import("sphmath");

const IDatMerger = @import("png/IDatMerger.zig");
const DataReader = @import("png/DataReader.zig");
const common = @import("png/common.zig");

pub const magic = &.{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub fn read(alloc: std.mem.Allocator, scratch: std.mem.Allocator, r: *std.Io.Reader, options: img.ImageLoadOptions) !img.Image {
    const image = try readImageData(alloc, scratch, r, options.force_pixel_format, options.vflip);

    if (options.force_transfer_fn == null and options.force_color_space == null) {
        return image;
    }

    const color_transform = color.makeColorTransform(image.colorspace, options.force_color_space);

    var converter = color.Converter{
        .data = image.data,
        .color_transform = color_transform,
    };
    converter.convert(image.transfer_fn, options.force_transfer_fn orelse image.transfer_fn);

    return .{
        .data = image.data,
        .colorspace = options.force_color_space orelse image.colorspace,
        .transfer_fn = options.force_transfer_fn orelse image.transfer_fn,
        .width = image.width,
    };
}

pub const Reader = struct {
    header: common.Header,
    input: *std.Io.Reader,
    outstanding_reader: union(enum) {
        data: DataReader,
        unknown: struct {
            hasher: std.hash.Crc32,
            reader: common.CrcReader,
        },
        none,
    },

    const PngSegment = union(enum) {
        data: *std.Io.Reader,
        gamma: f32,
        chrm: sphmath.Mat3x3,
        cicp: struct {
            color_primaries: u8,
            transfer_function: u8,
            matrix_coefficients: u8,
            video_full_range_flag: u8,
        },
        srgb: SrgbIntent,
        phys: PngPhys,
        unknown: struct {
            tag: [4]u8,
            reader: *std.Io.Reader,
        },
    };

    pub fn init(r: *std.Io.Reader) !Reader {
        const sig = try r.take(8);
        if (!std.mem.eql(u8, sig, magic)) return error.UnexpectedSignature;

        const header = try common.Header.read(r);

        try validateHeader(header);

        return .{
            .header = header,
            .input = r,
            .outstanding_reader = .none,
        };
    }

    // reader buf needs to be at least 1 scanline + 1 pixel bytes large
    pub fn next(self: *Reader, reader_buf: []u8) !?PngSegment {
        try self.consumeOutstanding();
        var hasher = std.hash.Crc32.init();
        const ch = try common.ChunkHeader.read(self.input, &hasher);

        switch (ch.typ) {
            .IDAT => {
                self.outstanding_reader = .{ .data = undefined };
                try self.outstanding_reader.data.initPinned(self.header, ch.len, self.input, reader_buf);
                return .{
                    .data = &self.outstanding_reader.data.reader,
                };
            },
            .IHDR => {
                return error.DuplicateHeader;
            },
            .IEND => {
                try common.validateCrc(hasher.final(), self.input);
                return null;
            },
            .cICP => {
                var helper: CrcReaderWithBuffer(4) = undefined;
                try helper.initPinned(ch, &hasher, self.input);

                const hr = helper.reader();
                const color_primaries = try hr.takeByte();
                const transfer_function = try hr.takeByte();
                const matrix_coefficients = try hr.takeByte();
                const video_full_range_flag = try hr.takeByte();

                try helper.finish();

                return .{
                    .cicp = .{
                        .color_primaries = color_primaries,
                        .transfer_function = transfer_function,
                        .matrix_coefficients = matrix_coefficients,
                        .video_full_range_flag = video_full_range_flag,
                    },
                };
            },
            .sRGB => {
                var helper: CrcReaderWithBuffer(1) = undefined;
                try helper.initPinned(ch, &hasher, self.input);

                const intent = try SrgbIntent.read(helper.reader());

                try helper.finish();

                return .{
                    .srgb = intent,
                };
            },
            .cHRM => {
                var helper: CrcReaderWithBuffer(32) = undefined;
                try helper.initPinned(ch, &hasher, self.input);

                const crcr = helper.reader();

                const whitepoint = try readChromaXY(crcr);
                const r = try readChromaXY(crcr);
                const g = try readChromaXY(crcr);
                const b = try readChromaXY(crcr);

                const mat = color.genRGBToXYZMat(r, g, b, whitepoint);

                try helper.finish();

                return .{
                    .chrm = mat,
                };
            },
            .gAMA => {
                var helper: CrcReaderWithBuffer(4) = undefined;
                try helper.initPinned(ch, &hasher, self.input);

                const gamma = try readx1000asf32(helper.reader());

                try helper.finish();

                return .{ .gamma = gamma };
            },
            .pHYs => {
                var helper: CrcReaderWithBuffer(PngPhys.size) = undefined;
                try helper.initPinned(ch, &hasher, self.input);

                const phys = try PngPhys.read(helper.reader());

                try helper.finish();

                return .{
                    .phys = phys,
                };
            },
            .unknown => |tag| {
                self.outstanding_reader = .{ .unknown = undefined };
                self.outstanding_reader.unknown.hasher = hasher;
                self.outstanding_reader.unknown.reader = .init(&self.outstanding_reader.unknown.hasher, self.input, .limited(ch.len), reader_buf);
                return .{
                    .unknown = .{
                        .tag = tag,
                        .reader = &self.outstanding_reader.unknown.reader.interface,
                    },
                };
            },
        }
    }

    pub fn consumeOutstanding(self: *Reader) !void {
        switch (self.outstanding_reader) {
            .data => |*pngr| try pngr.finish(),
            .unknown => |*ur| {
                _ = try ur.reader.interface.discardRemaining();
                try common.validateCrc(ur.hasher.final(), self.input);
            },
            .none => {},
        }
        self.outstanding_reader = .none;
    }
};

const PngPhys = struct {
    ppx: u32,
    ppy: u32,
    unit: u8,

    const size = 9;

    fn read(r: *std.Io.Reader) !PngPhys {
        return .{
            .ppx = try r.takeInt(u32, .big),
            .ppy = try r.takeInt(u32, .big),
            .unit = try r.takeByte(),
        };
    }
};

fn validateHeader(header: common.Header) !void {
    if (header.compression_method != 0) return error.UnsupportedCompressionMethod;
    if (header.bit_depth != 8 and header.bit_depth != 16) return error.InvalidBitDepth;
    if (header.filter_method != 0) return error.UnsupportedFilterMethod;
}

pub const SrgbIntent = enum {
    perceptual,
    relative_colorimetric,
    saturation,
    absolute_colorimetric,

    fn read(r: *std.Io.Reader) !SrgbIntent {
        return switch (try r.takeByte()) {
            0 => .perceptual,
            1 => .relative_colorimetric,
            2 => .saturation,
            3 => .absolute_colorimetric,
            else => return error.InvalidIntent,
        };
    }
};

fn CrcReaderWithBuffer(comptime expected_size: usize) type {
    return struct {
        crc_buf: [expected_size]u8 = undefined,
        crc_reader: common.CrcReader,
        inner_reader: *std.Io.Reader,

        fn initPinned(self: *@This(), ch: common.ChunkHeader, hasher: *std.hash.Crc32, r: *std.Io.Reader) !void {
            if (ch.len != expected_size) return error.InvalidChunk;

            self.* = .{
                .crc_reader = .init(hasher, r, .limited(ch.len), &self.crc_buf),
                .inner_reader = r,
            };
        }

        fn reader(self: *@This()) *std.Io.Reader {
            return &self.crc_reader.interface;
        }

        fn finish(self: *@This()) !void {
            try common.validateCrc(self.crc_reader.hasher.final(), self.inner_reader);
        }
    };
}

fn readx1000asf32(r: *std.Io.Reader) !f32 {
    const ret: f32 = @floatFromInt(try r.takeInt(u32, .big));
    return ret / 100000.0;
}

fn readChromaXY(r: *std.Io.Reader) !color.XY {
    return .{
        .x = try readx1000asf32(r),
        .y = try readx1000asf32(r),
    };
}

const DataReaderType = enum {
    convert_pixel_format,
    native,
    native_vflip,
};

fn resolveReaderType(in_px_format: img.PixelFormat, forced_format: ?img.PixelFormat, vflip: bool) DataReaderType {
    if (forced_format) |f| {
        if (f != in_px_format) {
            return .convert_pixel_format;
        }
    }

    if (vflip) {
        return .native_vflip;
    }

    return .native;
}

fn readImageData(alloc: std.mem.Allocator, scratch: std.mem.Allocator, r: *std.Io.Reader, forced_format: ?img.PixelFormat, vflip: bool) !img.Image {
    var pngr = try Reader.init(r);

    const pixel_size = (try pngr.header.color_type.components()) * pngr.header.bit_depth / 8;
    const scanline_buf = try scratch.alloc(u8, pixel_size * pngr.header.width * 2);

    const in_pixel_type = try pngr.header.pixelFormat();
    const reader_type = resolveReaderType(in_pixel_type, forced_format, vflip);

    switch (reader_type) {
        .convert_pixel_format => {
            const ir = try ImageReader.init(&pngr, scanline_buf);

            const out_pixel_format = forced_format orelse in_pixel_type;

            const data = try scanFormatAsFormat(
                alloc,
                in_pixel_type,
                out_pixel_format,
                pngr.header,
                ir.dr,
                vflip,
            );

            return try ir.finish(.init(out_pixel_format, data));
        },
        .native => {
            const ir = try ImageReader.init(&pngr, scanline_buf);

            const data = try alloc.alloc(u8, pngr.header.width * pngr.header.height * pixel_size);
            try ir.dr.readSliceAll(data);
            return try ir.finish(img.PixelData.init(in_pixel_type, data));
        },
        .native_vflip => {
            const ir = try ImageReader.init(&pngr, scanline_buf);

            const data = try alloc.alloc(u8, pngr.header.width * pngr.header.height * pixel_size);
            const img_height = pngr.header.height;
            const row_width = pngr.header.width * pixel_size;
            for (0..img_height) |y| {
                const dst = data[(img_height - (y + 1)) * row_width ..][0..row_width];
                try ir.dr.readSliceAll(dst);
            }

            return try ir.finish(img.PixelData.init(in_pixel_type, data));
        },
    }
}

const TransferFnBuilder = struct {
    inner: img.TransferFn,
    taken_priority: u8,

    fn init() TransferFnBuilder {
        return .{
            .inner = .srgb,
            .taken_priority = 0,
        };
    }

    fn update(self: *TransferFnBuilder, segment: Reader.PngSegment) void {
        if (self.hasPriority(segment)) |p| {
            self.taken_priority = p;
            self.inner = switch (segment) {
                .gamma => |g| .{ .gamma = g },
                .cicp, .srgb => .srgb,
                .data, .chrm, .phys, .unknown => unreachable,
            };
        }
    }

    fn pngPriority(segment: Reader.PngSegment) ?u8 {
        switch (segment) {
            .cicp => |params| {
                // Some PNGs are srgb, but only flag themselves as such through
                // the cicp header. We do not support anything else, so we only
                // take it if we see the known bt709 transfer fn
                //
                // Theoretically we could take gamma as well, but that's
                // already handled by the gamma case below
                if (params.transfer_function == 1) {
                    return 4;
                }
                return null;
            },
            .srgb => return 2,
            .gamma => return 1,
            .data, .chrm, .phys, .unknown => return null,
        }
    }

    fn hasPriority(self: *const TransferFnBuilder, segment: Reader.PngSegment) ?u8 {
        const new_prio = pngPriority(segment) orelse return null;
        if (self.taken_priority < new_prio) return new_prio;
        return null;
    }
};

const ColorspaceBuilder = struct {
    inner: img.Colorspace,
    taken_priority: u8,

    fn init() ColorspaceBuilder {
        return .{
            .inner = .srgb,
            .taken_priority = 0,
        };
    }

    fn update(self: *ColorspaceBuilder, segment: Reader.PngSegment) void {
        if (self.hasPriority(segment)) |p| {
            self.taken_priority = p;
            self.inner = switch (segment) {
                .chrm => |m| .{ .chroma = m },
                .srgb => .srgb,
                .cicp, .data, .gamma, .phys, .unknown => unreachable,
            };
        }
    }

    fn pngPriority(segment: Reader.PngSegment) ?u8 {
        switch (segment) {
            .srgb => return 2,
            .chrm => return 1,
            // NOTE: cicp unsupported
            .cicp, .data, .gamma, .phys, .unknown => return null,
        }
    }

    fn hasPriority(self: *const ColorspaceBuilder, segment: Reader.PngSegment) ?u8 {
        const new_prio = pngPriority(segment) orelse return null;
        if (self.taken_priority < new_prio) return new_prio;
        return null;
    }
};

// Different than png.Reader. This is a helper to read the data of an img.Image
const ImageReader = struct {
    transfer_fn: img.TransferFn,
    colorspace: img.Colorspace,
    dr: *std.Io.Reader,
    pngr: *Reader,
    scanline_buf: []u8,

    pub fn init(pngr: *Reader, scanline_buf: []u8) !ImageReader {
        var transfer_fn = TransferFnBuilder.init();
        var colorspace = ColorspaceBuilder.init();

        while (try pngr.next(scanline_buf)) |segment| {
            transfer_fn.update(segment);
            colorspace.update(segment);

            switch (segment) {
                .data => |dr| {
                    return .{
                        .transfer_fn = transfer_fn.inner,
                        .colorspace = colorspace.inner,
                        .dr = dr,
                        .pngr = pngr,
                        .scanline_buf = scanline_buf,
                    };
                },
                else => {},
            }
        }

        return error.NoData;
    }

    pub fn finish(self: ImageReader, data: img.PixelData) !img.Image {
        while (try self.pngr.next(self.scanline_buf)) |_| {}

        return .{
            .width = self.pngr.header.width,
            .colorspace = self.colorspace,
            .transfer_fn = self.transfer_fn,
            .data = data,
        };
    }
};

fn convertPx(comptime OutPx: type, comptime InPx: type, dr: *std.Io.Reader) !OutPx {
    const in_px = try InPx.read(dr);
    return OutPx.from(in_px);
}

fn scanTypeAsType(comptime OutPx: type, comptime InPx: type, header: common.Header, dr: *std.Io.Reader, vflip: bool, out_data: []u8) !void {
    const out_pixel_size = @bitSizeOf(OutPx) / 8;

    if (vflip) {
        for (0..header.height) |y| {
            const out_scanline_start = (header.height - (y + 1)) * header.width * out_pixel_size;
            const out_packed = img.PackedData(OutPx){ .data = out_data[out_scanline_start..] };

            for (0..header.width) |i| {
                out_packed.write(i, try convertPx(OutPx, InPx, dr));
            }
        }
    } else {
        const out_packed = img.PackedData(OutPx){ .data = out_data };
        for (0..header.height * header.width) |i| {
            out_packed.write(i, try convertPx(OutPx, InPx, dr));
        }
    }
}

fn scanFormatAsType(comptime OutPx: type, in_format: img.PixelFormat, header: common.Header, dr: *std.Io.Reader, vflip: bool, out_data: []u8) !void {
    switch (in_format) {
        inline else => |in_tag| {
            try scanTypeAsType(OutPx, img.PixelType(in_tag), header, dr, vflip, out_data);
        },
    }
}

fn scanFormatAsFormat(
    alloc: std.mem.Allocator,
    in_format: img.PixelFormat,
    out_format: img.PixelFormat,
    header: common.Header,
    dr: *std.Io.Reader,
    vflip: bool,
) ![]u8 {
    const out_pixel_size = out_format.pixelSize();
    const out_data = try alloc.alloc(u8, header.width * header.height * out_pixel_size);

    switch (out_format) {
        inline else => |out_tag| {
            try scanFormatAsType(img.PixelType(out_tag), in_format, header, dr, vflip, out_data);
        },
    }

    return out_data;
}

test "progressive read" {
    const png = @embedFile("png/res/smile.png");
    const ppm = @embedFile("png/res/smile.ppm");

    var r = std.Io.Reader.fixed(png);

    var pngr = try Reader.init(&r);

    var ppm_data = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer ppm_data.deinit();

    var ppm_writer = try img.ppm.Writer.init(pngr.header.width, pngr.header.height, &ppm_data.writer);

    var scanline_buf: [1 * 1024 * 1024]u8 = undefined;

    while (try pngr.next(&scanline_buf)) |segment| switch (segment) {
        .data => |dr| {
            switch (try pngr.header.pixelFormat()) {
                inline else => |fmt| {
                    for (0..pngr.header.width * pngr.header.height) |_| {
                        const px = try img.PixelType(fmt).read(dr);
                        try ppm_writer.writePx(px);
                    }
                },
            }
        },
        else => {},
    };

    try std.testing.expectEqualSlices(u8, ppm, ppm_data.written());
}

fn genFullReadCombos() []const img.ImageLoadOptions {
    return comptime blk: {
        const pixel_formats = std.meta.fields(img.PixelFormat);
        var combos: [(pixel_formats.len + 1) * 2]img.ImageLoadOptions = undefined;
        combos[0] = .{ .vflip = false };
        combos[1] = .{ .vflip = true };

        for (pixel_formats, 1..) |fmt, i| {
            combos[i * 2] = .{
                .force_pixel_format = @enumFromInt(fmt.value),
                .vflip = false,
            };
            combos[i * 2 + 1] = .{
                .force_pixel_format = @enumFromInt(fmt.value),
                .vflip = true,
            };
        }
        const final = combos;
        break :blk &final;
    };
}

test "full read" {
    const Sample = struct {
        source: []const u8,
        ppm: []const u8,
        ppm_flipped: []const u8,
    };

    const samples: []const Sample = &.{
        .{
            .source = @embedFile("png/res/smile.png"),
            .ppm = @embedFile("png/res/smile.ppm"),
            .ppm_flipped = @embedFile("png/res/smile_flipped.ppm"),
        },
        .{
            .source = @embedFile("png/res/ffmpeg_from_obs.png"),
            .ppm = @embedFile("png/res/ffmpeg_from_obs.ppm"),
            .ppm_flipped = @embedFile("png/res/ffmpeg_from_obs_flipped.ppm"),
        },
    };

    var scratch_buf: [1 * 1024 * 1024]u8 = undefined;
    const combos = genFullReadCombos();
    for (combos) |options| {
        for (samples) |sample| {
            var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);

            var r = std.Io.Reader.fixed(sample.source);

            const image = try read(scratch.allocator(), scratch.allocator(), &r, options);

            var ppm_data = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer ppm_data.deinit();

            try img.ppm.write(image, &ppm_data.writer);
            const expected = if (options.vflip) sample.ppm_flipped else sample.ppm;

            try std.testing.expectEqualSlices(u8, expected, ppm_data.written());
        }
    }
}
