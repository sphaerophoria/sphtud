const std = @import("std");
const lin = @import("lin.zig");

pub const CircleSampler = struct {
    idx: usize = 0,
    radius: f32,
    num_samples: usize,

    pub fn next(self: *CircleSampler) ?lin.Vec2 {
        if (self.idx >= self.num_samples) {
            return null;
        }

        defer self.idx += 1;

        const idx_f: f32 = @floatFromInt(self.idx);
        const num_samples_f: f32 = @floatFromInt(self.num_samples);
        const angle = 2 * std.math.pi * idx_f / num_samples_f;

        const transform = lin.Transform.rotate(angle);
        const point = lin.applyHomogenous(transform.apply(lin.Vec3{ 1, 0, 1 }));

        return point * @as(lin.Vec2, @splat(self.radius));
    }
};

// Generates a triangle fan for a cone. Center is at 0,0,0, base is offset by
// height
pub const ConeGenerator = struct {
    height: f32,
    base_sampler: CircleSampler,
    first_base_elem: lin.Vec2 = undefined,
    state: enum {
        center, // First point
        first_base, // Forward to the circle sampler + remember output
        base, // Forward to the circle sampler
        finished, // No more work to do
    } = .center,

    pub fn init(radius: f32, height: f32, num_vertices: usize) ConeGenerator {
        return .{
            .height = height,
            .base_sampler = .{
                .radius = radius,
                .num_samples = num_vertices - 2,
            },
        };
    }

    pub fn next(self: *ConeGenerator) ?lin.Vec3 {
        switch (self.state) {
            .center => {
                self.state = .first_base;
                return .{ 0, 0, 0 };
            },
            .first_base => {
                self.first_base_elem = self.base_sampler.next() orelse return null;
                self.state = .base;
                return circleToBase(self.first_base_elem, self.height);
            },
            .base => {
                const base_loc = self.base_sampler.next() orelse blk: {
                    self.state = .finished;
                    break :blk self.first_base_elem;
                };
                return circleToBase(base_loc, self.height);
            },
            .finished => {
                return null;
            },
        }
    }

    fn circleToBase(point: lin.Vec2, height: f32) lin.Vec3 {
        return .{ point[0], point[1], height };
    }
};

pub const TentGenerator = struct {
    a: lin.Vec2,
    b: lin.Vec2,
    width: f32,
    height: f32,
    idx: usize = 0,

    pub fn next(self: *TentGenerator) ?lin.Vec3 {
        if (self.idx >= 6) return null;
        defer self.idx += 1;

        const initial_vector = lin.normalize(self.b - self.a);
        const perp = lin.Vec2{ -initial_vector[1], initial_vector[0] };

        const ref_point_idx = self.idx % 2;
        //perp_dir -1, 0, 1
        const perp_dir = @as(f32, @floatFromInt(self.idx / 2)) - 1;
        const perp_dir_splat: lin.Vec2 = @splat(perp_dir);
        const width_splat: lin.Vec2 = @splat(self.width);

        const ref_points = [2]lin.Vec2{ self.a, self.b };
        const ref_point = ref_points[ref_point_idx];
        const ret2 = ref_point + perp * perp_dir_splat * width_splat;

        const depth = @abs(perp_dir) * self.height;

        return .{ ret2[0], ret2[1], depth };
    }
};
