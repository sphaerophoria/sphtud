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

        const InnerProgram = shader_program.Program(Vertex, KnownUniforms);
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

        pub fn makeFullScreenPlane(self: Self, gl_alloc: *GlAlloc) !Buffer {
            return try self.inner.makeBuffer(gl_alloc, &.{
                .{ .vPos = .{ -1.0, -1.0 }, .vUv = .{ 0.0, 0.0 } },
                .{ .vPos = .{ 1.0, -1.0 }, .vUv = .{ 1.0, 0.0 } },
                .{ .vPos = .{ -1.0, 1.0 }, .vUv = .{ 0.0, 1.0 } },

                .{ .vPos = .{ 1.0, -1.0 }, .vUv = .{ 1.0, 0.0 } },
                .{ .vPos = .{ -1.0, 1.0 }, .vUv = .{ 0.0, 1.0 } },
                .{ .vPos = .{ 1.0, 1.0 }, .vUv = .{ 1.0, 1.0 } },
            });
        }

        pub fn render(self: Self, buffer: Buffer, options: KnownUniforms) void {
            self.inner.render(buffer, options);
        }

        pub fn renderWithExtra(self: Self, buffer: Buffer, options: KnownUniforms, defs: shader_program.UnknownUniforms, values: []const sphrender.ResolvedUniformValue) void {
            self.inner.renderWithExtra(buffer, options, defs, values);
        }
    };
}

pub const Vertex = struct {
    vPos: sphmath.Vec2,
};

pub const Buffer = shader_program.Buffer(Vertex);

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
