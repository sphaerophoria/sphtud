const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const shader_program = @import("shader_program.zig");
const sphrender = @import("sphrender.zig");
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

        pub fn renderLineLoop(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.inner.renderLineLoop(array.inner, options);
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

pub const vertex_shader =
    \\#version 330
    \\in vec2 vPos;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\}
;
