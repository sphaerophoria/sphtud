const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const gl = @import("sphrender").gl;
const Renderer = @import("Renderer.zig");
const obj_mod = @import("object.zig");
const StbImage = @import("StbImage.zig");
const sphtext = @import("sphtext");
const ttf_mod = sphtext.ttf;
const FontStorage = @import("FontStorage.zig");
const coords = @import("coords.zig");
const tool = @import("tool.zig");
const ToolParams = tool.ToolParams;
const dependency_loop = @import("dependency_loop.zig");
const shader_storage = @import("shader_storage.zig");
const stbiw = @cImport({
    @cInclude("stb_image_write.h");
});
const sphrender = @import("sphrender");
const sphutil = @import("sphutil");
const memory_limits = @import("memory_limits.zig");
const InputState = @import("InputState.zig");
const ViewState = @import("ViewState.zig");
const RuntimeBoundedArray = sphutil.RuntimeBoundedArray;
const RenderAlloc = sphrender.RenderAlloc;
const GlAlloc = sphrender.GlAlloc;
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const Sphalloc = sphalloc.Sphalloc;

const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Objects = obj_mod.Objects;

const Vec2 = sphmath.Vec2;
const Vec3 = sphmath.Vec3;
const Transform = sphmath.Transform;
const PixelDims = obj_mod.PixelDims;

const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;

const App = @This();

alloc: RenderAlloc,
scratch: Scratch,
objects: Objects,
shaders: ShaderStorage(ShaderId),
brushes: ShaderStorage(BrushId),
fonts: FontStorage,
renderer: Renderer,
view_state: ViewState,
input_state: InputState = .{},
tool_params: ToolParams = .{},
io_alloc: *Sphalloc,
io_thread: *IoThread,
io_thread_handle: std.Thread,

mul_fragment_shader: ShaderId,

const shader_alloc_name = "shaders";
const brush_alloc_name = "brushes";

pub fn init(alloc: RenderAlloc, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, exe_path: []const u8, window_width: usize, window_height: usize) !App {
    const objects = Objects.init(try alloc.makeSubAlloc("object storage"));

    const renderer = try Renderer.init(alloc.gl);

    const resource_paths = try ResourcePaths.init(scratch_alloc.allocator(), exe_path);

    var shaders = try ShaderStorage(ShaderId).init(
        try alloc.makeSubAlloc(shader_alloc_name),
    );
    try populateDefaultShaders(scratch_alloc, &shaders, resource_paths.shaders);

    const mul_fragment_shader_id = try shaders.addShader("mask_mul", Renderer.mul_fragment_shader, scratch_alloc);

    var brushes = try ShaderStorage(BrushId).init(
        try alloc.makeSubAlloc(brush_alloc_name),
    );
    try populateDefaultShaders(scratch_alloc, &brushes, resource_paths.brushes);

    var fonts = try FontStorage.init(try alloc.heap.makeSubAlloc("fonts"));
    try populateDefaultFonts(scratch_alloc, &fonts, resource_paths.fonts);

    const io_alloc = try alloc.heap.makeSubAlloc("io");

    const io_thread = try alloc.heap.arena().create(IoThread);
    io_thread.* = .{};

    const io_thread_handle = try std.Thread.spawn(.{}, IoThread.run, .{io_thread});
    errdefer {
        io_thread.shutdown();
        io_thread_handle.join();
    }

    return .{
        .alloc = alloc,
        .scratch = .{
            .heap = scratch_alloc,
            .gl = scratch_gl,
        },
        .objects = objects,
        .shaders = shaders,
        .brushes = brushes,
        .fonts = fonts,
        .renderer = renderer,
        .view_state = .{
            .window_width = window_width,
            .window_height = window_height,
        },
        .mul_fragment_shader = mul_fragment_shader_id,
        .io_alloc = io_alloc,
        .io_thread = io_thread,
        .io_thread_handle = io_thread_handle,
    };
}

pub fn deinit(self: *App) void {
    self.io_thread.shutdown();
    self.io_thread_handle.join();
}

pub fn save(self: *App, path: []const u8) !void {
    const checkpoint = self.scratch.heap.checkpoint();
    defer self.scratch.heap.restore(checkpoint);

    const alloc = self.scratch.heap.allocator();

    const object_saves = try self.objects.saveLeaky(alloc);
    const shader_saves = try self.shaders.save(alloc);
    const brush_saves = try self.brushes.save(alloc);
    const font_saves = try self.fonts.saveLeaky(alloc);

    const out_f = try std.fs.cwd().createFile(path, .{});
    defer out_f.close();

    try std.json.stringify(
        SaveData{
            .fonts = font_saves,
            .objects = object_saves,
            .shaders = shader_saves,
            .brushes = brush_saves,
        },
        .{ .whitespace = .indent_2 },
        out_f.writer(),
    );
}

pub fn exportImage(self: *App, path: [:0]const u8) !void {
    {
        self.io_thread.mutex.lock();
        defer self.io_thread.mutex.unlock();
        if (self.io_thread.protected.save_request != null) return;
    }

    const dims = self.selectedDims();

    // All allocations are freed in App.step() if the save request is complete.
    // This allows us to have an allocator that is only accessed from this
    // thread, but doesn't hold memory forever
    const alloc = self.io_alloc.arena();

    const checkpoint = self.scratch.checkpoint();
    defer self.scratch.restore(checkpoint);

    var fr = self.renderer.makeFrameRenderer(
        self.scratch.heap.allocator(),
        self.scratch.gl,
        &self.objects,
        &self.shaders,
        &self.brushes,
        self.input_state.mouse_pos,
    );

    const texture = try fr.renderObjectToTexture(self.selectedObject().*);

    const out_buf = try alloc.alloc(u8, dims[0] * dims[1] * 4);

    gl.glGetTextureImage(texture.inner, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, @intCast(out_buf.len), out_buf.ptr);

    const duped_path = try alloc.dupeZ(u8, path);

    self.io_thread.requestSave(.{
        .data = out_buf,
        .width = @intCast(dims[0]),
        .height = @intCast(dims[1]),
        .stride = @intCast(dims[0] * 4),
        .path = duped_path,
    });
}

pub fn step(self: *App) !void {
    self.io_thread.mutex.lock();
    defer self.io_thread.mutex.unlock();

    if (self.io_thread.protected.save_request) |req| {
        if (req.finished) {
            self.io_thread.protected.save_request = null;
            try self.io_alloc.reset();
        }
    }
}

pub fn load(self: *App, path: []const u8) !void {
    const in_f = try std.fs.cwd().openFile(path, .{});
    defer in_f.close();

    const checkpoint = self.scratch.checkpoint();
    defer self.scratch.restore(checkpoint);

    const scratch = self.scratch.heap.allocator();

    var json_reader = std.json.reader(scratch, in_f.reader());

    const parsed = try std.json.parseFromTokenSourceLeaky(SaveData, scratch, &json_reader, .{});

    var new_shaders = try ShaderStorage(ShaderId).init(
        try self.alloc.makeSubAlloc(shader_alloc_name),
    );
    // Note that shaders gets swapped in and is freed by this defer
    defer new_shaders.alloc.deinit();

    for (parsed.shaders) |saved_shader| {
        _ = try new_shaders.addShader(saved_shader.name, saved_shader.fs_source, self.scratch.heap);
    }

    var new_brushes = try ShaderStorage(BrushId).init(
        try self.alloc.makeSubAlloc(brush_alloc_name),
    );
    // Note that shaders gets swapped in and is freed by this defer
    defer new_brushes.alloc.deinit();

    for (parsed.brushes) |saved_brush| {
        _ = try new_brushes.addShader(saved_brush.name, saved_brush.fs_source, self.scratch.heap);
    }

    var new_fonts = try FontStorage.init(try self.alloc.heap.makeSubAlloc("fonts"));
    // Note that shaders gets swapped in and is freed by this defer
    defer new_fonts.alloc.deinit();

    for (parsed.fonts) |p| {
        _ = try loadFontIntoStorage(self.scratch.heap, std.fs.cwd(), p, &new_fonts);
    }

    var new_objects = try Objects.load(
        try self.alloc.makeSubAlloc("object storage"),
        parsed.objects,
        new_shaders,
        new_brushes,
        self.renderer.path_program,
    );
    // Note that objects gets swapped in and is freed by this defer
    defer new_objects.alloc.deinit();

    // Swap objects so the old ones get deinited
    std.mem.swap(ShaderStorage(ShaderId), &new_shaders, &self.shaders);
    std.mem.swap(ShaderStorage(BrushId), &new_brushes, &self.brushes);
    std.mem.swap(Objects, &new_objects, &self.objects);
    std.mem.swap(FontStorage, &new_fonts, &self.fonts);
    errdefer {
        // If regeneration fails, we shouldn't accept the load
        std.mem.swap(ShaderStorage(ShaderId), &new_shaders, &self.shaders);
        std.mem.swap(ShaderStorage(BrushId), &new_brushes, &self.brushes);
        std.mem.swap(Objects, &new_objects, &self.objects);
        std.mem.swap(FontStorage, &new_fonts, &self.fonts);
    }

    // Loaded masks do not generate textures
    try self.regenerateAllMasks();
    // Loaded drawings do not generate distance fields
    try self.regenerateDistanceFields();
    try self.regenerateAllTextObjects();

    var id_it = self.objects.idIter();
    if (id_it.next()) |id| {
        // Select the first object to create a sane initial input state
        self.input_state.selectObject(id, &self.objects);
    }
}

pub fn render(self: *App, now: std.time.Instant) !void {
    const checkpoint = self.scratch.checkpoint();
    defer self.scratch.restore(checkpoint);
    var frame_renderer = self.renderer.makeFrameRenderer(
        self.scratch.heap.allocator(),
        self.scratch.gl,
        &self.objects,
        &self.shaders,
        &self.brushes,
        self.input_state.mouse_pos,
    );

    const transform = self.view_state.objectToClipTransform(self.selectedDims());
    try frame_renderer.render(self.input_state.selected_object, transform);

    const ui_renderer = self.renderer.makeUiRenderer(self.tool_params, self.input_state.mouse_pos, now);
    ui_renderer.render(self.objects.get(self.input_state.selected_object).*, transform);
}

pub fn makeFrameRenderer(self: *App, alloc: RenderAlloc) Renderer.FrameRenderer {
    return self.renderer.makeFrameRenderer(
        alloc.heap.general(),
        alloc.gl,
        &self.objects,
        &self.shaders,
        &self.brushes,
        self.input_state.mouse_pos,
    );
}

pub fn setKeyDown(self: *App, key: u8, ctrl: bool) !void {
    const checkpoint = self.scratch.checkpoint();
    defer self.scratch.restore(checkpoint);

    var fr = self.renderer.makeFrameRenderer(self.scratch.heap.allocator(), self.scratch.gl, &self.objects, &self.shaders, &self.brushes, self.input_state.mouse_pos);

    const action = try self.input_state.setKeyDown(key, ctrl, &self.objects, &fr);
    try self.handleInputAction(action);
}

pub fn setMouseDown(self: *App) !void {
    var fr = self.renderer.makeFrameRenderer(self.scratch.heap.allocator(), self.scratch.gl, &self.objects, &self.shaders, &self.brushes, self.input_state.mouse_pos);

    const action = try self.input_state.setMouseDown(self.tool_params, &self.objects, &fr);
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

pub fn setRightDown(self: *App) !void {
    const input_action = self.input_state.setRightDown();
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
    const input_action = self.input_state.setMousePos(self.tool_params, new_pos, &self.objects);

    try self.handleInputAction(input_action);
}

pub fn createPath(self: *App) !ObjectId {
    const initial_positions: []const Vec2 = &.{
        Vec2{ -0.5, -0.5 },
        Vec2{ 0.5, 0.5 },
    };

    const path_id = self.objects.nextId();
    {
        const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.path));
        errdefer obj_alloc.deinit();

        const path_obj = try obj_mod.PathObject.init(
            obj_alloc.heap.general(),
            initial_positions,
            self.input_state.selected_object,
            try self.renderer.path_program.makeBuffer(obj_alloc.gl),
        );

        try self.objects.append(.{
            .alloc = obj_alloc,
            .name = try obj_alloc.heap.general().dupe(u8, "new path"),
            .data = .{
                .path = path_obj,
            },
        });
    }

    const mask_id = self.objects.nextId();
    {
        const selected_dims = self.objects.get(self.input_state.selected_object).dims(&self.objects);

        const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.generated_mask));
        errdefer obj_alloc.deinit();

        const mask_obj = try obj_mod.GeneratedMaskObject.generate(
            self.scratch.heap,
            obj_alloc.gl,
            path_id,
            selected_dims[0],
            selected_dims[1],
            initial_positions,
        );

        try self.objects.append(.{
            .alloc = obj_alloc,
            .name = try obj_alloc.heap.general().dupe(u8, "new mask"),
            .data = .{
                .generated_mask = mask_obj,
            },
        });
    }

    {
        const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.shader));
        errdefer obj_alloc.deinit();

        var shader_obj = try obj_mod.ShaderObject.init(obj_alloc.heap.general(), self.mul_fragment_shader, self.shaders, 0);
        try shader_obj.setUniform(0, .{ .image = self.input_state.selected_object });
        try shader_obj.setUniform(1, .{ .image = mask_id });
        try self.objects.append(.{
            .alloc = obj_alloc,
            .name = try obj_alloc.heap.general().dupe(u8, "masked obj"),
            .data = .{
                .shader = shader_obj,
            },
        });
    }

    return path_id;
}

pub fn updateSelectedObjectName(self: *App, name: []const u8) !void {
    const selected_object = self.selectedObject();
    try selected_object.updateName(name);
}

pub fn updateTextObjectContent(self: *App, text: []const u8) !void {
    const selected_obj = self.selectedObject();
    const text_obj = selected_obj.asText() orelse return error.NotText;
    try text_obj.update(selected_obj.alloc.heap.general(), self.scratch.heap, self.scratch.gl, text, self.fonts, self.renderer.distance_field_generator);
}

pub fn updateFontId(self: *App, id: FontStorage.FontId) !void {
    const selected_obj = self.selectedObject();
    const text_obj = selected_obj.asText() orelse return error.NotText;
    try text_obj.updateFont(self.scratch.heap, self.scratch.gl, id, self.fonts, self.renderer.distance_field_generator);
}

pub fn updateFontSize(self: *App, requested_size: f32) !void {
    // NOTE: This feels like it should be done somewhere down the stack,
    // however this is an application level decision. Lower down elements
    // could probably handle smaller fonts, but we don't really think they
    // would look good, etc.
    //
    // We also don't error as UI will spam us with these requests. Heal and move on
    const size = @max(requested_size, 6.0);

    const selected_obj = self.selectedObject();
    const text_obj = selected_obj.asText() orelse return error.NotText;
    try text_obj.updateFontSize(self.scratch.heap, self.scratch.gl, size, self.fonts, self.renderer.distance_field_generator);
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

    self.objects.remove(self.input_state.selected_object);

    if (next) |v| {
        self.input_state.selectObject(v, &self.objects);
    } else if (prev) |v| {
        self.input_state.selectObject(v, &self.objects);
    }
}

pub fn updateSelectedWidth(self: *App, width: f32) !void {
    const obj = self.selectedObject();
    switch (obj.data) {
        .composition => |*c| {
            c.dims[0] = @intFromFloat(width);
        },
        else => return error.CannotUpdateDims,
    }
}

pub fn updateSelectedHeight(self: *App, height: f32) !void {
    const obj = self.selectedObject();
    switch (obj.data) {
        .composition => |*c| {
            c.dims[1] = @intFromFloat(height);
        },
        else => return error.CannotUpdateDims,
    }
}

pub fn addToComposition(self: *App, id: obj_mod.ObjectId) !obj_mod.CompositionIdx {
    const selected_object = self.objects.get(self.input_state.selected_object);

    if (selected_object.data != .composition) {
        return error.SelectedItemNotComposition;
    }

    const new_idx = try selected_object.data.composition.addObj(id);
    errdefer selected_object.data.composition.removeObj(new_idx);

    try dependency_loop.ensureNoDependencyLoops(self.scratch.heap.allocator(), self.input_state.selected_object, &self.objects);
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

pub fn toggleCompositionDebug(self: *App) !void {
    const composition = self.selectedObject().asComposition() orelse return error.NotComposition;
    composition.debug_masks = !composition.debug_masks;
}

pub fn addComposition(self: *App) !ObjectId {
    const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.composition));
    errdefer obj_alloc.deinit();

    const id = self.objects.nextId();
    try self.objects.append(.{
        .alloc = obj_alloc,
        .name = try obj_alloc.heap.general().dupe(u8, "composition"),
        .data = .{ .composition = obj_mod.CompositionObject{} },
    });

    return id;
}

pub fn updatePathDisplayObj(self: *App, id: ObjectId) !void {
    const path_data = self.selectedObject().asPath() orelse return error.SelectedItemNotPath;
    const prev = path_data.display_object;

    path_data.display_object = id;
    errdefer path_data.display_object = prev;

    try dependency_loop.ensureNoDependencyLoops(self.scratch.heap.allocator(), self.input_state.selected_object, &self.objects);
}

pub fn setShaderFloat(self: *App, uniform_idx: usize, float_idx: usize, val: f32) !void {
    const obj = self.selectedObject();
    const bindings = switch (obj.data) {
        .shader => |s| s.bindings,
        .drawing => |d| d.bindings,
        else => return error.NoShaderParams,
    };
    const uniform = &bindings[uniform_idx];
    switch (uniform.*) {
        .float => |*v| {
            v.* = val;
        },
        .float2 => |*v| {
            v[float_idx] = val;
        },
        .float3 => |*v| {
            v[float_idx] = val;
        },
        .image, .int, .uint, .mat3x3 => {},
    }
}

pub fn setShaderImage(self: *App, idx: usize, image: ObjectId) !void {
    const obj = self.selectedObject();
    const bindings = switch (obj.data) {
        .shader => |s| s.bindings,
        .drawing => |d| d.bindings,
        else => return error.NoShaderParams,
    };

    if (idx >= bindings.len) {
        return error.InvalidShaderIdx;
    }

    const prev_val = bindings[idx];
    bindings[idx] = .{ .image = image };
    errdefer bindings[idx] = prev_val;

    try dependency_loop.ensureNoDependencyLoops(self.scratch.heap.allocator(), self.input_state.selected_object, &self.objects);
}

pub fn setBrushDependency(self: *App, idx: usize, val: Renderer.UniformValue) !void {
    const drawing_data = self.selectedObject().asDrawing() orelse return error.SelectedItemNotDrawing;
    if (idx >= drawing_data.bindings.len) {
        return error.InvalidShaderIdx;
    }

    const prev_val = drawing_data.bindings[idx];

    try drawing_data.setUniform(idx, val);
    errdefer drawing_data.bindings[idx] = prev_val;

    try dependency_loop.ensureNoDependencyLoops(self.scratch.heap.allocator(), self.input_state.selected_object, &self.objects);
}

pub fn setDrawingObjectBrush(self: *App, id: BrushId) !void {
    const selected_object = self.selectedObject();
    const drawing_data = selected_object.asDrawing() orelse return error.SelectedItemNotDrawing;
    try drawing_data.updateBrush(id, self.brushes);
}

pub fn addDrawing(self: *App) !ObjectId {
    const id = self.objects.nextId();

    const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.drawing));
    errdefer obj_alloc.deinit();

    var brush_iter = self.brushes.idIter();
    const first_brush = brush_iter.next() orelse return error.NoBrushes;

    try self.objects.append(.{
        .alloc = obj_alloc,
        .name = try obj_alloc.heap.general().dupe(u8, "drawing"),
        .data = .{
            .drawing = try obj_mod.DrawingObject.init(
                obj_alloc.heap.general(),
                obj_alloc.gl,
                self.input_state.selected_object,
                first_brush,
                self.brushes,
            ),
        },
    });

    return id;
}

pub fn addText(self: *App) !ObjectId {
    const id = self.objects.nextId();

    const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.text));
    errdefer obj_alloc.deinit();

    var font_id_it = self.fonts.idIter();
    const font_id = font_id_it.next() orelse return error.NoFonts;

    try self.objects.append(.{
        .alloc = obj_alloc,
        .name = try obj_alloc.heap.general().dupe(u8, "text"),
        .data = .{
            .text = try obj_mod.TextObject.init(obj_alloc.heap.general(), obj_alloc.gl, font_id),
        },
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

    try dependency_loop.ensureNoDependencyLoops(self.scratch.heap.allocator(), self.input_state.selected_object, &self.objects);
}

pub fn loadImage(self: *App, path: [:0]const u8) !ObjectId {
    const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.filesystem));
    errdefer obj_alloc.deinit();

    const alloc = obj_alloc.heap.arena();

    const fs = try obj_mod.FilesystemObject.load(alloc, obj_alloc.gl, path);

    const id = self.objects.nextId();
    try self.objects.append(.{
        .alloc = obj_alloc,
        .name = try obj_alloc.heap.general().dupe(u8, path),
        .data = .{
            .filesystem = fs,
        },
    });

    return id;
}

pub fn loadShader(self: *App, path: [:0]const u8) !ShaderId {
    return try loadShaderImpl(self.scratch.heap, std.fs.cwd(), path, &self.shaders);
}

pub fn loadBrush(self: *App, path: [:0]const u8) !BrushId {
    return try loadShaderImpl(self.scratch.heap, std.fs.cwd(), path, &self.brushes);
}

pub fn loadFont(self: *App, path: [:0]const u8) !FontStorage.FontId {
    return loadFontIntoStorage(self.scratch.heap, std.fs.cwd(), path, &self.fonts);
}

fn loadFontIntoStorage(scratch_alloc: *ScratchAlloc, dir: std.fs.Dir, path: []const u8, fonts: *FontStorage) !FontStorage.FontId {
    const checkpoint = scratch_alloc.checkpoint();
    defer scratch_alloc.restore(checkpoint);

    // readToEndAlloc uses an ArrayList under the hood. No go for our arena.
    // Instead read into scratch, then copy out
    const f = try dir.openFile(path, .{});
    defer f.close();

    const font_alloc = try fonts.alloc.makeSubAlloc(obj_mod.getAllocName(.text));
    errdefer font_alloc.deinit();

    const alloc = font_alloc.arena();

    const scratch_ttf_data = try f.readToEndAlloc(scratch_alloc.allocator(), 1 << 20);
    const ttf_data = try alloc.dupe(u8, scratch_ttf_data);

    const path_duped = try dir.realpathAlloc(alloc, path);
    const ttf = try ttf_mod.Ttf.init(alloc, ttf_data);
    return try fonts.append(ttf_data, path_duped, ttf);
}

pub fn addShaderFromFragmentSource(self: *App, name: []const u8, fs_source: [:0]const u8) !ShaderId {
    return try self.shaders.addShader(name, fs_source, self.scratch.heap);
}

pub fn addBrushFromFragmnetSource(self: *App, name: []const u8, fs_source: [:0]const u8) !BrushId {
    return try self.brushes.addShader(name, fs_source, self.scratch.heap);
}

pub fn addShaderObject(self: *App, name: []const u8, shader_id: ShaderId) !ObjectId {
    const obj_alloc = try self.objects.alloc.makeSubAlloc(obj_mod.getAllocName(.shader));
    errdefer obj_alloc.deinit();

    const shader_obj = try obj_mod.ShaderObject.init(
        obj_alloc.heap.general(),
        shader_id,
        self.shaders,
        0,
    );

    const object_id = self.objects.nextId();
    try self.objects.append(.{
        .alloc = obj_alloc,
        .name = try obj_alloc.heap.general().dupe(u8, name),
        .data = .{
            .shader = shader_obj,
        },
    });
    return object_id;
}

pub fn selectedObjectId(self: App) ObjectId {
    return self.input_state.selected_object;
}

pub fn selectedObject(self: *App) *Object {
    return self.objects.get(self.input_state.selected_object);
}

pub fn selectedDims(self: *App) PixelDims {
    return self.objects.get(self.input_state.selected_object).dims(&self.objects);
}

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
                try p.addPoint(obj_loc);
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
                try d.addStroke(self.scratch.heap, self.scratch.gl, pos, &self.objects, self.renderer.distance_field_generator);
            }
        },
        .add_stroke_sample => |pos| {
            const selected_object = self.selectedObject();
            if (selected_object.asDrawing()) |d| {
                try d.addSample(self.scratch.heap, self.scratch.gl, pos, &self.objects, self.renderer.distance_field_generator);
            }
        },
        .remove_stroke_samples => |pos| {
            // FIXME: Error consistency the whole way down
            const selected_object = self.selectedObject();
            if (selected_object.asDrawing()) |d| {
                try d.removePointsWithinRange(
                    self.scratch.heap,
                    self.scratch.gl,
                    pos,
                    self.tool_params.eraser_width,
                    &self.objects,
                    self.renderer.distance_field_generator,
                );
            }
        },
        .set_drawing_tool => |t| {
            self.tool_params.active_drawing_tool = t;
        },
        .save => {
            try self.save("save.json");
        },
        .export_image => {
            try self.exportImage("image.png");
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
    try mask.regenerate(self.scratch.heap, width, height, path.points.items);
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
        try drawing_obj.generateDistanceField(self.scratch.heap, self.scratch.gl, &self.objects, self.renderer.distance_field_generator);
    }
}

fn regenerateAllTextObjects(self: *App) !void {
    var obj_it = self.objects.idIter();
    while (obj_it.next()) |obj_id| {
        const obj = self.objects.get(obj_id);
        const text_obj = obj.asText() orelse continue;
        try text_obj.regenerate(self.scratch.heap, self.scratch.gl, self.fonts, self.renderer.distance_field_generator);
    }
}

fn getCompositionObj(self: *App) ?*obj_mod.CompositionObject {
    switch (self.objects.get(self.input_state.selected_object).data) {
        .composition => |*c| return c,
        else => return null,
    }
}

pub const SaveData = struct {
    fonts: []FontStorage.Save,
    shaders: []shader_storage.Save,
    brushes: []shader_storage.Save,
    objects: []obj_mod.SaveObject,
};

const SaveRequest = struct {
    data: []const u8,
    width: c_int,
    height: c_int,
    stride: c_int,
    path: [:0]const u8,
    finished: bool = false,
};

const IoThread = struct {
    mutex: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    protected: Data = .{},

    const Data = struct {
        save_request: ?SaveRequest = null,
        shutdown: bool = false,

        fn needsAction(self: Data) bool {
            if (self.shutdown) {
                return true;
            }

            if (self.save_request) |req| {
                if (!req.finished) {
                    return true;
                }
            }

            return false;
        }
    };

    fn run(self: *IoThread) void {
        while (true) {
            const data = self.getData();
            if (data.shutdown) {
                break;
            }

            if (data.save_request) |*req| {
                stbiw.stbi_flip_vertically_on_write(1);
                _ = stbiw.stbi_write_png(
                    req.path.ptr,
                    req.width,
                    req.height,
                    4,
                    req.data.ptr,
                    req.stride,
                );

                self.mutex.lock();
                defer self.mutex.unlock();
                self.protected.save_request.?.finished = true;
            }
        }
    }

    fn shutdown(self: *IoThread) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.protected.shutdown = true;
        self.cv.signal();
    }

    fn requestSave(self: *IoThread, req: SaveRequest) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.protected.save_request == null);

        self.protected.save_request = req;
        self.cv.signal();
    }

    fn getData(self: *IoThread) Data {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.protected.needsAction()) {
                return self.protected;
            }
            self.cv.wait(&self.mutex);
        }
    }
};

const Scratch = struct {
    heap: *ScratchAlloc,
    gl: *GlAlloc,

    const Checkpoint = struct {
        heap: ScratchAlloc.Checkpoint,
        gl: GlAlloc.Checkpoint,
    };

    fn checkpoint(self: Scratch) Checkpoint {
        return .{
            .heap = self.heap.checkpoint(),
            .gl = self.gl.checkpoint(),
        };
    }

    fn restore(self: *Scratch, from: Checkpoint) void {
        self.heap.restore(from.heap);
        self.gl.restore(from.gl);
    }
};

const ResourcePaths = struct {
    brushes: []const u8,
    shaders: []const u8,
    fonts: []const u8,

    pub fn init(alloc: Allocator, argv0: []const u8) !App.ResourcePaths {
        const prefix = std.fs.path.dirname(std.fs.path.dirname(argv0).?).?;
        return .{
            .brushes = try std.fs.path.join(alloc, &.{ prefix, "share/sphimp/brushes" }),
            .shaders = try std.fs.path.join(alloc, &.{ prefix, "share/sphimp/shaders" }),
            .fonts = try std.fs.path.join(alloc, &.{ prefix, "share/sphimp/ttf" }),
        };
    }
};

fn populateDefaultShaders(scratch: *ScratchAlloc, shaders: anytype, path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();

    while (try it.next()) |entry| {
        _ = loadShaderImpl(scratch, dir, entry.name, shaders) catch |e| {
            std.log.err("Invalid shader at {s}: {s}", .{ path, @errorName(e) });
            continue;
        };
    }
}

fn StorageId(comptime Ptr: type) type {
    return @typeInfo(Ptr).Pointer.child.Id;
}

fn loadShaderImpl(scratch: *ScratchAlloc, dir: std.fs.Dir, path: []const u8, storage: anytype) !StorageId(@TypeOf(storage)) {
    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    const f = try dir.openFile(path, .{});
    defer f.close();

    const fragment_source = try f.readToEndAllocOptions(scratch.allocator(), 1 << 20, null, 4, 0);

    return try storage.addShader(path, fragment_source, scratch);
}

fn populateDefaultFonts(scratch: *ScratchAlloc, fonts: *FontStorage, path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();

    while (try it.next()) |entry| {
        _ = loadFontIntoStorage(scratch, dir, entry.name, fonts) catch |e| {
            std.log.err("Invalid font at {s}: {s}", .{ path, @errorName(e) });
            continue;
        };
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
