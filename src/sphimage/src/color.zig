const std = @import("std");
const img = @import("sphimage.zig");
const sphmath = @import("sphmath");

pub const XYY = struct {
    x: f32,
    y: f32,
    Y: f32,
};

pub const XY = struct {
    x: f32,
    y: f32,
};

pub const XYZ = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn fromxyy(in: XYY) XYZ {
        return .{ .x = in.x * in.Y / in.y, .y = in.Y, .z = (1 - in.x - in.y) * in.Y / in.y };
    }
};

pub const srgb_to_xyz = sphmath.Mat3x3{
    .data = .{
        0.4124, 0.3576, 0.1805,
        0.2126, 0.7152, 0.0722,
        0.0193, 0.1192, 0.9505,
    },
};
pub const xyz_to_srgb = srgb_to_xyz.invert();

pub const bradford = sphmath.Mat3x3{
    .data = .{
        0.8951,  0.2664,  -0.1614,
        -0.7502, 1.7135,  0.0367,
        0.0389,  -0.0685, 1.0296,
    },
};
pub const bradford_inv = bradford.invert();

pub fn genRGBToXYZMat(r: XY, g: XY, b: XY, whitepoint: XY) sphmath.Mat3x3 {
    const ir_xyz = XYZ.fromxyy(.{ .x = r.x, .y = r.y, .Y = 1.0 });
    const ig_xyz = XYZ.fromxyy(.{ .x = g.x, .y = g.y, .Y = 1.0 });
    const ib_xyz = XYZ.fromxyy(.{ .x = b.x, .y = b.y, .Y = 1.0 });

    const interm_mat = sphmath.Mat3x3{
        .data = .{
            ir_xyz.x, ig_xyz.x, ib_xyz.x,
            ir_xyz.y, ig_xyz.y, ib_xyz.y,
            ir_xyz.z, ig_xyz.z, ib_xyz.z,
        },
    };

    const wtpt_xyz = XYZ.fromxyy(.{ .x = whitepoint.x, .y = whitepoint.y, .Y = 1.0 });

    const inv_interm_mat = interm_mat.invert();

    const actual_ys = inv_interm_mat.mul(.{ wtpt_xyz.x, wtpt_xyz.y, wtpt_xyz.z });

    const actual_r_xyz = XYZ.fromxyy(.{
        .x = r.x,
        .y = r.y,
        .Y = actual_ys[0],
    });
    const actual_g_xyz = XYZ.fromxyy(.{
        .x = g.x,
        .y = g.y,
        .Y = actual_ys[1],
    });

    const actual_b_xyz = XYZ.fromxyy(.{
        .x = b.x,
        .y = b.y,
        .Y = actual_ys[2],
    });

    return .{
        .data = .{
            actual_r_xyz.x, actual_g_xyz.x, actual_b_xyz.x,
            actual_r_xyz.y, actual_g_xyz.y, actual_b_xyz.y,
            actual_r_xyz.z, actual_g_xyz.z, actual_b_xyz.z,
        },
    };
}

test "genRGBToXYZMat" {
    // Using the srgb values we should get the srgb matrix

    const mat = genRGBToXYZMat(
        .{ .x = 0.64, .y = 0.33 },
        .{ .x = 0.3, .y = 0.6 },
        .{ .x = 0.15, .y = 0.06 },
        .{ .x = 0.3127, .y = 0.329 },
    );

    for (srgb_to_xyz.data, mat.data) |e, c| {
        try std.testing.expectApproxEqAbs(e, c, 0.0001);
    }
}

pub fn genColorTransform(in_rgb_to_xyz: sphmath.Mat3x3, out_rgb_to_xyz: sphmath.Mat3x3) sphmath.Mat3x3 {
    const out_rgb_to_lms = bradford.matmul(out_rgb_to_xyz);
    const in_rgb_to_lms = bradford.matmul(in_rgb_to_xyz);

    const in_whitepoint = in_rgb_to_lms.mul(.{ 1, 1, 1 });
    const out_whitepoint = out_rgb_to_lms.mul(.{ 1, 1, 1 });

    const scale_mat = sphmath.Mat3x3{
        .data = .{
            out_whitepoint[0] / in_whitepoint[0], 0,                                    0,
            0,                                    out_whitepoint[1] / in_whitepoint[1], 0,
            0,                                    0,                                    out_whitepoint[2] / in_whitepoint[2],
        },
    };

    return out_rgb_to_lms.invert()
        .matmul(scale_mat)
        .matmul(in_rgb_to_lms);
}

// Ideally we have another test for this but I don't want to :)
test "genColorTransform identity" {
    const no_scale = genColorTransform(srgb_to_xyz, srgb_to_xyz);
    const identity = sphmath.Mat3x3{};

    for (no_scale.data, identity.data) |s, e| {
        try std.testing.expectApproxEqAbs(e, s, 0.001);
    }
}

pub fn srgbToLinear(val: f32) f32 {
    if (val <= 0.04045) {
        return val / 12.92;
    } else {
        return std.math.pow(f32, (val + 0.055) / 1.055, 2.4);
    }
}

pub fn linearToSrgb(val: f32) f32 {
    if (val <= 0.0031308) {
        return 12.92 * val;
    } else {
        return std.math.pow(f32, val, 1.0 / 2.4) * 1.055 - 0.055;
    }
}

pub fn makeColorTransform(in_colorspace: img.Colorspace, desired_color_space_opt: ?img.Colorspace) sphmath.Mat3x3 {
    const desired_color_space = desired_color_space_opt orelse return .{};
    return genColorTransform(in_colorspace.asRgbToXyz(), desired_color_space.asRgbToXyz());
}

pub const Converter = struct {
    data: img.PixelData,
    color_transform: sphmath.Mat3x3,

    const GammaAdjustment = struct {
        source_gamma: f32,
        dest_gamma: f32,

        pub fn apply(self: GammaAdjustment, val: f32) f32 {
            return std.math.pow(f32, val, self.dest_gamma / self.source_gamma);
        }
    };

    const Identity = struct {
        pub fn apply(val: f32) f32 {
            return val;
        }
    };

    const SrgbToLinear = struct {
        pub fn apply(val: f32) f32 {
            return srgbToLinear(val);
        }
    };

    const LinearToSrgb = struct {
        pub fn apply(val: f32) f32 {
            return linearToSrgb(val);
        }
    };

    pub fn convert(self: *Converter, source_transfer: img.TransferFn, dest_transfer: img.TransferFn) void {
        switch (source_transfer) {
            .gamma => |g| {
                self.convertImageDataToLinearConcrete(GammaAdjustment{ .source_gamma = g, .dest_gamma = 1.0 }, dest_transfer);
            },
            .srgb => {
                self.convertImageDataToLinearConcrete(SrgbToLinear, dest_transfer);
            },
            .linear => {
                self.convertImageDataToLinearConcrete(Identity, dest_transfer);
            },
        }
    }

    fn convertImageDataToLinearConcrete(self: *Converter, to_linear: anytype, dest_transfer: img.TransferFn) void {
        switch (dest_transfer) {
            .gamma => |g| {
                self.convertImageDataFromLinearConcrete(
                    to_linear,
                    GammaAdjustment{ .source_gamma = 1.0, .dest_gamma = g },
                );
            },
            .srgb => {
                self.convertImageDataFromLinearConcrete(
                    to_linear,
                    LinearToSrgb,
                );
            },
            .linear => {
                self.convertImageDataFromLinearConcrete(
                    to_linear,
                    Identity,
                );
            },
        }
    }

    fn convertImageDataFromLinearConcrete(self: *Converter, to_linear: anytype, dest_transfer: anytype) void {
        switch (self.data) {
            inline else => |d| {
                var it = d.iter();
                while (it.next()) |px| {
                    var px_f = px.tof32();

                    const linear = sphmath.Vec3{
                        to_linear.apply(px_f.r),
                        to_linear.apply(px_f.g),
                        to_linear.apply(px_f.b),
                    };

                    const transformed = std.math.clamp(self.color_transform.mul(linear), @as(sphmath.Vec3, @splat(0.0)), @as(sphmath.Vec3, @splat(1.0)));

                    px_f.r = dest_transfer.apply(transformed[0]);
                    px_f.g = dest_transfer.apply(transformed[1]);
                    px_f.b = dest_transfer.apply(transformed[2]);

                    it.write(@TypeOf(px).from(px_f));
                }
            },
        }
    }
};

test "Color conversion sanity" {
    var pixel_data_bytes: [9]u8 = .{
        20,  40,  60,
        80,  100, 120,
        140, 160, 180,
    };

    const pixel_data = img.PixelData.init(.rgb_888_packed, &pixel_data_bytes);
    var converter = Converter{
        .color_transform = .{
            .data = .{
                0.0, 1.0, 0.0,
                1.0, 0.0, 0.0,
                0.0, 0.0, 1.0,
            },
        },
        .data = pixel_data,
    };

    converter.convert(.linear, .{ .gamma = 2.2 });

    const expected: []const u8 = &.{
        4,  0,  10,
        32, 19, 48,
        91, 68, 118,
    };

    for (&pixel_data_bytes, expected) |o, e| {
        try std.testing.expectEqual(e, o);
    }
}
