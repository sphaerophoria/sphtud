const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const gl = @import("gl.zig");
const geometry = @import("geometry.zig");
const sphrender = @import("sphrender.zig");
const Texture = sphrender.Texture;

program: gl.GLuint,
cone_buf: InstancedRenderBuffer,
tent_buf: InstancedRenderBuffer,
df_scale_loc: gl.GLint,
sign_loc: gl.GLint,
sign_valid_loc: gl.GLint,

const DistanceFieldGenerator = @This();

const num_cone_points = 20;
const depth_radius = 2 * std.math.sqrt2;

pub fn init() !DistanceFieldGenerator {
    const program = try sphrender.compileLinkProgram(distance_field_vertex_shader, distance_field_fragment_shader);
    errdefer gl.glDeleteProgram(program);

    const df_scale_loc = gl.glGetUniformLocation(program, "scale");
    const sign_loc = gl.glGetUniformLocation(program, "sign");
    const sign_valid_loc = gl.glGetUniformLocation(program, "sign_valid");

    const vpos_loc = gl.glGetAttribLocation(program, "vPos");
    const cone_offs_loc = gl.glGetAttribLocation(program, "vOffs");
    const stretch_loc = gl.glGetAttribLocation(program, "stretch");
    const rot_loc = gl.glGetAttribLocation(program, "rotation");

    const cone_buf = try genCone(@bitCast(vpos_loc), @bitCast(cone_offs_loc), @bitCast(stretch_loc), @bitCast(rot_loc));
    const tent_buf = try genTent(@bitCast(vpos_loc), @bitCast(cone_offs_loc), @bitCast(stretch_loc), @bitCast(rot_loc));

    return .{
        .program = program,
        .df_scale_loc = df_scale_loc,
        .cone_buf = cone_buf,
        .tent_buf = tent_buf,
        .sign_loc = sign_loc,
        .sign_valid_loc = sign_valid_loc,
    };
}

pub fn deinit(self: DistanceFieldGenerator) void {
    self.cone_buf.deinit();
    self.tent_buf.deinit();
    gl.glDeleteProgram(self.program);
}

pub fn generateDistanceField(self: DistanceFieldGenerator, alloc: Allocator, point_it: anytype, sign_texture: Texture, width: u31, height: u31) !Texture {
    const color_texture = sphrender.makeTextureOfSize(width, height, .rf32);
    errdefer color_texture.deinit();

    const depth_texture = sphrender.makeTextureCommon();
    defer depth_texture.deinit();

    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_DEPTH24_STENCIL8, width, height, 0, gl.GL_DEPTH_STENCIL, gl.GL_UNSIGNED_INT_24_8, null);

    gl.glEnable(gl.GL_DEPTH_TEST);
    // FIXME: Restore initial state, don't hard disable
    defer gl.glDisable(gl.GL_DEPTH_TEST);

    {
        const fb = try sphrender.FramebufferRenderContext.init(color_texture, depth_texture);
        defer fb.reset();

        // Output texture size is not the same as input size
        // Set viewport to full texture output size, restore original after
        const temp_viewport = sphrender.TemporaryViewport.init();
        defer temp_viewport.reset();

        const temp_scissor = sphrender.TemporaryScissor.init();
        defer temp_scissor.reset();

        temp_viewport.setViewport(@intCast(width), @intCast(height));
        temp_scissor.setAbsolute(0, 0, @intCast(width), @intCast(height));

        clearBuffers();

        const aspect_correction = calcAspectCorrection(width, height);

        gl.glUseProgram(self.program);
        gl.glUniform2f(self.df_scale_loc, aspect_correction[0], aspect_correction[1]);

        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, sign_texture.inner);
        gl.glUniform1i(self.sign_loc, 0);
        gl.glUniform1i(self.sign_valid_loc, @intFromBool(sign_texture.inner != Texture.invalid.inner));

        const lens = try self.updateBuffers(alloc, point_it, aspect_correction);

        gl.glBindVertexArray(self.cone_buf.vao);
        gl.glDrawArraysInstanced(gl.GL_TRIANGLE_FAN, 0, num_cone_points, @intCast(lens.cones));

        gl.glBindVertexArray(self.tent_buf.vao);
        gl.glDrawArraysInstanced(gl.GL_TRIANGLE_STRIP, 0, 6, @intCast(lens.tents));
    }

    return color_texture;
}

// Abstraction around inputs for the distance field generator program. A
// mesh (cone or tent) is instanced at a location with some transformations
// applied to it
const InstancedRenderBuffer = struct {
    mesh_vbo: gl.GLuint, // mesh data
    offsets_vbo: gl.GLuint, // instance data
    vao: gl.GLuint,

    offsets_loc: gl.GLuint,
    stretch_loc: gl.GLuint,
    rot_loc: gl.GLuint,

    const mesh_binding_index = 0;
    const offsets_binding_index = 1;

    fn init(vpos_location: gl.GLuint, offs_location: gl.GLuint, stretch_location: gl.GLuint, rot_loc: gl.GLuint) InstancedRenderBuffer {
        var vertex_buffer: gl.GLuint = 0;
        gl.glCreateBuffers(1, &vertex_buffer);

        var offsets_vbo: gl.GLuint = 0;
        gl.glCreateBuffers(1, &offsets_vbo);

        var vertex_array: gl.GLuint = 0;
        gl.glCreateVertexArrays(1, &vertex_array);

        gl.glEnableVertexArrayAttrib(vertex_array, vpos_location);

        gl.glVertexArrayVertexBuffer(vertex_array, mesh_binding_index, vertex_buffer, 0, @sizeOf(sphmath.Vec3));
        gl.glVertexArrayAttribFormat(vertex_array, @intCast(vpos_location), 3, gl.GL_FLOAT, gl.GL_FALSE, 0);
        gl.glVertexArrayAttribBinding(vertex_array, @intCast(vpos_location), mesh_binding_index);

        // By default we disable the extra transformations, as the cone
        // doesn't need them
        gl.glBindVertexArray(vertex_array);
        gl.glVertexAttrib2f(offs_location, 0.0, 0.0);
        gl.glVertexAttrib1f(stretch_location, 1.0);
        gl.glVertexAttrib1f(rot_loc, 0.0);
        gl.glBindVertexArray(0);

        return .{
            .mesh_vbo = vertex_buffer,
            .offsets_vbo = offsets_vbo,
            .vao = vertex_array,
            .offsets_loc = offs_location,
            .stretch_loc = stretch_location,
            .rot_loc = rot_loc,
        };
    }

    fn deinit(self: InstancedRenderBuffer) void {
        gl.glDeleteBuffers(1, &self.mesh_vbo);
        gl.glDeleteBuffers(1, &self.offsets_vbo);
        gl.glDeleteVertexArrays(1, &self.vao);
    }

    fn setMeshData(self: InstancedRenderBuffer, points: []const sphmath.Vec3) void {
        gl.glNamedBufferData(
            self.mesh_vbo,
            @intCast(points.len * @sizeOf(sphmath.Vec3)),
            points.ptr,
            gl.GL_STATIC_DRAW,
        );
    }

    fn setOffsetData(self: InstancedRenderBuffer, offsets: []const sphmath.Vec2) void {
        gl.glEnableVertexArrayAttrib(self.vao, self.offsets_loc);

        gl.glVertexArrayVertexBuffer(self.vao, offsets_binding_index, self.offsets_vbo, 0, @sizeOf(sphmath.Vec2));
        gl.glVertexArrayAttribFormat(self.vao, self.offsets_loc, 2, gl.GL_FLOAT, gl.GL_FALSE, 0);
        gl.glVertexArrayAttribBinding(self.vao, self.offsets_loc, offsets_binding_index);

        gl.glNamedBufferData(
            self.offsets_vbo,
            @intCast(offsets.len * @sizeOf(sphmath.Vec2)),
            offsets.ptr,
            gl.GL_STATIC_DRAW,
        );
        gl.glVertexArrayBindingDivisor(self.vao, offsets_binding_index, 1);
    }

    const TentTransform = struct {
        offset: sphmath.Vec2,
        stretch: f32,
        rotation: f32,
    };

    // Somewhat specific API, but this isn't a generic buffer so it's fine.
    // Enable all the extra transforms and set the data appropriately
    fn setTentTransformData(self: InstancedRenderBuffer, tent_transforms: []const TentTransform) void {
        gl.glEnableVertexArrayAttrib(self.vao, self.offsets_loc);
        gl.glEnableVertexArrayAttrib(self.vao, self.stretch_loc);
        gl.glEnableVertexArrayAttrib(self.vao, self.rot_loc);

        gl.glVertexArrayVertexBuffer(self.vao, offsets_binding_index, self.offsets_vbo, 0, @sizeOf(TentTransform));

        gl.glVertexArrayAttribFormat(
            self.vao,
            self.offsets_loc,
            2,
            gl.GL_FLOAT,
            gl.GL_FALSE,
            @offsetOf(TentTransform, "offset"),
        );
        gl.glVertexArrayAttribFormat(
            self.vao,
            self.stretch_loc,
            1,
            gl.GL_FLOAT,
            gl.GL_FALSE,
            @offsetOf(TentTransform, "stretch"),
        );
        gl.glVertexArrayAttribFormat(
            self.vao,
            self.rot_loc,
            1,
            gl.GL_FLOAT,
            gl.GL_FALSE,
            @offsetOf(TentTransform, "rotation"),
        );

        gl.glVertexArrayAttribBinding(self.vao, self.offsets_loc, offsets_binding_index);

        gl.glVertexArrayAttribBinding(self.vao, self.stretch_loc, offsets_binding_index);

        gl.glVertexArrayAttribBinding(self.vao, self.rot_loc, offsets_binding_index);

        gl.glNamedBufferData(self.offsets_vbo, @intCast(tent_transforms.len * @sizeOf(TentTransform)), tent_transforms.ptr, gl.GL_STATIC_DRAW);
        gl.glVertexArrayBindingDivisor(self.vao, offsets_binding_index, 1);
    }
};

fn genCone(vpos_location: gl.GLuint, offs_location: gl.GLuint, stretch_location: gl.GLuint, rot_loc: gl.GLuint) !InstancedRenderBuffer {
    var cone_points: [num_cone_points]sphmath.Vec3 = undefined;
    var i: usize = 0;
    var cone_it = geometry.ConeGenerator.init(depth_radius, 1.0, cone_points.len);
    while (cone_it.next()) |point| {
        cone_points[i] = point;
        i += 1;
    }

    var ret = InstancedRenderBuffer.init(vpos_location, offs_location, stretch_location, rot_loc);
    ret.setMeshData(&cone_points);

    return ret;
}

fn genTent(vpos_location: gl.GLuint, offs_location: gl.GLuint, stretch_location: gl.GLuint, rot_loc: gl.GLuint) !InstancedRenderBuffer {
    var tent_points: [6]sphmath.Vec3 = undefined;
    var i: usize = 0;
    var tent_it = geometry.TentGenerator{
        .a = .{ -0.5, 0.0 },
        .b = .{ 0.5, 0.0 },
        .width = depth_radius,
        .height = 1.0,
    };
    while (tent_it.next()) |point| {
        tent_points[i] = point;
        i += 1;
    }

    var ret = InstancedRenderBuffer.init(vpos_location, offs_location, stretch_location, rot_loc);
    ret.setMeshData(&tent_points);

    return ret;
}

fn clearBuffers() void {
    var clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
    gl.glClearBufferfv(gl.GL_COLOR, 0, &clear_color);
    const max_depth = std.math.inf(f32);
    gl.glClearBufferfv(gl.GL_DEPTH, 0, &max_depth);
}

fn calcAspectCorrection(width: usize, height: usize) sphmath.Vec2 {
    const aspect = sphmath.calcAspect(width, height);
    if (aspect > 1.0) {
        return .{ 1.0, aspect };
    } else {
        return .{ 1.0 / aspect, 1.0 };
    }
}

const BufferLens = struct {
    cones: usize,
    tents: usize,
};

fn updateBuffers(self: DistanceFieldGenerator, alloc: Allocator, point_it: anytype, aspect_correction: sphmath.Vec2) !BufferLens {
    var cone_offsets = std.ArrayList(sphmath.Vec2).init(alloc);
    defer cone_offsets.deinit();

    var tent_transforms = std.ArrayList(InstancedRenderBuffer.TentTransform).init(alloc);
    defer tent_transforms.deinit();

    while (point_it.next()) |item| {
        const p = switch (item) {
            .new_line => |p| {
                try cone_offsets.append(p / aspect_correction);
                continue;
            },
            .line_point => |p| p / aspect_correction,
        };
        const last_point = cone_offsets.getLast();
        try cone_offsets.append(p);

        const line = p - last_point;
        const stretch = sphmath.length(line);
        const rotation = std.math.atan2(line[1], line[0]);
        const offs = (last_point + p) / sphmath.Vec2{ 2.0, 2.0 };

        try tent_transforms.append(.{
            .offset = offs,
            .stretch = stretch,
            .rotation = rotation,
        });
    }

    self.cone_buf.setOffsetData(cone_offsets.items);
    self.tent_buf.setTentTransformData(tent_transforms.items);

    return .{
        .cones = cone_offsets.items.len,
        .tents = tent_transforms.items.len,
    };
}

const distance_field_vertex_shader =
    \\#version 330
    \\in vec3 vPos;
    \\in vec2 vOffs;
    \\in float stretch;
    \\in float rotation;
    \\out float depth;
    \\out vec2 uv;
    \\uniform vec2 scale = vec2(1.0, 1.0);
    \\void main()
    \\{
    \\    mat2x2 rot_mat = mat2x2(vec2(cos(rotation), sin(rotation)), vec2(-sin(rotation), cos(rotation)));
    \\    vec2 pos = vOffs + rot_mat * vec2(vPos.x * stretch, vPos.y);
    \\    gl_Position = vec4(pos * scale, vPos.z, 1.0);
    \\    depth = vPos.z;
    \\    uv = gl_Position.xy / 2.0 + 0.5;
    \\}
;

const distance_field_fragment_shader =
    \\#version 330 core
    \\out vec4 fragment;
    \\in vec2 uv;
    \\uniform sampler2D sign;
    \\uniform int sign_valid;
    \\in float depth;
    \\void main()
    \\{
    \\    float sign_val = texture(sign, uv).r;
    \\    float sign_mul = (sign_valid != 0 && sign_val < 0.5) ? -1.0 : 1.0;
    \\    fragment = vec4(sqrt(depth) * sign_mul, sqrt(depth) * sign_mul, sqrt(depth) * sign_mul, 1.0);
    \\}
;
