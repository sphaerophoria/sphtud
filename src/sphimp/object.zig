const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const Renderer = @import("Renderer.zig");
const StbImage = @import("StbImage.zig");
const FontStorage = @import("FontStorage.zig");
const shader_storage = @import("shader_storage.zig");
const coords = @import("coords.zig");
const sphtext = @import("sphtext");
const GlyphAtlas = sphtext.GlyphAtlas;
const TextRenderer = sphtext.TextRenderer;
const ttf_mod = sphtext.ttf;
const sphrender = @import("sphrender");
const sphutil = @import("sphutil");
const RuntimeBoundedArray = sphutil.RuntimeBoundedArray;
const GlAlloc = sphrender.GlAlloc;
const RenderAlloc = sphrender.RenderAlloc;
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const memory_limits = @import("memory_limits.zig");

const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;

const Transform = sphmath.Transform;
const Vec3 = sphmath.Vec3;
const Vec2 = sphmath.Vec2;
pub const PixelDims = @Vector(2, usize);

pub fn getAllocName(comptime data_type: Object.DataType) []const u8 {
    return switch (data_type) {
        .filesystem => "fs_obj",
        .composition => "composition object",
        .shader => "shader object",
        .path => "path object",
        .generated_mask => "mask object",
        .drawing => "drawing object",
        .text => "text object",
    };
}

pub const Object = struct {
    name: []const u8,
    data: Data,
    alloc: RenderAlloc,

    pub const DataType = enum {
        filesystem,
        composition,
        shader,
        path,
        generated_mask,
        drawing,
        text,
    };

    pub const Data = union(enum) {
        filesystem: FilesystemObject,
        composition: CompositionObject,
        shader: ShaderObject,
        path: PathObject,
        generated_mask: GeneratedMaskObject,
        drawing: DrawingObject,
        text: TextObject,
    };

    pub fn deinit(self: *Object) void {
        self.alloc.deinit();
    }

    pub fn updateName(self: *Object, name: []const u8) !void {
        const gpa = self.alloc.heap.general();
        const new_name = try gpa.dupe(u8, name);
        gpa.free(self.name);
        self.name = new_name;
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
            .text => |t| .{
                .text = .{
                    .font_id = t.font.value,
                    .current_text = t.current_text,
                },
            },
        };

        return .{
            .name = self.name,
            .id = id,
            .data = data,
        };
    }

    pub fn load(alloc: RenderAlloc, save_obj: SaveObject, shaders: ShaderStorage(ShaderId), brushes: ShaderStorage(BrushId), path_render_program: Renderer.PathRenderProgram) !Object {
        const data: Data = switch (save_obj.data) {
            .filesystem => |s| blk: {
                break :blk .{
                    .filesystem = try FilesystemObject.load(alloc.heap.arena(), alloc.gl, s),
                };
            },
            .composition => |c| blk: {
                var objects = std.ArrayListUnmanaged(CompositionObject.ComposedObject){};

                try objects.appendSlice(alloc.heap.general(), c);
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

                var shader_object = try ShaderObject.init(alloc.heap.general(), .{ .value = s.shader_id }, shaders, s.primary_input_idx);

                for (0..s.bindings.len) |idx| {
                    try shader_object.setUniform(idx, s.bindings[idx]);
                }
                break :blk .{ .shader = shader_object };
            },
            .path => |p| blk: {
                break :blk .{
                    .path = try PathObject.init(alloc.heap.general(), p.points, .{ .value = p.display_object }, try path_render_program.makeBuffer(alloc.gl)),
                };
            },
            .generated_mask => |source| .{
                .generated_mask = try GeneratedMaskObject.initEmptyTexture(.{ .value = source }, alloc.gl),
            },
            .drawing => |d| blk: {
                var drawing_object = try DrawingObject.init(
                    alloc.heap.general(),
                    alloc.gl,
                    .{ .value = d.display_object },
                    .{ .value = d.brush },
                    brushes,
                );

                for (0..d.bindings.len) |idx| {
                    try drawing_object.setUniform(idx, d.bindings[idx]);
                }

                for (d.strokes) |saved_stroke| {
                    var stroke = DrawingObject.Stroke{
                        .points = .{},
                    };

                    try stroke.points.appendSlice(alloc.heap.general(), saved_stroke);
                    try drawing_object.strokes.append(alloc.heap.general(), stroke);
                }

                break :blk .{
                    .drawing = drawing_object,
                };
            },
            .text => |t| blk: {
                var text_object = try TextObject.init(alloc.heap.general(), alloc.gl, .{ .value = t.font_id });

                text_object.current_text = try alloc.heap.general().dupe(u8, t.current_text);
                break :blk .{ .text = text_object };
            },
        };

        return .{
            .alloc = alloc,
            .name = try alloc.heap.general().dupe(u8, save_obj.name),
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
                const default_res = PixelDims{ 1024, 1024 };
                if (s.primary_input_idx >= s.bindings.len) return default_res;
                const primary_input = s.bindings[s.primary_input_idx];
                if (primary_input != .image) return default_res;
                if (primary_input.image == null) return default_res;
                const source = object_list.get(primary_input.image.?);

                return dims(source.*, object_list);
            },
            .composition => |c| {
                return c.dims;
            },
            .drawing => |d| {
                const display_object = object_list.get(d.display_object);
                return dims(display_object.*, object_list);
            },
            .text => |t| {
                return t.getSizePx();
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
                .text => {
                    return null;
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
            .text => true,
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

    pub fn asText(self: *Object) ?*TextObject {
        switch (self.data) {
            .text => |*t| return t,
            else => return null,
        }
    }

    pub fn shaderBindings(self: *Object) ?[]Renderer.UniformValue {
        switch (self.data) {
            .shader => |s| return s.bindings,
            .drawing => |d| return d.bindings,
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
    dims: PixelDims = .{ 1920, 1080 },
    debug_masks: bool = false,

    pub fn setTransform(self: *CompositionObject, idx: CompositionIdx, transform: Transform) void {
        const obj = &self.objects.items[idx.value];
        obj.transform = transform;
    }

    pub fn addObj(self: *CompositionObject, id: ObjectId) !CompositionIdx {
        const ret = self.objects.items.len;
        try self.objects.append(self.objectsAlloc(), .{
            .id = id,
            .transform = Transform.identity,
        });
        return .{ .value = ret };
    }

    pub fn removeObj(self: *CompositionObject, id: CompositionIdx) void {
        _ = self.objects.swapRemove(id.value);
    }

    fn objectsAlloc(self: *CompositionObject) Allocator {
        const data: *Object.Data = @alignCast(@fieldParentPtr("composition", self));
        const object: *Object = @fieldParentPtr("data", data);
        return object.alloc.heap.general();
    }
};

pub const ShaderObject = struct {
    primary_input_idx: usize,
    program: ShaderId,
    bindings: []Renderer.UniformValue,

    pub fn init(alloc: Allocator, id: ShaderId, shaders: ShaderStorage(ShaderId), primary_input_idx: usize) !ShaderObject {
        const shader = shaders.get(id);

        const bindings = try alloc.alloc(Renderer.UniformValue, shader.uniforms.items.len);

        for (shader.uniforms.items, 0..) |uniform, idx| {
            bindings[idx] = Renderer.UniformValue.fromDefault(uniform.default);
        }

        return .{
            .primary_input_idx = primary_input_idx,
            .program = id,
            .bindings = bindings,
        };
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

    pub fn load(alloc: Allocator, gl_alloc: *GlAlloc, path: [:0]const u8) !FilesystemObject {
        const image = try StbImage.init(path);
        defer image.deinit();

        const texture = try sphrender.makeTextureFromRgba(gl_alloc, image.data, image.width);

        const source = try alloc.dupeZ(u8, path);

        return .{
            .texture = texture,
            .width = image.width,
            .height = image.calcHeight(),
            .source = source,
        };
    }
};

pub const PathIdx = struct { value: usize };

pub const PathObject = struct {
    points: std.ArrayListUnmanaged(Vec2) = .{},
    display_object: ObjectId,

    render_buffer: Renderer.PathRenderBuffer,

    pub fn init(alloc: Allocator, initial_points: []const Vec2, display_object: ObjectId, render_buffer: Renderer.PathRenderBuffer) !PathObject {
        var points = try std.ArrayListUnmanaged(Vec2).initCapacity(alloc, initial_points.len);

        try points.appendSlice(alloc, initial_points);

        render_buffer.setData(points.items);

        return .{
            .points = points,
            .display_object = display_object,
            .render_buffer = render_buffer,
        };
    }

    pub fn addPoint(self: *PathObject, pos: Vec2) !void {
        try self.points.append(self.pointsAlloc(), pos);
        self.render_buffer.setData(self.points.items);
    }

    pub fn movePoint(self: *PathObject, idx: PathIdx, movement: Vec2) void {
        self.points.items[idx.value] += movement;
        self.render_buffer.updatePoint(idx.value, self.points.items[idx.value]);
    }

    fn pointsAlloc(self: *PathObject) Allocator {
        const data: *Object.Data = @alignCast(@fieldParentPtr("path", self));
        const object: *Object = @fieldParentPtr("data", data);
        return object.alloc.heap.general();
    }
};

pub const GeneratedMaskObject = struct {
    source: ObjectId,

    texture: Renderer.Texture,

    pub fn initEmptyTexture(source: ObjectId, gl_alloc: *GlAlloc) !GeneratedMaskObject {
        return .{
            .source = source,
            .texture = try sphrender.makeTextureCommon(gl_alloc),
        };
    }

    pub fn generate(scratch_alloc: *ScratchAlloc, gl_alloc: *GlAlloc, source: ObjectId, width: usize, height: usize, path_points: []const Vec2) !GeneratedMaskObject {
        const checkpoint = scratch_alloc.checkpoint();
        defer scratch_alloc.restore(checkpoint);

        const mask = try generateCpuMask(scratch_alloc, width, height, path_points);
        const texture = try sphrender.makeTextureFromR(gl_alloc, mask, width);

        return .{
            .texture = texture,
            .source = source,
        };
    }

    pub fn regenerate(self: *GeneratedMaskObject, scratch_alloc: *ScratchAlloc, width: usize, height: usize, path_points: []const Vec2) !void {
        const checkpoint = scratch_alloc.checkpoint();
        defer scratch_alloc.restore(checkpoint);

        std.debug.assert(self.texture.inner != Renderer.Texture.invalid.inner);

        const mask = try generateCpuMask(scratch_alloc, width, height, path_points);
        sphrender.setTextureFromR(self.texture, mask, width);
    }

    fn generateCpuMask(scratch_alloc: *ScratchAlloc, width: usize, height: usize, path_points: []const Vec2) ![]const u8 {
        const mask = try scratch_alloc.allocator().alloc(u8, width * height);
        @memset(mask, 0);

        const checkpoint = scratch_alloc.checkpoint();
        defer scratch_alloc.restore(checkpoint);

        const bb = findBoundingBox(path_points, width, height);
        const width_i64: i64 = @intCast(width);

        for (bb.y_start..bb.y_end) |y| {
            scratch_alloc.restore(checkpoint);
            const intersection_points = try findIntersectionPoints(scratch_alloc.allocator(), path_points, y, width, height);

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

        return mask;
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

            if (@abs(a[1] - b[1]) < 1e-7) {
                continue;
            }

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
};

const DrawingIndex = struct {
    stroke_id: usize,
    point_id: usize,
};

pub const DrawingObject = struct {
    pub const Stroke = struct {
        points: std.ArrayListUnmanaged(Vec2) = .{},

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
    distance_field: Renderer.Texture,

    pub const Save = struct {
        display_object: usize,
        strokes: [][]const Vec2,
        brush: usize,
        bindings: []Renderer.UniformValue,
    };

    pub fn init(alloc: Allocator, gl_alloc: *GlAlloc, display_object: ObjectId, brush_id: BrushId, brushes: ShaderStorage(BrushId)) !DrawingObject {
        const brush = brushes.get(brush_id);
        const uniforms = brush.uniforms.items;
        const bindings = try alloc.alloc(Renderer.UniformValue, uniforms.len);

        for (0..bindings.len) |i| {
            bindings[i] = Renderer.UniformValue.fromDefault(uniforms[i].default);
        }
        return .{
            .display_object = display_object,
            .brush = brush_id,
            .bindings = bindings,
            .distance_field = try sphrender.makeTextureCommon(gl_alloc),
        };
    }

    fn strokeAlloc(self: *DrawingObject) Allocator {
        const data: *Object.Data = @alignCast(@fieldParentPtr("drawing", self));
        const object: *Object = @fieldParentPtr("data", data);
        return object.alloc.heap.general();
    }

    pub fn addStroke(
        self: *DrawingObject,
        scratch_alloc: *ScratchAlloc,
        scratch_gl: *GlAlloc,
        pos: Vec2,
        objects: *Objects,
        distance_field_renderer: sphrender.DistanceFieldGenerator,
    ) !void {
        try self.strokes.append(self.strokeAlloc(), Stroke{});
        try self.addSample(scratch_alloc, scratch_gl, pos, objects, distance_field_renderer);
    }

    pub fn addSample(
        self: *DrawingObject,
        scratch_alloc: *ScratchAlloc,
        scratch_gl: *GlAlloc,
        pos: Vec2,
        objects: *Objects,
        distance_field_renderer: sphrender.DistanceFieldGenerator,
    ) !void {
        const last_stroke = &self.strokes.items[self.strokes.items.len - 1];
        try last_stroke.addPoint(self.strokeAlloc(), pos);

        try self.generateDistanceField(scratch_alloc, scratch_gl, objects, distance_field_renderer);
    }

    pub fn removePointsWithinRange(
        self: *DrawingObject,
        scratch: *ScratchAlloc,
        scratch_gl: *GlAlloc,
        pos: Vec2,
        dist: f32,
        objects: *Objects,
        distance_field_renderer: sphrender.DistanceFieldGenerator,
    ) !void {
        defer self.clearEmptyStrokes();

        const dist2 = dist * dist;

        var total_num_elems: usize = 0;
        for (self.strokes.items) |s| {
            total_num_elems += s.points.items.len;
        }

        var to_remove = try sphutil.RuntimeSegmentedList(DrawingIndex).init(
            scratch.allocator(),
            scratch.allocator(),
            100,
            @max(100, total_num_elems),
        );

        var stroke_idx = self.strokes.items.len;
        while (stroke_idx > 0) {
            stroke_idx -= 1;

            const stroke = self.strokes.items[stroke_idx];
            var point_idx = stroke.points.items.len;
            while (point_idx > 0) {
                point_idx -= 1;

                const point = stroke.points.items[point_idx];
                if (sphmath.length2(pos - point) < dist2) {
                    try to_remove.append(.{
                        .stroke_id = stroke_idx,
                        .point_id = point_idx,
                    });
                }
            }
        }

        var it = to_remove.iter();
        while (it.next()) |elem| {
            try self.remove(elem.*);
        }

        try self.generateDistanceField(scratch, scratch_gl, objects, distance_field_renderer);
    }

    fn remove(self: *DrawingObject, id: DrawingIndex) !void {
        var stroke = &self.strokes.items[id.stroke_id];

        const right_point_id = id.point_id + 1;
        const right_half: []const @Vector(2, f32) =
            if (right_point_id < stroke.points.items.len)
            stroke.points.items[right_point_id..]
        else
            &.{};

        if (right_half.len > 0) {
            try self.strokes.append(self.strokeAlloc(), Stroke{});
            // reference may be invalidated
            stroke = &self.strokes.items[id.stroke_id];
            try self.strokes.items[self.strokes.items.len - 1].points.appendSlice(self.strokeAlloc(), right_half);
        }

        stroke.points.shrinkAndFree(self.strokeAlloc(), id.point_id);
    }

    fn clearEmptyStrokes(self: *DrawingObject) void {
        var idx = self.strokes.items.len;
        while (idx > 0) {
            idx -= 1;
            const stroke = self.strokes.items[idx];
            if (stroke.points.items.len == 0) {
                var removed = self.strokes.swapRemove(idx);
                removed.points.deinit(self.strokeAlloc());
            }
        }
    }

    pub fn generateDistanceField(
        self: *DrawingObject,
        scratch_alloc: *ScratchAlloc,
        scratch_gl: *GlAlloc,
        objects: *Objects,
        distance_field_renderer: sphrender.DistanceFieldGenerator,
    ) !void {
        var vertex_array_it = StrokeVertexArrayIt{ .strokes = self.strokes.items };

        const dims = objects.get(self.display_object).dims(objects);

        try distance_field_renderer.renderDistanceFieldToTexture(
            scratch_alloc,
            scratch_gl,
            &vertex_array_it,
            Renderer.Texture.invalid,
            @intCast(dims[0]),
            @intCast(dims[1]),
            self.distance_field,
        );
    }

    pub fn hasPoints(self: DrawingObject) bool {
        return self.strokes.items.len > 0;
    }

    pub fn setUniform(self: *DrawingObject, idx: usize, val: Renderer.UniformValue) !void {
        if (idx >= self.bindings.len) return error.InvalidBrushUniformIdx;
        self.bindings[idx] = val;
    }

    pub fn updateBrush(self: *DrawingObject, brush_id: BrushId, brushes: ShaderStorage(BrushId)) !void {
        const brush = brushes.get(brush_id);
        const uniforms = brush.uniforms;

        var bindings = try self.strokeAlloc().alloc(Renderer.UniformValue, uniforms.items.len);
        defer self.strokeAlloc().free(bindings);

        for (0..bindings.len) |i| {
            bindings[i] = Renderer.UniformValue.fromDefault(uniforms.items[i].default);
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
};

pub const TextObject = struct {
    font: FontStorage.FontId,
    current_text: []const u8,

    renderer: TextRenderer,
    width: usize,
    height: usize,
    buffer: TextRenderer.Buffer,

    const null_width = 100;
    const null_height = 100;
    const default_point_size = 64.0;

    pub fn init(gpa: Allocator, gl_alloc: *GlAlloc, font_id: FontStorage.FontId) !TextObject {
        const renderer = try TextRenderer.init(gpa, gl_alloc, default_point_size);

        const buffer = try renderer.program.makeFullScreenPlane(gl_alloc);
        return .{
            .font = font_id,
            .renderer = renderer,
            .buffer = buffer,
            .width = null_width,
            .height = null_height,
            .current_text = &.{},
        };
    }

    pub fn update(self: *TextObject, alloc: Allocator, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, text: []const u8, fonts: FontStorage, distance_field_renderer: sphrender.DistanceFieldGenerator) !void {
        const new_text = try alloc.dupe(u8, text);
        alloc.free(self.current_text);
        self.current_text = new_text;

        try self.regenerate(scratch_alloc, scratch_gl, fonts, distance_field_renderer);
    }

    pub fn updateFont(self: *TextObject, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, font_id: FontStorage.FontId, fonts: FontStorage, distance_field_renderer: sphrender.DistanceFieldGenerator) !void {
        self.font = font_id;
        try self.renderer.resetAtlas();
        try self.regenerate(scratch_alloc, scratch_gl, fonts, distance_field_renderer);
    }

    pub fn updateFontSize(self: *TextObject, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, size: f32, fonts: FontStorage, distance_field_renderer: sphrender.DistanceFieldGenerator) !void {
        self.renderer.point_size = size;
        try self.renderer.resetAtlas();
        try self.regenerate(scratch_alloc, scratch_gl, fonts, distance_field_renderer);
    }

    pub fn regenerate(self: *TextObject, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, fonts: FontStorage, distance_field_renderer: sphrender.DistanceFieldGenerator) !void {
        if (self.current_text.len < 1) {
            self.buffer.updateBuffer(&.{});
            self.width = null_width;
            self.height = null_height;
            return;
        }

        const ttf = &fonts.get(self.font).ttf;
        const layout = try self.renderer.layoutText(
            scratch_alloc.allocator(),
            self.current_text,
            ttf.*,
            std.math.maxInt(u31),
        );

        try self.renderer.updateTextBuffer(scratch_alloc, scratch_gl, layout, ttf.*, distance_field_renderer, &self.buffer);
        self.width = layout.width();
        self.height = layout.height();
    }

    fn getSizePx(self: TextObject) PixelDims {
        return .{
            self.width, self.height,
        };
    }
};

pub const SaveObject = struct {
    id: usize,
    name: []const u8,
    data: Data,

    const Data = union(Object.DataType) {
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
        text: struct {
            font_id: usize,
            current_text: []const u8,
        },
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

    alloc: sphrender.RenderAlloc,
    inner: ObjectStorage = .{},
    next_id: usize = 0,

    pub fn init(alloc: sphrender.RenderAlloc) Objects {
        return .{
            .alloc = alloc,
        };
    }

    pub fn load(alloc: sphrender.RenderAlloc, data: []SaveObject, shaders: ShaderStorage(ShaderId), brushes: ShaderStorage(BrushId), path_render_program: Renderer.PathRenderProgram) !Objects {
        var objects = ObjectStorage{};

        const gpa = alloc.heap.general();

        try objects.ensureTotalCapacity(gpa, @intCast(data.len));

        var max_id: usize = 0;
        for (data) |saved_object| {
            const obj_alloc = switch (saved_object.data) {
                inline else => |_, t| try alloc.makeSubAlloc(getAllocName(t)),
            };
            const object = try Object.load(obj_alloc, saved_object, shaders, brushes, path_render_program);
            try objects.put(gpa, .{ .value = saved_object.id }, object);
            max_id = @max(max_id, saved_object.id);
        }

        return Objects{
            .alloc = alloc,
            .inner = objects,
            .next_id = max_id + 1,
        };
    }

    pub fn get(self: *Objects, id: ObjectId) *Object {
        return self.inner.getPtr(id) orelse @panic("Invalid object ID");
    }

    pub fn numItems(self: Objects) usize {
        return self.inner.count();
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

    pub fn remove(self: *Objects, id: ObjectId) void {
        var item = self.inner.fetchOrderedRemove(id) orelse return;
        item.value.deinit();
    }

    pub fn append(self: *Objects, object: Object) !void {
        const id = ObjectId{ .value = self.next_id };
        self.next_id += 1;
        try self.inner.put(self.alloc.heap.general(), id, object);
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
