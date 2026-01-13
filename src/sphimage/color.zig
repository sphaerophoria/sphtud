const std = @import("std");
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

pub const bradford = sphmath.Mat3x3T(f64){
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
    const in_rgb_to_xyz_f64 = in_rgb_to_xyz.withT(f64);
    const out_rgb_to_xyz_f64 = out_rgb_to_xyz.withT(f64);

    const out_rgb_to_lms = bradford.matmul(out_rgb_to_xyz_f64);
    const in_rgb_to_lms = bradford.matmul(in_rgb_to_xyz_f64);

    const in_whitepoint = in_rgb_to_lms.mul(.{ 1, 1, 1 });
    const out_whitepoint = out_rgb_to_lms.mul(.{ 1, 1, 1 });

    const scale_mat = sphmath.Mat3x3T(f64){
        .data = .{
            out_whitepoint[0] / in_whitepoint[0], 0,                                    0,
            0,                                    out_whitepoint[1] / in_whitepoint[1], 0,
            0,                                    0,                                    out_whitepoint[2] / in_whitepoint[2],
        },
    };

    const ret = out_rgb_to_lms.invert()
        .matmul(scale_mat)
        .matmul(in_rgb_to_lms);

    return ret.withT(f32);
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
