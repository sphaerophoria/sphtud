const std = @import("std");
const sphmath = @import("sphmath");

pub const CircleSampler = struct {
    idx: usize = 0,
    radius: f32,
    num_samples: usize,

    pub fn next(self: *CircleSampler) ?sphmath.Vec2 {
        if (self.idx >= self.num_samples) {
            return null;
        }

        defer self.idx += 1;

        const idx_f: f32 = @floatFromInt(self.idx);
        const num_samples_f: f32 = @floatFromInt(self.num_samples);
        const angle = 2 * std.math.pi * idx_f / num_samples_f;

        const transform = sphmath.Transform.rotate(angle);
        const point = sphmath.applyHomogenous(transform.apply(sphmath.Vec3{ 1, 0, 1 }));

        return point * @as(sphmath.Vec2, @splat(self.radius));
    }
};

// Generates a triangle fan for a cone. Center is at 0,0,0, base is offset by
// height
pub const ConeGenerator = struct {
    height: f32,
    base_sampler: CircleSampler,
    first_base_elem: sphmath.Vec2 = undefined,
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

    pub fn next(self: *ConeGenerator) ?sphmath.Vec3 {
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

    fn circleToBase(point: sphmath.Vec2, height: f32) sphmath.Vec3 {
        return .{ point[0], point[1], height };
    }
};

pub const TentGenerator = struct {
    a: sphmath.Vec2,
    b: sphmath.Vec2,
    width: f32,
    height: f32,
    idx: usize = 0,

    pub fn next(self: *TentGenerator) ?sphmath.Vec3 {
        if (self.idx >= 6) return null;
        defer self.idx += 1;

        const initial_vector = sphmath.normalize(self.b - self.a);
        const perp = sphmath.Vec2{ -initial_vector[1], initial_vector[0] };

        const ref_point_idx = self.idx % 2;
        //perp_dir -1, 0, 1
        const perp_dir = @as(f32, @floatFromInt(self.idx / 2)) - 1;
        const perp_dir_splat: sphmath.Vec2 = @splat(perp_dir);
        const width_splat: sphmath.Vec2 = @splat(self.width);

        const ref_points = [2]sphmath.Vec2{ self.a, self.b };
        const ref_point = ref_points[ref_point_idx];
        const ret2 = ref_point + perp * perp_dir_splat * width_splat;

        const depth = @abs(perp_dir) * self.height;

        return .{ ret2[0], ret2[1], depth };
    }
};

pub const ConeSegmentGenerator = struct {
    // Sample circle of radius 1.0, we will multiply elements as needed
    normalized_sampler: CircleSampler,
    // First output of normalized_sampler since we need to close the loop
    initial_sample: sphmath.Vec2,

    inner_radius: f32,
    outer_radius: f32,

    inner_depth: f32,
    outer_depth: f32,

    prev_sample: sphmath.Vec2,
    curr_sample: sphmath.Vec2,
    state: State = .new_sample,

    const State = enum {
        new_sample,
        output_second_tri,
        output_final,
        finished,
    };

    pub fn init(num_samples: usize, inner_radius: f32, outer_radius: f32, inner_depth: f32, outer_depth: f32) ConeSegmentGenerator {
        var sampler = CircleSampler{
            .radius = 1.0,
            .num_samples = num_samples,
        };
        const initial_sample = sampler.next().?;

        return .{
            .normalized_sampler = sampler,
            .initial_sample = initial_sample,
            .curr_sample = initial_sample,
            .prev_sample = undefined,
            .inner_radius = inner_radius,
            .outer_radius = outer_radius,
            .inner_depth = inner_depth,
            .outer_depth = outer_depth,
        };
    }

    pub const Triangle = [3]sphmath.Vec3;

    pub fn next(self: *ConeSegmentGenerator) ?Triangle {
        const sample = retrieveNextSample(self.state, &self.normalized_sampler, self.initial_sample);
        const this_state = self.state;

        if (sample.new_sample) |v| {
            self.prev_sample = self.curr_sample;
            self.curr_sample = v;
        }

        self.state = sample.new_state;

        return generateTriangle(
            this_state,
            self.prev_sample,
            self.curr_sample,
            self.inner_radius,
            self.outer_radius,
            self.inner_depth,
            self.outer_depth,
        );
    }

    const Sample = struct {
        new_sample: ?sphmath.Vec2,
        new_state: State,
    };

    fn retrieveNextSample(current_state: State, sampler: *CircleSampler, initial_sample: sphmath.Vec2) Sample {
        var new_state = current_state;
        var new_sample: ?sphmath.Vec2 = null;

        switch (current_state) {
            .new_sample => {
                if (sampler.next()) |v| {
                    new_state = .output_second_tri;
                    new_sample = v;
                } else {
                    new_state = .output_final;
                    new_sample = initial_sample;
                }
            },
            .output_second_tri => {
                new_state = .new_sample;
            },
            .output_final => {
                new_state = .finished;
            },
            .finished => {},
        }

        return .{
            .new_sample = new_sample,
            .new_state = new_state,
        };
    }

    fn generateTriangle(
        state: State,
        prev_sample: sphmath.Vec2,
        curr_sample: sphmath.Vec2,
        inner_radius: f32,
        outer_radius: f32,
        inner_depth: f32,
        outer_depth: f32,
    ) ?Triangle {
        switch (state) {
            .new_sample => {
                // Sampler moves CCW, triangles should have CW winding order
                const a = prev_sample * sphmath.Vec2{ outer_radius, outer_radius };
                const b = prev_sample * sphmath.Vec2{ inner_radius, inner_radius };
                const c = curr_sample * sphmath.Vec2{ inner_radius, inner_radius };

                return .{
                    addDepth(a, outer_depth),
                    addDepth(b, inner_depth),
                    addDepth(c, inner_depth),
                };
            },
            .output_second_tri, .output_final => {
                // Sampler moves CCW, triangles should have CW winding order
                const a = prev_sample * sphmath.Vec2{ outer_radius, outer_radius };
                const b = curr_sample * sphmath.Vec2{ inner_radius, inner_radius };
                const c = curr_sample * sphmath.Vec2{ outer_radius, outer_radius };

                return .{
                    addDepth(a, outer_depth),
                    addDepth(b, inner_depth),
                    addDepth(c, outer_depth),
                };
            },
            .finished => return null,
        }
    }
    fn addDepth(item: sphmath.Vec2, depth: f32) sphmath.Vec3 {
        return .{ item[0], item[1], depth };
    }
};
