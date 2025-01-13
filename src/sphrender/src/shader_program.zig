const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const sphrender = @import("sphrender.zig");
const sphmath = @import("sphmath");
const Uniform = sphrender.Uniform;
const ResolvedUniformValue = sphrender.ResolvedUniformValue;
const ReservedUniformValue = sphrender.ReservedUniformValue;

pub fn Program(comptime Vertex: type, comptime KnownUniforms: type) type {
    const num_known_uniforms = std.meta.fields(KnownUniforms).len;

    return struct {
        program: gl.GLuint,
        known_uniform_locations: UniformLocations,

        const UniformLocations = [num_known_uniforms]?gl.GLint;

        const Self = @This();

        pub fn init(vs: [:0]const u8, fs: [:0]const u8) !Self {
            const program = try sphrender.compileLinkProgram(vs, fs);
            errdefer gl.glDeleteProgram(program);

            var uniform_it = try sphrender.ProgramUniformIt.init(program);
            var known_uniform_locations: UniformLocations = .{null} ** num_known_uniforms;

            while (uniform_it.next()) |uniform| {
                if (knownUniformIdx(KnownUniforms, uniform.name)) |idx| {
                    if (num_known_uniforms > 0) {
                        known_uniform_locations[idx] = uniform.loc;
                    }
                }
            }

            return .{
                .program = program,
                .known_uniform_locations = known_uniform_locations,
            };
        }

        pub fn deinit(self: Self) void {
            gl.glDeleteProgram(self.program);
        }

        pub fn makeBuffer(self: Self, initial_data: []const Vertex) Buffer(Vertex) {
            return Buffer(Vertex).init(self.program, initial_data);
        }

        pub fn unknownUniforms(self: Self, alloc: Allocator) !UnknownUniforms {
            var uniform_it = try sphrender.ProgramUniformIt.init(self.program);
            var items = std.ArrayList(UnknownUniforms.Item).init(alloc);
            defer {
                for (items.items) |*item| {
                    item.deinit(alloc);
                }
                items.deinit();
            }

            while (uniform_it.next()) |uniform| {
                if (knownUniformIdx(KnownUniforms, uniform.name)) |_| {
                    continue;
                }

                const duped_name = try alloc.dupe(u8, uniform.name);
                try items.append(.{
                    .loc = uniform.loc,
                    .default = uniform.default,
                    .name = duped_name,
                });
            }

            return .{
                .items = try items.toOwnedSlice(),
            };
        }

        pub fn render(self: Self, buffer: Buffer(Vertex), options: KnownUniforms) void {
            return self.renderWithExtra(buffer, options, UnknownUniforms.empty, &.{});
        }

        pub fn renderWithExtra(self: Self, buffer: Buffer(Vertex), options: KnownUniforms, defs: UnknownUniforms, values: []const ResolvedUniformValue) void {
            gl.glUseProgram(self.program);
            gl.glBindVertexArray(buffer.vertex_array);

            var texture_unit_alloc = sphrender.TextureUnitAlloc{};

            const option_fiels = std.meta.fields(KnownUniforms);
            inline for (option_fiels, 0..) |option, idx| {
                const loc_opt = self.known_uniform_locations[idx];
                if (loc_opt) |loc| {
                    const uniform_type: sphrender.UniformType = switch (option.type) {
                        sphmath.Vec3 => .float3,
                        sphmath.Vec2 => .float2,
                        f32 => .float,
                        sphmath.Mat3x3 => .mat3x3,
                        sphrender.Texture => .image,
                        u32 => .uint,
                        else => @compileError("Unsupported uniform type " ++ @typeName(option.type)),
                    };
                    const val: ResolvedUniformValue = switch (option.type) {
                        sphrender.Texture => .{
                            .image = @field(options, option.name).inner,
                        },
                        else => @unionInit(ResolvedUniformValue, @tagName(uniform_type), @field(options, option.name)),
                    };
                    sphrender.applyUniformAtLocation(loc, uniform_type, val, &texture_unit_alloc);
                }
            }

            for (values, defs.items) |val, uniform| {
                sphrender.applyUniformAtLocation(uniform.loc, uniform.default, val, &texture_unit_alloc);
            }

            gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(buffer.len));
        }
    };
}

pub fn Buffer(comptime Elem: type) type {
    return struct {
        vertex_buffer: gl.GLuint,
        vertex_array: gl.GLuint,
        len: usize,

        const elem_stride = @sizeOf(Elem);

        const Self = @This();

        pub fn init(program: gl.GLuint, initial_data: []const Elem) Self {
            const fields = std.meta.fields(Elem);
            var field_locs: [fields.len]gl.GLint = undefined;

            inline for (fields, 0..) |elem, i| {
                field_locs[i] = gl.glGetAttribLocation(program, elem.name);
            }

            var vertex_buffer: gl.GLuint = 0;
            gl.glGenBuffers(1, &vertex_buffer);
            errdefer gl.glDeleteBuffers(1, &vertex_buffer);

            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
            gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(initial_data.len * elem_stride), initial_data.ptr, gl.GL_STATIC_DRAW);

            var vertex_array: gl.GLuint = 0;
            gl.glGenVertexArrays(1, &vertex_array);
            errdefer gl.glDeleteVertexArrays(1, &vertex_array);

            gl.glBindVertexArray(vertex_array);

            inline for (fields, field_locs) |field, loc| {
                if (loc >= 0) {
                    const offs = @offsetOf(Elem, field.name);
                    const offs_ptr: ?*anyopaque = if (offs == 0) null else @ptrFromInt(offs);

                    gl.glEnableVertexAttribArray(@intCast(loc));
                    const num_elems = switch (field.type) {
                        sphmath.Vec2 => 2,
                        sphmath.Vec3 => 3,
                        f32 => 1,
                        else => @compileError("Unknown type"),
                    };
                    const elem_type = switch (field.type) {
                        sphmath.Vec3, sphmath.Vec2, f32 => gl.GL_FLOAT,
                        else => @compileError("Unknown type"),
                    };
                    gl.glVertexAttribPointer(@intCast(loc), num_elems, elem_type, gl.GL_FALSE, elem_stride, offs_ptr);
                }
            }

            return .{
                .vertex_array = vertex_array,
                .vertex_buffer = vertex_buffer,
                .len = initial_data.len,
            };
        }

        pub fn deinit(self: Self) void {
            gl.glDeleteBuffers(1, &self.vertex_buffer);
            gl.glDeleteVertexArrays(1, &self.vertex_array);
        }

        pub fn updateBuffer(self: *Self, points: []const Elem) void {
            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vertex_buffer);
            gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(points.len * elem_stride), points.ptr, gl.GL_STATIC_DRAW);
            self.len = points.len;
        }
    };
}

fn knownUniformIdx(comptime KnownUniforms: type, name: []const u8) ?usize {
    const field_names = std.meta.fieldNames(KnownUniforms);
    inline for (field_names, 0..) |field_name, idx| {
        if (std.mem.eql(u8, name, field_name)) {
            return idx;
        }
    }

    return null;
}

pub const UnknownUniforms = struct {
    pub const Item = struct {
        loc: gl.GLint,
        default: sphrender.UniformDefault,
        name: []const u8,

        fn deinit(self: Item, alloc: Allocator) void {
            alloc.free(self.name);
        }
    };

    pub const empty: UnknownUniforms = .{ .items = &.{} };

    items: []Item,

    pub fn deinit(self: UnknownUniforms, alloc: Allocator) void {
        for (self.items) |item| {
            item.deinit(alloc);
        }
        alloc.free(self.items);
    }
};
