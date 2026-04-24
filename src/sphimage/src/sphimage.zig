const std = @import("std");
pub const png = @import("png.zig");
pub const color = @import("color.zig");
pub const ppm = @import("ppm.zig");
pub const gif = @import("gif.zig");
const sphmath = @import("sphmath");

pub fn read(alloc: std.mem.Allocator, scratch: std.mem.Allocator, r: *std.Io.Reader, options: ImageLoadOptions) !Image {
    switch (try detectType(r)) {
        .gif => {
            const seq = try gif.read(alloc, r, options);
            return seq.asImage(0);
        },
        .png => {
            return png.read(alloc, scratch, r, options);
        },
        .unknown => return error.UnknownImage,
    }
}

const ImageType = enum {
    gif,
    png,
    unknown,
};

fn detectType(r: *std.Io.Reader) !ImageType {
    // CAREFUL, detection is sorted by sequence length. Maybe we should
    // automatically sort if this gets out of hand. Likely this doesn't
    // actually matter, but imagine the case where a 4 byte file with a 2 byte
    // signature is a valid image, reading more than that would fail before we
    // detected

    if (std.mem.eql(u8, try r.peek(gif.magic.len), gif.magic)) {
        return .gif;
    }

    if (std.mem.eql(u8, try r.peek(png.magic.len), png.magic)) {
        return .png;
    }

    return .unknown;
}

pub const PixelFormat = enum(u8) {
    rgb_888_packed,
    rgba_8888,

    pub fn pixelSize(self: PixelFormat) usize {
        switch (self) {
            inline else => |t| {
                return @bitSizeOf(PixelType(t)) / 8;
            },
        }
    }
};

pub fn PixelType(comptime format: PixelFormat) type {
    switch (format) {
        .rgb_888_packed => return Rgb888Pixel,
        .rgba_8888 => return Rgba8888Pixel,
    }
}

pub const RgbF32Pixel = struct {
    r: f32,
    g: f32,
    b: f32,
};

pub const RgbaF32Pixel = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const Rgb888Pixel = packed struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn read(r: *std.Io.Reader) !Rgb888Pixel {
        const vals = try r.take(3);

        return .{
            .r = vals[0],
            .g = vals[1],
            .b = vals[2],
        };
    }

    pub inline fn from(px: anytype) Rgb888Pixel {
        if (@TypeOf(px.r) == f32) {
            return .{
                .r = f32ToU8Px(px.r),
                .g = f32ToU8Px(px.g),
                .b = f32ToU8Px(px.b),
            };
        } else {
            return .{
                .r = px.r,
                .g = px.g,
                .b = px.b,
            };
        }
    }

    pub fn tof32(self: Rgb888Pixel) RgbF32Pixel {
        return .{
            .r = u8ToF32Px(self.r),
            .g = u8ToF32Px(self.g),
            .b = u8ToF32Px(self.b),
        };
    }
};

fn u8ToF32Px(val: u8) f32 {
    const ret: f32 = @floatFromInt(val);
    return ret / 255.0;
}

fn f32ToU8Px(val: f32) u8 {
    return @intFromFloat(val * 255.0);
}

pub const Rgba8888Pixel = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn read(r: *std.Io.Reader) !Rgba8888Pixel {
        const vals = try r.take(4);

        return .{
            .r = vals[0],
            .g = vals[1],
            .b = vals[2],
            .a = vals[3],
        };
    }

    pub inline fn from(px: anytype) Rgba8888Pixel {
        if (@TypeOf(px.r) == f32) {
            return .{
                .r = f32ToU8Px(px.r),
                .g = f32ToU8Px(px.g),
                .b = f32ToU8Px(px.b),
                .a = if (@hasField(@TypeOf(px), "a")) f32ToU8Px(px.a) else 255,
            };
        } else {
            return .{
                .r = px.r,
                .g = px.g,
                .b = px.b,
                .a = if (@hasField(@TypeOf(px), "a")) px.a else 255,
            };
        }
    }

    pub fn tof32(self: Rgba8888Pixel) RgbaF32Pixel {
        return .{
            .r = u8ToF32Px(self.r),
            .g = u8ToF32Px(self.g),
            .b = u8ToF32Px(self.b),
            .a = u8ToF32Px(self.a),
        };
    }
};

// Reminder that an []Rgb888Pixel will align each pixel to a 4 byte boundary,
// which is explicitly not what we want. I guess we do it manually :)
pub fn PackedData(comptime PxType: type) type {
    return struct {
        data: []u8,

        const Self = @This();

        const short_len = @bitSizeOf(PxType) / 8;

        pub fn get(self: Self, idx: usize) PxType {
            var ret: PxType = undefined;
            const in_slice = self.getByteSlice(idx, 1);
            @memcpy(std.mem.asBytes(&ret)[0..short_len], in_slice);
            return ret;
        }

        pub fn write(self: Self, idx: usize, val: PxType) void {
            const val_short = std.mem.asBytes(&val)[0..short_len];
            @memcpy(self.data[idx * short_len ..][0..short_len], val_short);
        }

        pub fn getByteSlice(self: Self, idx: usize, num_pixels: usize) []u8 {
            return self.data[idx * short_len ..][0 .. short_len * num_pixels];
        }

        pub fn slice(self: Self, idx: usize, num_pixels: usize) Self {
            return .{
                .data = self.getByteSlice(idx, num_pixels),
            };
        }

        pub fn len(self: Self) usize {
            return self.data.len * 8 / @bitSizeOf(PxType);
        }

        pub const Iter = struct {
            i: usize,
            parent: Self,

            pub fn next(self: *Iter) ?PxType {
                if (self.i >= self.parent.len()) return null;

                defer self.i += 1;
                return self.parent.get(self.i);
            }

            pub fn write(self: *Iter, val: PxType) void {
                // Index has been stepped when we are in the loop
                self.parent.write(self.i - 1, val);
            }
        };

        pub fn iter(self: Self) Iter {
            return .{ .i = 0, .parent = self };
        }
    };
}

pub const PixelData = union(PixelFormat) {
    rgb_888_packed: PackedData(Rgb888Pixel),
    rgba_8888: PackedData(Rgba8888Pixel),

    pub fn init(format: PixelFormat, data: []u8) PixelData {
        switch (format) {
            inline else => |t| {
                return @unionInit(PixelData, @tagName(t), PackedData(PixelType(t)){ .data = data });
            },
        }
    }

    pub fn slice(self: PixelData, start_idx: usize, num_pixels: usize) PixelData {
        switch (self) {
            inline else => |data, tag| {
                return @unionInit(PixelData, @tagName(tag), data.slice(start_idx, num_pixels));
            },
        }
    }

    pub fn len(self: PixelData) usize {
        switch (self) {
            inline else => |d| {
                return d.len();
            },
        }
    }
};

pub const Colorspace = union(enum) {
    srgb,
    // RGB -> XYZ matrix
    chroma: sphmath.Mat3x3,

    pub fn asRgbToXyz(self: Colorspace) sphmath.Mat3x3 {
        switch (self) {
            .srgb => return color.srgb_to_xyz,
            .chroma => |m| return m,
        }
    }
};

pub const TransferFn = union(enum) {
    linear,
    srgb,
    gamma: f32,

    pub fn asGamma(self: TransferFn) f32 {
        return switch (self) {
            .gamma => |g| g,
            .linear => 1.0,
            // Note that srgb is not really gamma 0.45454, but I don't care
            // enough to do something different rn :)
            .srgb => 1.0 / 2.2,
        };
    }
};

pub const ImageLoadOptions = struct {
    force_pixel_format: ?PixelFormat = null,
    force_color_space: ?Colorspace = null,
    force_transfer_fn: ?TransferFn = null,
    vflip: bool = false,
};

pub const Image = struct {
    width: u32,
    data: PixelData,
    colorspace: Colorspace,
    transfer_fn: TransferFn,

    pub fn calcHeight(image: Image) usize {
        return image.data.len() / image.width;
    }
};

pub const ImageSequence = struct {
    width: u32,
    height: u32,
    data: PixelData,
    colorspace: Colorspace,
    transfer_fn: TransferFn,

    loop_count: u16,
    timesteps_ms: []u32,

    pub fn numImages(self: ImageSequence) usize {
        return self.timesteps_ms.len;
    }

    pub fn asImage(self: ImageSequence, frame_idx: usize) Image {
        return .{
            .width = self.width,
            .data = self.data.slice(frame_idx * self.width * self.height, self.width * self.height),
            .colorspace = self.colorspace,
            .transfer_fn = self.transfer_fn,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
