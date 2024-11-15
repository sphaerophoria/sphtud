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

    pub fn scale(x: f32, y: f32) Transform {
        return .{ .inner = .{
            .data = .{
                x,   0.0, 0.0,
                0.0, y,   0.0,
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
