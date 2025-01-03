const std = @import("std");
const Allocator = std.mem.Allocator;
const obj_mod = @import("object.zig");
const coords = @import("coords.zig");
const shader_storage = @import("shader_storage.zig");
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const sphtext = @import("sphtext");
const TextRenderer = sphtext.TextRenderer;
const gl = sphrender.gl;

pub const ResolvedUniformValue = sphrender.ResolvedUniformValue;
pub const UniformType = sphrender.UniformType;
pub const UniformDefault = sphrender.UniformDefault;
pub const Uniform = sphrender.Uniform;
pub const PlaneRenderProgram = sphrender.PlaneRenderProgram;
pub const Texture = sphrender.Texture;
pub const DefaultPlaneReservedIndex = sphrender.DefaultPlaneReservedIndex;
pub const plane_vertex_shader = sphrender.plane_vertex_shader;
pub const plane_fragment_shader = sphrender.plane_fragment_shader;
pub const FramebufferRenderContext = sphrender.FramebufferRenderContext;

const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;

const Objects = obj_mod.Objects;
const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Transform = sphmath.Transform;

program: PlaneRenderProgram,
default_buffer: PlaneRenderProgram.Buffer,
background_program: PlaneRenderProgram,
path_program: PathRenderProgram,
comp_id_program: PlaneRenderProgram,
display_id_program: PlaneRenderProgram,
distance_field_generator: sphrender.DistanceFieldGenerator,

const Renderer = @This();

fn glDebugCallback(source: gl.GLenum, typ: gl.GLenum, id: gl.GLuint, severity: gl.GLenum, length: gl.GLsizei, msg: [*c]const gl.GLchar, ctx: ?*const anyopaque) callconv(.C) void {
    _ = source;
    _ = typ;
    _ = id;
    _ = ctx;
    _ = length;

    const enable_debug_logs = false;
    switch (severity) {
        gl.GL_DEBUG_SEVERITY_HIGH => std.log.err("{s}", .{msg}),
        gl.GL_DEBUG_SEVERITY_MEDIUM => std.log.warn("{s}", .{msg}),
        else => if (enable_debug_logs) std.log.debug("{s}", .{msg}),
    }
}

pub fn init(alloc: Allocator) !Renderer {
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    gl.glDebugMessageCallback(glDebugCallback, null);

    const plane_program = try PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, sphrender.plane_fragment_shader, sphrender.DefaultPlaneReservedIndex);
    errdefer plane_program.deinit(alloc);

    const background_program = try PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, checkerboard_fragment_shader, sphrender.DefaultPlaneReservedIndex);
    errdefer background_program.deinit(alloc);

    const path_program = try PathRenderProgram.init();
    errdefer path_program.deinit();

    const distance_field_generator = try sphrender.DistanceFieldGenerator.init();
    errdefer distance_field_generator.deinit();

    const comp_id_program = try sphrender.PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, comp_id_frag, IdProgIdx);
    errdefer comp_id_program.deinit(alloc);

    const display_id_prog = try sphrender.PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, display_id_frag, DisplayIdProgIdx);
    errdefer display_id_prog.deinit(alloc);

    return .{
        .program = plane_program,
        .default_buffer = plane_program.makeDefaultBuffer(),
        .background_program = background_program,
        .path_program = path_program,
        .comp_id_program = comp_id_program,
        .display_id_program = display_id_prog,
        .distance_field_generator = distance_field_generator,
    };
}

pub fn deinit(self: *Renderer, alloc: Allocator) void {
    self.program.deinit(alloc);
    self.background_program.deinit(alloc);
    self.path_program.deinit();
    self.distance_field_generator.deinit();
    self.comp_id_program.deinit(alloc);
    self.display_id_program.deinit(alloc);
}

pub const FrameRenderer = struct {
    alloc: Allocator,
    renderer: *Renderer,
    objects: *Objects,
    shaders: *const ShaderStorage(ShaderId),
    brushes: *const ShaderStorage(BrushId),
    texture_cache: TextureCache,
    mouse_pos: sphmath.Vec2,

    pub fn deinit(self: *FrameRenderer) void {
        self.texture_cache.deinit();
    }

    pub fn render(self: *FrameRenderer, selected_object: ObjectId, transform: Transform) !void {
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const active_object = self.objects.get(selected_object);
        const object_dims = active_object.dims(self.objects);

        const toplevel_aspect = sphmath.calcAspect(object_dims[0], object_dims[1]);

        self.renderer.background_program.render(
            self.renderer.default_buffer,
            &.{},
            &.{
                .{
                    .idx = DefaultPlaneReservedIndex.aspect.asIndex(),
                    .val = .{ .float = toplevel_aspect },
                },
                .{
                    .idx = DefaultPlaneReservedIndex.transform.asIndex(),
                    .val = .{ .mat3x3 = transform.inner },
                },
            },
        );

        try self.renderObjectWithTransform(active_object.*, transform);
    }

    fn renderedTexture(self: *FrameRenderer, id: ObjectId) !Texture {
        if (self.texture_cache.get(id)) |t| {
            return t;
        }

        const texture = try self.renderObjectToTexture(self.objects.get(id).*);
        try self.texture_cache.put(id, texture);
        return texture;
    }

    pub fn renderCompositionIdMask(self: *FrameRenderer, composition_obj: Object, size: u31, center: sphmath.Vec2) !Texture {
        const composition_data = composition_obj.data.composition;

        const composition_object_dims = composition_obj.dims(self.objects);
        const composition_object_aspect = sphmath.calcAspect(composition_object_dims[0], composition_object_dims[1]);

        const output_tex = sphrender.makeTextureOfSize(size, size, .ri32);
        errdefer output_tex.deinit();

        const render_context = try FramebufferRenderContext.init(output_tex, null);
        defer render_context.reset();

        const temp_viewport = sphrender.TemporaryViewport.init();
        defer temp_viewport.reset();

        const temp_scissor = sphrender.TemporaryScissor.init();
        defer temp_scissor.reset();

        temp_viewport.setViewport(size, size);
        temp_scissor.setAbsolute(0, 0, size, size);

        // I hear that clearing integer textures with normal glClear is
        // undefined. At best its imprecise
        var clear_color: [4]i32 = .{ @bitCast(@as(u32, std.math.maxInt(u32))), 0, 0, 0 };
        gl.glClearBufferiv(gl.GL_COLOR, 0, &clear_color);

        const obj_width_f: f32 = @floatFromInt(composition_object_dims[0]);
        const obj_height_f: f32 = @floatFromInt(composition_object_dims[1]);
        const size_f: f32 = @floatFromInt(size);

        // NxN window centered on mouse position
        const composition_to_viewport =
            Transform.translate(-center[0], -center[1])
            .then(Transform.scale(obj_width_f / size_f, obj_height_f / size_f));

        for (composition_data.objects.items, 0..) |item, comp_idx| {
            const tex = try self.renderedTexture(item.id);

            const composed_to_composition = item.composedToCompositionTransform(self.objects, composition_object_aspect);
            const total_transform = composed_to_composition
                .then(composition_to_viewport);

            // Run render program that samples from tex
            self.renderer.comp_id_program.render(
                self.renderer.default_buffer,
                &.{},
                &.{
                    .{
                        .idx = @intFromEnum(IdProgIdx.input_image),
                        .val = .{ .image = tex.inner },
                    },
                    .{
                        .idx = @intFromEnum(IdProgIdx.composition_idx),
                        .val = .{ .uint = @intCast(comp_idx) },
                    },
                    .{
                        .idx = @intFromEnum(IdProgIdx.transform),
                        .val = .{ .mat3x3 = total_transform.inner },
                    },
                },
            );
        }

        return output_tex;
    }

    pub fn renderObjectWithTransform(self: *FrameRenderer, object: Object, transform: Transform) !void {
        switch (object.data) {
            .composition => |c| {
                const composition_object_dims = object.dims(self.objects);
                const composition_object_aspect = sphmath.calcAspect(composition_object_dims[0], composition_object_dims[1]);

                for (c.objects.items) |composition_object| {
                    const next_object = self.objects.get(composition_object.id);

                    const composed_to_composition = composition_object.composedToCompositionTransform(self.objects, composition_object_aspect);
                    const next_transform = composed_to_composition
                        .then(transform);

                    try self.renderObjectWithTransform(next_object.*, next_transform);
                }

                if (c.debug_masks) {
                    // Res?
                    const output_tex = try self.renderCompositionIdMask(object, 50, self.mouse_pos);
                    defer output_tex.deinit();

                    const preview_scale = 0.2;

                    const preview_transform = Transform.scale(preview_scale, preview_scale)
                        .then(Transform.translate(1.0 - preview_scale, preview_scale - 1.0));

                    self.renderer.display_id_program.render(self.renderer.default_buffer, &.{}, &.{
                        .{
                            .idx = @intFromEnum(DisplayIdProgIdx.input_image),
                            .val = .{
                                .image = output_tex.inner,
                            },
                        },
                        .{
                            .idx = @intFromEnum(DisplayIdProgIdx.transform),
                            .val = .{ .mat3x3 = preview_transform.inner },
                        },
                    });
                }
            },
            .filesystem => |f| {
                self.renderer.program.render(self.renderer.default_buffer, &.{}, &.{
                    .{
                        .idx = DefaultPlaneReservedIndex.input_image.asIndex(),
                        .val = .{ .image = f.texture.inner },
                    },
                    .{
                        .idx = DefaultPlaneReservedIndex.aspect.asIndex(),
                        .val = .{ .float = sphmath.calcAspect(f.width, f.height) },
                    },
                    .{
                        .idx = DefaultPlaneReservedIndex.transform.asIndex(),
                        .val = .{ .mat3x3 = transform.inner },
                    },
                });
            },
            .shader => |s| {
                var sources = std.ArrayList(ResolvedUniformValue).init(self.alloc);
                defer sources.deinit();

                for (s.bindings) |binding| {
                    try sources.append(try self.resolveUniform(binding));
                }

                const object_dims = object.dims(self.objects);
                self.shaders.get(s.program).program.render(self.renderer.default_buffer, sources.items, &.{
                    .{
                        .idx = CustomShaderReservedIndex.aspect.asIndex(),
                        .val = .{ .float = sphmath.calcAspect(object_dims[0], object_dims[1]) },
                    },
                    .{
                        .idx = CustomShaderReservedIndex.transform.asIndex(),
                        .val = .{ .mat3x3 = transform.inner },
                    },
                });
            },
            .path => |p| {
                const display_object = self.objects.get(p.display_object);
                try self.renderObjectWithTransform(display_object.*, transform);

                self.renderer.path_program.render(p.render_buffer, transform, p.points.items.len);
            },
            .generated_mask => |m| {
                const object_dims = object.dims(self.objects);
                self.renderer.program.render(
                    self.renderer.default_buffer,
                    &.{},
                    &.{
                        .{
                            .idx = DefaultPlaneReservedIndex.input_image.asIndex(),
                            .val = .{ .image = m.texture.inner },
                        },
                        .{
                            .idx = DefaultPlaneReservedIndex.aspect.asIndex(),
                            .val = .{ .float = sphmath.calcAspect(object_dims[0], object_dims[1]) },
                        },
                        .{
                            .idx = DefaultPlaneReservedIndex.transform.asIndex(),
                            .val = .{ .mat3x3 = transform.inner },
                        },
                    },
                );
            },
            .drawing => |d| {
                const display_object = self.objects.get(d.display_object);
                const dims = display_object.dims(self.objects);
                try self.renderObjectWithTransform(display_object.*, transform);

                var sources = std.ArrayList(ResolvedUniformValue).init(self.alloc);
                defer sources.deinit();

                for (d.bindings) |binding| {
                    try sources.append(try self.resolveUniform(binding));
                }

                const brush = self.brushes.get(d.brush);

                if (d.hasPoints()) {
                    brush.program.render(self.renderer.default_buffer, sources.items, &.{
                        .{
                            .idx = BrushReservedIndex.aspect.asIndex(),
                            .val = .{ .float = sphmath.calcAspect(dims[0], dims[1]) },
                        },
                        .{
                            .idx = BrushReservedIndex.distance_field.asIndex(),
                            .val = .{ .image = d.distance_field.inner },
                        },
                        .{
                            .idx = BrushReservedIndex.transform.asIndex(),
                            .val = .{ .mat3x3 = transform.inner },
                        },
                    });
                }
            },
            .text => |t| {
                if (t.buffer) |b| {
                    t.renderer.render(b, transform);
                }
            },
        }
    }

    pub fn renderObjectToTexture(self: *FrameRenderer, input: Object) anyerror!Texture {
        const dep_width, const dep_height = input.dims(self.objects);

        const texture = sphrender.makeTextureOfSize(@intCast(dep_width), @intCast(dep_height), .rgbaf32);
        errdefer texture.deinit();

        const render_context = try FramebufferRenderContext.init(texture, null);
        defer render_context.reset();

        // Output texture size is not the same as input size
        // Set viewport to full texture output size, restore original after
        const temp_viewport = sphrender.TemporaryViewport.init();
        defer temp_viewport.reset();

        const temp_scissor = sphrender.TemporaryScissor.init();
        defer temp_scissor.reset();

        gl.glClearColor(0.0, 0.0, 0.0, 0.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        temp_viewport.setViewport(@intCast(dep_width), @intCast(dep_height));
        temp_scissor.setAbsolute(0, 0, @intCast(dep_width), @intCast(dep_height));

        try self.renderObjectWithTransform(input, Transform.identity);
        return texture;
    }

    fn resolveUniform(
        self: *FrameRenderer,
        uniform: UniformValue,
    ) !ResolvedUniformValue {
        switch (uniform) {
            .image => |opt_id| {
                const texture = if (opt_id) |o|
                    try self.renderedTexture(o)
                else
                    Texture.invalid;

                return .{ .image = texture.inner };
            },
            inline else => |val, tag| {
                return @unionInit(ResolvedUniformValue, @tagName(tag), val);
            },
        }
    }
};

pub fn makeFrameRenderer(self: *Renderer, alloc: Allocator, objects: *Objects, shaders: *const ShaderStorage(ShaderId), brushes: *const ShaderStorage(BrushId), mouse_pos: sphmath.Vec2) FrameRenderer {
    return .{
        .alloc = alloc,
        .renderer = self,
        .objects = objects,
        .shaders = shaders,
        .brushes = brushes,
        .texture_cache = TextureCache.init(alloc, objects),
        .mouse_pos = mouse_pos,
    };
}

pub const UniformValue = union(UniformType) {
    image: ?ObjectId,
    float: f32,
    float2: [2]f32,
    float3: [3]f32,
    int: i32,
    uint: u32,
    mat3x3: sphmath.Mat3x3,

    pub fn fromDefault(default: UniformDefault) UniformValue {
        switch (default) {
            .image => return .{ .image = null },
            inline else => |val, tag| {
                return @unionInit(UniformValue, @tagName(tag), val);
            },
        }
    }
};

pub const CustomShaderReservedIndex = enum {
    aspect,
    transform,

    fn asIndex(self: CustomShaderReservedIndex) usize {
        return @intFromEnum(self);
    }
};

pub const BrushReservedIndex = enum {
    aspect,
    distance_field,
    transform,

    fn asIndex(self: BrushReservedIndex) usize {
        return @intFromEnum(self);
    }
};

const TextureCache = struct {
    inner: Inner,
    objects: *Objects,
    const Inner = std.AutoHashMap(ObjectId, Texture);

    fn init(alloc: Allocator, objects: *Objects) TextureCache {
        return .{
            .inner = Inner.init(alloc),
            .objects = objects,
        };
    }

    fn deinit(self: *TextureCache) void {
        var texture_it = self.inner.valueIterator();
        while (texture_it.next()) |t| {
            t.deinit();
        }

        self.inner.deinit();
    }

    fn get(self: *TextureCache, id: ObjectId) ?Texture {
        const object = self.objects.get(id);

        switch (object.data) {
            .filesystem => |f| return f.texture,
            .generated_mask => |m| return m.texture,
            else => {},
        }

        return self.inner.get(id);
    }

    fn put(self: *TextureCache, id: ObjectId, texture: Texture) !void {
        try self.inner.put(id, texture);
    }
};

pub const PathRenderBuffer = struct {
    vertex_array: gl.GLuint,
    vertex_buffer: gl.GLuint,

    fn init(vpos_location: gl.GLuint) PathRenderBuffer {
        var vertex_buffer: gl.GLuint = 0;
        gl.glCreateBuffers(1, &vertex_buffer);
        errdefer gl.glDeleteBuffers(1, &vertex_buffer);

        var vertex_array: gl.GLuint = 0;
        gl.glCreateVertexArrays(1, &vertex_array);
        errdefer gl.glDeleteVertexArrays(1, &vertex_array);

        gl.glVertexArrayVertexBuffer(vertex_array, 0, vertex_buffer, 0, 8);

        gl.glEnableVertexArrayAttrib(vertex_array, vpos_location);
        gl.glVertexArrayAttribFormat(vertex_array, vpos_location, 2, gl.GL_FLOAT, gl.GL_FALSE, 0);
        gl.glVertexArrayAttribBinding(vertex_array, 0, 0);
        return .{
            .vertex_array = vertex_array,
            .vertex_buffer = vertex_buffer,
        };
    }

    pub fn deinit(self: PathRenderBuffer) void {
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
    }

    pub fn setData(self: PathRenderBuffer, points: []const sphmath.Vec2) void {
        gl.glNamedBufferData(self.vertex_buffer, @intCast(points.len * 8), points.ptr, gl.GL_DYNAMIC_DRAW);
    }

    pub fn updatePoint(self: PathRenderBuffer, idx: usize, point: sphmath.Vec2) void {
        gl.glNamedBufferSubData(self.vertex_buffer, @intCast(idx * 8), 8, &point);
    }
};

pub const PathRenderProgram = struct {
    program: gl.GLuint,
    vpos_location: gl.GLuint,
    transform_location: gl.GLint,

    fn init() !PathRenderProgram {
        const program = try sphrender.compileLinkProgram(path_vertex_shader, path_fragment_shader);
        errdefer gl.glDeleteProgram(program);

        const vpos_location: gl.GLuint = @intCast(gl.glGetAttribLocation(program, "vPos"));
        const transform_location = gl.glGetUniformLocation(program, "transform");

        return .{
            .program = program,
            .vpos_location = vpos_location,
            .transform_location = transform_location,
        };
    }

    fn deinit(self: PathRenderProgram) void {
        gl.glDeleteProgram(self.program);
    }

    pub fn makeBuffer(self: PathRenderProgram) PathRenderBuffer {
        return PathRenderBuffer.init(self.vpos_location);
    }

    fn render(self: PathRenderProgram, render_buffer: PathRenderBuffer, transform: Transform, num_points: usize) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(render_buffer.vertex_array);
        gl.glUniformMatrix3fv(self.transform_location, 1, gl.GL_TRUE, &transform.inner.data);

        gl.glLineWidth(8);
        gl.glPointSize(20.0);

        gl.glDrawArrays(gl.GL_LINE_LOOP, 0, @intCast(num_points));
        gl.glDrawArrays(gl.GL_POINTS, 0, @intCast(num_points));
    }
};

pub const checkerboard_fragment_shader =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform float aspect;
    \\void main()
    \\{
    \\    ivec2 biguv = ivec2(uv.x * 100, uv.y * 100 / aspect);
    \\    bool is_dark = (biguv.x + biguv.y) % 2 == 0;
    \\    fragment = (is_dark) ? vec4(0.4, 0.4, 0.4, 1.0) : vec4(0.6, 0.6, 0.6, 1.0);
    \\}
;

const IdProgIdx = enum {
    input_image,
    composition_idx,
    transform,
};

pub const comp_id_frag =
    \\#version 330
    \\in vec2 uv;
    \\out uint fragment;
    \\uniform uint composition_idx;
    \\uniform sampler2D input_image;
    \\void main()
    \\{
    \\    float input_alpha = texture(input_image, uv).a;
    \\    if (input_alpha < 0.01) discard;
    \\    fragment = composition_idx;
    \\}
;

const DisplayIdProgIdx = enum {
    input_image,
    transform,
};

pub const display_id_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform usampler2D input_image;
    \\const vec3 palette[6] = vec3[6](
    \\    vec3(1.0, 0.0, 0.0),
    \\    vec3(0.0, 1.0, 0.0),
    \\    vec3(0.0, 0.0, 1.0),
    \\    vec3(1.0, 1.0, 0.0),
    \\    vec3(0.0, 1.0, 1.0),
    \\    vec3(1.0, 0.0, 1.0)
    \\);
    \\#define UINT_MAX uint(0xffffffff)
    \\void main()
    \\{
    \\    uint composition_idx = texture(input_image, vec2(uv.x, uv.y)).r;
    \\    if (composition_idx == UINT_MAX) discard;
    \\    vec3 color = palette[composition_idx % uint(6)];
    \\    fragment = vec4(color, 1.0);
    \\}
;

pub const mul_fragment_shader =
    \\#version 330 core
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D input_image;
    \\uniform sampler2D mask;
    \\void main()
    \\{
    \\    vec4 val = texture(input_image, vec2(uv.x, uv.y));
    \\    float mask_val = texture(mask, vec2(uv.x, uv.y)).r;
    \\    fragment = vec4(val.xyz, val.w * mask_val);
    \\}
;

const path_vertex_shader =
    \\#version 330
    \\uniform mat3x3 transform;
    \\in vec2 vPos;
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\}
;

pub const path_fragment_shader =
    \\#version 330
    \\out vec4 fragment;
    \\void main()
    \\{
    \\    fragment = vec4(1.0, 1.0, 1.0, 1.0);
    \\}
;
