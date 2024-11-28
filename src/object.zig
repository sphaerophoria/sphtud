const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const lin = @import("lin.zig");
const Renderer = @import("Renderer.zig");
const StbImage = @import("StbImage.zig");
const shader_storage = @import("shader_storage.zig");
const coords = @import("coords.zig");

const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;

const Transform = lin.Transform;
const Vec3 = lin.Vec3;
const Vec2 = lin.Vec2;
pub const PixelDims = @Vector(2, usize);

pub const Object = struct {
    name: []u8,
    data: Data,

    pub const Data = union(enum) {
        filesystem: FilesystemObject,
        composition: CompositionObject,
        shader: ShaderObject,
        path: PathObject,
        generated_mask: GeneratedMaskObject,
        drawing: DrawingObject,
    };

    pub fn deinit(self: *Object, alloc: Allocator) void {
        alloc.free(self.name);
        switch (self.data) {
            .filesystem => |*f| f.deinit(alloc),
            .composition => |*c| c.deinit(alloc),
            .shader => |*s| s.deinit(alloc),
            .path => |*p| p.deinit(alloc),
            .generated_mask => |*g| g.deinit(),
            .drawing => |*d| d.deinit(alloc),
        }
    }

    pub fn updateName(self: *Object, alloc: Allocator, name: []const u8) !void {
        const duped_name = try alloc.dupe(u8, name);
        alloc.free(self.name);
        self.name = duped_name;
    }

    pub fn saveLeaky(self: Object, alloc: Allocator, id: usize) !SaveObject {
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
            .drawing => |d| .{
                .drawing = try d.saveLeaky(alloc),
            },
        };

        return .{
            .name = self.name,
            .id = id,
            .data = data,
        };
    }

    pub fn load(alloc: Allocator, save_obj: SaveObject, shaders: ShaderStorage(ShaderId), brushes: ShaderStorage(BrushId), path_render_program: Renderer.PathRenderProgram) !Object {
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

                var shader_object = try ShaderObject.init(alloc, .{ .value = s.shader_id }, shaders, s.primary_input_idx);
                errdefer shader_object.deinit(alloc);

                for (0..s.bindings.len) |idx| {
                    try shader_object.setUniform(idx, s.bindings[idx]);
                }
                break :blk .{ .shader = shader_object };
            },
            .path => |p| blk: {
                break :blk .{
                    .path = try PathObject.init(alloc, p.points, .{ .value = p.display_object }, path_render_program.makeBuffer()),
                };
            },
            .generated_mask => |source| .{
                .generated_mask = GeneratedMaskObject.initNullTexture(.{ .value = source }),
            },
            .drawing => |d| blk: {
                var drawing_object = try DrawingObject.init(
                    alloc,
                    .{ .value = d.display_object },
                    .{ .value = d.brush },
                    brushes,
                );
                errdefer drawing_object.deinit(alloc);

                for (0..d.bindings.len) |idx| {
                    try drawing_object.setUniform(idx, d.bindings[idx]);
                }

                for (d.strokes) |saved_stroke| {
                    var stroke = DrawingObject.Stroke{
                        .points = .{},
                    };
                    errdefer stroke.deinit(alloc);

                    try stroke.points.appendSlice(alloc, saved_stroke);
                    try drawing_object.strokes.append(alloc, stroke);
                }

                break :blk .{
                    .drawing = drawing_object,
                };
            },
        };

        return .{
            .name = try alloc.dupe(u8, save_obj.name),
            .data = data,
        };
    }

    pub fn dims(self: Object, object_list: *Objects) PixelDims {
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
                const primary_input = s.bindings[s.primary_input_idx];
                const default_res = PixelDims{ 1024, 1024 };
                if (primary_input != .image) return default_res;
                if (primary_input.image == null) return default_res;
                const source = object_list.get(primary_input.image.?);

                return dims(source.*, object_list);
            },
            .composition => {
                // FIXME: Customize composition size
                return .{ 1920, 1080 };
            },
            .drawing => |d| {
                const display_object = object_list.get(d.display_object);
                return dims(display_object.*, object_list);
            },
        }
    }

    const DependencyIt = struct {
        idx: usize = 0,
        object: Object,

        pub fn next(self: *DependencyIt) ?ObjectId {
            switch (self.object.data) {
                .filesystem => return null,
                .path => |*p| {
                    if (self.idx >= 1) {
                        return null;
                    }
                    defer self.idx += 1;
                    return p.display_object;
                },
                .shader => |*s| {
                    while (self.idx < s.bindings.len) {
                        defer self.idx += 1;

                        const binding = s.bindings[self.idx];
                        if (binding == .image and binding.image != null) {
                            return binding.image.?;
                        }
                    }

                    return null;
                },
                .composition => |*c| {
                    if (self.idx >= c.objects.items.len) {
                        return null;
                    }
                    defer self.idx += 1;
                    return c.objects.items[self.idx].id;
                },
                .generated_mask => |*m| {
                    if (self.idx > 0) {
                        return null;
                    }
                    defer self.idx += 1;
                    return m.source;
                },
                .drawing => |*d| {
                    if (self.idx >= 1) {
                        return null;
                    }
                    defer self.idx += 1;
                    return d.display_object;
                },
            }
        }
    };

    pub fn dependencies(self: Object) DependencyIt {
        return .{
            .object = self,
        };
    }

    pub fn isComposable(self: Object) bool {
        return switch (self.data) {
            .filesystem => true,
            .path => false,
            .generated_mask => true,
            .shader => true,
            .composition => true,
            .drawing => true,
        };
    }

    pub fn asPath(self: *Object) ?*PathObject {
        switch (self.data) {
            .path => |*p| return p,
            else => return null,
        }
    }

    pub fn asDrawing(self: *Object) ?*DrawingObject {
        switch (self.data) {
            .drawing => |*d| return d,
            else => return null,
        }
    }

    pub fn asComposition(self: *Object) ?*CompositionObject {
        switch (self.data) {
            .composition => |*c| return c,
            else => return null,
        }
    }

    pub fn asShader(self: *Object) ?*ShaderObject {
        switch (self.data) {
            .shader => |*s| return s,
            else => return null,
        }
    }
};

pub const CompositionIdx = struct {
    value: usize,
};

pub const CompositionObject = struct {
    const ComposedObject = struct {
        id: ObjectId,
        // Identity represents an aspect ratio corrected object that would fill
        // the composition if it were square. E.g. if the object is wide, it
        // scales until it fits horizontally in a 1:1 square, if it is tall it
        // scales to fit vertically. The actual composition will ensure that
        // this 1:1 square is fully visible, but may contain extra stuff
        // outside depending on the aspect ratio of the composition
        transform: Transform,

        pub fn composedToCompositionTransform(self: ComposedObject, objects: *Objects, composition_aspect: f32) Transform {
            const object = objects.get(self.id);
            const object_dims = object.dims(objects);

            // Put it in a square
            const obj_aspect_transform = coords.aspectRatioCorrectedFill(object_dims[0], object_dims[1], 1, 1);

            const composition_aspect_transform = if (composition_aspect > 1.0)
                Transform.scale(1.0 / composition_aspect, 1.0)
            else
                Transform.scale(1.0, composition_aspect);

            return obj_aspect_transform
                .then(self.transform)
                .then(composition_aspect_transform);
        }
    };

    objects: std.ArrayListUnmanaged(ComposedObject) = .{},

    pub fn setTransform(self: *CompositionObject, idx: CompositionIdx, transform: Transform) void {
        const obj = &self.objects.items[idx.value];
        obj.transform = transform;
    }

    pub fn addObj(self: *CompositionObject, alloc: Allocator, id: ObjectId) !CompositionIdx {
        const ret = self.objects.items.len;
        try self.objects.append(alloc, .{
            .id = id,
            .transform = Transform.identity,
        });
        return .{ .value = ret };
    }

    pub fn removeObj(self: *CompositionObject, id: CompositionIdx) void {
        _ = self.objects.swapRemove(id.value);
    }

    pub fn deinit(self: *CompositionObject, alloc: Allocator) void {
        self.objects.deinit(alloc);
    }
};

pub const ShaderObject = struct {
    primary_input_idx: usize,
    program: ShaderId,
    bindings: []Renderer.UniformValue,

    pub fn init(alloc: Allocator, id: ShaderId, shaders: ShaderStorage(ShaderId), primary_input_idx: usize) !ShaderObject {
        const program = shaders.get(id).program;

        const bindings = try alloc.alloc(Renderer.UniformValue, program.uniforms.len);
        errdefer alloc.free(bindings);

        for (program.uniforms, 0..) |uniform, idx| {
            bindings[idx] = uniform.default;
        }

        return .{
            .primary_input_idx = primary_input_idx,
            .program = id,
            .bindings = bindings,
        };
    }

    pub fn deinit(self: *ShaderObject, alloc: Allocator) void {
        alloc.free(self.bindings);
    }

    pub fn setUniform(self: *ShaderObject, idx: usize, val: Renderer.UniformValue) !void {
        if (idx >= self.bindings.len) {
            return error.InvalidShaderIndex;
        }
        // FIXME: ensure type match

        self.bindings[idx] = val;
    }

    pub fn save(self: ShaderObject) SaveObject.Data {
        comptime {
            std.debug.assert(@alignOf(ObjectId) == @alignOf(usize));
            std.debug.assert(@sizeOf(ObjectId) == @sizeOf(usize));
        }

        return .{
            .shader = .{
                .bindings = self.bindings,
                .shader_id = self.program.value,
                .primary_input_idx = self.primary_input_idx,
            },
        };
    }
};

pub const FilesystemObject = struct {
    source: [:0]const u8,
    width: usize,
    height: usize,

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

pub const PathIdx = struct { value: usize };

pub const PathObject = struct {
    points: std.ArrayListUnmanaged(Vec2) = .{},
    display_object: ObjectId,

    render_buffer: Renderer.PathRenderBuffer,

    pub fn init(alloc: Allocator, initial_points: []const Vec2, display_object: ObjectId, render_buffer: Renderer.PathRenderBuffer) !PathObject {
        errdefer render_buffer.deinit();

        var points = try std.ArrayListUnmanaged(Vec2).initCapacity(alloc, initial_points.len);
        errdefer points.deinit(alloc);

        try points.appendSlice(alloc, initial_points);

        render_buffer.setData(points.items);

        return .{
            .points = points,
            .display_object = display_object,
            .render_buffer = render_buffer,
        };
    }

    pub fn addPoint(self: *PathObject, alloc: Allocator, pos: Vec2) !void {
        try self.points.append(alloc, pos);
        self.render_buffer.setData(self.points.items);
    }

    pub fn movePoint(self: *PathObject, idx: PathIdx, movement: Vec2) void {
        self.points.items[idx.value] += movement;
        self.render_buffer.updatePoint(idx.value, self.points.items[idx.value]);
    }

    pub fn deinit(self: *PathObject, alloc: Allocator) void {
        self.points.deinit(alloc);
        self.render_buffer.deinit();
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

pub const DrawingObject = struct {
    pub const Stroke = struct {
        points: std.ArrayListUnmanaged(Vec2) = .{},

        fn deinit(self: *Stroke, alloc: Allocator) void {
            self.points.deinit(alloc);
        }

        fn addPoint(self: *Stroke, alloc: Allocator, point: Vec2) !void {
            try self.points.append(alloc, point);
        }
    };

    const StrokeVertexArrayIt = struct {
        inner_idx: usize = 0,
        idx: usize = 0,
        strokes: []Stroke,

        const Output = union(enum) {
            new_line: Vec2,
            line_point: Vec2,
        };

        pub fn next(self: *StrokeVertexArrayIt) ?Output {
            while (true) {
                if (self.idx >= self.strokes.len) {
                    return null;
                }

                if (self.inner_idx >= self.strokes[self.idx].points.items.len) {
                    self.idx += 1;
                    self.inner_idx = 0;
                    continue;
                }

                defer self.inner_idx += 1;
                const point = self.strokes[self.idx].points.items[self.inner_idx];
                if (self.inner_idx == 0) return .{
                    .new_line = point,
                } else return .{
                    .line_point = point,
                };
            }
        }
    };

    display_object: ObjectId,
    strokes: std.ArrayListUnmanaged(Stroke) = .{},

    brush: BrushId,
    bindings: []Renderer.UniformValue,
    distance_field: Renderer.Texture = Renderer.Texture.invalid,

    pub const Save = struct {
        display_object: usize,
        strokes: [][]const Vec2,
        brush: usize,
        bindings: []Renderer.UniformValue,
    };

    pub fn init(alloc: Allocator, display_object: ObjectId, brush_id: BrushId, brushes: ShaderStorage(BrushId)) !DrawingObject {
        const brush = brushes.get(brush_id);
        const uniforms = brush.program.uniforms;
        const bindings = try alloc.alloc(Renderer.UniformValue, uniforms.len);
        errdefer alloc.free(bindings);

        for (0..bindings.len) |i| {
            bindings[i] = uniforms[i].default;
        }
        return .{
            .display_object = display_object,
            .brush = brush_id,
            .bindings = bindings,
        };
    }

    pub fn addStroke(
        self: *DrawingObject,
        alloc: Allocator,
        pos: Vec2,
        objects: *Objects,
        distance_field_renderer: Renderer.DistanceFieldGenerator,
    ) !void {
        try self.strokes.append(alloc, Stroke{});
        try self.addSample(alloc, pos, objects, distance_field_renderer);
    }

    pub fn addSample(
        self: *DrawingObject,
        alloc: Allocator,
        pos: Vec2,
        objects: *Objects,
        distance_field_renderer: Renderer.DistanceFieldGenerator,
    ) !void {
        const last_stroke = &self.strokes.items[self.strokes.items.len - 1];
        try last_stroke.addPoint(alloc, pos);

        try self.generateDistanceField(alloc, objects, distance_field_renderer);
    }

    pub fn generateDistanceField(
        self: *DrawingObject,
        alloc: Allocator,
        objects: *Objects,
        distance_field_renderer: Renderer.DistanceFieldGenerator,
    ) !void {
        var vertex_array_it = StrokeVertexArrayIt{ .strokes = self.strokes.items };

        const dims = objects.get(self.display_object).dims(objects);

        const new_distance_field = try distance_field_renderer.generateDistanceField(
            alloc,
            &vertex_array_it,
            @intCast(dims[0]),
            @intCast(dims[1]),
        );

        self.distance_field.deinit();
        self.distance_field = new_distance_field;
    }

    pub fn hasPoints(self: DrawingObject) bool {
        return self.strokes.items.len > 0;
    }

    pub fn setUniform(self: *DrawingObject, idx: usize, val: Renderer.UniformValue) !void {
        if (idx >= self.bindings.len) return error.InvalidBrushUniformIdx;
        self.bindings[idx] = val;
    }

    pub fn updateBrush(self: *DrawingObject, alloc: Allocator, brush_id: BrushId, brushes: ShaderStorage(BrushId)) !void {
        const brush = brushes.get(brush_id);
        const uniforms = brush.program.uniforms;

        var bindings = try alloc.alloc(Renderer.UniformValue, uniforms.len);
        defer alloc.free(bindings);

        for (0..bindings.len) |i| {
            bindings[i] = uniforms[i].default;
        }
        self.brush = brush_id;
        std.mem.swap([]Renderer.UniformValue, &bindings, &self.bindings);
    }

    pub fn saveLeaky(self: DrawingObject, alloc: Allocator) !Save {
        const strokes = try alloc.alloc([]const Vec2, self.strokes.items.len);
        for (0..strokes.len) |i| {
            strokes[i] = self.strokes.items[i].points.items;
        }

        return .{
            .display_object = self.display_object.value,
            .strokes = strokes,
            .brush = self.brush.value,
            .bindings = self.bindings,
        };
    }

    fn deinit(self: *DrawingObject, alloc: Allocator) void {
        for (self.strokes.items) |*stroke| {
            stroke.deinit(alloc);
        }
        self.strokes.deinit(alloc);
        alloc.free(self.bindings);
    }
};

pub const SaveObject = struct {
    id: usize,
    name: []const u8,
    data: Data,

    const Data = union(enum) {
        filesystem: [:0]const u8,
        composition: []CompositionObject.ComposedObject,
        shader: struct {
            bindings: []Renderer.UniformValue,
            shader_id: usize,
            primary_input_idx: usize,
        },
        path: struct {
            points: []Vec2,
            display_object: usize,
        },
        generated_mask: usize,
        drawing: DrawingObject.Save,
    };
};

pub const ObjectId = struct {
    value: usize,
};

pub const Objects = struct {
    // FIXME: Maybe we just do hole tracking ourselves and us the object as the
    // index. Internal impl just linearly scans for matching hash anyways, so
    // why use it
    const ObjectStorage = std.AutoArrayHashMapUnmanaged(ObjectId, Object);
    inner: ObjectStorage = .{},
    next_id: usize = 0,

    pub fn load(alloc: Allocator, data: []SaveObject, shaders: ShaderStorage(ShaderId), brushes: ShaderStorage(BrushId), path_render_program: Renderer.PathRenderProgram) !Objects {
        var objects = ObjectStorage{};
        errdefer freeObjectList(alloc, &objects);

        try objects.ensureTotalCapacity(alloc, @intCast(data.len));

        var max_id: usize = 0;
        for (data) |saved_object| {
            const object = try Object.load(alloc, saved_object, shaders, brushes, path_render_program);
            try objects.put(alloc, .{ .value = saved_object.id }, object);
            max_id = @max(max_id, saved_object.id);
        }

        return Objects{
            .inner = objects,
            .next_id = max_id + 1,
        };
    }

    pub fn deinit(self: *Objects, alloc: Allocator) void {
        freeObjectList(alloc, &self.inner);
    }

    pub fn get(self: *Objects, id: ObjectId) *Object {
        return self.inner.getPtr(id) orelse @panic("Invalid object ID");
    }

    pub fn nextId(self: Objects) ObjectId {
        return .{ .value = self.next_id };
    }

    pub const IdIter = struct {
        it: []ObjectId,
        idx: usize = 0,

        pub fn next(self: *IdIter) ?ObjectId {
            if (self.idx >= self.it.len) return null;
            defer self.idx += 1;
            return self.it[self.idx];
        }
    };

    pub fn idIter(self: Objects) IdIter {
        return .{ .it = self.inner.keys() };
    }

    pub fn saveLeaky(self: Objects, alloc: Allocator) ![]SaveObject {
        const object_saves = try alloc.alloc(SaveObject, self.inner.count());
        errdefer alloc.free(object_saves);

        var it = self.inner.iterator();
        var i: usize = 0;
        while (it.next()) |item| {
            defer i += 1;
            object_saves[i] = try item.value_ptr.saveLeaky(alloc, item.key_ptr.value);
        }

        return object_saves;
    }

    pub fn remove(self: *Objects, alloc: Allocator, id: ObjectId) void {
        var item = self.inner.fetchOrderedRemove(id) orelse return;
        item.value.deinit(alloc);
    }

    pub fn append(self: *Objects, alloc: Allocator, object: Object) !void {
        const id = ObjectId{ .value = self.next_id };
        self.next_id += 1;
        try self.inner.put(alloc, id, object);
    }

    pub fn isDependedUpon(self: *Objects, id: ObjectId) bool {
        if (self.inner.count() == 1) {
            // App expects that there is always at least one object available
            return true;
        }

        var id_iter = self.idIter();
        while (id_iter.next()) |other_id| {
            if (other_id.value == id.value) continue;

            const other_obj = self.get(other_id);
            var deps = other_obj.dependencies();
            while (deps.next()) |dep_id| {
                if (dep_id.value == id.value) {
                    return true;
                }
            }
        }

        return false;
    }

    fn freeObjectList(alloc: Allocator, objects: *ObjectStorage) void {
        for (objects.values()) |*object| {
            object.deinit(alloc);
        }
        objects.deinit(alloc);
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
