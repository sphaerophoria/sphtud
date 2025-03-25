const std = @import("std");

pub const Vec4 = @Vector(4, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec2 = @Vector(2, f32);

pub fn applyHomogenous(in: Vec3) Vec2 {
    return .{
        in[0] / in[2],
        in[1] / in[2],
    };
}

pub fn length2(in: anytype) f32 {
    return @reduce(.Add, in * in);
}

pub fn length(in: anytype) f32 {
    return @sqrt(length2(in));
}

pub fn dot(a: anytype, b: anytype) f32 {
    return @reduce(.Add, a * b);
}

test "dot sanity" {
    const ret = dot(Vec3{ 1, 2, 3 }, Vec3{ 4, 5, 6 });
    try std.testing.expectApproxEqAbs(32, ret, 0.001);
}

pub fn normalize(in: anytype) @TypeOf(in) {
    const l: @TypeOf(in) = @splat(length(in));
    return in / l;
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

test "cross sanity" {
    const ret = cross(Vec3{ 1, 2, 3 }, Vec3{ 5, 11, 34 });
    try std.testing.expectApproxEqAbs(35, ret[0], 0.0001);
    try std.testing.expectApproxEqAbs(-19, ret[1], 0.0001);
    try std.testing.expectApproxEqAbs(1, ret[2], 0.0001);
}

pub fn cross2(a: Vec2, b: Vec2) f32 {
    return a[0] * b[1] - a[1] * b[0];
}

pub const Mat3x3 = struct {
    data: [9]f32 = .{
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
    },

    pub fn mul(self: Mat3x3, vec: Vec3) Vec3 {
        const x = self.data[0..3].* * vec;
        const y = self.data[3..6].* * vec;
        const z = self.data[6..9].* * vec;

        return .{
            @reduce(.Add, x),
            @reduce(.Add, y),
            @reduce(.Add, z),
        };
    }

    pub fn matmul(a: Mat3x3, b: Mat3x3) Mat3x3 {
        var ret: [9]f32 = undefined;

        for (0..9) |i| {
            const row = i / 3;
            const col = i % 3;

            const a_row = a.data[row * 3 .. (row + 1) * 3];
            const b_col = [3]f32{
                b.data[col],
                b.data[3 + col],
                b.data[6 + col],
            };

            ret[i] =
                a_row[0] * b_col[0] +
                a_row[1] * b_col[1] +
                a_row[2] * b_col[2];
        }

        return .{
            .data = ret,
        };
    }

    pub fn invert(self: Mat3x3) Mat3x3 {
        const x0 = Vec3{ self.data[0], self.data[3], self.data[6] };
        const x1 = Vec3{ self.data[1], self.data[4], self.data[7] };
        const x2 = Vec3{ self.data[2], self.data[5], self.data[8] };

        const c12 = cross(x1, x2);
        const c20 = cross(x2, x0);
        const c01 = cross(x0, x1);

        const det = dot(x0, c12);
        const det_splat: Vec3 = @splat(det);

        var ret: Mat3x3 = undefined;

        ret.data[0..3].* = c12 / det_splat;
        ret.data[3..6].* = c20 / det_splat;
        ret.data[6..9].* = c01 / det_splat;

        return ret;
    }

    test "sanity invert" {
        const m1 = Mat3x3{ .data = .{
            40, 50,  123,
            92, -12, -25,
            0,  0,   1,
        } };

        const inverse = m1.invert();

        const identity = inverse.matmul(m1);
        for (0..9) |idx| {
            const row = idx / 3;
            const col = idx % 3;
            const is_diag = row == col;
            if (is_diag) {
                try std.testing.expectApproxEqAbs(1.0, identity.data[idx], 0.001);
            } else {
                try std.testing.expectApproxEqAbs(0.0, identity.data[idx], 0.001);
            }
        }
    }

    pub fn transpose(self: Mat3x3) Mat3x3 {
        var ret = self;

        const pairs: [3][2]usize = .{
            .{ 1, 3 },
            .{ 2, 6 },
            .{ 5, 7 },
        };

        for (pairs) |pair| {
            std.mem.swap(f32, &ret.data[pair[0]], &ret.data[pair[1]]);
        }

        return ret;
    }

    test "sanity transpose" {
        const m1 = Mat3x3{ .data = .{
            40, 50,  123,
            92, -12, -25,
            0,  45,  1,
        } };

        const transposed = m1.transpose();

        try std.testing.expectApproxEqAbs(40, transposed.data[0], 1e-7);
        try std.testing.expectApproxEqAbs(92, transposed.data[1], 1e-7);
        try std.testing.expectApproxEqAbs(0, transposed.data[2], 1e-7);
        try std.testing.expectApproxEqAbs(50, transposed.data[3], 1e-7);
        try std.testing.expectApproxEqAbs(-12, transposed.data[4], 1e-7);
        try std.testing.expectApproxEqAbs(45, transposed.data[5], 1e-7);
        try std.testing.expectApproxEqAbs(123, transposed.data[6], 1e-7);
        try std.testing.expectApproxEqAbs(-25, transposed.data[7], 1e-7);
        try std.testing.expectApproxEqAbs(1, transposed.data[8], 1e-7);
    }
};

pub const Mat4x4 = struct {
    data: [16]f32 = .{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    },

    pub fn to3x3(self: Mat4x4) Mat3x3 {
        return .{
            .data = .{
                self.data[0], self.data[1], self.data[2],
                self.data[4], self.data[5], self.data[6],
                self.data[7], self.data[8], self.data[9],
            },
        };
    }

    pub fn mul(self: Mat4x4, vec: Vec4) Vec4 {
        const x = self.data[0..4].* * vec;
        const y = self.data[4..8].* * vec;
        const z = self.data[8..12].* * vec;
        const w = self.data[12..16].* * vec;

        return .{
            @reduce(.Add, x),
            @reduce(.Add, y),
            @reduce(.Add, z),
            @reduce(.Add, w),
        };
    }

    pub fn matmul(a: Mat4x4, b: Mat4x4) Mat4x4 {
        var ret: [16]f32 = undefined;

        for (0..16) |i| {
            const row = i / 4;
            const col = i % 4;

            const a_row = a.data[row * 4 .. (row + 1) * 4];
            const b_col = [4]f32{
                b.data[col],
                b.data[4 + col],
                b.data[8 + col],
                b.data[12 + col],
            };

            ret[i] =
                a_row[0] * b_col[0] +
                a_row[1] * b_col[1] +
                a_row[2] * b_col[2] +
                a_row[3] * b_col[3];
        }

        return .{
            .data = ret,
        };
    }

    test "sanity mat4x4 mul" {
        const a = Mat4x4{
            .data = .{
                0.1200094,  0.30596924, 0.1209669,  0.20991278,
                0.68232872, 0.7114988,  0.61315368, 0.46940583,
                0.7062717,  0.56776279, 0.07779681, 0.7478156,
                0.43145997, 0.54170567, 0.55784837, 0.80018073,
            },
        };

        const b = Mat4x4{
            .data = .{
                0.24334952, 0.24894254, 0.95571304, 0.06000008,
                0.84849957, 0.2171747,  0.71621696, 0.27510181,
                0.27072156, 0.82861865, 0.93675428, 0.97610207,
                0.85716946, 0.39110445, 0.38627996, 0.56932472,
            },
        };

        const expected = Mat4x4{
            .data = .{
                0.50149817, 0.27865748, 0.52823627, 0.32895784,
                1.33810506, 1.01603747, 1.91739436, 1.1024193,
                1.31568333, 0.65606268, 1.44337709, 0.70025646,
                1.40154467, 1.00025132, 1.63199134, 1.17499146,
            },
        };

        const output = a.matmul(b);
        for (expected.data, output.data) |expected_val, output_val| {
            try std.testing.expectApproxEqAbs(expected_val, output_val, 1e-4);
        }
    }

    pub fn transpose(self: Mat4x4) Mat4x4 {
        var ret = self;

        const pairs: [6][2]usize = .{
            .{ 1, 4 },
            .{ 2, 8 },
            .{ 3, 12 },
            .{ 6, 9 },
            .{ 7, 13 },
            .{ 11, 14 },
        };

        for (pairs) |pair| {
            std.mem.swap(f32, &ret.data[pair[0]], &ret.data[pair[1]]);
        }

        return ret;
    }
};

pub const Transform = struct {
    pub const identity: Transform = .{};

    inner: Mat3x3 = .{},

    pub fn then(self: Transform, next: Transform) Transform {
        return .{ .inner = next.inner.matmul(self.inner) };
    }

    pub fn apply(self: Transform, point: Vec3) Vec3 {
        return self.inner.mul(point);
    }

    pub fn invert(self: Transform) Transform {
        return .{ .inner = self.inner.invert() };
    }

    pub fn scale(x: f32, y: f32) Transform {
        return .{ .inner = .{
            .data = .{
                x,   0.0, 0.0,
                0.0, y,   0.0,
                0.0, 0.0, 1.0,
            },
        } };
    }

    pub fn rotateAToB(a: Vec2, b: Vec2) Transform {
        const a_norm = normalize(a);
        const b_norm = normalize(b);

        const c = dot(a_norm, b_norm);
        const s = cross2(a_norm, b_norm);

        return .{ .inner = .{
            .data = .{
                c,   -s,  0.0,
                s,   c,   0.0,
                0.0, 0.0, 1.0,
            },
        } };
    }

    pub fn rotate(angle: f32) Transform {
        const c = @cos(angle);
        const s = @sin(angle);

        return .{ .inner = .{
            .data = .{
                c,   -s,  0.0,
                s,   c,   0.0,
                0.0, 0.0, 1.0,
            },
        } };
    }

    pub fn translate(x: f32, y: f32) Transform {
        return .{ .inner = .{ .data = .{
            1.0, 0.0, x,
            0.0, 1.0, y,
            0.0, 0.0, 1.0,
        } } };
    }
};

pub const Transform3D = struct {
    pub const identity: Transform3D = .{};

    inner: Mat4x4 = .{},

    pub fn then(self: Transform3D, next: Transform3D) Transform3D {
        return .{ .inner = next.inner.matmul(self.inner) };
    }

    pub fn scale(x: f32, y: f32, z: f32) Transform3D {
        return .{ .inner = .{
            .data = .{
                x,   0.0, 0.0, 0.0,
                0.0, y,   0.0, 0.0,
                0.0, 0.0, z,   0.0,
                0.0, 0.0, 0.0, 1.0,
            },
        } };
    }

    pub fn rotateX(angle: f32) Transform3D {
        const c = @cos(angle);
        const s = @sin(angle);

        return .{ .inner = .{
            .data = .{
                1.0, 0.0, 0.0, 0.0,
                0.0, c,   -s,  0.0,
                0.0, s,   c,   0.0,
                0.0, 0.0, 0.0, 1.0,
            },
        } };
    }

    pub fn rotateY(angle: f32) Transform3D {
        const c = @cos(angle);
        const s = @sin(angle);

        return .{ .inner = .{
            .data = .{
                c,   0.0, -s,  0.0,
                0.0, 1.0, 0.0, 0.0,
                s,   0.0, c,   0.0,
                0.0, 0.0, 0.0, 1.0,
            },
        } };
    }

    pub fn rotateZ(angle: f32) Transform3D {
        const c = @cos(angle);
        const s = @sin(angle);

        return .{ .inner = .{
            .data = .{
                c,   -s,  0.0, 0.0,
                s,   c,   0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            },
        } };
    }

    pub fn translate(x: f32, y: f32, z: f32) Transform3D {
        return .{ .inner = .{ .data = .{
            1.0, 0.0, 0.0, x,
            0.0, 1.0, 0.0, y,
            0.0, 0.0, 1.0, z,
            0.0, 0.0, 0.0, 1.0,
        } } };
    }

    pub fn perspective(fov: f32, near: f32, far: f32) Transform3D {
        const z1 = far / (near - far);
        const z2 = (near * far) / (near - far);

        const cot = 1 / @tan(fov / 2.0);

        return .{ .inner = .{ .data = .{
            cot, 0.0, 0.0, 0.0,
            0.0, cot, 0.0, 0.0,
            0.0, 0.0, z1,  -z2,
            0.0, 0.0, 1.0, 0.0,
        } } };
    }

    pub fn format(value: Transform3D, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        for (0..4) |row_idx| {
            const row = value.inner.data[row_idx * 4 .. (row_idx + 1) * 4];
            for (0..4) |col_idx| {
                try writer.print("{d}, ", .{row[col_idx]});
            }
            try writer.print("\n", .{});
        }
    }
};

pub fn calcAspect(width: usize, height: usize) f32 {
    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);

    return width_f / height_f;
}

pub const Quaternion = struct {
    r: f32,
    x: f32,
    y: f32,
    z: f32,

    pub const identity = Quaternion{ .r = 1.0, .x = 0, .y = 0, .z = 0 };

    pub fn toTransform3D(q: Quaternion) Transform3D {
        const r = q.r;
        // Our quaternions rotate CCW around the given axis, math we had from
        // https://en.wikipedia.org/wiki/Quaternions_and_spatial_rotation seems
        // to rotate clockwise. Invert our axis to be CCW as expected :)
        const i = -q.x;
        const j = -q.y;
        const k = -q.z;

        // My friend claude wrote this kinda and we cross referenced with
        // wikipedia :)
        const m00 = 1.0 - 2.0 * (j * j + k * k);
        const m01 = 2.0 * (i * j - k * r);
        const m02 = 2.0 * (i * k + j * r);

        const m10 = 2.0 * (i * j + k * r);
        const m11 = 1.0 - 2.0 * (i * i + k * k);
        const m12 = 2.0 * (j * k - i * r);

        const m20 = 2.0 * (i * k - j * r);
        const m21 = 2.0 * (j * k + i * r);
        const m22 = 1.0 - 2.0 * (i * i + j * j);

        var ret = Transform3D{
            .inner = .{
                .data = .{
                    m00, m01, m02, 0.0,
                    m10, m11, m12, 0.0,
                    m20, m21, m22, 0.0,
                    0.0, 0.0, 0.0, 1.0,
                },
            },
        };

        return ret.then(Transform3D.scale(1, 1, 1));
    }

    pub fn slerp(q1: Quaternion, q2_in: Quaternion, t: f32) Quaternion {
        // Geometric slerp from https://en.wikipedia.org/wiki/Slerp

        var q2 = q2_in;

        var cos = q1.r * q2.r + q1.x * q2.x + q1.y * q2.y + q1.z * q2.z;

        // Force us to go the short way
        if (cos < 0.0) {
            q2.r = -q2.r;
            q2.x = -q2.x;
            q2.y = -q2.y;
            q2.z = -q2.z;
            cos = -cos;
        }

        const angle = std.math.acos(cos);
        const sin = @sqrt(1.0 - cos * cos);

        // Avoid divide by 0, they're basically the same quat
        if (std.math.approxEqAbs(f32, sin, 0.0, 0.0001)) {
            return q1;
        }

        const coeff1 = @sin((1.0 - t) * angle) / sin;
        const coeff2 = @sin(t * angle) / sin;

        return Quaternion{
            .r = coeff1 * q1.r + coeff2 * q2.r,
            .x = coeff1 * q1.x + coeff2 * q2.x,
            .y = coeff1 * q1.y + coeff2 * q2.y,
            .z = coeff1 * q1.z + coeff2 * q2.z,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
