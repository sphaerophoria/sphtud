const std = @import("std");
const Allocator = std.mem.Allocator;
const obj_mod = @import("object.zig");
const coords = @import("coords.zig");
const shader_storage = @import("shader_storage.zig");
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const sphtext = @import("sphtext");
const tool = @import("tool.zig");
const ToolParams = tool.ToolParams;
const TextRenderer = sphtext.TextRenderer;
const gl = sphrender.gl;
const ShaderProgram = sphrender.shader_program.Program;
const PlaneProgram = sphrender.xyuvt_program.Program;
const PlaneBuffer = sphrender.xyuvt_program.Buffer;
const GlAlloc = sphrender.GlAlloc;

pub const ResolvedUniformValue = sphrender.ResolvedUniformValue;
pub const UniformType = sphrender.UniformType;
pub const UniformDefault = sphrender.UniformDefault;
pub const Uniform = sphrender.Uniform;
pub const Texture = sphrender.Texture;
pub const FramebufferRenderContext = sphrender.FramebufferRenderContext;

const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;

const Objects = obj_mod.Objects;
const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Transform = sphmath.Transform;

const TransformOnlyUniform = struct {
    transform: sphmath.Mat3x3,
};

sampler_program: PlaneProgram(sphrender.xyuvt_program.ImageSamplerUniforms),
sampler_buffer: PlaneBuffer,
background_program: PlaneProgram(BackgroundUniforms),
background_buffer: PlaneBuffer,
path_program: PathRenderProgram,
comp_id_program: PlaneProgram(IdUniforms),
comp_id_buffer: PlaneBuffer,
display_id_program: PlaneProgram(DisplayIdUniforms),
display_id_buffer: PlaneBuffer,
eraser_preview_program: PlaneProgram(TransformOnlyUniform),
eraser_preview_buffer: PlaneBuffer,
eraser_preview_start: ?std.time.Instant = null,
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

pub fn init(gl_alloc: *GlAlloc) !Renderer {
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    gl.glDebugMessageCallback(glDebugCallback, null);

    const sampler_program = try PlaneProgram(sphrender.xyuvt_program.ImageSamplerUniforms).init(gl_alloc, sphrender.xyuvt_program.image_sampler_frag);

    const background_program = try PlaneProgram(BackgroundUniforms).init(gl_alloc, checkerboard_fragment_shader);

    const background_buffer = try background_program.makeFullScreenPlane(gl_alloc);

    const path_program = try PathRenderProgram.init(gl_alloc);

    const distance_field_generator = try sphrender.DistanceFieldGenerator.init(gl_alloc);

    const comp_id_program = try PlaneProgram(IdUniforms).init(gl_alloc, comp_id_frag);

    const comp_id_buffer = try comp_id_program.makeFullScreenPlane(gl_alloc);

    const display_id_prog = try PlaneProgram(DisplayIdUniforms).init(gl_alloc, display_id_frag);
    const eraser_perview_program = try PlaneProgram(TransformOnlyUniform).init(gl_alloc, eraser_preview_shader);

    return .{
        .sampler_program = sampler_program,
        .sampler_buffer = try sampler_program.makeFullScreenPlane(gl_alloc),
        .background_program = background_program,
        .background_buffer = background_buffer,
        .path_program = path_program,
        .comp_id_program = comp_id_program,
        .comp_id_buffer = comp_id_buffer,
        .eraser_preview_program = eraser_perview_program,
        .eraser_preview_buffer = try eraser_perview_program.makeFullScreenPlane(gl_alloc),
        .display_id_program = display_id_prog,
        .display_id_buffer = try display_id_prog.makeFullScreenPlane(gl_alloc),
        .distance_field_generator = distance_field_generator,
    };
}

pub const FrameRenderer = struct {
    alloc: Allocator,
    gl_alloc: *GlAlloc,
    renderer: *Renderer,
    objects: *Objects,
    shaders: *const ShaderStorage(ShaderId),
    brushes: *const ShaderStorage(BrushId),
    texture_cache: TextureCache,

    pub fn render(self: *FrameRenderer, selected_object: ObjectId, transform: Transform) !void {
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const active_object = self.objects.get(selected_object);
        const object_dims = active_object.dims(self.objects);

        const toplevel_aspect = sphmath.calcAspect(object_dims[0], object_dims[1]);

        self.renderer.background_program.render(
            self.renderer.background_buffer,
            .{
                .aspect = toplevel_aspect,
                .transform = transform.inner,
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

        const output_tex = try sphrender.makeTextureOfSize(self.gl_alloc, size, size, .ri32);

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
                self.renderer.comp_id_buffer,
                .{
                    .input_image = tex,
                    .composition_idx = @intCast(comp_idx),
                    .transform = total_transform.inner,
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
            },
            .filesystem => |f| {
                self.renderer.sampler_program.render(self.renderer.sampler_buffer, .{
                    .input_image = f.texture,
                    .transform = transform.inner,
                });
            },
            .shader => |s| {
                var sources = std.ArrayList(ResolvedUniformValue).init(self.alloc);
                defer sources.deinit();

                for (s.bindings) |binding| {
                    try sources.append(try self.resolveUniform(binding));
                }

                const object_dims = object.dims(self.objects);
                const shader = self.shaders.get(s.program);
                shader.program.renderWithExtra(
                    shader.buffer,
                    .{
                        .aspect = sphmath.calcAspect(object_dims[0], object_dims[1]),
                        .transform = transform.inner,
                    },
                    shader.uniforms,
                    sources.items,
                );
            },
            .path => |p| {
                const display_object = self.objects.get(p.display_object);
                try self.renderObjectWithTransform(display_object.*, transform);

                self.renderer.path_program.render(p.render_buffer, transform, p.points.items.len);
            },
            .generated_mask => |m| {
                self.renderer.sampler_program.render(self.renderer.sampler_buffer, .{
                    .input_image = m.texture,
                    .transform = transform.inner,
                });
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
                    brush.program.renderWithExtra(brush.buffer, .{
                        .aspect = sphmath.calcAspect(dims[0], dims[1]),
                        .distance_field = d.distance_field,
                        .transform = transform.inner,
                    }, brush.uniforms, sources.items);
                }
            },
            .text => |t| {
                t.renderer.render(t.buffer, transform);
            },
        }
    }

    pub fn renderObjectToTexture(self: *FrameRenderer, input: Object) anyerror!Texture {
        const dep_width, const dep_height = input.dims(self.objects);

        const texture = try sphrender.makeTextureOfSize(self.gl_alloc, @intCast(dep_width), @intCast(dep_height), .rgbaf32);

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

    pub fn makeUiRenderer(self: *FrameRenderer, tool_params: ToolParams, mouse_pos: sphmath.Vec2, now: std.time.Instant) UiRenderer {
        return .{
            .frame_renderer = self,
            .tool_params = tool_params,
            .mouse_pos = mouse_pos,
            .now = now,
        };
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

pub fn makeFrameRenderer(
    self: *Renderer,
    alloc: Allocator,
    gl_alloc: *GlAlloc,
    objects: *Objects,
    shaders: *const ShaderStorage(ShaderId),
    brushes: *const ShaderStorage(BrushId),
) FrameRenderer {
    return .{
        .alloc = alloc,
        .gl_alloc = gl_alloc,
        .renderer = self,
        .objects = objects,
        .shaders = shaders,
        .brushes = brushes,
        .texture_cache = TextureCache.init(alloc, objects),
    };
}

pub const UiRenderer = struct {
    frame_renderer: *FrameRenderer,
    tool_params: ToolParams,
    mouse_pos: sphmath.Vec2,
    now: std.time.Instant,

    pub fn render(self: *const UiRenderer, object: Object, transform: Transform) !void {
        switch (object.data) {
            .drawing => {
                switch (self.tool_params.active_drawing_tool) {
                    .brush => {},
                    .eraser => blk: {
                        // Render preview
                        const inv = transform.invert();
                        const screen_pos_w = transform.apply(.{ self.mouse_pos[0], self.mouse_pos[1], 1.0 });
                        const screen_pos = sphmath.applyHomogenous(screen_pos_w);

                        const mouse_off_screen = screen_pos[0] < -1.0 or screen_pos[0] > 1.0 or
                            screen_pos[1] < -1.0 or screen_pos[1] > 1.0;

                        const renderer = self.frame_renderer.renderer;

                        const wants_preview = renderer.eraser_preview_start != null and self.now.since(renderer.eraser_preview_start.?) < 500 * std.time.ns_per_ms;

                        // FIXME: Obviously split a fn
                        const eraser_preview_center: sphmath.Vec2 =
                            if (mouse_off_screen and wants_preview)
                            sphmath.applyHomogenous(inv.apply(.{ 0.0, 0.0, 1.0 }))
                        else if (!mouse_off_screen)
                            self.mouse_pos
                        else
                            break :blk;

                        const preview_transform = Transform.scale(
                            self.tool_params.eraser_width,
                            self.tool_params.eraser_width,
                        )
                            .then(Transform.translate(eraser_preview_center[0], eraser_preview_center[1]))
                            .then(transform);

                        renderer.eraser_preview_program.render(renderer.eraser_preview_buffer, .{
                            .transform = preview_transform.inner,
                        });
                    },
                }
            },
            .composition => {
                if (self.tool_params.composition_debug) {
                    // Res?
                    const output_tex = try self.frame_renderer.renderCompositionIdMask(object, 50, self.mouse_pos);

                    const preview_scale = 0.2;

                    const preview_transform = Transform.scale(preview_scale, preview_scale)
                        .then(Transform.translate(1.0 - preview_scale, preview_scale - 1.0));

                    const renderer = self.frame_renderer.renderer;

                    renderer.display_id_program.render(renderer.display_id_buffer, .{
                        .input_image = output_tex,
                        .transform = preview_transform.inner,
                    });
                }
            },
            else => return,
        }
    }
};

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

pub const CustomShaderUniforms = struct {
    aspect: f32,
    transform: sphmath.Mat3x3,
};

pub const BrushUniforms = struct {
    aspect: f32,
    distance_field: Texture,
    transform: sphmath.Mat3x3,
};

const BackgroundUniforms = struct {
    aspect: f32,
    transform: sphmath.Mat3x3,
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

    fn init(gl_alloc: *GlAlloc, vpos_location: gl.GLuint) !PathRenderBuffer {
        const vertex_buffer = try gl_alloc.createBuffer();
        const vertex_array = try gl_alloc.createArray();

        gl.glVertexArrayVertexBuffer(vertex_array, 0, vertex_buffer, 0, 8);

        gl.glEnableVertexArrayAttrib(vertex_array, vpos_location);
        gl.glVertexArrayAttribFormat(vertex_array, vpos_location, 2, gl.GL_FLOAT, gl.GL_FALSE, 0);
        gl.glVertexArrayAttribBinding(vertex_array, 0, 0);
        return .{
            .vertex_array = vertex_array,
            .vertex_buffer = vertex_buffer,
        };
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

    fn init(gl_alloc: *GlAlloc) !PathRenderProgram {
        const program = try sphrender.compileLinkProgram(gl_alloc, path_vertex_shader, path_fragment_shader);

        const vpos_location: gl.GLuint = @intCast(gl.glGetAttribLocation(program, "vPos"));
        const transform_location = gl.glGetUniformLocation(program, "transform");

        return .{
            .program = program,
            .vpos_location = vpos_location,
            .transform_location = transform_location,
        };
    }

    pub fn makeBuffer(
        self: PathRenderProgram,
        gl_alloc: *GlAlloc,
    ) !PathRenderBuffer {
        return try PathRenderBuffer.init(gl_alloc, self.vpos_location);
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

const IdUniforms = struct {
    input_image: Texture,
    composition_idx: u32,
    transform: sphmath.Mat3x3,
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

const DisplayIdUniforms = struct {
    input_image: Texture,
    transform: sphmath.Mat3x3,
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

pub const eraser_preview_shader =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\void main()
    \\{
    \\    vec2 center_offs = uv - 0.5;
    \\    float alpha = (length(center_offs) < 0.5) ? 0.5 : 0.0;
    \\    fragment = vec4(0.0, 0.0, 1.0, alpha);
    \\}
;
