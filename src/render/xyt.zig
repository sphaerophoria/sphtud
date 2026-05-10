const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const shader_program = @import("shader_program.zig");
const sphrender = @import("../render.zig");
const GlAlloc = @import("GlAlloc.zig");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;

pub fn Program(comptime KnownUniforms: type) type {
    return struct {
        inner: InnerProgram,

        const InnerProgram = shader_program.Program(KnownUniforms);
        const Self = @This();

        pub fn init(gl_alloc: *GlAlloc, fs: [:0]const u8) !Self {
            const inner = try InnerProgram.init(gl_alloc, vertex_shader, fs);
            return .{
                .inner = inner,
            };
        }

        pub fn unknownUniforms(self: Self, scratch: *ScratchAlloc) !shader_program.UnknownUniforms {
            return self.inner.unknownUniforms(scratch);
        }

        pub fn render(self: Self, buffer: RenderSource, options: KnownUniforms) void {
            self.inner.render(buffer.inner, options);
        }

        pub fn renderFan(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.inner.renderFan(array.inner, options);
        }

        pub fn renderPoints(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.inner.renderPoints(array.inner, options);
        }

        pub fn renderLines(self: Self, buffer: RenderSource, options: KnownUniforms) void {
            self.inner.renderLines(buffer.inner, options);
        }

        pub fn renderLineLoop(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.inner.renderLineLoop(array.inner, options);
        }

        pub fn renderLineStrip(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.inner.renderLineStrip(array.inner, options);
        }

        pub fn renderWithExtra(self: Self, buffer: Buffer, options: KnownUniforms, defs: shader_program.UnknownUniforms, values: []const sphrender.ResolvedUniformValue) void {
            self.inner.renderWithExtra(buffer, options, defs, values);
        }

        pub fn handle(self: Self) shader_program.ProgramHandle {
            return self.inner.handle;
        }
    };
}

pub const Vertex = struct {
    vPos: sphmath.Vec2,
};

pub const Buffer = shader_program.Buffer(Vertex);
pub const RenderSource = shader_program.RenderSourceTyped(Vertex);

pub const SolidColorUniforms = struct {
    color: sphmath.Vec3,
    transform: sphmath.Mat3x3,
    depth: f32 = 0.0,
};

pub const SolidColorProgram = Program(SolidColorUniforms);

pub const solid_color_frag =
    \\#version 330
    \\out vec4 fragment;
    \\uniform vec3 color;
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;

pub fn solidColorProgram(gl_alloc: *GlAlloc) !SolidColorProgram {
    return SolidColorProgram.init(gl_alloc, solid_color_frag);
}

pub const vertex_shader =
    \\#version 330
    \\in vec2 vPos;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\uniform float depth = 0.0;
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, depth, transformed.z);
    \\}
;
