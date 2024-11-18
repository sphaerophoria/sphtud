const std = @import("std");

pub const Vec3 = @Vector(3, f32);
pub const Vec2 = @Vector(2, f32);

pub fn applyHomogenous(in: Vec3) Vec2 {
    return .{
        in[0] / in[2],
        in[1] / in[2],
    };
}

pub fn length2(in: Vec2) f32 {
    return @reduce(.Add, in * in);
}

pub fn length(in: Vec2) f32 {
    return @sqrt(length2(in));
}

pub fn dot(a: anytype, b: anytype) f32 {
    return @reduce(.Add, a * b);
}

test "dot sanity" {
    const ret = dot(Vec3{ 1, 2, 3 }, Vec3{ 4, 5, 6 });
    try std.testing.expectApproxEqAbs(32, ret, 0.001);
}

pub fn normalize(in: Vec2) Vec2 {
    const l: Vec2 = @splat(length(in));
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
