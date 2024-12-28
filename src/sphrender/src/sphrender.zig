pub const gl = @import("gl.zig");
pub const geometry = @import("geometry.zig");
pub const PlaneRenderProgram = @import("PlaneRenderProgram.zig");
pub const DistanceFieldGenerator = @import("DistanceFieldGenerator.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");

pub const UniformType = enum {
    image,
    float,
    float2,
    float3,
    int,

    pub fn fromGlType(typ: gl.GLenum) ?UniformType {
        switch (typ) {
            gl.GL_SAMPLER_2D => return .image,
            gl.GL_FLOAT => return .float,
            gl.GL_FLOAT_VEC2 => return .float2,
            gl.GL_FLOAT_VEC3 => return .float3,
            gl.GL_INT => return .int,
            else => return null,
        }
    }
};

pub const UniformDefault = union(UniformType) {
    image,
    float: f32,
    float2: [2]f32,
    float3: [3]f32,
    int: i32,
};

pub const ResolvedUniformValue = union(UniformType) {
    image: gl.GLuint,
    float: f32,
    float2: [2]f32,
    float3: [3]f32,
    int: i32,
};

pub const ReservedUniformValue = struct {
    idx: usize,
    val: ResolvedUniformValue,
};

pub const Uniform = struct {
    name: []const u8,
    loc: gl.GLint,
    default: UniformDefault,

    pub fn clone(self: Uniform, alloc: Allocator) !Uniform {
        return .{
            .name = try alloc.dupe(u8, self.name),
            .loc = self.loc,
            .default = self.default,
        };
    }

    pub fn deinit(self: Uniform, alloc: Allocator) void {
        alloc.free(self.name);
    }
};

pub fn checkShaderCompilation(shader: gl.GLuint) !void {
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

pub fn checkProgramLink(program: gl.GLuint) !void {
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

pub fn compileLinkProgram(vs: [:0]const u8, fs: [:0]const u8) !gl.GLuint {
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

            const default: UniformDefault = switch (parsed_typ) {
                .image => .image,
                .float => blk: {
                    var default: f32 = 0.0;
                    gl.glGetUniformfv(self.program, @intCast(self.idx), &default);
                    break :blk .{ .float = default };
                },
                .float2 => blk: {
                    var default: [2]f32 = .{ 0.0, 0.0 };
                    gl.glGetUniformfv(self.program, @intCast(self.idx), &default);
                    break :blk .{ .float2 = default };
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

pub const UniformListsOutput = struct {
    other: []Uniform,
    reserved: []?Uniform,
};

pub fn getUniformList(alloc: Allocator, program: gl.GLuint, reserved_items: []const []const u8) !UniformListsOutput {
    var uniforms = std.ArrayList(Uniform).init(alloc);
    defer {
        for (uniforms.items) |item| {
            item.deinit(alloc);
        }
        uniforms.deinit();
    }

    var reserved_uniforms = try alloc.alloc(?Uniform, reserved_items.len);
    errdefer freeOptionalUniformList(alloc, reserved_uniforms);
    @memset(reserved_uniforms, null);

    var uniform_it = try ProgramUniformIt.init(program);
    while (uniform_it.next()) |uniform| {
        if (isReservedItem(uniform.name, reserved_items)) |idx| {
            reserved_uniforms[idx] = try uniform.clone(alloc);
            continue;
        }

        const cloned = try uniform.clone(alloc);
        errdefer cloned.deinit(alloc);
        try uniforms.append(cloned);
    }

    return .{
        .other = try uniforms.toOwnedSlice(),
        .reserved = reserved_uniforms,
    };
}

pub fn freeUniformList(alloc: Allocator, uniforms: []const Uniform) void {
    for (uniforms) |item| {
        item.deinit(alloc);
    }
    alloc.free(uniforms);
}

pub fn freeOptionalUniformList(alloc: Allocator, uniforms: []const ?Uniform) void {
    for (uniforms) |opt| {
        if (opt) |item| {
            item.deinit(alloc);
        }
    }
    alloc.free(uniforms);
}

pub fn isReservedItem(val: []const u8, skipped_items: []const []const u8) ?usize {
    for (skipped_items, 0..) |item, idx| {
        if (std.mem.eql(u8, val, item)) {
            return idx;
        }
    }

    return null;
}

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
    \\uniform sampler2D input_image;  // The texture
    \\void main()
    \\{
    \\    fragment = texture(input_image, vec2(uv.x, uv.y));
    \\}
;

pub const DefaultPlaneReservedIndex = enum {
    aspect,
    input_image,

    pub fn asIndex(self: DefaultPlaneReservedIndex) usize {
        return @intFromEnum(self);
    }
};

pub const TextureUnitAlloc = struct {
    idx: usize = 0,

    const Output = struct {
        active_texture: gl.GLenum,
        uniform_idx: gl.GLint,
    };

    pub fn next(self: *TextureUnitAlloc) Output {
        defer self.idx += 1;
        return .{
            .active_texture = @intCast(gl.GL_TEXTURE0 + self.idx),
            .uniform_idx = @intCast(self.idx),
        };
    }
};

pub fn applyUniformAtLocation(loc: gl.GLint, expected_type: UniformType, val: ResolvedUniformValue, texture_unit_alloc: *TextureUnitAlloc) void {
    if (expected_type != std.meta.activeTag(val)) {
        std.log.err("Uniform type mismatch", .{});
        return;
    }

    switch (val) {
        .image => |t| {
            const texture_unit = texture_unit_alloc.next();
            gl.glActiveTexture(texture_unit.active_texture);
            gl.glBindTexture(gl.GL_TEXTURE_2D, t);
            gl.glUniform1i(loc, texture_unit.uniform_idx);
        },
        .float => |f| {
            gl.glUniform1f(loc, f);
        },
        .float2 => |f| {
            gl.glUniform2f(loc, f[0], f[1]);
        },
        .float3 => |f| {
            gl.glUniform3f(loc, f[0], f[1], f[2]);
        },
        .int => |v| {
            gl.glUniform1i(loc, v);
        },
    }
}

pub const Texture = struct {
    pub const invalid = Texture{ .inner = 0 };

    inner: gl.GLuint,

    pub fn deinit(self: Texture) void {
        gl.glDeleteTextures(1, &self.inner);
    }
};

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

const TextureFormat = enum {
    rgbaf32,
    rf32,

    fn toOpenGLType(self: TextureFormat) gl.GLint {
        return switch (self) {
            .rgbaf32 => gl.GL_RGBA32F,
            .rf32 => gl.GL_R32F,
        };
    }
};

pub fn makeTextureOfSize(width: u31, height: u31, storage_format: TextureFormat) Texture {
    const texture = makeTextureCommon();
    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        storage_format.toOpenGLType(),
        width,
        height,
        0,
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        null,
    );
    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);
    return texture;
}

pub fn makeTextureCommon() Texture {
    var texture: gl.GLuint = 0;

    // Generate the texture object
    gl.glGenTextures(1, &texture);
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture);

    // Set texture parameters (you can adjust these for your needs)
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE); // Wrap horizontally
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE); // Wrap vertically
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST); // Minification filter
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST); // Magnification filter

    return .{ .inner = texture };
}

pub const FramebufferRenderContext = struct {
    fbo: gl.GLuint,
    prev_fbo: gl.GLint,

    pub fn init(render_texture: Texture, depth_texture: ?Texture) !FramebufferRenderContext {
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

        if (depth_texture) |d| {
            gl.glFramebufferTexture2D(
                gl.GL_FRAMEBUFFER,
                gl.GL_DEPTH_STENCIL_ATTACHMENT,
                gl.GL_TEXTURE_2D,
                d.inner,
                0,
            );
        }

        if (gl.glCheckFramebufferStatus(gl.GL_FRAMEBUFFER) != gl.GL_FRAMEBUFFER_COMPLETE) {
            return error.IncompleteFramebuffer;
        }

        return .{
            .fbo = fbo,
            .prev_fbo = prev_id,
        };
    }

    pub fn bind(self: FramebufferRenderContext) void {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.fbo);
    }

    pub fn reset(self: FramebufferRenderContext) void {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
        gl.glDeleteFramebuffers(1, &self.fbo);
    }
};

pub const TemporaryViewport = struct {
    previous_viewport_args: [4]gl.GLint,

    pub fn init() TemporaryViewport {
        var current_viewport = [1]gl.GLint{0} ** 4;
        gl.glGetIntegerv(gl.GL_VIEWPORT, &current_viewport);
        return .{
            .previous_viewport_args = current_viewport,
        };
    }

    pub fn setViewport(_: TemporaryViewport, width: gl.GLint, height: gl.GLint) void {
        gl.glViewport(0, 0, @intCast(width), @intCast(height));
    }

    pub fn setViewportOffset(_: TemporaryViewport, left: gl.GLint, bottom: gl.GLint, width: gl.GLint, height: gl.GLint) void {
        gl.glViewport(left, bottom, @intCast(width), @intCast(height));
    }

    pub fn reset(self: TemporaryViewport) void {
        gl.glViewport(
            self.previous_viewport_args[0],
            self.previous_viewport_args[1],
            self.previous_viewport_args[2],
            self.previous_viewport_args[3],
        );
    }
};

pub const TemporaryScissor = struct {
    previous_args: [4]gl.GLint,
    previous_enable: bool,

    pub fn init() TemporaryScissor {
        var current = [1]gl.GLint{0} ** 4;
        gl.glGetIntegerv(gl.GL_SCISSOR_BOX, &current);

        var enable: c_int = 0;
        gl.glGetIntegerv(gl.GL_SCISSOR_TEST, &enable);
        if (enable == 0) {
            gl.glEnable(gl.GL_SCISSOR_TEST);
        }

        return .{
            .previous_args = current,
            .previous_enable = enable != 0,
        };
    }

    pub fn set(self: TemporaryScissor, left: gl.GLint, bottom: gl.GLint, width: gl.GLint, height: gl.GLint) void {
        if (!self.previous_enable) {
            gl.glScissor(left, bottom, width, height);
        }

        const requested_right = left + width;
        const requested_top = bottom + height;

        const previous_right = self.previous_args[0] + self.previous_args[2];
        const previous_top = self.previous_args[1] + self.previous_args[3];

        const new_left = @max(self.previous_args[0], left);
        const new_bottom = @max(self.previous_args[1], bottom);
        const new_right = @min(requested_right, previous_right);
        const new_top = @min(requested_top, previous_top);

        const new_height = @max(new_top - new_bottom, 0);
        const new_width = @max(new_right - new_left, 0);

        // If someone has previously scissored, we need to respect them
        gl.glScissor(new_left, new_bottom, new_width, new_height);
    }

    pub fn setAbsolute(_: TemporaryScissor, left: gl.GLint, bottom: gl.GLint, width: gl.GLint, height: gl.GLint) void {
        gl.glScissor(left, bottom, width, height);
    }

    pub fn reset(self: TemporaryScissor) void {
        gl.glScissor(
            self.previous_args[0],
            self.previous_args[1],
            self.previous_args[2],
            self.previous_args[3],
        );

        if (!self.previous_enable) {
            gl.glDisable(gl.GL_SCISSOR_TEST);
        }
    }
};
