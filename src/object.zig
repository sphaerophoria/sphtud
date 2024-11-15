const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const lin = @import("lin.zig");
const Renderer = @import("Renderer.zig");
const StbImage = @import("StbImage.zig");

const Transform = lin.Transform;
const Vec3 = lin.Vec3;
const Vec2 = lin.Vec2;

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

    pub fn deinit(self: *Object, alloc: Allocator) void {
        alloc.free(self.name);
        switch (self.data) {
            .filesystem => |*f| f.deinit(alloc),
            .composition => |*c| c.deinit(alloc),
            .shader => |*s| s.deinit(alloc),
            .path => |*p| p.deinit(alloc),
            .generated_mask => |*g| g.deinit(),
        }
    }

    pub fn save(self: Object) SaveObject {
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

    pub fn load(alloc: Allocator, save_obj: SaveObject, path_vpos_loc: gl.GLint) !Object {
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

    pub fn dims(self: Object, object_list: *Objects) struct { usize, usize } {
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

    pub fn selectClosestPoint(self: *CompositionObject, test_pos: Vec2) void {
        var closest_idx: usize = 0;
        var current_dist = std.math.inf(f32);

        for (0..self.objects.items.len) |idx| {
            const transform = self.objects.items[idx].transform;
            const center = lin.applyHomogenous(transform.mul(Vec3{ 0, 0, 1 }));
            const dist = lin.length2(center - test_pos);
            if (dist < current_dist) {
                closest_idx = idx;
                current_dist = dist;
            }
        }

        self.selected_obj = closest_idx;
    }

    pub fn moveObject(self: *CompositionObject, movement: Vec2) void {
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

    program: Renderer.PlaneRenderProgram,

    pub fn init(alloc: Allocator, input_images: []const ObjectId, shader_source: [:0]const u8, texture_names: []const [:0]const u8, width: usize, height: usize) !ShaderObject {
        const program = try Renderer.PlaneRenderProgram.init(alloc, Renderer.plane_vertex_shader, shader_source, texture_names);
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

    texture: Renderer.Texture,

    pub fn load(alloc: Allocator, path: [:0]const u8) !FilesystemObject {
        const image = try StbImage.init(path);
        defer image.deinit();

        const texture = Renderer.makeTextureFromRgba(image.data, image.width);
        errdefer texture.deinit();

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
        self.texture.deinit();
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

    pub fn selectClosestPoint(self: *PathObject, test_pos: Vec2) void {
        var closest_point: usize = 0;
        var min_dist = std.math.inf(f32);

        for (self.points.items, 0..) |point, idx| {
            const dist = lin.length2(test_pos - point);
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

    pub fn addPoint(self: *PathObject, alloc: Allocator, pos: Vec2) !void {
        try self.points.append(alloc, pos);
        setBufferData(self.vertex_buffer, self.points.items);
    }

    pub fn movePoint(self: *PathObject, movement: Vec2) void {
        const idx = if (self.selected_point) |idx| idx else return;

        self.points.items[idx] += movement;
        gl.glNamedBufferSubData(self.vertex_buffer, @intCast(idx * 8), 8, &self.points.items[idx]);
    }

    pub fn deinit(self: *PathObject, alloc: Allocator) void {
        self.points.deinit(alloc);
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
    }
};

pub const GeneratedMaskObject = struct {
    source: ObjectId,

    texture: Renderer.Texture,

    pub fn initNullTexture(source: ObjectId) GeneratedMaskObject {
        return .{
            .source = source,
            .texture = Renderer.Texture.invalid,
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

        const texture = Renderer.makeTextureFromR(mask, width);
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
        self.texture.deinit();
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

pub const SaveData = struct {
    objects: []SaveObject,
};

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

fn objectToPixelCoord(val: f32, max: usize) i64 {
    const max_f: f32 = @floatFromInt(max);
    return @intFromFloat(((val + 1) / 2) * max_f);
}

fn pixelToObjectCoord(val: usize, max: usize) f32 {
    const val_f: f32 = @floatFromInt(val);
    const max_f: f32 = @floatFromInt(max);
    return ((val_f / max_f) - 0.5) * 2;
}
