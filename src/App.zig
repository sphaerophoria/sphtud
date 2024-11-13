const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const stbi = @cImport({
    @cInclude("stb_image.h");
});

const App = @This();

alloc: Allocator,
objects: Objects = .{},
program: Program,
window_width: usize,
window_height: usize,
mouse_pos: Vec2 = .{ 0.0, 0.0 },
selected_object: ObjectId = .{ .value = 0 },

pub fn init(alloc: Allocator, window_width: usize, window_height: usize) !App {
    var objects = Objects{};
    errdefer objects.deinit(alloc);

    const program = try Program.init(vertex_shader_text, fragment_shader_text);
    return .{
        .alloc = alloc,
        .objects = objects,
        .program = program,
        .window_width = window_width,
        .window_height = window_height,
    };
}

pub fn deinit(self: *App) void {
    self.objects.deinit(self.alloc);
    self.program.deinit();
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
        var object = try Object.load(self.alloc, saved_object);
        errdefer object.deinit(self.alloc);

        try new_objects.append(self.alloc, object);
    }

    // Swap objects so the old ones get deinited
    std.mem.swap(Objects, &new_objects, &self.objects);
}

pub fn setMouseDown(self: *App) void {
    const composition_obj = self.getCompositionObj() orelse return;

    if (composition_obj.objects.items.len < 1) {
        return;
    }

    var closest_idx: usize = 0;
    var current_dist = std.math.inf(f32);

    for (0..composition_obj.objects.items.len) |idx| {
        const transform = composition_obj.objects.items[idx].transform;
        const center = applyHomogenous(transform.mul(Vec3{ 0, 0, 1 }));
        const dist = length2(center - self.mouse_pos);
        if (dist < current_dist) {
            closest_idx = idx;
            current_dist = dist;
        }
    }

    composition_obj.selected_obj = closest_idx;
}

pub fn setMouseUp(self: *App) void {
    const composition_obj = self.getCompositionObj() orelse return;
    composition_obj.selected_obj = null;
}

pub fn setMousePos(self: *App, xpos: f32, ypos: f32) void {
    const new_pos = self.windowToClip(xpos, ypos);
    defer self.mouse_pos = new_pos;

    const composition_object = self.getCompositionObj() orelse return;
    const movement = new_pos - self.mouse_pos;
    if (composition_object.selected_obj) |idx| {
        const obj = &composition_object.objects.items[idx];

        // FIXME: implement mat mul
        std.debug.assert(obj.transform.data[8] == 1);

        // FIXME: Gross hack, create translation and mat mul it in
        obj.transform.data[2] += movement[0];
        obj.transform.data[5] += movement[1];
    }
}

pub fn render(self: *App) !void {
    gl.glViewport(0, 0, @intCast(self.window_width), @intCast(self.window_height));
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    const active_object = self.objects.get(self.selected_object);
    try self.renderObjectWithTransform(active_object.*, Transform.identity);
}

fn renderObjectWithTransform(self: *App, object: Object, transform: Transform) !void {
    switch (object.data) {
        .composition => |c| {
            for (c.objects.items) |composition_object| {
                const next_object = self.objects.get(composition_object.id);
                switch (next_object.data) {
                    .composition => return error.NestedComposition,
                    else => {},
                }
                try self.renderObjectWithTransform(next_object.*, composition_object.transform);
            }
        },
        .filesystem => |f| {
            self.program.render(f.texture, transform);
        },
        .shader => |s| {
            const input = self.objects.get(s.input_image);
            const filesystem_obj = switch (input.data) {
                .filesystem => |f| f,
                inline else => |_, t| @panic("Do not know how to run shader on " ++ @tagName(t)),
            };

            s.program.render(filesystem_obj.texture, transform);
        },
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

const Program = struct {
    program: gl.GLuint,
    transform_location: gl.GLint,
    vertex_buffer: gl.GLuint,
    vertex_array: gl.GLuint,

    fn init(vs: [:0]const u8, fs: [:0]const u8) !Program {
        const program = try compileLinkProgram(vs, fs);
        errdefer gl.glDeleteProgram(program);

        const vpos_location = gl.glGetAttribLocation(program, "vPos");
        const vuv_location = gl.glGetAttribLocation(program, "vUv");
        const transform_location = gl.glGetUniformLocation(program, "transform");

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
            .vertex_buffer = vertex_buffer,
            .vertex_array = vertex_array,
            .transform_location = transform_location,
        };
    }

    fn deinit(self: Program) void {
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
        gl.glDeleteProgram(self.program);
    }

    fn render(self: Program, texture: gl.GLuint, transform: Transform) void {
        gl.glUseProgram(self.program);
        gl.glBindVertexArray(self.vertex_array);
        gl.glUniformMatrix3fv(self.transform_location, 1, gl.GL_TRUE, &transform.data);

        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, texture);

        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
    }
};

fn getCompositionObj(self: *App) ?*CompositionObject {
    switch (self.objects.get(self.selected_object).data) {
        .composition => |*c| return c,
        else => return null,
    }
}

fn windowToClip(self: App, xpos: f32, ypos: f32) Vec2 {
    const window_width_f: f32 = @floatFromInt(self.window_width);
    const window_height_f: f32 = @floatFromInt(self.window_height);
    return .{
        ((xpos / window_width_f) - 0.5) * 2,
        (1.0 - (ypos / window_height_f) - 0.5) * 2,
    };
}

const vertices: []const f32 = &.{
    -1.0, -1.0, 0.0, 0.0,
    1.0,  -1.0, 1.0, 0.0,
    -1.0, 1.0,  0.0, 1.0,
    1.0,  1.0,  1.0, 1.0,
};

const vertex_shader_text =
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

pub const fragment_shader_text =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D u_texture;  // The texture
    \\void main()
    \\{
    \\    fragment = texture(u_texture, vec2(uv.x, 1.0 - uv.y));
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

pub fn makeTextureFromRgba(data: []const u8, width: usize) gl.GLuint {
    var texture: gl.GLuint = 0;

    // Generate the texture object
    gl.glGenTextures(1, &texture);
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture);

    // Set texture parameters (you can adjust these for your needs)
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT); // Wrap horizontally
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT); // Wrap vertically
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR); // Minification filter
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR); // Magnification filter

    const height = data.len / width / 4;
    // Upload the RGBA data to the texture
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(width), @intCast(height), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, data.ptr);

    // Generate mipmaps (optional, you can omit if you don't want them)
    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);

    return texture;
}

const StbImage = struct {
    data: []u8,
    width: usize,

    fn init(path: [:0]const u8) !StbImage {
        var width: c_int = 0;
        var height: c_int = 0;
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
    };

    fn deinit(self: *Object, alloc: Allocator) void {
        alloc.free(self.name);
        switch (self.data) {
            .filesystem => |*f| f.deinit(alloc),
            .composition => |*c| c.deinit(alloc),
            .shader => |*s| s.deinit(alloc),
        }
    }

    fn save(self: Object) SaveObject {
        const data: SaveObject.Data = switch (self.data) {
            .filesystem => |s| .{ .filesystem = s.source },
            .composition => |c| .{ .composition = c.objects.items },
            .shader => |c| .{ .shader = .{
                .input_image = c.input_image.value,
                .shader_source = c.shader_source,
            } },
        };

        return .{
            .name = self.name,
            .data = data,
        };
    }

    fn load(alloc: Allocator, save_obj: SaveObject) !Object {
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
                break :blk .{
                    .shader = try ShaderObject.init(alloc, .{ .value = s.input_image }, s.shader_source),
                };
            },
        };

        return .{
            .name = try alloc.dupe(u8, save_obj.name),
            .data = data,
        };
    }
};

pub const CompositionObject = struct {
    const ComposedObject = struct {
        id: ObjectId,
        transform: Transform,
    };

    objects: std.ArrayListUnmanaged(ComposedObject) = .{},
    selected_obj: ?usize = null,

    pub fn deinit(self: *CompositionObject, alloc: Allocator) void {
        self.objects.deinit(alloc);
    }
};

pub const ShaderObject = struct {
    input_image: ObjectId,
    shader_source: [:0]const u8,

    program: Program,

    pub fn init(alloc: Allocator, input_image: ObjectId, shader_source: [:0]const u8) !ShaderObject {
        const program = try Program.init(vertex_shader_text, shader_source);

        return .{
            .input_image = input_image,
            .shader_source = try alloc.dupeZ(u8, shader_source),
            .program = program,
        };
    }

    pub fn deinit(self: *ShaderObject, alloc: Allocator) void {
        self.program.deinit();
        alloc.free(self.shader_source);
    }
};

pub const FilesystemObject = struct {
    source: [:0]const u8,
    // FIXME: Aspect

    texture: gl.GLuint,

    pub fn load(alloc: Allocator, path: [:0]const u8) !FilesystemObject {
        const texture = try App.loadImageToTexture(path);
        return .{
            .texture = texture,
            .source = try alloc.dupeZ(u8, path),
        };
    }

    pub fn deinit(self: FilesystemObject, alloc: Allocator) void {
        gl.glDeleteTextures(1, &self.texture);
        alloc.free(self.source);
    }
};

const SaveObject = struct {
    name: []const u8,
    data: Data,

    const Data = union(enum) {
        filesystem: [:0]const u8,
        composition: []CompositionObject.ComposedObject,
        shader: struct {
            input_image: usize,
            shader_source: [:0]const u8,
        },
    };
};

const SaveData = struct {
    objects: []SaveObject,
};
