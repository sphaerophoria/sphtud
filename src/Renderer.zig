const std = @import("std");
const Allocator = std.mem.Allocator;
const lin = @import("lin.zig");
const obj_mod = @import("object.zig");
const coords = @import("coords.zig");

const Objects = obj_mod.Objects;
const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Transform = lin.Transform;

const gl = @import("gl.zig");

program: PlaneRenderProgram,
path_program: PathRenderProgram,

const Renderer = @This();

pub fn init(alloc: Allocator) !Renderer {
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const plane_program = try PlaneRenderProgram.init(alloc, plane_vertex_shader, plane_fragment_shader, &.{"u_texture"});
    errdefer plane_program.deinit(alloc);

    const path_program = try PathRenderProgram.init();
    errdefer path_program.deinit(alloc);

    return .{
        .program = plane_program,
        .path_program = path_program,
    };
}

pub fn deinit(self: *Renderer, alloc: Allocator) void {
    self.program.deinit(alloc);
}

pub fn render(self: *Renderer, alloc: Allocator, objects: *Objects, selected_object: ObjectId, transform: Transform, window_width: usize, window_height: usize) !void {
    gl.glViewport(0, 0, @intCast(window_width), @intCast(window_height));
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    var texture_cache: TextureCache = TextureCache.init(alloc, objects);
    defer texture_cache.deinit();

    const active_object = objects.get(selected_object);
    try self.renderObjectWithTransform(alloc, objects, active_object.*, transform, &texture_cache);
}

fn renderedTexture(self: *Renderer, alloc: Allocator, objects: *Objects, texture_cache: *TextureCache, id: ObjectId) !Texture {
    if (texture_cache.get(id)) |t| {
        return t;
    }

    const texture = try self.renderObjectToTexture(alloc, objects, objects.get(id).*, texture_cache);
    try texture_cache.put(id, texture);
    return texture;
}

fn renderObjectWithTransform(self: *Renderer, alloc: Allocator, objects: *Objects, object: Object, transform: Transform, texture_cache: *TextureCache) !void {
    switch (object.data) {
        .composition => |c| {
            for (c.objects.items) |composition_object| {
                const next_object = objects.get(composition_object.id);
                switch (next_object.data) {
                    .composition => return error.NestedComposition,
                    else => {},
                }
                const next_object_dims = next_object.dims(objects);
                const composition_dims = object.dims(objects);

                const next_transform =
                    coords.aspectRatioCorrectedFill(
                    next_object_dims[0],
                    next_object_dims[1],
                    composition_dims[0],
                    composition_dims[1],
                )
                    .then(composition_object.transform)
                    .then(transform);

                try self.renderObjectWithTransform(alloc, objects, next_object.*, next_transform, texture_cache);
            }
        },
        .filesystem => |f| {
            self.program.render(&.{f.texture}, transform);
        },
        .shader => |s| {
            var sources = std.ArrayList(Texture).init(alloc);
            defer sources.deinit();

            for (s.input_images) |input_image| {
                const texture = try self.renderedTexture(alloc, objects, texture_cache, input_image);
                try sources.append(texture);
            }

            s.program.render(sources.items, transform);
        },
        .path => |p| {
            const display_object = objects.get(p.display_object);
            try self.renderObjectWithTransform(alloc, objects, display_object.*, transform, texture_cache);

            self.path_program.render(p.vertex_array, transform, p.selected_point, p.points.items.len);
        },
        .generated_mask => |m| {
            self.program.render(&.{m.texture}, transform);
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

fn renderObjectToTexture(self: *Renderer, alloc: Allocator, objects: *Objects, input: Object, texture_cache: *TextureCache) anyerror!Texture {
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

    try self.renderObjectWithTransform(alloc, objects, input, Transform.identity, texture_cache);
    return texture;
}

pub const Texture = struct {
    pub const invalid = Texture{ .inner = std.math.maxInt(gl.GLuint) };

    inner: gl.GLuint,

    pub fn deinit(self: Texture) void {
        gl.glDeleteTextures(1, &self.inner);
    }
};

pub const PlaneRenderProgram = struct {
    program: gl.GLuint,
    transform_location: gl.GLint,
    texture_locations: []gl.GLint,
    vertex_buffer: gl.GLuint,
    vertex_array: gl.GLuint,

    pub fn init(alloc: Allocator, vs: [:0]const u8, fs: [:0]const u8, texture_names: []const [:0]const u8) !PlaneRenderProgram {
        const program = try compileLinkProgram(vs, fs);
        errdefer gl.glDeleteProgram(program);

        const vpos_location = gl.glGetAttribLocation(program, "vPos");
        const vuv_location = gl.glGetAttribLocation(program, "vUv");
        const transform_location = gl.glGetUniformLocation(program, "transform");

        var texture_locations = std.ArrayList(gl.GLint).init(alloc);
        defer texture_locations.deinit();

        for (texture_names) |n| {
            const texture_location = gl.glGetUniformLocation(program, n);
            try texture_locations.append(texture_location);
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
            .texture_locations = try texture_locations.toOwnedSlice(),
            .vertex_buffer = vertex_buffer,
            .vertex_array = vertex_array,
            .transform_location = transform_location,
        };
    }

    pub fn deinit(self: PlaneRenderProgram, alloc: Allocator) void {
        alloc.free(self.texture_locations);
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
        gl.glDeleteProgram(self.program);
    }

    fn render(self: PlaneRenderProgram, textures: []const Texture, transform: lin.Transform) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(self.vertex_array);
        gl.glUniformMatrix3fv(self.transform_location, 1, gl.GL_TRUE, &transform.inner.data);

        for (0..textures.len) |i| {
            const texture_unit = gl.GL_TEXTURE0 + i;
            gl.glActiveTexture(@intCast(texture_unit));
            gl.glBindTexture(gl.GL_TEXTURE_2D, textures[i].inner);
            gl.glUniform1i(self.texture_locations[i], @intCast(i));
        }

        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
    }
};

pub const FramebufferRenderContext = struct {
    fbo: gl.GLuint,

    pub fn init(render_texture: Texture) FramebufferRenderContext {
        var fbo: gl.GLuint = undefined;
        gl.glGenFramebuffers(1, &fbo);

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
        };
    }

    pub fn reset(self: FramebufferRenderContext) void {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
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

const PathRenderProgram = struct {
    program: gl.GLuint,
    vpos_location: gl.GLint,
    transform_location: gl.GLint,

    fn init() !PathRenderProgram {
        const program = try compileLinkProgram(path_vertex_shader, path_fragment_shader);
        errdefer gl.glDeleteProgram(program);

        const vpos_location = gl.glGetAttribLocation(program, "vPos");
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

    fn render(self: PathRenderProgram, vertex_array: gl.GLuint, transform: Transform, selected_point: ?usize, num_points: usize) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(vertex_array);
        gl.glUniformMatrix3fv(self.transform_location, 1, gl.GL_TRUE, &transform.inner.data);

        gl.glLineWidth(8);
        gl.glPointSize(20.0);

        gl.glDrawArrays(gl.GL_LINE_LOOP, 0, @intCast(num_points));
        gl.glDrawArrays(gl.GL_POINTS, 0, @intCast(num_points));

        if (selected_point) |p| {
            gl.glPointSize(50.0);
            gl.glDrawArrays(gl.GL_POINTS, @intCast(p), 1);
        }
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
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT); // Wrap horizontally
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT); // Wrap vertically
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
    \\uniform sampler2D u_texture;  // The texture
    \\void main()
    \\{
    \\    fragment = texture(u_texture, vec2(uv.x, uv.y));
    \\}
;

pub const mul_fragment_shader =
    \\#version 330 core
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D u_texture;
    \\uniform sampler2D u_texture_2;
    \\void main()
    \\{
    \\    vec4 val = texture(u_texture, vec2(uv.x, uv.y));
    \\    float mask = texture(u_texture_2, vec2(uv.x, uv.y)).r;
    \\    fragment = vec4(val.xyz, val.w * mask);
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
