const std = @import("std");
const Allocator = std.mem.Allocator;
const lin = @import("lin.zig");
const obj_mod = @import("object.zig");
const coords = @import("coords.zig");
const ShaderStorage = @import("ShaderStorage.zig");

const Objects = obj_mod.Objects;
const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Transform = lin.Transform;

const gl = @import("gl.zig");

program: PlaneRenderProgram,
background_program: PlaneRenderProgram,
path_program: PathRenderProgram,

const Renderer = @This();

pub fn init(alloc: Allocator) !Renderer {
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const plane_program = try PlaneRenderProgram.init(alloc, plane_vertex_shader, plane_fragment_shader);
    errdefer plane_program.deinit(alloc);

    const background_program = try PlaneRenderProgram.init(alloc, plane_vertex_shader, checkerboard_fragment_shader);
    errdefer background_program.deinit(alloc);

    const path_program = try PathRenderProgram.init();
    errdefer path_program.deinit(alloc);

    return .{
        .program = plane_program,
        .background_program = background_program,
        .path_program = path_program,
    };
}

pub fn deinit(self: *Renderer, alloc: Allocator) void {
    self.program.deinit(alloc);
    self.background_program.deinit(alloc);
    self.path_program.deinit();
}

pub fn render(self: *Renderer, alloc: Allocator, objects: *Objects, shaders: ShaderStorage, selected_object: ObjectId, transform: Transform, window_width: usize, window_height: usize) !void {
    gl.glViewport(0, 0, @intCast(window_width), @intCast(window_height));
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    var texture_cache: TextureCache = TextureCache.init(alloc, objects);
    defer texture_cache.deinit();

    const active_object = objects.get(selected_object);
    const object_dims = active_object.dims(objects);

    const toplevel_aspect = coords.calcAspect(object_dims[0], object_dims[1]);
    self.background_program.render(&.{}, transform, toplevel_aspect);

    try self.renderObjectWithTransform(alloc, objects, shaders, active_object.*, transform, &texture_cache);
}

fn renderedTexture(self: *Renderer, alloc: Allocator, objects: *Objects, shaders: ShaderStorage, texture_cache: *TextureCache, id: ObjectId) !Texture {
    if (texture_cache.get(id)) |t| {
        return t;
    }

    const texture = try self.renderObjectToTexture(alloc, objects, shaders, objects.get(id).*, texture_cache);
    try texture_cache.put(id, texture);
    return texture;
}

fn renderObjectWithTransform(self: *Renderer, alloc: Allocator, objects: *Objects, shaders: ShaderStorage, object: Object, transform: Transform, texture_cache: *TextureCache) !void {
    switch (object.data) {
        .composition => |c| {
            const composition_object_dims = object.dims(objects);
            const composition_object_aspect = coords.calcAspect(composition_object_dims[0], composition_object_dims[1]);

            for (c.objects.items) |composition_object| {
                const next_object = objects.get(composition_object.id);

                const compsoed_to_composition = composition_object.composedToCompositionTransform(objects, composition_object_aspect);
                const next_transform = compsoed_to_composition
                    .then(transform);

                try self.renderObjectWithTransform(alloc, objects, shaders, next_object.*, next_transform, texture_cache);
            }
        },
        .filesystem => |f| {
            self.program.render(&.{.{ .image = f.texture.inner }}, transform, coords.calcAspect(f.width, f.height));
        },
        .shader => |s| {
            var sources = std.ArrayList(ResolvedUniformValue).init(alloc);
            defer sources.deinit();

            for (s.bindings) |binding| {
                switch (binding) {
                    .image => |opt_id| {
                        const texture = if (opt_id) |o|
                            try self.renderedTexture(alloc, objects, shaders, texture_cache, o)
                        else
                            Texture.invalid;

                        try sources.append(.{ .image = texture.inner });
                    },
                    .float => |f| {
                        try sources.append(.{ .float = f });
                    },
                    .float3 => |f| {
                        try sources.append(.{ .float3 = f });
                    },
                    .int => |i| {
                        try sources.append(.{ .int = i });
                    },
                }
            }

            const object_dims = object.dims(objects);
            shaders.get(s.program).program.render(sources.items, transform, coords.calcAspect(object_dims[0], object_dims[1]));
        },
        .path => |p| {
            const display_object = objects.get(p.display_object);
            try self.renderObjectWithTransform(alloc, objects, shaders, display_object.*, transform, texture_cache);

            self.path_program.render(p.render_buffer, transform, p.points.items.len);
        },
        .generated_mask => |m| {
            const object_dims = object.dims(objects);
            self.program.render(&.{.{ .image = m.texture.inner }}, transform, coords.calcAspect(object_dims[0], object_dims[1]));
        },
    }
}

const TemporaryViewport = struct {
    previous_viewport_args: [4]gl.GLint,

    fn init() TemporaryViewport {
        var current_viewport = [1]gl.GLint{0} ** 4;
        gl.glGetIntegerv(gl.GL_VIEWPORT, &current_viewport);
        return .{
            .previous_viewport_args = current_viewport,
        };
    }

    fn setViewport(_: TemporaryViewport, width: gl.GLint, height: gl.GLint) void {
        gl.glViewport(0, 0, @intCast(width), @intCast(height));
    }

    fn reset(self: TemporaryViewport) void {
        gl.glViewport(
            self.previous_viewport_args[0],
            self.previous_viewport_args[1],
            self.previous_viewport_args[2],
            self.previous_viewport_args[3],
        );
    }
};

fn renderObjectToTexture(self: *Renderer, alloc: Allocator, objects: *Objects, shaders: ShaderStorage, input: Object, texture_cache: *TextureCache) anyerror!Texture {
    const dep_width, const dep_height = input.dims(objects);

    const texture = makeTextureOfSize(@intCast(dep_width), @intCast(dep_height));
    errdefer texture.deinit();

    const render_context = FramebufferRenderContext.init(texture);
    defer render_context.reset();

    // Output texture size is not the same as input size
    // Set viewport to full texture output size, restore original after
    const temp_viewport = TemporaryViewport.init();
    defer temp_viewport.reset();

    temp_viewport.setViewport(@intCast(dep_width), @intCast(dep_height));

    try self.renderObjectWithTransform(alloc, objects, shaders, input, Transform.identity, texture_cache);
    return texture;
}

pub const Texture = struct {
    pub const invalid = Texture{ .inner = 0 };

    inner: gl.GLuint,

    pub fn deinit(self: Texture) void {
        gl.glDeleteTextures(1, &self.inner);
    }
};

pub const UniformType = enum {
    image,
    float,
    float3,
    int,

    fn fromGlType(typ: gl.GLenum) ?UniformType {
        switch (typ) {
            gl.GL_SAMPLER_2D => return .image,
            gl.GL_FLOAT => return .float,
            gl.GL_FLOAT_VEC3 => return .float3,
            gl.GL_INT => return .int,
            else => return null,
        }
    }
};

const ResolvedUniformValue = union(UniformType) {
    image: gl.GLuint,
    float: f32,
    float3: [3]f32,
    int: i32,
};

pub const UniformValue = union(UniformType) {
    image: ?ObjectId,
    float: f32,
    float3: [3]f32,
    int: i32,
};

pub const Uniform = struct {
    name: []const u8,
    loc: gl.GLint,
    default: UniformValue,

    fn clone(self: Uniform, alloc: Allocator) !Uniform {
        return .{
            .name = try alloc.dupe(u8, self.name),
            .loc = self.loc,
            .default = self.default,
        };
    }

    fn deinit(self: Uniform, alloc: Allocator) void {
        alloc.free(self.name);
    }
};

pub const PlaneRenderProgram = struct {
    program: gl.GLuint,
    transform_location: gl.GLint,
    aspect_location: gl.GLint,
    vertex_buffer: gl.GLuint,
    vertex_array: gl.GLuint,

    uniforms: []Uniform,

    pub fn init(alloc: Allocator, vs: [:0]const u8, fs: [:0]const u8) !PlaneRenderProgram {
        const program = try compileLinkProgram(vs, fs);
        errdefer gl.glDeleteProgram(program);

        const vpos_location = gl.glGetAttribLocation(program, "vPos");
        const vuv_location = gl.glGetAttribLocation(program, "vUv");
        const transform_location = gl.glGetUniformLocation(program, "transform");
        const aspect_location = gl.glGetUniformLocation(program, "aspect");

        var uniforms = std.ArrayList(Uniform).init(alloc);
        defer {
            for (uniforms.items) |item| {
                item.deinit(alloc);
            }
            uniforms.deinit();
        }

        var uniform_it = try ProgramUniformIt.init(program);
        while (uniform_it.next()) |uniform| {
            const cloned = try uniform.clone(alloc);
            errdefer cloned.deinit(alloc);
            try uniforms.append(cloned);
        }

        var vertex_buffer: gl.GLuint = 0;
        gl.glGenBuffers(1, &vertex_buffer);
        errdefer gl.glDeleteBuffers(1, &vertex_buffer);

        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, plane_vertices.len * 4, plane_vertices.ptr, gl.GL_STATIC_DRAW);

        var vertex_array: gl.GLuint = 0;
        gl.glGenVertexArrays(1, &vertex_array);
        errdefer gl.glDeleteVertexArrays(1, &vertex_array);

        gl.glBindVertexArray(vertex_array);

        gl.glEnableVertexAttribArray(@intCast(vpos_location));
        gl.glVertexAttribPointer(@intCast(vpos_location), 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * 4, null);

        gl.glEnableVertexAttribArray(@intCast(vuv_location));
        gl.glVertexAttribPointer(@intCast(vuv_location), 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * 4, @ptrFromInt(8));

        return .{
            .program = program,
            .aspect_location = aspect_location,
            .vertex_buffer = vertex_buffer,
            .vertex_array = vertex_array,
            .transform_location = transform_location,
            .uniforms = try uniforms.toOwnedSlice(),
        };
    }

    pub fn deinit(self: PlaneRenderProgram, alloc: Allocator) void {
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
        gl.glDeleteProgram(self.program);

        for (self.uniforms) |uniform| {
            uniform.deinit(alloc);
        }
        alloc.free(self.uniforms);
    }

    pub fn render(self: PlaneRenderProgram, uniforms: []const ResolvedUniformValue, transform: lin.Transform, aspect: f32) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(self.vertex_array);
        gl.glUniformMatrix3fv(self.transform_location, 1, gl.GL_TRUE, &transform.inner.data);
        gl.glUniform1f(self.aspect_location, aspect);

        for (self.uniforms, 0..) |uniform, i| {
            if (i >= uniforms.len) continue;
            const val = uniforms[i];
            if (std.meta.activeTag(uniform.default) != std.meta.activeTag(val)) {
                std.log.err("Uniform type mismatch", .{});
                continue;
            }

            switch (val) {
                .image => |t| {
                    const texture_unit = gl.GL_TEXTURE0 + i;
                    gl.glActiveTexture(@intCast(texture_unit));
                    gl.glBindTexture(gl.GL_TEXTURE_2D, t);
                    gl.glUniform1i(uniform.loc, @intCast(i));
                },
                .float => |f| {
                    gl.glUniform1f(uniform.loc, f);
                },
                .float3 => |f| {
                    gl.glUniform3f(uniform.loc, f[0], f[1], f[2]);
                },
                .int => |v| {
                    gl.glUniform1i(uniform.loc, v);
                },
            }
        }

        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
    }
};

const ProgramUniformIt = struct {
    num_uniforms: usize,
    program: gl.GLuint,
    name_buf: [1024]u8 = undefined,
    idx: usize = 0,

    fn init(program: gl.GLuint) !ProgramUniformIt {
        var num_uniforms: gl.GLint = 0;
        gl.glGetProgramiv(program, gl.GL_ACTIVE_UNIFORMS, &num_uniforms);

        if (num_uniforms < 0) {
            return error.InvalidNumUniforms;
        }

        return .{
            .program = program,
            .num_uniforms = @intCast(num_uniforms),
        };
    }

    fn next(self: *ProgramUniformIt) ?Uniform {
        while (self.idx < self.num_uniforms) {
            defer self.idx += 1;

            var name_len: gl.GLsizei = 0;
            var uniform_size: gl.GLint = 0;
            var uniform_type: gl.GLenum = 0;

            gl.glGetActiveUniform(
                self.program,
                @intCast(self.idx),
                @intCast(self.name_buf.len),
                &name_len,
                &uniform_size,
                &uniform_type,
                &self.name_buf,
            );

            const parsed_typ = UniformType.fromGlType(uniform_type) orelse continue;

            const default: UniformValue = switch (parsed_typ) {
                .image => .{ .image = null },
                .float => blk: {
                    var default: f32 = 0.0;
                    gl.glGetUniformfv(self.program, @intCast(self.idx), &default);
                    break :blk .{ .float = default };
                },
                .float3 => blk: {
                    var default: [3]f32 = .{ 0.0, 0.0, 0.0 };
                    gl.glGetUniformfv(self.program, @intCast(self.idx), &default);
                    break :blk .{ .float3 = default };
                },
                .int => blk: {
                    var default: gl.GLint = 0;
                    gl.glGetUniformiv(self.program, @intCast(self.idx), &default);
                    break :blk .{ .int = @intCast(default) };
                },
            };
            if (name_len < 0) continue;

            return .{
                .name = self.name_buf[0..@intCast(name_len)],
                .loc = @intCast(self.idx),
                .default = default,
            };
        }

        return null;
    }
};

pub const FramebufferRenderContext = struct {
    fbo: gl.GLuint,
    prev_fbo: gl.GLint,

    pub fn init(render_texture: Texture) FramebufferRenderContext {
        var fbo: gl.GLuint = undefined;
        gl.glGenFramebuffers(1, &fbo);

        var prev_id: gl.GLint = 0;
        gl.glGetIntegerv(gl.GL_DRAW_FRAMEBUFFER_BINDING, &prev_id);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo);
        gl.glFramebufferTexture2D(
            gl.GL_FRAMEBUFFER,
            gl.GL_COLOR_ATTACHMENT0,
            gl.GL_TEXTURE_2D,
            render_texture.inner,
            0,
        );

        return .{
            .fbo = fbo,
            .prev_fbo = prev_id,
        };
    }

    pub fn reset(self: FramebufferRenderContext) void {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
        gl.glDeleteFramebuffers(1, &self.fbo);
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

    pub fn setData(self: PathRenderBuffer, points: []const lin.Vec2) void {
        gl.glNamedBufferData(self.vertex_buffer, @intCast(points.len * 8), points.ptr, gl.GL_DYNAMIC_DRAW);
    }

    pub fn updatePoint(self: PathRenderBuffer, idx: usize, point: lin.Vec2) void {
        gl.glNamedBufferSubData(self.vertex_buffer, @intCast(idx * 8), 8, &point);
    }
};

pub const PathRenderProgram = struct {
    program: gl.GLuint,
    vpos_location: gl.GLuint,
    transform_location: gl.GLint,

    fn init() !PathRenderProgram {
        const program = try compileLinkProgram(path_vertex_shader, path_fragment_shader);
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

fn checkShaderCompilation(shader: gl.GLuint) !void {
    var status: c_int = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &status);

    if (status == gl.GL_TRUE) {
        return;
    }

    var buf: [1024]u8 = undefined;
    var len: gl.GLsizei = 0;
    gl.glGetShaderInfoLog(shader, buf.len, &len, &buf);
    std.log.err("Shader compilation failed: {s}", .{buf[0..@intCast(len)]});
    return error.ShaderCompilationFailed;
}

fn checkProgramLink(program: gl.GLuint) !void {
    var status: c_int = 0;
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &status);

    if (status == gl.GL_TRUE) {
        return;
    }

    var buf: [1024]u8 = undefined;
    var len: gl.GLsizei = 0;
    gl.glGetProgramInfoLog(program, buf.len, &len, &buf);
    std.log.err("Program linking failed: {s}", .{buf[0..@intCast(len)]});
    return error.ProgramLinkFailed;
}

fn compileLinkProgram(vs: [:0]const u8, fs: [:0]const u8) !gl.GLuint {
    const vertex_shader = gl.glCreateShader(gl.GL_VERTEX_SHADER);
    gl.glShaderSource(vertex_shader, 1, @ptrCast(&vs), null);
    gl.glCompileShader(vertex_shader);
    try checkShaderCompilation(vertex_shader);
    defer gl.glDeleteShader(vertex_shader);

    const fragment_shader = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
    gl.glShaderSource(fragment_shader, 1, @ptrCast(&fs), null);
    gl.glCompileShader(fragment_shader);
    try checkShaderCompilation(fragment_shader);
    defer gl.glDeleteShader(fragment_shader);

    const program = gl.glCreateProgram();
    gl.glAttachShader(program, vertex_shader);
    gl.glAttachShader(program, fragment_shader);
    gl.glLinkProgram(program);
    try checkProgramLink(program);

    return program;
}

pub fn makeTextureFromR(data: []const u8, width: usize) Texture {
    const texture = makeTextureCommon();
    const height = data.len / width;
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RED, @intCast(width), @intCast(height), 0, gl.GL_RED, gl.GL_UNSIGNED_BYTE, data.ptr);

    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);

    return texture;
}

pub fn makeTextureFromRgba(data: []const u8, width: usize) Texture {
    const texture = makeTextureCommon();

    const height = data.len / width / 4;
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(width), @intCast(height), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, data.ptr);

    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);

    return texture;
}

pub fn makeTextureOfSize(width: u31, height: u31) Texture {
    const texture = makeTextureCommon();
    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGBA,
        width,
        height,
        0,
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        null,
    );
    return texture;
}

fn makeTextureCommon() Texture {
    var texture: gl.GLuint = 0;

    // Generate the texture object
    gl.glGenTextures(1, &texture);
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture);

    // Set texture parameters (you can adjust these for your needs)
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE); // Wrap horizontally
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE); // Wrap vertically
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR); // Minification filter
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR); // Magnification filter

    return .{ .inner = texture };
}

const plane_vertices: []const f32 = &.{
    -1.0, -1.0, 0.0, 0.0,
    1.0,  -1.0, 1.0, 0.0,
    -1.0, 1.0,  0.0, 1.0,
    1.0,  1.0,  1.0, 1.0,
};

pub const plane_vertex_shader =
    \\#version 330
    \\in vec2 vUv;
    \\in vec2 vPos;
    \\out vec2 uv;
    \\uniform mat3x3 transform;
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\    uv = vUv;
    \\}
;

pub const plane_fragment_shader =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform float aspect;
    \\uniform sampler2D input_image;  // The texture
    \\void main()
    \\{
    \\    fragment = texture(input_image, vec2(uv.x, uv.y));
    \\}
;

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
