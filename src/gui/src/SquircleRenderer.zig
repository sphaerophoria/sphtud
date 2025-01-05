const std = @import("std");
const Allocator = std.mem.Allocator;

const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const gui = @import("gui.zig");
const Color = gui.Color;
const PixelBBox = gui.PixelBBox;

program: sphrender.PlaneRenderProgram,
buffer: sphrender.PlaneRenderProgram.Buffer,

const SquircleRenderer = @This();

pub fn init(alloc: Allocator) !SquircleRenderer {
    const program = try sphrender.PlaneRenderProgram.init(
        alloc,
        sphrender.plane_vertex_shader,
        fragment_shader,
        SquircleIndex,
    );

    const buffer = program.makeDefaultBuffer();

    return .{
        .program = program,
        .buffer = buffer,
    };
}

pub fn deinit(self: SquircleRenderer, alloc: Allocator) void {
    self.program.deinit(alloc);
    self.buffer.deinit();
}

pub fn render(self: SquircleRenderer, color: Color, corner_radius_px: f32, widget_bounds: PixelBBox, transform: sphmath.Transform) void {
    self.program.render(self.buffer, &.{}, &.{
        .{
            .idx = @intFromEnum(SquircleIndex.color),
            .val = .{
                .float3 = .{ color.r, color.g, color.b },
            },
        },
        .{
            .idx = @intFromEnum(SquircleIndex.total_size),
            .val = .{
                .float2 = .{
                    @floatFromInt(widget_bounds.calcWidth()),
                    @floatFromInt(widget_bounds.calcHeight()),
                },
            },
        },
        .{
            .idx = @intFromEnum(SquircleIndex.corner_radius),
            .val = .{ .float = corner_radius_px },
        },
        .{
            .idx = @intFromEnum(SquircleIndex.transform),
            .val = .{ .mat3x3 = transform.inner },
        },
    });
}

const SquircleIndex = enum {
    color,
    total_size,
    corner_radius,
    transform,
};

const fragment_shader =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform vec3 color;
    \\uniform vec2 total_size;
    \\uniform float corner_radius;
    \\
    \\bool inCorner(vec2 corner_coord) {
    \\    bool x_out = corner_coord.x >= total_size.x - corner_radius;
    \\    bool y_out = corner_coord.y >= total_size.y - corner_radius;
    \\    return x_out && y_out;
    \\}
    \\
    \\void main()
    \\{
    \\    vec2 pixel_coord = uv * total_size;
    \\    vec2 corner_coord = (abs(uv - 0.5) + 0.5) * total_size;
    \\    if (inCorner(corner_coord)) {
    \\        vec2 rel_0 = corner_coord - total_size + corner_radius;
    \\        if (rel_0.x * rel_0.x + rel_0.y * rel_0.y > corner_radius * corner_radius) discard;
    \\    }
    \\    fragment = vec4(color, 1.0);
    \\}
;
