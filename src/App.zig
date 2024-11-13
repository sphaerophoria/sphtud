const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const stbi = @cImport({
    @cInclude("stb_image.h");
});

const App = @This();

alloc: Allocator,
objects: Objects = .{},
program: PlaneRenderProgram,
path_program: PathRenderProgram,
window_width: usize,
window_height: usize,
mouse_pos: Vec2 = .{ 0.0, 0.0 },
selected_object: ObjectId = .{ .value = 0 },

pub fn init(alloc: Allocator, window_width: usize, window_height: usize) !App {
    var objects = Objects{};
    errdefer objects.deinit(alloc);

    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const plane_program = try PlaneRenderProgram.init(alloc, plane_vertex_shader, plane_fragment_shader, &.{"u_texture"});
    errdefer plane_program.deinit(alloc);

    const path_program = try PathRenderProgram.init();
    errdefer path_program.deinit(alloc);

    return .{
        .alloc = alloc,
        .objects = objects,
        .program = plane_program,
        .path_program = path_program,
        .window_width = window_width,
        .window_height = window_height,
    };
}

pub fn deinit(self: *App) void {
    self.objects.deinit(self.alloc);
    self.program.deinit(self.alloc);
}

pub fn save(self: *App, path: []const u8) !void {
    const object_saves = try self.objects.save(self.alloc);
    defer self.alloc.free(object_saves);

    const out_f = try std.fs.cwd().createFile(path, .{});
    defer out_f.close();

    try std.json.stringify(
        SaveData{
            .objects = object_saves,
        },
        .{ .whitespace = .indent_2 },
        out_f.writer(),
    );
}

pub fn load(self: *App, path: []const u8) !void {
    const in_f = try std.fs.cwd().openFile(path, .{});
    defer in_f.close();

    var json_reader = std.json.reader(self.alloc, in_f.reader());
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(SaveData, self.alloc, &json_reader, .{});
    defer parsed.deinit();

    var new_objects = try Objects.initCapacity(self.alloc, parsed.value.objects.len);
    // Note that objects gets swapped in and is freed by this defer
    defer new_objects.deinit(self.alloc);

    for (parsed.value.objects) |saved_object| {
        var object = try Object.load(self.alloc, saved_object, self.path_program.vpos_location);
        errdefer object.deinit(self.alloc);

        try new_objects.append(self.alloc, object);
    }

    // Swap objects so the old ones get deinited
    std.mem.swap(Objects, &new_objects, &self.objects);

    // Loaded masks do not generate textures
    try self.regenerateAllMasks();
}

pub fn setMouseDown(self: *App) void {
    switch (self.objects.get(self.selected_object).data) {
        .composition => |*c| c.selectClosestPoint(self.mouse_pos),
        .path => |*p| p.selectClosestPoint(self.mouse_pos),
        else => {},
    }
}

pub fn setMouseUp(self: *App) void {
    switch (self.objects.get(self.selected_object).data) {
        .composition => |*c| c.selected_obj = null,
        .path => |*p| p.selected_point = null,
        else => {},
    }
}

pub fn clickRightMouse(self: *App) !void {
    switch (self.objects.get(self.selected_object).data) {
        .path => |*p| {
            try p.addPoint(self.alloc, self.mouse_pos);
            try self.regeneratePathMasks(self.selected_object);
        },
        else => {},
    }
}

pub fn setMousePos(self: *App, xpos: f32, ypos: f32) !void {
    const new_x = windowToClipX(xpos, self.window_width);
    const new_y = windowToClipY(ypos, self.window_height);
    const new_pos = Vec2{ new_x, new_y };
    defer self.mouse_pos = new_pos;

    switch (self.objects.get(self.selected_object).data) {
        .composition => |*composition_object| {
            composition_object.moveObject(new_pos - self.mouse_pos);
        },
        .path => |*p| {
            p.movePoint(new_pos - self.mouse_pos);
            if (p.selected_point) |_| {
                try self.regeneratePathMasks(self.selected_object);
            }
        },
        else => {},
    }
}

pub fn createPath(self: *App) !void {
    const initial_positions: []const Vec2 = &.{
        Vec2{ -0.5, -0.5 },
        Vec2{ 0.5, 0.5 },
    };

    const path_id = self.objects.nextId();
    const path_obj = try PathObject.init(
        self.alloc,
        initial_positions,
        self.selected_object,
        self.path_program.vpos_location,
    );
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new path"),
        .data = .{
            .path = path_obj,
        },
    });

    const selected_dims = self.objects.get(self.selected_object).dims(&self.objects);
    const mask_id = self.objects.nextId();
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new mask"),
        .data = .{
            .generated_mask = try GeneratedMaskObject.generate(self.alloc, path_id, selected_dims[0], selected_dims[1], path_obj.points.items),
        },
    });

    const masked_obj_id = self.objects.nextId();
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "masked obj"),
        .data = .{
            .shader = try ShaderObject.init(self.alloc, &.{ self.selected_object, mask_id }, mul_fragment_shader, &.{ "u_texture", "u_texture_2" }, selected_dims[0], selected_dims[1]),
        },
    });

    // HACK: Assume composition object is 0
    const composition = &self.objects.get(.{ .value = 0 }).data.composition;
    try composition.objects.append(self.alloc, .{
        .id = masked_obj_id,
        .transform = Transform.scale(0.5, 0.5),
    });
}

pub fn render(self: *App) !void {
    gl.glViewport(0, 0, @intCast(self.window_width), @intCast(self.window_height));
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    var texture_cache: TextureCache = TextureCache.init(self.alloc, &self.objects);
    defer texture_cache.deinit();

    const active_object = self.objects.get(self.selected_object);
    try self.renderObjectWithTransform(active_object.*, Transform.identity, &texture_cache);
}

fn renderedTexture(self: *App, texture_cache: *TextureCache, id: ObjectId) !gl.GLuint {
    if (texture_cache.get(id)) |t| {
        return t;
    }

    const texture = try self.renderObjectToTexture(self.objects.get(id).*, texture_cache);
    try texture_cache.put(id, texture);
    return texture;
}

fn renderObjectWithTransform(self: *App, object: Object, transform: Transform, texture_cache: *TextureCache) !void {
    switch (object.data) {
        .composition => |c| {
            for (c.objects.items) |composition_object| {
                const next_object = self.objects.get(composition_object.id);
                switch (next_object.data) {
                    .composition => return error.NestedComposition,
                    else => {},
                }
                try self.renderObjectWithTransform(next_object.*, composition_object.transform, texture_cache);
            }
        },
        .filesystem => |f| {
            self.program.render(&.{f.texture}, transform);
        },
        .shader => |s| {
            var sources = std.ArrayList(gl.GLuint).init(self.alloc);
            defer sources.deinit();

            for (s.input_images) |input_image| {
                const texture = try self.renderedTexture(texture_cache, input_image);
                try sources.append(texture);
            }

            s.program.render(sources.items, transform);
        },
        .path => |p| {
            const display_object = self.objects.get(p.display_object);
            try self.renderObjectWithTransform(display_object.*, transform, texture_cache);

            self.path_program.render(p.vertex_array, p.selected_point, p.points.items.len);
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

fn renderObjectToTexture(self: *App, input: Object, texture_cache: *TextureCache) anyerror!gl.GLuint {
    const dep_width, const dep_height = input.dims(&self.objects);

    const texture = makeTextureOfSize(@intCast(dep_width), @intCast(dep_height));
    errdefer gl.glDeleteTextures(1, &texture);

    const render_context = FramebufferRenderContext.init(texture);
    defer render_context.reset();

    // Output texture size is not the same as input size
    // Set viewport to full texture output size, restore original after
    const temp_viewport = TemporaryViewport.init();
    defer temp_viewport.reset();

    temp_viewport.setViewport(@intCast(dep_width), @intCast(dep_height));

    try self.renderObjectWithTransform(input, Transform.identity, texture_cache);
    return texture;
}

const MaskIterator = struct {
    it: Objects.IdIter,
    objects: *Objects,

    fn next(self: *MaskIterator) ?*GeneratedMaskObject {
        while (self.it.next()) |obj_id| {
            const obj = self.objects.get(obj_id);
            switch (obj.data) {
                .generated_mask => |*m| return m,
                else => continue,
            }
        }

        return null;
    }
};

fn regenerateMask(self: *App, mask: *GeneratedMaskObject) !void {
    const path_obj = self.objects.get(mask.source);
    const path = switch (path_obj.data) {
        .path => |*p| p,
        else => return error.InvalidMaskObj,
    };

    const width, const height = path_obj.dims(&self.objects);
    var tmp = try GeneratedMaskObject.generate(self.alloc, mask.source, width, height, path.points.items);
    defer tmp.deinit();

    std.mem.swap(GeneratedMaskObject, mask, &tmp);
}

fn regeneratePathMasks(self: *App, path_id: ObjectId) !void {
    var it = MaskIterator{ .it = self.objects.idIter(), .objects = &self.objects };
    while (it.next()) |mask| {
        if (mask.source.value != path_id.value) continue;
        try self.regenerateMask(mask);
    }
}

fn regenerateAllMasks(self: *App) !void {
    var it = MaskIterator{ .it = self.objects.idIter(), .objects = &self.objects };
    while (it.next()) |mask| {
        try self.regenerateMask(mask);
    }
}

pub const ObjectId = struct {
    value: usize,
};

pub const Objects = struct {
    inner: std.ArrayListUnmanaged(Object) = .{},

    pub fn initCapacity(alloc: Allocator, capacity: usize) !Objects {
        return Objects{
            .inner = try std.ArrayListUnmanaged(Object).initCapacity(alloc, capacity),
        };
    }

    pub fn deinit(self: *Objects, alloc: Allocator) void {
        for (self.inner.items) |*object| {
            object.deinit(alloc);
        }
        self.inner.deinit(alloc);
    }

    pub fn get(self: *Objects, id: ObjectId) *Object {
        return &self.inner.items[id.value];
    }

    pub fn nextId(self: Objects) ObjectId {
        return .{ .value = self.inner.items.len };
    }

    pub const IdIter = struct {
        val: usize = 0,
        max: usize,

        pub fn next(self: *IdIter) ?ObjectId {
            if (self.val >= self.max) return null;
            defer self.val += 1;
            return .{ .value = self.val };
        }
    };

    pub fn idIter(self: Objects) IdIter {
        return .{ .max = self.inner.items.len };
    }

    pub fn save(self: Objects, alloc: Allocator) ![]SaveObject {
        const object_saves = try alloc.alloc(SaveObject, self.inner.items.len);
        errdefer alloc.free(object_saves);

        for (0..self.inner.items.len) |i| {
            object_saves[i] = self.inner.items[i].save();
        }

        return object_saves;
    }

    pub fn append(self: *Objects, alloc: Allocator, object: Object) !void {
        try self.inner.append(alloc, object);
    }
};

const TextureCache = struct {
    inner: Inner,
    objects: *Objects,
    const Inner = std.AutoHashMap(ObjectId, gl.GLuint);

    fn init(alloc: Allocator, objects: *Objects) TextureCache {
        return .{
            .inner = Inner.init(alloc),
            .objects = objects,
        };
    }

    fn deinit(self: *TextureCache) void {
        var texture_it = self.inner.valueIterator();
        while (texture_it.next()) |t| {
            gl.glDeleteTextures(1, t);
        }

        self.inner.deinit();
    }

    fn get(self: *TextureCache, id: ObjectId) ?gl.GLuint {
        const object = self.objects.get(id);

        switch (object.data) {
            .filesystem => |f| return f.texture,
            .generated_mask => |m| return m.texture,
            else => {},
        }

        return self.inner.get(id);
    }

    fn put(self: *TextureCache, id: ObjectId, texture: gl.GLuint) !void {
        try self.inner.put(id, texture);
    }
};

const PlaneRenderProgram = struct {
    program: gl.GLuint,
    transform_location: gl.GLint,
    texture_locations: []gl.GLint,
    vertex_buffer: gl.GLuint,
    vertex_array: gl.GLuint,

    fn init(alloc: Allocator, vs: [:0]const u8, fs: [:0]const u8, texture_names: []const [:0]const u8) !PlaneRenderProgram {
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
        gl.glBufferData(gl.GL_ARRAY_BUFFER, vertices.len * 4, vertices.ptr, gl.GL_STATIC_DRAW);

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

    fn deinit(self: PlaneRenderProgram, alloc: Allocator) void {
        alloc.free(self.texture_locations);
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
        gl.glDeleteProgram(self.program);
    }

    fn render(self: PlaneRenderProgram, textures: []const gl.GLuint, transform: Transform) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(self.vertex_array);
        gl.glUniformMatrix3fv(self.transform_location, 1, gl.GL_TRUE, &transform.data);

        for (0..textures.len) |i| {
            const texture_unit = gl.GL_TEXTURE0 + i;
            gl.glActiveTexture(@intCast(texture_unit));
            gl.glBindTexture(gl.GL_TEXTURE_2D, textures[i]);
            gl.glUniform1i(self.texture_locations[i], @intCast(i));
        }

        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
    }
};

pub const FramebufferRenderContext = struct {
    fbo: gl.GLuint,

    pub fn init(render_texture: gl.GLuint) FramebufferRenderContext {
        var fbo: gl.GLuint = undefined;
        gl.glGenFramebuffers(1, &fbo);

        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo);
        gl.glFramebufferTexture2D(
            gl.GL_FRAMEBUFFER,
            gl.GL_COLOR_ATTACHMENT0,
            gl.GL_TEXTURE_2D,
            render_texture,
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

const PathRenderProgram = struct {
    program: gl.GLuint,
    vpos_location: gl.GLint,

    fn init() !PathRenderProgram {
        const program = try compileLinkProgram(path_vertex_shader, path_fragment_shader);
        errdefer gl.glDeleteProgram(program);

        const vpos_location = gl.glGetAttribLocation(program, "vPos");

        return .{
            .program = program,
            .vpos_location = vpos_location,
        };
    }

    fn deinit(self: PathRenderProgram) void {
        gl.glDeleteProgram(self.program);
    }

    fn render(self: PathRenderProgram, vertex_array: gl.GLuint, selected_point: ?usize, num_points: usize) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(vertex_array);
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

fn getCompositionObj(self: *App) ?*CompositionObject {
    switch (self.objects.get(self.selected_object).data) {
        .composition => |*c| return c,
        else => return null,
    }
}

fn windowToClipX(xpos: f32, width: usize) f32 {
    const window_width_f: f32 = @floatFromInt(width);
    return ((xpos / window_width_f) - 0.5) * 2;
}

fn windowToClipY(ypos: f32, height: usize) f32 {
    const window_height_f: f32 = @floatFromInt(height);
    return (1.0 - (ypos / window_height_f) - 0.5) * 2;
}

fn objectToPixelCoord(val: f32, max: usize) i64 {
    const max_f: f32 = @floatFromInt(max);
    return @intFromFloat(((val + 1) / 2) * max_f);
}

fn pixelToObjectCoord(val: usize, max: usize) f32 {
    const val_f: f32 = @floatFromInt(val);
    const max_f: f32 = @floatFromInt(max);
    return ((val_f / max_f) - 0.5) * 2;
}

const vertices: []const f32 = &.{
    -1.0, -1.0, 0.0, 0.0,
    1.0,  -1.0, 1.0, 0.0,
    -1.0, 1.0,  0.0, 1.0,
    1.0,  1.0,  1.0, 1.0,
};

const plane_vertex_shader =
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
    \\in vec2 vPos;
    \\void main()
    \\{
    \\    gl_Position = vec4(vPos, 0.0, 1.0);
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

pub fn loadImageToTexture(path: [:0]const u8) !gl.GLuint {
    const image = try StbImage.init(path);
    defer image.deinit();

    return makeTextureFromRgba(image.data, image.width);
}

pub fn makeTextureFromR(data: []const u8, width: usize) gl.GLuint {
    const texture = makeTextureCommon();
    const height = data.len / width;
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RED, @intCast(width), @intCast(height), 0, gl.GL_RED, gl.GL_UNSIGNED_BYTE, data.ptr);

    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);

    return texture;
}

pub fn makeTextureFromRgba(data: []const u8, width: usize) gl.GLuint {
    const texture = makeTextureCommon();

    const height = data.len / width / 4;
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(width), @intCast(height), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, data.ptr);

    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);

    return texture;
}

pub fn makeTextureOfSize(width: u31, height: u31) gl.GLuint {
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

pub fn makeTextureCommon() gl.GLuint {
    var texture: gl.GLuint = 0;

    // Generate the texture object
    gl.glGenTextures(1, &texture);
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture);

    // Set texture parameters (you can adjust these for your needs)
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT); // Wrap horizontally
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT); // Wrap vertically
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR); // Minification filter
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR); // Magnification filter

    return texture;
}

const StbImage = struct {
    data: []u8,
    width: usize,

    fn init(path: [:0]const u8) !StbImage {
        var width: c_int = 0;
        var height: c_int = 0;
        stbi.stbi_set_flip_vertically_on_load(1);
        const data = stbi.stbi_load(path, &width, &height, null, 4);

        if (data == null) {
            return error.NoData;
        }

        errdefer stbi.stbi_image_free(data);

        if (width < 0) {
            return error.InvalidWidth;
        }

        return .{
            .data = data[0..@intCast(width * height * 4)],
            .width = @intCast(width),
        };
    }

    fn deinit(self: StbImage) void {
        stbi.stbi_image_free(@ptrCast(self.data.ptr));
    }

    fn calcHeight(self: StbImage) usize {
        return self.data.len / self.width / 4;
    }
};

const Vec3 = @Vector(3, f32);
const Vec2 = @Vector(2, f32);

fn applyHomogenous(in: Vec3) Vec2 {
    return .{
        in[0] / in[2],
        in[1] / in[2],
    };
}

fn length2(in: Vec2) f32 {
    return @reduce(.Add, in * in);
}

pub const Transform = struct {
    const identity: Transform = .{};

    data: [9]f32 = .{
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
    },

    pub fn mul(self: Transform, vec: Vec3) Vec3 {
        const x = self.data[0..3].* * vec;
        const y = self.data[3..6].* * vec;
        const z = self.data[6..9].* * vec;

        return .{
            @reduce(.Add, x),
            @reduce(.Add, y),
            @reduce(.Add, z),
        };
    }

    pub fn scale(x: f32, y: f32) Transform {
        return .{ .data = .{
            x,   0.0, 0.0,
            0.0, y,   0.0,
            0.0, 0.0, 1.0,
        } };
    }
};

pub const Object = struct {
    name: []u8,
    data: Data,

    pub const Data = union(enum) {
        filesystem: FilesystemObject,
        composition: CompositionObject,
        shader: ShaderObject,
        path: PathObject,
        generated_mask: GeneratedMaskObject,
    };

    fn deinit(self: *Object, alloc: Allocator) void {
        alloc.free(self.name);
        switch (self.data) {
            .filesystem => |*f| f.deinit(alloc),
            .composition => |*c| c.deinit(alloc),
            .shader => |*s| s.deinit(alloc),
            .path => |*p| p.deinit(alloc),
            .generated_mask => |*g| g.deinit(),
        }
    }

    fn save(self: Object) SaveObject {
        const data: SaveObject.Data = switch (self.data) {
            .filesystem => |s| .{ .filesystem = s.source },
            .composition => |c| .{ .composition = c.objects.items },
            .shader => |s| s.save(),
            .path => |p| .{ .path = .{
                .points = p.points.items,
                .display_object = p.display_object.value,
            } },
            .generated_mask => |g| .{
                .generated_mask = g.source.value,
            },
        };

        return .{
            .name = self.name,
            .data = data,
        };
    }

    fn load(alloc: Allocator, save_obj: SaveObject, path_vpos_loc: gl.GLint) !Object {
        const data: Data = switch (save_obj.data) {
            .filesystem => |s| blk: {
                break :blk .{
                    .filesystem = try FilesystemObject.load(alloc, s),
                };
            },
            .composition => |c| blk: {
                var objects = std.ArrayListUnmanaged(CompositionObject.ComposedObject){};
                errdefer objects.deinit(alloc);

                try objects.appendSlice(alloc, c);
                break :blk .{
                    .composition = .{
                        .objects = objects,
                    },
                };
            },
            .shader => |s| blk: {
                comptime {
                    std.debug.assert(@alignOf(ObjectId) == @alignOf(usize));
                    std.debug.assert(@sizeOf(ObjectId) == @sizeOf(usize));
                }

                break :blk .{
                    .shader = try ShaderObject.init(alloc, @ptrCast(s.input_images), s.shader_source, s.texture_names, s.width, s.height),
                };
            },
            .path => |p| blk: {
                break :blk .{
                    .path = try PathObject.init(alloc, p.points, .{ .value = p.display_object }, path_vpos_loc),
                };
            },
            .generated_mask => |source| .{
                .generated_mask = GeneratedMaskObject.initNullTexture(.{ .value = source }),
            },
        };

        return .{
            .name = try alloc.dupe(u8, save_obj.name),
            .data = data,
        };
    }

    fn dims(self: Object, object_list: *Objects) struct { usize, usize } {
        switch (self.data) {
            .filesystem => |*f| {
                return .{ f.width, f.height };
            },
            .path => |*p| {
                const display_object = object_list.get(p.display_object);
                return dims(display_object.*, object_list);
            },
            .generated_mask => |*m| {
                const source = object_list.get(m.source);
                return dims(source.*, object_list);
            },
            .shader => |s| {
                return .{ s.width, s.height };
            },
            inline else => |_, t| {
                @panic("Do not know how to get width for " ++ @tagName(t));
            },
        }
    }
};

pub const CompositionObject = struct {
    const ComposedObject = struct {
        id: ObjectId,
        transform: Transform,
    };

    objects: std.ArrayListUnmanaged(ComposedObject) = .{},
    selected_obj: ?usize = null,

    fn selectClosestPoint(self: *CompositionObject, test_pos: Vec2) void {
        var closest_idx: usize = 0;
        var current_dist = std.math.inf(f32);

        for (0..self.objects.items.len) |idx| {
            const transform = self.objects.items[idx].transform;
            const center = applyHomogenous(transform.mul(Vec3{ 0, 0, 1 }));
            const dist = length2(center - test_pos);
            if (dist < current_dist) {
                closest_idx = idx;
                current_dist = dist;
            }
        }

        self.selected_obj = closest_idx;
    }

    fn moveObject(self: *CompositionObject, movement: Vec2) void {
        if (self.selected_obj) |idx| {
            const obj = &self.objects.items[idx];

            // FIXME: implement mat mul
            std.debug.assert(obj.transform.data[8] == 1);

            // FIXME: Gross hack, create translation and mat mul it in
            obj.transform.data[2] += movement[0];
            obj.transform.data[5] += movement[1];
        }
    }

    pub fn deinit(self: *CompositionObject, alloc: Allocator) void {
        self.objects.deinit(alloc);
    }
};

pub const ShaderObject = struct {
    input_images: []ObjectId,
    shader_source: [:0]const u8,
    texture_names: []const [:0]const u8,
    width: usize,
    height: usize,

    program: PlaneRenderProgram,

    pub fn init(alloc: Allocator, input_images: []const ObjectId, shader_source: [:0]const u8, texture_names: []const [:0]const u8, width: usize, height: usize) !ShaderObject {
        const program = try PlaneRenderProgram.init(alloc, plane_vertex_shader, shader_source, texture_names);
        errdefer program.deinit(alloc);

        const duped_names = try copyTextureNames(alloc, texture_names);
        errdefer freeTextureNames(alloc, duped_names);

        const duped_images = try alloc.dupe(ObjectId, input_images);
        errdefer alloc.free(duped_images);

        const duped_source = try alloc.dupeZ(u8, shader_source);
        errdefer alloc.free(duped_source);

        return .{
            .input_images = duped_images,
            .shader_source = duped_source,
            .texture_names = duped_names,
            .program = program,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *ShaderObject, alloc: Allocator) void {
        self.program.deinit(alloc);
        alloc.free(self.input_images);
        alloc.free(self.shader_source);
        freeTextureNames(alloc, self.texture_names);
    }

    pub fn save(self: ShaderObject) SaveObject.Data {
        comptime {
            std.debug.assert(@alignOf(ObjectId) == @alignOf(usize));
            std.debug.assert(@sizeOf(ObjectId) == @sizeOf(usize));
        }

        return .{
            .shader = .{
                .input_images = @ptrCast(self.input_images),
                .shader_source = @ptrCast(self.shader_source),
                .width = self.width,
                .height = self.height,
                .texture_names = self.texture_names,
            },
        };
    }

    fn copyTextureNames(alloc: Allocator, texture_names: []const [:0]const u8) ![]const [:0]const u8 {
        var i: usize = 0;
        const duped_texture_names = try alloc.alloc([:0]const u8, texture_names.len);
        errdefer {
            for (0..i) |j| {
                alloc.free(duped_texture_names[j]);
            }
            alloc.free(duped_texture_names);
        }

        while (i < texture_names.len) {
            duped_texture_names[i] = try alloc.dupeZ(u8, texture_names[i]);
            i += 1;
        }

        return duped_texture_names;
    }

    fn freeTextureNames(alloc: Allocator, texture_names: []const [:0]const u8) void {
        for (texture_names) |n| {
            alloc.free(n);
        }
        alloc.free(texture_names);
    }
};

pub const FilesystemObject = struct {
    source: [:0]const u8,
    width: usize,
    height: usize,
    // FIXME: Aspect

    texture: gl.GLuint,

    pub fn load(alloc: Allocator, path: [:0]const u8) !FilesystemObject {
        const image = try StbImage.init(path);
        defer image.deinit();

        const texture = App.makeTextureFromRgba(image.data, image.width);
        errdefer gl.glDeleteTextures(1, &texture);

        const source = try alloc.dupeZ(u8, path);
        errdefer alloc.free(source);

        return .{
            .texture = texture,
            .width = image.width,
            .height = image.calcHeight(),
            .source = source,
        };
    }

    pub fn deinit(self: FilesystemObject, alloc: Allocator) void {
        gl.glDeleteTextures(1, &self.texture);
        alloc.free(self.source);
    }
};

pub const PathObject = struct {
    points: std.ArrayListUnmanaged(Vec2) = .{},
    display_object: ObjectId,

    selected_point: ?usize = null,
    vertex_array: gl.GLuint,
    vertex_buffer: gl.GLuint,

    pub fn init(alloc: Allocator, initial_points: []const Vec2, display_object: ObjectId, vpos_location: gl.GLint) !PathObject {
        var points = try std.ArrayListUnmanaged(Vec2).initCapacity(alloc, initial_points.len);
        errdefer points.deinit(alloc);

        try points.appendSlice(alloc, initial_points);

        var vertex_buffer: gl.GLuint = 0;
        gl.glGenBuffers(1, &vertex_buffer);
        errdefer gl.glDeleteBuffers(1, &vertex_buffer);

        setBufferData(vertex_buffer, points.items);

        var vertex_array: gl.GLuint = 0;
        gl.glGenVertexArrays(1, &vertex_array);
        errdefer gl.glDeleteVertexArrays(1, &vertex_array);

        gl.glBindVertexArray(vertex_array);

        gl.glEnableVertexAttribArray(@intCast(vpos_location));
        gl.glVertexAttribPointer(@intCast(vpos_location), 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * 2, null);
        return .{
            .points = points,
            .display_object = display_object,
            .vertex_array = vertex_array,
            .vertex_buffer = vertex_buffer,
        };
    }

    fn selectClosestPoint(self: *PathObject, test_pos: Vec2) void {
        var closest_point: usize = 0;
        var min_dist = std.math.inf(f32);

        for (self.points.items, 0..) |point, idx| {
            const dist = length2(test_pos - point);
            if (dist < min_dist) {
                closest_point = idx;
                min_dist = dist;
            }
        }

        self.selected_point = closest_point;
    }

    fn setBufferData(vertex_buffer: gl.GLuint, points: []const Vec2) void {
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(points.len * 8), points.ptr, gl.GL_DYNAMIC_DRAW);
    }

    fn addPoint(self: *PathObject, alloc: Allocator, pos: Vec2) !void {
        try self.points.append(alloc, pos);
        setBufferData(self.vertex_buffer, self.points.items);
    }

    fn movePoint(self: *PathObject, movement: Vec2) void {
        const idx = if (self.selected_point) |idx| idx else return;

        self.points.items[idx] += movement;
        gl.glNamedBufferSubData(self.vertex_buffer, @intCast(idx * 8), 8, &self.points.items[idx]);
    }

    fn deinit(self: *PathObject, alloc: Allocator) void {
        self.points.deinit(alloc);
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
    }
};

pub const GeneratedMaskObject = struct {
    source: ObjectId,

    texture: gl.GLuint,

    pub fn initNullTexture(source: ObjectId) GeneratedMaskObject {
        return .{
            .source = source,
            .texture = std.math.maxInt(gl.GLuint),
        };
    }

    pub fn generate(alloc: Allocator, source: ObjectId, width: usize, height: usize, path_points: []const Vec2) !GeneratedMaskObject {
        const mask = try alloc.alloc(u8, width * height);
        defer alloc.free(mask);

        @memset(mask, 0);

        const bb = findBoundingBox(path_points, width, height);
        const width_i64: i64 = @intCast(width);

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        for (bb.y_start..bb.y_end) |y| {
            _ = arena.reset(.retain_capacity);
            const arena_alloc = arena.allocator();

            const intersection_points = try findIntersectionPoints(arena_alloc, path_points, y, width, height);
            defer arena_alloc.free(intersection_points);

            // Assume we start outside the polygon
            const row_start = width * y;
            const row_end = row_start + width;

            const row = mask[row_start..row_end];
            for (0..intersection_points.len / 2) |i| {
                const a = intersection_points[i * 2];
                const b = intersection_points[i * 2 + 1];
                const a_u: usize = @intCast(std.math.clamp(a, 0, width_i64));
                const b_u: usize = @intCast(std.math.clamp(b, 0, width_i64));
                @memset(row[a_u..b_u], 0xff);
            }
        }

        const texture = makeTextureFromR(mask, width);
        return .{
            .texture = texture,
            .source = source,
        };
    }

    const BoundingBox = struct {
        y_start: usize,
        y_end: usize,
        x_start: usize,
        x_end: usize,
    };

    fn findBoundingBox(points: []const Vec2, width: usize, height: usize) BoundingBox {
        // Points are in [-1, 1]
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);

        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);

        for (points) |point| {
            if (point[0] < min_x) min_x = point[0];
            if (point[1] < min_y) min_y = point[1];
            if (point[0] > max_x) max_x = point[0];
            if (point[1] > max_y) max_y = point[1];
        }

        const min_x_pixel = objectToPixelCoord(min_x, width);
        const min_y_pixel = objectToPixelCoord(min_y, height);
        const max_x_pixel = objectToPixelCoord(max_x, width);
        const max_y_pixel = objectToPixelCoord(max_y, height);

        const w_i64: i64 = @intCast(width);
        const h_i64: i64 = @intCast(height);
        return .{
            .x_start = @intCast(std.math.clamp(min_x_pixel, 0, w_i64)),
            .y_start = @intCast(std.math.clamp(min_y_pixel, 0, h_i64)),
            .x_end = @intCast(std.math.clamp(max_x_pixel, 0, w_i64)),
            .y_end = @intCast(std.math.clamp(max_y_pixel, 0, h_i64)),
        };
    }

    fn findIntersectionPoints(alloc: Allocator, points: []const Vec2, y_px: usize, width: usize, height: usize) ![]i64 {
        var intersection_points = std.ArrayList(i64).init(alloc);
        defer intersection_points.deinit();

        const y_clip = pixelToObjectCoord(y_px, height);

        for (0..points.len) |i| {
            const a = points[i];
            const b = points[(i + 1) % points.len];

            const t = (y_clip - b[1]) / (a[1] - b[1]);
            if (t > 1.0 or t < 0.0) {
                continue;
            }

            const x_clip = std.math.lerp(b[0], a[0], t);
            const x_px = objectToPixelCoord(x_clip, width);
            try intersection_points.append(@intCast(x_px));
        }

        const lessThan = struct {
            fn f(_: void, lhs: i64, rhs: i64) bool {
                return lhs < rhs;
            }
        }.f;

        std.mem.sort(i64, intersection_points.items, {}, lessThan);
        return try intersection_points.toOwnedSlice();
    }

    pub fn deinit(self: GeneratedMaskObject) void {
        gl.glDeleteTextures(1, &self.texture);
    }
};

const SaveObject = struct {
    name: []const u8,
    data: Data,

    const Data = union(enum) {
        filesystem: [:0]const u8,
        composition: []CompositionObject.ComposedObject,
        shader: struct {
            input_images: []usize,
            shader_source: [:0]const u8,
            texture_names: []const [:0]const u8,
            width: usize,
            height: usize,
        },
        path: struct {
            points: []Vec2,
            display_object: usize,
        },
        generated_mask: usize,
    };
};

const SaveData = struct {
    objects: []SaveObject,
};
