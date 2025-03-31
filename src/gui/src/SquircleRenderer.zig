const std = @import("std");
const Allocator = std.mem.Allocator;

const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const gui = @import("gui.zig");
const Color = gui.Color;
const PixelBBox = gui.PixelBBox;

const Program = sphrender.xyuvt_program.Program(SquircleUniform);
const RenderSource = sphrender.xyuvt_program.RenderSource;
const GlAlloc = sphrender.GlAlloc;

program: Program,
render_source: RenderSource,

const SquircleRenderer = @This();

pub fn init(gl_alloc: *GlAlloc) !SquircleRenderer {
    const program = try Program.init(
        gl_alloc,
        fragment_shader,
    );

    var render_source = try RenderSource.init(gl_alloc);
    render_source.bindData(program.handle(), try sphrender.xyuvt_program.makeFullScreenPlane(gl_alloc));
    return .{
        .program = program,
        .render_source = render_source,
    };
}

pub fn render(self: SquircleRenderer, color: Color, corner_radius_px: f32, widget_bounds: PixelBBox, transform: sphmath.Transform) void {
    self.program.render(self.render_source, .{
        .color = .{ color.r, color.g, color.b },
        .total_size = .{
            @floatFromInt(widget_bounds.calcWidth()),
            @floatFromInt(widget_bounds.calcHeight()),
        },
        .corner_radius = corner_radius_px,
        .transform = transform.inner,
    });
}

const SquircleUniform = struct {
    color: sphmath.Vec3,
    total_size: sphmath.Vec2,
    corner_radius: f32,
    transform: sphmath.Mat3x3,
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
