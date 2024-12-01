const std = @import("std");
const Allocator = std.mem.Allocator;
const lin = @import("lin.zig");
const gl = @import("gl.zig");
const Renderer = @import("Renderer.zig");
const obj_mod = @import("object.zig");
const StbImage = @import("StbImage.zig");
const coords = @import("coords.zig");
const dependency_loop = @import("dependency_loop.zig");
const shader_storage = @import("shader_storage.zig");

const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Objects = obj_mod.Objects;

const Vec2 = lin.Vec2;
const Vec3 = lin.Vec3;
const Transform = lin.Transform;
const PixelDims = obj_mod.PixelDims;

const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;

const App = @This();

alloc: Allocator,
objects: Objects = .{},
shaders: ShaderStorage(ShaderId),
brushes: ShaderStorage(BrushId),
renderer: Renderer,
view_state: ViewState,
input_state: InputState = .{},

mul_fragment_shader: ShaderId,

pub fn init(alloc: Allocator, window_width: usize, window_height: usize) !App {
    var objects = Objects{};
    errdefer objects.deinit(alloc);

    var renderer = try Renderer.init(alloc);
    errdefer renderer.deinit(alloc);

    var shaders = ShaderStorage(ShaderId){};
    errdefer shaders.deinit(alloc);

    const mul_fragment_shader_id = try shaders.addShader(alloc, "mask_mul", Renderer.mul_fragment_shader);

    var brushes = ShaderStorage(BrushId){};
    errdefer brushes.deinit(alloc);

    return .{
        .alloc = alloc,
        .objects = objects,
        .shaders = shaders,
        .brushes = brushes,
        .renderer = renderer,
        .view_state = .{
            .window_width = window_width,
            .window_height = window_height,
        },
        .mul_fragment_shader = mul_fragment_shader_id,
    };
}

pub fn deinit(self: *App) void {
    self.objects.deinit(self.alloc);
    self.renderer.deinit(self.alloc);
    self.shaders.deinit(self.alloc);
    self.brushes.deinit(self.alloc);
}

pub fn save(self: *App, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const object_saves = try self.objects.saveLeaky(arena_alloc);
    const shader_saves = try self.shaders.save(arena_alloc);
    const brush_saves = try self.brushes.save(arena_alloc);

    const out_f = try std.fs.cwd().createFile(path, .{});
    defer out_f.close();

    try std.json.stringify(
        SaveData{
            .objects = object_saves,
            .shaders = shader_saves,
            .brushes = brush_saves,
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

    var new_shaders = ShaderStorage(ShaderId){};
    // Note that shaders gets swapped in and is freed by this defer
    defer new_shaders.deinit(self.alloc);

    for (parsed.value.shaders) |saved_shader| {
        _ = try new_shaders.addShader(self.alloc, saved_shader.name, saved_shader.fs_source);
    }

    var new_brushes = ShaderStorage(BrushId){};
    // Note that shaders gets swapped in and is freed by this defer
    defer new_brushes.deinit(self.alloc);

    for (parsed.value.brushes) |saved_brush| {
        _ = try new_brushes.addShader(self.alloc, saved_brush.name, saved_brush.fs_source);
    }

    var new_objects = try Objects.load(self.alloc, parsed.value.objects, new_shaders, new_brushes, self.renderer.path_program);
    // Note that objects gets swapped in and is freed by this defer
    defer new_objects.deinit(self.alloc);

    // Swap objects so the old ones get deinited
    std.mem.swap(ShaderStorage(ShaderId), &new_shaders, &self.shaders);
    std.mem.swap(ShaderStorage(BrushId), &new_brushes, &self.brushes);
    std.mem.swap(Objects, &new_objects, &self.objects);
    errdefer {
        // If regeneration fails, we shouldn't accept the load
        std.mem.swap(ShaderStorage(ShaderId), &new_shaders, &self.shaders);
        std.mem.swap(ShaderStorage(BrushId), &new_brushes, &self.brushes);
        std.mem.swap(Objects, &new_objects, &self.objects);
    }

    // Loaded masks do not generate textures
    try self.regenerateAllMasks();
    // Loaded drawings do not generate distance fields
    try self.regenerateDistanceFields();

    var id_it = self.objects.idIter();
    if (id_it.next()) |id| {
        // Select the first object to create a sane initial input state
        self.input_state.selectObject(id, &self.objects);
    }
}

pub fn render(self: *App) !void {
    var frame_renderer = self.renderer.makeFrameRenderer(
        self.alloc,
        &self.objects,
        &self.shaders,
        &self.brushes,
    );
    defer frame_renderer.deinit();

    try frame_renderer.render(self.input_state.selected_object, self.view_state.objectToClipTransform(self.selectedDims()), self.view_state.window_width, self.view_state.window_height);
}

pub fn setKeyDown(self: *App, key: u8, ctrl: bool) !void {
    const action = self.input_state.setKeyDown(key, ctrl, &self.objects);
    try self.handleInputAction(action);
}

pub fn setMouseDown(self: *App) !void {
    const action = self.input_state.setMouseDown(&self.objects);
    try self.handleInputAction(action);
}

pub fn setMouseUp(self: *App) void {
    self.input_state.setMouseUp();
}

pub fn setMiddleDown(self: *App) void {
    self.input_state.setMiddleDown();
}

pub fn setMiddleUp(self: *App) void {
    self.input_state.setMiddleUp();
}

pub fn clickRightMouse(self: *App) !void {
    const input_action = self.input_state.clickRightMouse();
    try self.handleInputAction(input_action);
}

pub fn setSelectedObject(self: *App, id: ObjectId) void {
    self.input_state.selectObject(id, &self.objects);
    self.view_state.reset();
}

pub fn scroll(self: *App, amount: f32) void {
    self.view_state.zoom(amount);
}

pub fn setMousePos(self: *App, xpos: f32, ypos: f32) !void {
    const new_x = self.view_state.windowToClipX(xpos);
    const new_y = self.view_state.windowToClipY(ypos);
    const selected_dims = self.selectedDims();
    const new_pos = self.view_state.clipToObject(Vec2{ new_x, new_y }, selected_dims);
    const input_action = self.input_state.setMousePos(new_pos);

    try self.handleInputAction(input_action);
}

pub fn createPath(self: *App) !ObjectId {
    const initial_positions: []const Vec2 = &.{
        Vec2{ -0.5, -0.5 },
        Vec2{ 0.5, 0.5 },
    };

    const path_id = self.objects.nextId();
    const path_obj = try obj_mod.PathObject.init(
        self.alloc,
        initial_positions,
        self.input_state.selected_object,
        self.renderer.path_program.makeBuffer(),
    );
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new path"),
        .data = .{
            .path = path_obj,
        },
    });

    const selected_dims = self.objects.get(self.input_state.selected_object).dims(&self.objects);
    const mask_id = self.objects.nextId();
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new mask"),
        .data = .{
            .generated_mask = try obj_mod.GeneratedMaskObject.generate(self.alloc, path_id, selected_dims[0], selected_dims[1], path_obj.points.items),
        },
    });

    var shader_obj = try obj_mod.ShaderObject.init(self.alloc, self.mul_fragment_shader, self.shaders, 0);
    try shader_obj.setUniform(0, .{ .image = self.input_state.selected_object });
    try shader_obj.setUniform(1, .{ .image = mask_id });

    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "masked obj"),
        .data = .{
            .shader = shader_obj,
        },
    });

    return path_id;
}

pub fn updateSelectedObjectName(self: *App, name: []const u8) !void {
    const selected_object = self.selectedObject();
    try selected_object.updateName(self.alloc, name);
}

pub fn deleteSelectedObject(self: *App) !void {
    if (self.objects.isDependedUpon(self.input_state.selected_object)) {
        return error.DeletionCausesInvalidState;
    }

    var object_ids = self.objects.idIter();

    var prev: ?ObjectId = null;

    while (object_ids.next()) |id| {
        if (id.value == self.input_state.selected_object.value) {
            break;
        }
        prev = id;
    }

    const next: ?ObjectId = object_ids.next();

    self.objects.remove(self.alloc, self.input_state.selected_object);

    if (next) |v| {
        self.input_state.selectObject(v, &self.objects);
    } else if (prev) |v| {
        self.input_state.selectObject(v, &self.objects);
    }
}

pub fn updateSelectedDims(self: *App, dims: PixelDims) !void {
    const obj = self.selectedObject();
    switch (obj.data) {
        .composition => |*c| {
            c.dims = dims;
        },
        else => return error.CannotUpdateDims,
    }
}

pub fn addToComposition(self: *App, id: obj_mod.ObjectId) !obj_mod.CompositionIdx {
    const selected_object = self.objects.get(self.input_state.selected_object);

    if (selected_object.data != .composition) {
        return error.SelectedItemNotComposition;
    }

    const new_idx = try selected_object.data.composition.addObj(self.alloc, id);
    errdefer selected_object.data.composition.removeObj(new_idx);

    try dependency_loop.ensureNoDependencyLoops(self.alloc, self.input_state.selected_object, &self.objects);
    return new_idx;
}

pub fn deleteFromComposition(self: *App, id: obj_mod.CompositionIdx) !void {
    const selected_object = self.objects.get(self.input_state.selected_object);

    if (selected_object.data != .composition) {
        return error.SelectedItemNotComposition;
    }

    selected_object.data.composition.removeObj(id);
    // Force input state to release any references to a composition object
    self.input_state.setMouseUp();
}

pub fn addComposition(self: *App) !ObjectId {
    const id = self.objects.nextId();

    const name = try self.alloc.dupe(u8, "composition");
    errdefer self.alloc.free(name);

    try self.objects.append(self.alloc, .{
        .name = name,
        .data = .{ .composition = obj_mod.CompositionObject{} },
    });

    return id;
}

pub fn updatePathDisplayObj(self: *App, id: ObjectId) !void {
    const path_data = self.selectedObject().asPath() orelse return error.SelectedItemNotPath;
    const prev = path_data.display_object;

    path_data.display_object = id;
    errdefer path_data.display_object = prev;

    try dependency_loop.ensureNoDependencyLoops(self.alloc, self.input_state.selected_object, &self.objects);
}

pub fn setShaderDependency(self: *App, idx: usize, val: Renderer.UniformValue) !void {
    const shader_data = self.selectedObject().asShader() orelse return error.SelectedItemNotShader;
    if (idx >= shader_data.bindings.len) {
        return error.InvalidShaderIdx;
    }

    const prev_val = shader_data.bindings[idx];

    try shader_data.setUniform(idx, val);
    errdefer shader_data.bindings[idx] = prev_val;

    try dependency_loop.ensureNoDependencyLoops(self.alloc, self.input_state.selected_object, &self.objects);
}

pub fn setBrushDependency(self: *App, idx: usize, val: Renderer.UniformValue) !void {
    const drawing_data = self.selectedObject().asDrawing() orelse return error.SelectedItemNotDrawing;
    if (idx >= drawing_data.bindings.len) {
        return error.InvalidShaderIdx;
    }

    const prev_val = drawing_data.bindings[idx];

    try drawing_data.setUniform(idx, val);
    errdefer drawing_data.bindings[idx] = prev_val;

    try dependency_loop.ensureNoDependencyLoops(self.alloc, self.input_state.selected_object, &self.objects);
}

pub fn setDrawingObjectBrush(self: *App, id: BrushId) !void {
    const drawing_data = self.selectedObject().asDrawing() orelse return error.SelectedItemNotDrawing;
    try drawing_data.updateBrush(self.alloc, id, self.brushes);
}

pub fn addDrawing(self: *App) !ObjectId {
    const id = self.objects.nextId();

    const name = try self.alloc.dupe(u8, "drawing");
    errdefer self.alloc.free(name);

    var brush_iter = self.brushes.idIter();
    const first_brush = brush_iter.next() orelse return error.NoBrushes;
    try self.objects.append(self.alloc, .{
        .name = name,
        .data = .{ .drawing = try obj_mod.DrawingObject.init(
            self.alloc,
            self.input_state.selected_object,
            first_brush,
            self.brushes,
        ) },
    });

    return id;
}

pub fn setShaderPrimaryInput(self: *App, idx: usize) !void {
    const shader_data = self.selectedObject().asShader() orelse return error.SelectedItemNotShader;
    if (idx >= shader_data.bindings.len) {
        return error.InvalidShaderIdx;
    }

    shader_data.primary_input_idx = idx;
}

pub fn updateDrawingDisplayObj(self: *App, id: ObjectId) !void {
    const drawing_data = self.selectedObject().asDrawing() orelse return error.SelectedItemNotDrawing;
    const previous_id = drawing_data.display_object;
    drawing_data.display_object = id;
    errdefer drawing_data.display_object = previous_id;

    try dependency_loop.ensureNoDependencyLoops(self.alloc, self.input_state.selected_object, &self.objects);
}

pub fn loadImage(self: *App, path: [:0]const u8) !ObjectId {
    const id = self.objects.nextId();

    const obj = try obj_mod.FilesystemObject.load(self.alloc, path);
    errdefer obj.deinit(self.alloc);

    const name = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(name);

    try self.objects.append(self.alloc, .{
        .name = name,
        .data = .{
            .filesystem = obj,
        },
    });

    return id;
}

pub fn loadShader(self: *App, path: [:0]const u8) !ShaderId {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const fragment_source = try f.readToEndAllocOptions(self.alloc, 1 << 20, null, 4, 0);
    defer self.alloc.free(fragment_source);

    return self.addShaderFromFragmentSource(path, fragment_source);
}

pub fn loadBrush(self: *App, path: [:0]const u8) !BrushId {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const fragment_source = try f.readToEndAllocOptions(self.alloc, 1 << 20, null, 4, 0);
    defer self.alloc.free(fragment_source);

    return self.brushes.addShader(self.alloc, path, fragment_source);
}

pub fn addShaderFromFragmentSource(self: *App, name: []const u8, fs_source: [:0]const u8) !ShaderId {
    return try self.shaders.addShader(self.alloc, name, fs_source);
}

pub fn addBrushFromFragmnetSource(self: *App, name: []const u8, fs_source: [:0]const u8) !BrushId {
    return try self.brushes.addShader(self.alloc, name, fs_source);
}

pub fn addShaderObject(self: *App, name: []const u8, shader_id: ShaderId) !ObjectId {
    const object_id = self.objects.nextId();

    const duped_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(duped_name);

    var obj = try obj_mod.ShaderObject.init(
        self.alloc,
        shader_id,
        self.shaders,
        0,
    );
    errdefer obj.deinit(self.alloc);

    try self.objects.append(self.alloc, .{
        .name = duped_name,
        .data = .{
            .shader = obj,
        },
    });

    return object_id;
}

fn selectedObject(self: *App) *Object {
    return self.objects.get(self.input_state.selected_object);
}

fn selectedDims(self: *App) PixelDims {
    return self.objects.get(self.input_state.selected_object).dims(&self.objects);
}

const ViewState = struct {
    window_width: usize,
    window_height: usize,
    viewport_center: Vec2 = .{ 0.0, 0.0 },
    zoom_level: f32 = 1.0,

    fn reset(self: *ViewState) void {
        self.viewport_center = .{ 0.0, 0.0 };
        self.zoom_level = 1.0;
    }

    fn pan(self: *ViewState, movement_obj: Vec2) void {
        self.viewport_center -= movement_obj;
    }

    fn zoom(self: *ViewState, amount: f32) void {
        // Note that amount is in range [-N,N]
        // If we want the zoom adjustment to feel consistent, we need the
        // change from 4-8x to feel the same as the change from 1-2x
        // This means that a multiplicative level feels better than an additive one
        // So we need a function that goes from [-N,N] -> [lower than 1, greater than 1]
        // If we take this to the extreme, we want -inf -> 0, inf -> inf, 1 ->
        // 0. x^y provides this.
        // x^y also has the nice property that x^y*x^z == x^(y+z), which
        // results in merged scroll events acting the same as multiple split
        // events
        // Constant tuned until whatever scroll value we were getting felt ok
        //
        //
        // 1.1^(x+y) == 1.1^x * 1.1^y
        self.zoom_level *= std.math.pow(f32, 1.1, amount);
    }

    fn windowToClipX(self: ViewState, xpos: f32) f32 {
        const window_width_f: f32 = @floatFromInt(self.window_width);
        return ((xpos / window_width_f) - 0.5) * 2;
    }

    fn windowToClipY(self: ViewState, ypos: f32) f32 {
        const window_height_f: f32 = @floatFromInt(self.window_height);
        return (1.0 - (ypos / window_height_f) - 0.5) * 2;
    }

    fn clipToObject(self: *ViewState, val: Vec2, object_dims: PixelDims) Vec2 {
        const transform = self.objectToClipTransform(object_dims).invert();
        return lin.applyHomogenous(transform.apply(Vec3{ val[0], val[1], 1.0 }));
    }

    fn objectToClipTransform(self: ViewState, object_dims: PixelDims) Transform {
        const aspect_transform = coords.aspectRatioCorrectedFill(
            object_dims[0],
            object_dims[1],
            self.window_width,
            self.window_height,
        );

        return Transform.translate(-self.viewport_center[0], -self.viewport_center[1])
            .then(Transform.scale(self.zoom_level, self.zoom_level))
            .then(aspect_transform);
    }

    test "test aspect no zoom/pan" {
        const view_state = ViewState{
            .window_width = 100,
            .window_height = 50,
            .viewport_center = .{ 0.0, 0.0 },
            .zoom_level = 1.0,
        };

        const transform = view_state.objectToClipTransform(.{ 50, 100 });
        // Given an object that's 50x100, in a window 100x50
        //
        //  ______________________
        // |       |      |       |
        // |       | o  o |       |
        // |       | ____ |       |
        // |       |      |       |
        // |       |      |       |
        // |_______|______|_______|
        //
        // The object has coordinates of [-1, 1] in both dimensions, as does
        // the window
        //
        // This means that in window space, the object coordinates have be
        // squished, such that the aspect ratio of the object is preserved, and
        // the height stays the same

        const tl_obj = Vec3{ -1.0, 1.0, 1.0 };
        const br_obj = Vec3{ 1.0, -1.0, 1.0 };

        const tl_obj_win = lin.applyHomogenous(transform.apply(tl_obj));
        const br_obj_win = lin.applyHomogenous(transform.apply(br_obj));

        // Height is essentially preserved
        try std.testing.expectApproxEqAbs(1.0, tl_obj_win[1], 0.01);
        try std.testing.expectApproxEqAbs(-1.0, br_obj_win[1], 0.01);

        // Width needs to be scaled in such a way that the aspect ratio 50/100
        // is preserved in _pixel_ space. The window is stretched so that the
        // aspect is 2:1. In a non stretched window, we would expect that
        // 50/100 maps to N/2, so the width of 1/2 needs to be halfed _again_
        // to stay correct in the stretched window
        //
        // New width is then 0.5
        try std.testing.expectApproxEqAbs(-0.25, tl_obj_win[0], 0.01);
        try std.testing.expectApproxEqAbs(0.25, br_obj_win[0], 0.01);
    }

    test "test aspect with zoom/pan" {
        // Similar to the above test case, but with the viewport moved
        const view_state = ViewState{
            .window_width = 100,
            .window_height = 50,
            .viewport_center = .{ 0.5, 0.5 },
            .zoom_level = 2.0,
        };

        const transform = view_state.objectToClipTransform(.{ 50, 100 });

        const tl_obj = Vec3{ -1.0, 1.0, 1.0 };
        const br_obj = Vec3{ 1.0, -1.0, 1.0 };

        const tl_obj_win = lin.applyHomogenous(transform.apply(tl_obj));
        const br_obj_win = lin.applyHomogenous(transform.apply(br_obj));

        // Height should essentially be doubled in window space, because the
        // zoom is doubled. We are centered 0.5,0.5 up to the right, so a 2.0
        // height object should be 1.0 above us, and 3.0 below us
        try std.testing.expectApproxEqAbs(1.0, tl_obj_win[1], 0.01);
        try std.testing.expectApproxEqAbs(-3.0, br_obj_win[1], 0.01);

        // In unzoomed space, the answer was [-0.25, 0.25]. We are centered at
        // 0.5 in object space, with a 2x zoom. The 2x zoom gives moves the
        // total range to 1.0. We are centered 1/4 to the right, which means we
        // have 0.25 to the right, and 0.75 to the left
        try std.testing.expectApproxEqAbs(-0.75, tl_obj_win[0], 0.01);
        try std.testing.expectApproxEqAbs(0.25, br_obj_win[0], 0.01);
    }
};

// State required to adjust the transformation of a composed object according
// to some mouse movement
const TransformAdjustingInputState = struct {
    // Transform to go from composition space to the coordinate frame of the
    // composed object
    //
    // Confusing, but not the inverse of initial_transform. Note
    // that there are expectations about extra work done on the
    // stored transform to correct for aspect ratios of the
    // container and the object
    comp_to_object: Transform,
    // Object transform when adjustment started
    initial_transform: Transform,
    // Mouse position in composition space when adjustment started
    start_pos: lin.Vec2,
    // Which object is being modified
    idx: obj_mod.CompositionIdx,

    fn init(mouse_pos: Vec2, composition_id: ObjectId, comp_idx: obj_mod.CompositionIdx, objects: *Objects) TransformAdjustingInputState {
        const composition_obj = objects.get(composition_id);
        const composition_dims = composition_obj.dims(objects);
        const composition_aspect = coords.calcAspect(composition_dims[0], composition_dims[1]);

        const composition_data = if (composition_obj.asComposition()) |comp| comp else unreachable;

        const composed_obj = composition_data.objects.items[comp_idx.value];
        const composed_to_comp = composed_obj.composedToCompositionTransform(objects, composition_aspect);
        const initial_transform = composed_obj.transform;

        return .{
            .comp_to_object = composed_to_comp.invert(),
            .initial_transform = initial_transform,
            .idx = comp_idx,
            .start_pos = mouse_pos,
        };
    }
};

const InputState = struct {
    selected_object: ObjectId = .{ .value = 0 },
    // object coords
    mouse_pos: lin.Vec2 = .{ 0.0, 0.0 },
    panning: bool = false,
    data: union(enum) {
        composition: CompositionInputState,
        path: ?obj_mod.PathIdx,
        drawing: struct {
            mouse_down: bool,
        },
        none,
    } = .none,

    const CompositionInputPurpose = enum {
        move,
        rotation,
        scale,
        none,
    };

    const CompositionInputState = union(CompositionInputPurpose) {
        move: TransformAdjustingInputState,
        rotation: TransformAdjustingInputState,
        scale: TransformAdjustingInputState,
        none,
    };

    const InputAction = union(enum) {
        add_path_elem: Vec2,
        set_composition_transform: struct {
            idx: obj_mod.CompositionIdx,
            transform: Transform,
        },
        move_path_point: struct {
            idx: obj_mod.PathIdx,
            amount: Vec2,
        },
        add_draw_stroke: Vec2,
        add_stroke_sample: Vec2,
        save,
        pan: Vec2,
    };

    fn selectObject(self: *InputState, id: ObjectId, objects: *Objects) void {
        const obj = objects.get(id);
        switch (obj.data) {
            .composition => self.data = .{ .composition = .none },
            .path => self.data = .{ .path = null },
            .drawing => self.data = .{ .drawing = .{ .mouse_down = false } },
            else => self.data = .none,
        }
        self.selected_object = id;
    }

    // FIXME: Objects should be const
    fn setMouseDown(self: *InputState, objects: *obj_mod.Objects) ?InputAction {
        switch (self.data) {
            .composition => |*action| {
                action.* = self.makeCompositionInputState(objects, .move);
            },
            .path => |*selected_obj| {
                const path = objects.get(self.selected_object).asPath() orelse return null; // FIXME assert?
                var closest_point: usize = 0;
                var min_dist = std.math.inf(f32);

                for (path.points.items, 0..) |point, idx| {
                    const dist = lin.length2(self.mouse_pos - point);
                    if (dist < min_dist) {
                        closest_point = idx;
                        min_dist = dist;
                    }
                }

                if (min_dist != std.math.inf(f32)) {
                    selected_obj.* = .{ .value = closest_point };
                }
            },
            .drawing => |*d| {
                d.mouse_down = true;
                return .{
                    .add_draw_stroke = self.mouse_pos,
                };
            },
            .none => {},
        }
        return null;
    }

    fn setMouseUp(self: *InputState) void {
        switch (self.data) {
            .composition => |*action| action.* = .none,
            .path => |*selected_path_item| selected_path_item.* = null,
            .drawing => |*d| d.mouse_down = false,
            .none => {},
        }
    }

    fn setMousePos(self: *InputState, new_pos: Vec2) ?InputAction {
        var apply_mouse_pos = true;
        defer if (apply_mouse_pos) {
            self.mouse_pos = new_pos;
        };

        switch (self.data) {
            .composition => |*composition_state| {
                switch (composition_state.*) {
                    .move => |*params| {
                        const transformed_start = params.comp_to_object.apply(
                            Vec3{ params.start_pos[0], params.start_pos[1], 1.0 },
                        );
                        const transformed_end = params.comp_to_object.apply(Vec3{ new_pos[0], new_pos[1], 1.0 });
                        const movement = transformed_end - transformed_start;

                        return InputAction{
                            .set_composition_transform = .{
                                .idx = params.idx,
                                .transform = Transform.translate(movement[0], movement[1]).then(params.initial_transform),
                            },
                        };
                    },
                    .rotation => |*params| {
                        const transformed_start = params.comp_to_object.apply(
                            Vec3{ params.start_pos[0], params.start_pos[1], 1.0 },
                        );
                        const transformed_end = params.comp_to_object.apply(Vec3{ new_pos[0], new_pos[1], 1.0 });

                        const rotate = Transform.rotateAToB(
                            lin.applyHomogenous(transformed_start),
                            lin.applyHomogenous(transformed_end),
                        );

                        const translation_vec = lin.applyHomogenous(params.initial_transform.apply(Vec3{ 0, 0, 1.0 }));
                        const inv_translation = Transform.translate(-translation_vec[0], -translation_vec[1]);
                        const retranslate = Transform.translate(translation_vec[0], translation_vec[1]);

                        const transform = params.initial_transform
                            .then(inv_translation)
                            .then(rotate)
                            .then(retranslate);

                        return InputAction{
                            .set_composition_transform = .{
                                .idx = params.idx,
                                .transform = transform,
                            },
                        };
                    },
                    .scale => |*params| {
                        const transformed_start = params.comp_to_object.apply(
                            Vec3{ params.start_pos[0], params.start_pos[1], 1.0 },
                        );
                        const transformed_end = params.comp_to_object.apply(Vec3{ new_pos[0], new_pos[1], 1.0 });
                        const scale = lin.applyHomogenous(transformed_end) / lin.applyHomogenous(transformed_start);
                        return InputAction{
                            .set_composition_transform = .{
                                .idx = params.idx,
                                .transform = Transform.scale(scale[0], scale[1]).then(params.initial_transform),
                            },
                        };
                    },
                    .none => {},
                }
            },
            .path => |path_idx| {
                if (path_idx) |idx| {
                    return InputAction{ .move_path_point = .{
                        .idx = idx,
                        .amount = new_pos - self.mouse_pos,
                    } };
                }
            },
            .drawing => |*d| {
                if (d.mouse_down) {
                    return InputAction{ .add_stroke_sample = new_pos };
                }
            },
            else => {},
        }

        if (self.panning) {
            // A little odd, the camera movement is applied in object space,
            // because that's the coordinate space we store our mouse in. If we
            // apply a pan, the mouse SHOULD NOT MOVE in object space. Because
            // of this we ask that the viewport moves us around, but do not
            // update our internal cached position
            apply_mouse_pos = false;
            return .{
                .pan = new_pos - self.mouse_pos,
            };
        }

        return null;
    }

    fn clickRightMouse(self: *InputState) ?InputAction {
        switch (self.data) {
            .path => {
                return .{ .add_path_elem = self.mouse_pos };
            },
            .composition => |*c| {
                switch (c.*) {
                    .move, .rotation, .scale => |*params| {
                        defer c.* = .none;
                        return .{
                            .set_composition_transform = .{
                                .idx = params.idx,
                                .transform = params.initial_transform,
                            },
                        };
                    },
                    // FIXME: Cancel movement
                    else => {},
                }
                return .{ .add_path_elem = self.mouse_pos };
            },
            else => return null,
        }
    }

    fn setMiddleDown(self: *InputState) void {
        self.panning = true;
    }

    fn setMiddleUp(self: *InputState) void {
        self.panning = false;
    }

    // FIXME: Const objects probably
    fn setKeyDown(self: *InputState, key: u8, ctrl: bool, objects: *Objects) ?InputAction {
        switch (self.data) {
            .composition => |*c| {
                switch (key) {
                    'S' => c.* = self.makeCompositionInputState(objects, .scale),
                    'R' => c.* = self.makeCompositionInputState(objects, .rotation),
                    else => {},
                }
            },
            else => {},
        }

        if (key == 'S' and ctrl) {
            return .save;
        }

        return null;
    }

    fn makeCompositionInputState(self: InputState, objects: *Objects, comptime purpose: CompositionInputPurpose) CompositionInputState {
        const idx = self.findCompositionIdx(objects) orelse return .none;
        const state = TransformAdjustingInputState.init(self.mouse_pos, self.selected_object, idx, objects);
        return @unionInit(CompositionInputState, @tagName(purpose), state);
    }

    fn findCompositionIdx(self: InputState, objects: *Objects) ?obj_mod.CompositionIdx {
        const obj = objects.get(self.selected_object);
        const composition_obj = &obj.data.composition;
        var closest_idx: usize = 0;
        var current_dist = std.math.inf(f32);
        const composition_dims = obj.dims(objects);
        const composition_aspect = coords.calcAspect(composition_dims[0], composition_dims[1]);

        for (0..composition_obj.objects.items.len) |idx| {
            const transform = composition_obj.objects.items[idx].composedToCompositionTransform(objects, composition_aspect);
            const center = lin.applyHomogenous(transform.apply(Vec3{ 0, 0, 1 }));
            const dist = lin.length2(center - self.mouse_pos);
            if (dist < current_dist) {
                closest_idx = idx;
                current_dist = dist;
            }
        }

        if (current_dist == std.math.inf(f32)) {
            return null;
        } else {
            return .{ .value = closest_idx };
        }
    }
};

const MaskIterator = struct {
    it: Objects.IdIter,
    objects: *Objects,

    fn next(self: *MaskIterator) ?*obj_mod.GeneratedMaskObject {
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

fn handleInputAction(self: *App, action: ?InputState.InputAction) !void {
    switch (action orelse return) {
        .add_path_elem => |obj_loc| {
            const selected_object = self.selectedObject();
            if (selected_object.asPath()) |p| {
                try p.addPoint(self.alloc, obj_loc);
                try self.regeneratePathMasks(self.input_state.selected_object);
            }
        },
        .set_composition_transform => |movement| {
            const selected_object = self.selectedObject();
            if (selected_object.asComposition()) |composition| {
                composition.setTransform(movement.idx, movement.transform);
            }
        },
        .move_path_point => |movement| {
            const selected_object = self.selectedObject();
            if (selected_object.asPath()) |path| {
                path.movePoint(
                    movement.idx,
                    movement.amount,
                );
                try self.regeneratePathMasks(self.input_state.selected_object);
            }
        },
        .add_draw_stroke => |pos| {
            const selected_object = self.selectedObject();
            if (selected_object.asDrawing()) |d| {
                try d.addStroke(self.alloc, pos, &self.objects, self.renderer.distance_field_generator);
            }
        },
        .add_stroke_sample => |pos| {
            const selected_object = self.selectedObject();
            if (selected_object.asDrawing()) |d| {
                try d.addSample(self.alloc, pos, &self.objects, self.renderer.distance_field_generator);
            }
        },
        .save => {
            try self.save("save.json");
        },
        .pan => |amount| {
            self.view_state.pan(amount);
        },
    }
}

fn regenerateMask(self: *App, mask: *obj_mod.GeneratedMaskObject) !void {
    const path_obj = self.objects.get(mask.source);
    const path = switch (path_obj.data) {
        .path => |*p| p,
        else => return error.InvalidMaskObj,
    };

    const width, const height = path_obj.dims(&self.objects);
    var tmp = try obj_mod.GeneratedMaskObject.generate(self.alloc, mask.source, width, height, path.points.items);
    defer tmp.deinit();

    std.mem.swap(obj_mod.GeneratedMaskObject, mask, &tmp);
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

fn regenerateDistanceFields(self: *App) !void {
    var obj_it = self.objects.idIter();
    while (obj_it.next()) |obj_id| {
        const obj = self.objects.get(obj_id);
        const drawing_obj = obj.asDrawing() orelse continue;
        try drawing_obj.generateDistanceField(self.alloc, &self.objects, self.renderer.distance_field_generator);
    }
}

fn getCompositionObj(self: *App) ?*obj_mod.CompositionObject {
    switch (self.objects.get(self.input_state.selected_object).data) {
        .composition => |*c| return c,
        else => return null,
    }
}

pub const SaveData = struct {
    shaders: []shader_storage.Save,
    brushes: []shader_storage.Save,
    objects: []obj_mod.SaveObject,
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
