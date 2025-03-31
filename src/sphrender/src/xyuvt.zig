const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const shader_program = @import("shader_program.zig");
const sphrender = @import("sphrender.zig");
const GlAlloc = @import("GlAlloc.zig");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;

pub const ImageSamplerUniforms = struct {
    input_image: sphrender.Texture,
    transform: sphmath.Mat3x3 = sphmath.Transform.identity.inner,
};

pub const image_sampler_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D input_image;
    \\void main()
    \\{
    \\    fragment = texture(input_image, vec2(uv.x, uv.y));
    \\}
;

pub const RenderSource = shader_program.RenderSourceTyped(Vertex);

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

        pub fn render(self: Self, render_source: RenderSource, options: KnownUniforms) void {
            self.inner.render(render_source.inner, options);
        }

        pub fn renderWithExtra(self: Self, render_source: RenderSource, options: KnownUniforms, defs: shader_program.UnknownUniforms, values: []const sphrender.ResolvedUniformValue) void {
            self.inner.renderWithExtra(render_source.inner, options, defs, values);
        }

        pub fn handle(self: Self) shader_program.ProgramHandle {
            return self.inner.handle;
        }
    };
}

pub fn makeFullScreenPlane(gl_alloc: *GlAlloc) !Buffer {
    return try Buffer.init(gl_alloc, &.{
        .{ .vPos = .{ -1.0, -1.0 }, .vUv = .{ 0.0, 0.0 } },
        .{ .vPos = .{ 1.0, -1.0 }, .vUv = .{ 1.0, 0.0 } },
        .{ .vPos = .{ -1.0, 1.0 }, .vUv = .{ 0.0, 1.0 } },

        .{ .vPos = .{ 1.0, 1.0 }, .vUv = .{ 1.0, 1.0 } },
        .{ .vPos = .{ -1.0, 1.0 }, .vUv = .{ 0.0, 1.0 } },
        .{ .vPos = .{ 1.0, -1.0 }, .vUv = .{ 1.0, 0.0 } },
    });
}

pub const ImageRenderer = struct {
    prog: Program(ImageSamplerUniforms),
    render_source: RenderSource,

    pub fn init(alloc: *GlAlloc) !ImageRenderer {
        const prog = try Program(ImageSamplerUniforms).init(alloc, image_sampler_frag);
        var render_source = try RenderSource.init(alloc);
        render_source.bindData(prog.handle(), try makeFullScreenPlane(alloc));

        return .{
            .prog = prog,
            .render_source = render_source,
        };
    }

    pub fn renderTexture(self: ImageRenderer, texture: sphrender.Texture, transform: sphmath.Transform) void {
        self.prog.render(self.render_source, .{
            .input_image = texture,
            .transform = transform.inner,
        });
    }
};

pub const Vertex = struct {
    vUv: sphmath.Vec2,
    vPos: sphmath.Vec2,
};

pub const Buffer = shader_program.Buffer(Vertex);

pub const vertex_shader =
    \\#version 330
    \\in vec2 vUv;
    \\in vec2 vPos;
    \\out vec2 uv;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\    uv = vUv;
    \\}
;
