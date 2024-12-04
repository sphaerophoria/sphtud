const std = @import("std");
const Allocator = std.mem.Allocator;
const lin = @import("lin.zig");
const obj_mod = @import("object.zig");
const coords = @import("coords.zig");
const geometry = @import("geometry.zig");
const shader_storage = @import("shader_storage.zig");

const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;

const Objects = obj_mod.Objects;
const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Transform = lin.Transform;

const gl = @import("gl.zig");

program: PlaneRenderProgram,
default_buffer: PlaneRenderProgram.Buffer,
background_program: PlaneRenderProgram,
path_program: PathRenderProgram,
distance_field_generator: DistanceFieldGenerator,

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

    const plane_program = try PlaneRenderProgram.init(alloc, plane_vertex_shader, plane_fragment_shader, DefaultPlaneReservedIndex);
    errdefer plane_program.deinit(alloc);

    const background_program = try PlaneRenderProgram.init(alloc, plane_vertex_shader, checkerboard_fragment_shader, DefaultPlaneReservedIndex);
    errdefer background_program.deinit(alloc);

    const path_program = try PathRenderProgram.init();
    errdefer path_program.deinit();

    const distance_field_generator = try DistanceFieldGenerator.init();
    errdefer distance_field_generator.deinit();

    return .{
        .program = plane_program,
        .default_buffer = plane_program.makeDefaultBuffer(),
        .background_program = background_program,
        .path_program = path_program,
        .distance_field_generator = distance_field_generator,
    };
}

pub fn deinit(self: *Renderer, alloc: Allocator) void {
    self.program.deinit(alloc);
    self.background_program.deinit(alloc);
    self.path_program.deinit();
    self.distance_field_generator.deinit();
}

pub const FrameRenderer = struct {
    alloc: Allocator,
    renderer: *Renderer,
    objects: *Objects,
    shaders: *const ShaderStorage(ShaderId),
    brushes: *const ShaderStorage(BrushId),
    texture_cache: TextureCache,

    pub fn deinit(self: *FrameRenderer) void {
        self.texture_cache.deinit();
    }

    pub fn render(self: *FrameRenderer, selected_object: ObjectId, transform: Transform, window_width: usize, window_height: usize) !void {
        gl.glViewport(0, 0, @intCast(window_width), @intCast(window_height));
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const active_object = self.objects.get(selected_object);
        const object_dims = active_object.dims(self.objects);

        const toplevel_aspect = coords.calcAspect(object_dims[0], object_dims[1]);

        self.renderer.background_program.render(
            self.renderer.default_buffer,
            &.{},
            &.{.{ .idx = DefaultPlaneReservedIndex.aspect.asIndex(), .val = .{ .float = toplevel_aspect } }},
            transform,
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

    fn renderObjectWithTransform(self: *FrameRenderer, object: Object, transform: Transform) !void {
        switch (object.data) {
            .composition => |c| {
                const composition_object_dims = object.dims(self.objects);
                const composition_object_aspect = coords.calcAspect(composition_object_dims[0], composition_object_dims[1]);

                for (c.objects.items) |composition_object| {
                    const next_object = self.objects.get(composition_object.id);

                    const compsoed_to_composition = composition_object.composedToCompositionTransform(self.objects, composition_object_aspect);
                    const next_transform = compsoed_to_composition
                        .then(transform);

                    try self.renderObjectWithTransform(next_object.*, next_transform);
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
                        .val = .{ .float = coords.calcAspect(f.width, f.height) },
                    },
                }, transform);
            },
            .shader => |s| {
                var sources = std.ArrayList(ResolvedUniformValue).init(self.alloc);
                defer sources.deinit();

                for (s.bindings) |binding| {
                    try sources.append(try self.resolveUniform(binding));
                }

                const object_dims = object.dims(self.objects);
                self.shaders.get(s.program).program.render(self.renderer.default_buffer, sources.items, &.{.{
                    .idx = CustomShaderReservedIndex.aspect.asIndex(),
                    .val = .{ .float = coords.calcAspect(object_dims[0], object_dims[1]) },
                }}, transform);
            },
            .path => |p| {
                const display_object = self.objects.get(p.display_object);
                try self.renderObjectWithTransform(display_object.*, transform);

                self.renderer.path_program.render(p.render_buffer, transform, p.points.items.len);
            },
            .generated_mask => |m| {
                const object_dims = object.dims(self.objects);
                self.renderer.program.render(self.renderer.default_buffer, &.{.{ .image = m.texture.inner }}, &.{.{
                    .idx = DefaultPlaneReservedIndex.aspect.asIndex(),
                    .val = .{ .float = coords.calcAspect(object_dims[0], object_dims[1]) },
                }}, transform);
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
                            .val = .{ .float = coords.calcAspect(dims[0], dims[1]) },
                        },
                        .{
                            .idx = BrushReservedIndex.distance_field.asIndex(),
                            .val = .{ .image = d.distance_field.inner },
                        },
                    }, transform);
                }
            },
        }
    }

    pub fn renderObjectToTexture(self: *FrameRenderer, input: Object) anyerror!Texture {
        const dep_width, const dep_height = input.dims(self.objects);

        const texture = makeTextureOfSize(@intCast(dep_width), @intCast(dep_height));
        errdefer texture.deinit();

        const render_context = FramebufferRenderContext.init(texture, null);
        defer render_context.reset();

        // Output texture size is not the same as input size
        // Set viewport to full texture output size, restore original after
        const temp_viewport = TemporaryViewport.init();
        defer temp_viewport.reset();

        temp_viewport.setViewport(@intCast(dep_width), @intCast(dep_height));

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
            .float => |f| {
                return .{ .float = f };
            },
            .float2 => |f| {
                return .{ .float2 = f };
            },
            .float3 => |f| {
                return .{ .float3 = f };
            },
            .int => |i| {
                return .{ .int = i };
            },
        }
    }
};

pub fn makeFrameRenderer(self: *Renderer, alloc: Allocator, objects: *Objects, shaders: *const ShaderStorage(ShaderId), brushes: *const ShaderStorage(BrushId)) FrameRenderer {
    return .{
        .alloc = alloc,
        .renderer = self,
        .objects = objects,
        .shaders = shaders,
        .brushes = brushes,
        .texture_cache = TextureCache.init(alloc, objects),
    };
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
    float2,
    float3,
    int,

    fn fromGlType(typ: gl.GLenum) ?UniformType {
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

const ResolvedUniformValue = union(UniformType) {
    image: gl.GLuint,
    float: f32,
    float2: [2]f32,
    float3: [3]f32,
    int: i32,
};

const ReservedUniformValue = struct {
    idx: usize,
    val: ResolvedUniformValue,
};

pub const UniformValue = union(UniformType) {
    image: ?ObjectId,
    float: f32,
    float2: [2]f32,
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

pub const DefaultPlaneReservedIndex = enum {
    aspect,
    input_image,

    fn asIndex(self: DefaultPlaneReservedIndex) usize {
        return @intFromEnum(self);
    }
};

pub const CustomShaderReservedIndex = enum {
    aspect,

    fn asIndex(self: CustomShaderReservedIndex) usize {
        return @intFromEnum(self);
    }
};

pub const BrushReservedIndex = enum {
    aspect,
    distance_field,

    fn asIndex(self: BrushReservedIndex) usize {
        return @intFromEnum(self);
    }
};

pub const PlaneRenderProgram = struct {
    program: gl.GLuint,
    transform_location: gl.GLint,

    uniforms: []Uniform,
    reserved_uniforms: []?Uniform,

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

    pub fn init(alloc: Allocator, vs: [:0]const u8, fs: [:0]const u8, comptime IndexType: ?type) !PlaneRenderProgram {
        const program = try compileLinkProgram(vs, fs);
        errdefer gl.glDeleteProgram(program);

        const transform_location = gl.glGetUniformLocation(program, "transform");

        const reserved_names = if (IndexType) |T| std.meta.fieldNames(T) else &.{};
        const uniforms = try getUniformList(alloc, program, reserved_names);
        errdefer freeUniformList(alloc, uniforms.other);
        errdefer freeOptionalUniformList(alloc, uniforms.reserved);

        return .{
            .program = program,
            .transform_location = transform_location,
            .uniforms = uniforms.other,
            .reserved_uniforms = uniforms.reserved,
        };
    }

    pub fn deinit(self: PlaneRenderProgram, alloc: Allocator) void {
        gl.glDeleteProgram(self.program);

        freeUniformList(alloc, self.uniforms);
        freeOptionalUniformList(alloc, self.reserved_uniforms);
    }

    pub fn makeDefaultBuffer(self: PlaneRenderProgram) Buffer {
        return Buffer.init(self.program);
    }

    pub fn render(self: PlaneRenderProgram, buffer: Buffer, uniforms: []const ResolvedUniformValue, reserved_uniforms: []const ReservedUniformValue, transform: lin.Transform) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(buffer.vertex_array);
        gl.glUniformMatrix3fv(self.transform_location, 1, gl.GL_TRUE, &transform.inner.data);

        var texture_unit_alloc = TextureUnitAlloc{};
        for (self.uniforms, 0..) |uniform, i| {
            if (i >= uniforms.len) continue;
            const val = uniforms[i];
            applyUniformAtLocation(uniform.loc, std.meta.activeTag(uniform.default), val, &texture_unit_alloc);
        }

        for (reserved_uniforms) |reserved| {
            const uniform_opt = self.reserved_uniforms[reserved.idx];
            if (uniform_opt) |uniform| {
                applyUniformAtLocation(uniform.loc, std.meta.activeTag(uniform.default), reserved.val, &texture_unit_alloc);
            }
        }

        gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(buffer.len));
    }
};

const TextureUnitAlloc = struct {
    idx: usize = 0,

    const Output = struct {
        active_texture: gl.GLenum,
        uniform_idx: gl.GLint,
    };

    fn next(self: *TextureUnitAlloc) Output {
        defer self.idx += 1;
        return .{
            .active_texture = @intCast(gl.GL_TEXTURE0 + self.idx),
            .uniform_idx = @intCast(self.idx),
        };
    }
};

fn applyUniformAtLocation(loc: gl.GLint, expected_type: UniformType, val: ResolvedUniformValue, texture_unit_alloc: *TextureUnitAlloc) void {
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

const UniformListsOutput = struct {
    other: []Uniform,
    reserved: []?Uniform,
};

fn getUniformList(alloc: Allocator, program: gl.GLuint, reserved_items: []const []const u8) !UniformListsOutput {
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

fn freeUniformList(alloc: Allocator, uniforms: []const Uniform) void {
    for (uniforms) |item| {
        item.deinit(alloc);
    }
    alloc.free(uniforms);
}

fn freeOptionalUniformList(alloc: Allocator, uniforms: []const ?Uniform) void {
    for (uniforms) |opt| {
        if (opt) |item| {
            item.deinit(alloc);
        }
    }
    alloc.free(uniforms);
}

fn isReservedItem(val: []const u8, skipped_items: []const []const u8) ?usize {
    for (skipped_items, 0..) |item, idx| {
        if (std.mem.eql(u8, val, item)) {
            return idx;
        }
    }

    return null;
}

pub const FramebufferRenderContext = struct {
    fbo: gl.GLuint,
    prev_fbo: gl.GLint,

    pub fn init(render_texture: Texture, depth_texture: ?Texture) FramebufferRenderContext {
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

        std.debug.assert(gl.glCheckFramebufferStatus(gl.GL_FRAMEBUFFER) == gl.GL_FRAMEBUFFER_COMPLETE);

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

pub const DistanceFieldGenerator = struct {
    program: gl.GLuint,
    cone_buf: InstancedRenderBuffer,
    tent_buf: InstancedRenderBuffer,
    df_scale_loc: gl.GLint,

    const num_cone_points = 20;
    const depth_radius = 2 * std.math.sqrt2;

    fn init() !DistanceFieldGenerator {
        const program = try compileLinkProgram(distance_field_vertex_shader, distance_field_fragment_shader);
        errdefer gl.glDeleteProgram(program);

        const df_scale_loc = gl.glGetUniformLocation(program, "scale");

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
        };
    }

    fn deinit(self: DistanceFieldGenerator) void {
        self.cone_buf.deinit();
        self.tent_buf.deinit();
        gl.glDeleteProgram(self.program);
    }

    pub fn generateDistanceField(self: DistanceFieldGenerator, alloc: Allocator, point_it: anytype, width: u31, height: u31) !Texture {
        const color_texture = makeTextureOfSize(width, height);
        errdefer color_texture.deinit();

        const depth_texture = makeTextureCommon();
        defer depth_texture.deinit();

        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_DEPTH24_STENCIL8, width, height, 0, gl.GL_DEPTH_STENCIL, gl.GL_UNSIGNED_INT_24_8, null);

        gl.glEnable(gl.GL_DEPTH_TEST);
        // FIXME: Restore initial state, don't hard disable
        defer gl.glDisable(gl.GL_DEPTH_TEST);

        {
            const fb = FramebufferRenderContext.init(color_texture, depth_texture);
            defer fb.reset();

            // Output texture size is not the same as input size
            // Set viewport to full texture output size, restore original after
            const temp_viewport = TemporaryViewport.init();
            defer temp_viewport.reset();

            temp_viewport.setViewport(@intCast(width), @intCast(height));

            clearBuffers();

            const aspect_correction = calcAspectCorrection(width, height);

            gl.glUseProgram(self.program);
            gl.glUniform2f(self.df_scale_loc, aspect_correction[0], aspect_correction[1]);

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

            gl.glVertexArrayVertexBuffer(vertex_array, mesh_binding_index, vertex_buffer, 0, @sizeOf(lin.Vec3));
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

        fn setMeshData(self: InstancedRenderBuffer, points: []const lin.Vec3) void {
            gl.glNamedBufferData(
                self.mesh_vbo,
                @intCast(points.len * @sizeOf(lin.Vec3)),
                points.ptr,
                gl.GL_STATIC_DRAW,
            );
        }

        fn setOffsetData(self: InstancedRenderBuffer, offsets: []const lin.Vec2) void {
            gl.glEnableVertexArrayAttrib(self.vao, self.offsets_loc);

            gl.glVertexArrayVertexBuffer(self.vao, offsets_binding_index, self.offsets_vbo, 0, @sizeOf(lin.Vec2));
            gl.glVertexArrayAttribFormat(self.vao, self.offsets_loc, 2, gl.GL_FLOAT, gl.GL_FALSE, 0);
            gl.glVertexArrayAttribBinding(self.vao, self.offsets_loc, offsets_binding_index);

            gl.glNamedBufferData(
                self.offsets_vbo,
                @intCast(offsets.len * @sizeOf(lin.Vec2)),
                offsets.ptr,
                gl.GL_STATIC_DRAW,
            );
            gl.glVertexArrayBindingDivisor(self.vao, offsets_binding_index, 1);
        }

        const TentTransform = struct {
            offset: lin.Vec2,
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
        var cone_points: [num_cone_points]lin.Vec3 = undefined;
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
        var tent_points: [6]lin.Vec3 = undefined;
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

    fn calcAspectCorrection(width: usize, height: usize) lin.Vec2 {
        const aspect = coords.calcAspect(width, height);
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

    fn updateBuffers(self: DistanceFieldGenerator, alloc: Allocator, point_it: anytype, aspect_correction: lin.Vec2) !BufferLens {
        var cone_offsets = std.ArrayList(lin.Vec2).init(alloc);
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
            const stretch = lin.length(line);
            const rotation = std.math.atan2(line[1], line[0]);
            const offs = (last_point + p) / lin.Vec2{ 2.0, 2.0 };

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
        gl.GL_RGBA32F,
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

fn makeTextureCommon() Texture {
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

const plane_vertices: []const f32 = &.{
    -1.0, -1.0, 0.0, 0.0,
    1.0,  -1.0, 1.0, 0.0,
    -1.0, 1.0,  0.0, 1.0,
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

const distance_field_vertex_shader =
    \\#version 330
    \\in vec3 vPos;
    \\in vec2 vOffs;
    \\in float stretch;
    \\in float rotation;
    \\out float depth;
    \\uniform vec2 scale = vec2(1.0, 1.0);
    \\void main()
    \\{
    \\    mat2x2 rot_mat = mat2x2(vec2(cos(rotation), sin(rotation)), vec2(-sin(rotation), cos(rotation)));
    \\    vec2 pos = vOffs + rot_mat * vec2(vPos.x * stretch, vPos.y);
    \\    gl_Position = vec4(pos * scale, vPos.z, 1.0);
    \\    depth = vPos.z;
    \\}
;

const distance_field_fragment_shader =
    \\#version 330 core
    \\out vec4 fragment;
    \\in float depth;
    \\void main()
    \\{
    \\    // I still struggle with OpenGL coordinate systems...
    \\    // Visualizing texture output in blender seemed pretty parabolic
    \\    fragment = vec4(sqrt(depth), sqrt(depth), sqrt(depth), 1.0);
    \\}
;
