const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl");
const sphrender = @import("sphrender.zig");
const sphmath = @import("sphmath");
const Uniform = sphrender.Uniform;
const ResolvedUniformValue = sphrender.ResolvedUniformValue;
const ReservedUniformValue = sphrender.ReservedUniformValue;
const GlAlloc = @import("GlAlloc.zig");
const sphutil = @import("sphutil");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;

pub fn IndexBuffer(comptime T: type) type {
    return struct {
        value: gl.GLuint,
        len: usize,

        const Self = @This();
        pub fn init(gl_alloc: *GlAlloc) !Self {
            return .{
                .value = try gl_alloc.createBuffer(),
                .len = 0,
            };
        }

        pub fn bindData(self: *Self, data: []const T) void {
            gl.glNamedBufferData(self.value, @intCast(data.len * @sizeOf(T)), data.ptr, gl.GL_STATIC_DRAW);
            self.len = data.len;
        }
    };
}

pub const RenderSource = struct {
    vao: gl.GLuint,
    index_type: ?gl.GLenum = null,
    len: usize,

    const Self = @This();

    pub fn init(gl_alloc: *GlAlloc) !Self {
        return .{
            .vao = try gl_alloc.createArray(),
            .len = 0,
        };
    }

    pub fn bindData(self: *RenderSource, comptime VertElem: type, program: ProgramHandle, data: Buffer(VertElem)) void {
        const fields = std.meta.fields(VertElem);
        const field_locs = fieldLocs(fields, program);

        const binding_index = 0;

        gl.glVertexArrayVertexBuffer(self.vao, binding_index, data.vertex_buffer, 0, @sizeOf(VertElem));

        inline for (fields, field_locs) |field, loc| {
            if (loc >= 0) {
                const offs = @offsetOf(VertElem, field.name);

                applyAttribFormat(self.vao, loc, field.type, offs);
                gl.glVertexArrayAttribBinding(self.vao, @intCast(loc), binding_index);
            }
        }

        self.len = data.len;
    }

    pub fn setIndexBuffer(self: *RenderSource, comptime T: type, buf: IndexBuffer(T)) void {
        gl.glVertexArrayElementBuffer(self.vao, buf.value);
        self.index_type = switch (T) {
            u16 => gl.GL_UNSIGNED_SHORT,
            else => @compileError("Unimplemented index buffer type"),
        };
        self.len = buf.len;
    }

    pub fn bindDataSplit(self: *RenderSource, comptime VertElem: type, program: ProgramHandle, data: SplitBuffers(VertElem)) void {
        const fields = std.meta.fields(VertElem);
        const field_locs = fieldLocs(fields, program);

        var len: ?usize = null;
        inline for (fields, field_locs, 0..) |field, loc, binding_index| {
            if (loc >= 0) {
                switch (@field(data, field.name)) {
                    .default => |d| {
                        switch (field.type) {
                            [2]f32 => gl.glVertexAttrib2f(@intCast(loc), d[0], d[1]),
                            [4]f32 => gl.glVertexAttrib4f(@intCast(loc), d[0], d[1], d[2], d[3]),
                            [4]u8 => gl.glVertexAttrib4ubv(@intCast(loc), &d),
                            else => unreachable,
                        }
                    },
                    .populated => |buf| {
                        if (len) |*l| {
                            std.debug.assert(buf.len == l.*);
                        } else {
                            len = buf.len;
                        }

                        gl.glVertexArrayVertexBuffer(self.vao, binding_index, buf.vertex_buffer, 0, @sizeOf(field.type));
                        applyAttribFormat(self.vao, loc, field.type, 0);
                        gl.glVertexArrayAttribBinding(self.vao, @intCast(loc), binding_index);
                    },
                }
            }
        }

        self.len = len.?;
    }
};

fn fieldLocs(comptime fields: anytype, program: ProgramHandle) [fields.len]gl.GLint {
    var field_locs: [fields.len]gl.GLint = undefined;

    inline for (fields, 0..) |elem, i| {
        field_locs[i] = gl.glGetAttribLocation(program.value, elem.name);
    }
    return field_locs;
}

fn arrayLen(comptime T: type) comptime_int {
    const info = @typeInfo(T);
    switch (info) {
        .array => |ai| {
            return ai.len;
        },
        .vector => |vi| {
            return vi.len;
        },
        else => return 1,
    }
}

fn toGlType(comptime T: type) gl.GLenum {
    const info = @typeInfo(T);
    switch (info) {
        .array => |ai| {
            return toGlType(ai.child);
        },
        .vector => |vi| {
            return toGlType(vi.child);
        },
        .float => |fi| {
            switch (fi.bits) {
                32 => return gl.GL_FLOAT,
                else => @compileError("Unhandled gl float bits"),
            }
        },
        .int => |ii| {
            switch (ii.signedness) {
                .signed => @compileError("Unimplemented signed gl type"),
                .unsigned => {
                    switch (ii.bits) {
                        8 => return gl.GL_UNSIGNED_BYTE,
                        16 => return gl.GL_UNSIGNED_SHORT,
                        32 => return gl.GL_UNSIGNED_INT,
                        else => @compileError("Unhandled gl uint bits"),
                    }
                },
            }
        },
        else => @compileError("Unhandled gl type"),
    }
}

fn applyAttribFormat(vao: gl.GLuint, loc: gl.GLint, comptime Field: type, offs: usize) void {
    if (loc < 0) return;

    gl.glEnableVertexArrayAttrib(vao, @intCast(loc));

    const num_elems = arrayLen(Field);
    const gl_type = comptime toGlType(Field);

    switch (gl_type) {
        gl.GL_FLOAT => {
            gl.glVertexArrayAttribFormat(vao, @intCast(loc), num_elems, gl_type, gl.GL_FALSE, @intCast(offs));
        },
        gl.GL_UNSIGNED_BYTE, gl.GL_UNSIGNED_SHORT, gl.GL_UNSIGNED_INT => {
            gl.glVertexArrayAttribIFormat(vao, @intCast(loc), num_elems, gl_type, @intCast(offs));
        },
        else => @compileError("Unknown type"),
    }
}

pub fn RenderSourceTyped(comptime Vertex: type) type {
    return struct {
        inner: RenderSource,

        const Self = @This();

        pub fn init(gl_alloc: *GlAlloc) !Self {
            return .{ .inner = try RenderSource.init(gl_alloc) };
        }

        pub fn bindData(self: *Self, program: ProgramHandle, data: Buffer(Vertex)) void {
            self.inner.bindData(Vertex, program, data);
        }

        pub fn setLen(self: *Self, len: usize) void {
            self.inner.len = len;
        }
    };
}

pub const ProgramHandle = struct {
    value: gl.GLuint,
};

pub fn Program(comptime KnownUniforms: type) type {
    const num_known_uniforms = std.meta.fields(KnownUniforms).len;

    return struct {
        handle: ProgramHandle,
        known_uniform_locations: UniformLocations,

        const UniformLocations = [num_known_uniforms]?gl.GLint;

        const Self = @This();

        pub fn init(gl_alloc: *GlAlloc, vs: [:0]const u8, fs: [:0]const u8) !Self {
            const program = try sphrender.compileLinkProgram(gl_alloc, vs, fs);

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
                .handle = .{ .value = program },
                .known_uniform_locations = known_uniform_locations,
            };
        }

        pub fn unknownUniforms(self: Self, scratch: *ScratchAlloc) !UnknownUniforms {
            var uniform_it = try sphrender.ProgramUniformIt.init(self.handle.value);

            var ret = try sphutil.RuntimeBoundedArray(UnknownUniforms.Item).init(
                scratch.allocator(),
                uniform_it.num_uniforms,
            );

            while (uniform_it.next()) |uniform| {
                if (knownUniformIdx(KnownUniforms, uniform.name)) |_| {
                    continue;
                }

                const duped_name = try scratch.allocator().dupe(u8, uniform.name);
                try ret.append(.{
                    .loc = uniform.loc,
                    .default = uniform.default,
                    .name = duped_name,
                });
            }

            return .{
                .items = ret.items,
            };
        }

        pub fn render(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.renderWithExtra(array, options, UnknownUniforms.empty, &.{});
        }

        pub fn renderLines(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.renderInner(array, options, UnknownUniforms.empty, &.{}, gl.GL_LINES);
        }

        pub fn renderWithExtra(self: Self, array: RenderSource, options: KnownUniforms, defs: UnknownUniforms, values: []const ResolvedUniformValue) void {
            self.renderInner(array, options, defs, values, gl.GL_TRIANGLES);
        }

        fn renderInner(self: Self, array: RenderSource, options: KnownUniforms, defs: UnknownUniforms, values: []const ResolvedUniformValue, mode: gl.GLenum) void {
            gl.glUseProgram(self.handle.value);
            gl.glBindVertexArray(array.vao);

            var texture_unit_alloc = sphrender.TextureUnitAlloc{};

            const option_fiels = std.meta.fields(KnownUniforms);
            inline for (option_fiels, 0..) |option, idx| {
                const loc_opt = self.known_uniform_locations[idx];
                if (loc_opt) |loc| {
                    const val = resolvedUniformType(option.type, &@field(options, option.name));
                    const uniform_type = std.meta.stringToEnum(sphrender.UniformType, @tagName(val)).?;
                    sphrender.applyUniformAtLocation(loc, uniform_type, val, &texture_unit_alloc);
                }
            }

            for (values, defs.items) |val, uniform| {
                sphrender.applyUniformAtLocation(uniform.loc, uniform.default, val, &texture_unit_alloc);
            }

            if (array.index_type) |t| {
                gl.glDrawElements(mode, @intCast(array.len), t, null);
            } else {
                gl.glDrawArrays(mode, 0, @intCast(array.len));
            }
        }
    };
}

fn resolvedUniformType(comptime T: type, val: anytype) sphrender.ResolvedUniformValue {
    switch (T) {
        sphrender.Texture => return .{
            .image = val.inner,
        },
        else => blk: {
            const uniform_type = switch (T) {
                sphmath.Vec3 => .float3,
                sphmath.Vec2 => .float2,
                f32 => .float,
                sphmath.Mat3x3 => .mat3x3,
                sphmath.Mat4x4 => .mat4x4,
                sphrender.Texture => .image,
                u32 => .uint,
                else => break :blk,
            };
            return @unionInit(ResolvedUniformValue, @tagName(uniform_type), val.*);
        },
    }

    const info = @typeInfo(T);
    switch (info) {
        .array => |a| {
            switch (a.child) {
                sphmath.Mat4x4 => {
                    return .{
                        .mat4x4_arr = val,
                    };
                },
                else => {},
            }
        },
        else => {},
    }
    @compileError("Unsupported uniform type " ++ @typeName(T));
}

pub fn SplitBufferVal(comptime T: type) type {
    return union(enum) {
        default: T,
        populated: Buffer(T),
    };
}

pub fn SplitBuffers(comptime T: type) type {
    const fields = std.meta.fields(T);

    var new_fields: [fields.len]std.builtin.Type.StructField = undefined;
    inline for (fields, &new_fields) |in_field, *out_field| {
        out_field.* = .{
            .name = in_field.name,
            .type = SplitBufferVal(in_field.type),
            .is_comptime = false,
            .alignment = @alignOf(?*anyopaque),
            .default_value_ptr = null,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &new_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn Buffer(comptime Elem: type) type {
    return struct {
        vertex_buffer: gl.GLuint,
        len: usize,

        const elem_stride = @sizeOf(Elem);

        const Self = @This();

        pub fn init(gl_alloc: *GlAlloc, initial_data: []const Elem) !Self {
            const vertex_buffer = try gl_alloc.createBuffer();
            gl.glNamedBufferData(vertex_buffer, @intCast(initial_data.len * elem_stride), initial_data.ptr, gl.GL_STATIC_DRAW);

            return .{
                .vertex_buffer = vertex_buffer,
                .len = initial_data.len,
            };
        }

        pub fn updateBuffer(self: *Self, points: []const Elem) void {
            gl.glNamedBufferData(self.vertex_buffer, @intCast(points.len * elem_stride), points.ptr, gl.GL_STATIC_DRAW);
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

        fn clone(self: Item, alloc: Allocator) !Item {
            return .{
                .loc = self.loc,
                .default = self.default,
                .name = try alloc.dupe(u8, self.name),
            };
        }
    };

    pub const empty: UnknownUniforms = .{ .items = &.{} };

    items: []Item,

    pub fn clone(self: UnknownUniforms, alloc: Allocator) !UnknownUniforms {
        const items = try alloc.alloc(Item, self.items.len);
        for (items, self.items) |*dst, *src| {
            dst.* = try src.clone(alloc);
        }
        return .{
            .items = items,
        };
    }
};
