const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const sphrender = @import("sphrender.zig");
const sphmath = @import("sphmath");
const Uniform = sphrender.Uniform;
const ResolvedUniformValue = sphrender.ResolvedUniformValue;
const ReservedUniformValue = sphrender.ReservedUniformValue;

program: gl.GLuint,

uniforms: []Uniform,
reserved_uniforms: []?Uniform,

const PlaneRenderProgram = @This();

const plane_vertices: []const f32 = &.{
    -1.0, -1.0, 0.0, 0.0,
    1.0,  -1.0, 1.0, 0.0,
    -1.0, 1.0,  0.0, 1.0,
    1.0,  -1.0, 1.0, 0.0,
    -1.0, 1.0,  0.0, 1.0,
    1.0,  1.0,  1.0, 1.0,
};

pub fn init(alloc: Allocator, vs: [:0]const u8, fs: [:0]const u8, comptime IndexType: ?type) !PlaneRenderProgram {
    const program = try sphrender.compileLinkProgram(vs, fs);
    errdefer gl.glDeleteProgram(program);

    const reserved_names = if (IndexType) |T| std.meta.fieldNames(T) else &.{};
    const uniforms = try sphrender.getUniformList(alloc, program, reserved_names);
    errdefer sphrender.freeUniformList(alloc, uniforms.other);
    errdefer sphrender.freeOptionalUniformList(alloc, uniforms.reserved);

    return .{
        .program = program,
        .uniforms = uniforms.other,
        .reserved_uniforms = uniforms.reserved,
    };
}

pub fn deinit(self: PlaneRenderProgram, alloc: Allocator) void {
    gl.glDeleteProgram(self.program);

    sphrender.freeUniformList(alloc, self.uniforms);
    sphrender.freeOptionalUniformList(alloc, self.reserved_uniforms);
}

pub fn makeDefaultBuffer(self: PlaneRenderProgram) Buffer {
    return Buffer.init(self.program);
}

pub fn render(self: PlaneRenderProgram, buffer: Buffer, uniforms: []const ResolvedUniformValue, reserved_uniforms: []const ReservedUniformValue) void {
    gl.glUseProgram(self.program);
    gl.glBindVertexArray(buffer.vertex_array);

    var texture_unit_alloc = sphrender.TextureUnitAlloc{};
    for (self.uniforms, 0..) |uniform, i| {
        if (i >= uniforms.len) continue;
        const val = uniforms[i];
        sphrender.applyUniformAtLocation(uniform.loc, std.meta.activeTag(uniform.default), val, &texture_unit_alloc);
    }

    for (reserved_uniforms) |reserved| {
        const uniform_opt = self.reserved_uniforms[reserved.idx];
        if (uniform_opt) |uniform| {
            sphrender.applyUniformAtLocation(uniform.loc, std.meta.activeTag(uniform.default), reserved.val, &texture_unit_alloc);
        }
    }

    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(buffer.len));
}

pub const Buffer = struct {
    vertex_buffer: gl.GLuint,
    vertex_array: gl.GLuint,
    len: usize,

    pub fn init(program: gl.GLuint) Buffer {
        const vpos_location = gl.glGetAttribLocation(program, "vPos");
        const vuv_location = gl.glGetAttribLocation(program, "vUv");

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

        if (vuv_location >= 0) {
            gl.glEnableVertexAttribArray(@intCast(vuv_location));
            gl.glVertexAttribPointer(@intCast(vuv_location), 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * 4, @ptrFromInt(8));
        }

        return .{
            .vertex_array = vertex_array,
            .vertex_buffer = vertex_buffer,
            .len = 6,
        };
    }

    pub fn deinit(self: Buffer) void {
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
    }

    pub const BufferPoint = packed struct {
        clip_x: f32,
        clip_y: f32,
        uv_x: f32,
        uv_y: f32,
    };

    pub fn updateBuffer(self: *Buffer, points: []const BufferPoint) void {
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vertex_buffer);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(points.len * @bitSizeOf(BufferPoint) / 8), points.ptr, gl.GL_STATIC_DRAW);
        self.len = points.len;
    }
};
