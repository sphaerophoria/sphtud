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

pub const Transform = struct {
    pub const identity: Transform = .{};

    data: [9]f32 = .{
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
    },

    pub fn mul(self: Transform, vec: Vec3) Vec3 {
        const x = self.data[0..3].* * vec;
        const y = self.data[3..6].* * vec;
        const z = self.data[6..9].* * vec;

        return .{
            @reduce(.Add, x),
            @reduce(.Add, y),
            @reduce(.Add, z),
        };
    }

    pub fn scale(x: f32, y: f32) Transform {
        return .{ .data = .{
            x,   0.0, 0.0,
            0.0, y,   0.0,
            0.0, 0.0, 1.0,
        } };
    }
};
