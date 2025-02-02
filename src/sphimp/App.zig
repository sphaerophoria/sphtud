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
const dependency_loop = @import("dependency_loop.zig");
const shader_storage = @import("shader_storage.zig");
const stbiw = @cImport({
    @cInclude("stb_image_write.h");
});
const sphrender = @import("sphrender");
const sphutil = @import("sphutil");
const memory_limits = @import("memory_limits.zig");
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
io_alloc: *Sphalloc,
io_thread: *IoThread,
io_thread_handle: std.Thread,

mul_fragment_shader: ShaderId,

const shader_alloc_name = "shaders";
const brush_alloc_name = "brushes";

pub fn init(alloc: RenderAlloc, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, window_width: usize, window_height: usize) !App {
    const objects = Objects.init(try alloc.makeSubAlloc("object storage"));

    const renderer = try Renderer.init(alloc.gl);

    var shaders = try ShaderStorage(ShaderId).init(
        try alloc.makeSubAlloc(shader_alloc_name),
    );

    const mul_fragment_shader_id = try shaders.addShader("mask_mul", Renderer.mul_fragment_shader, scratch_alloc);

    const brushes = try ShaderStorage(BrushId).init(
        try alloc.makeSubAlloc(brush_alloc_name),
    );

    const fonts = try FontStorage.init(try alloc.heap.makeSubAlloc("fonts"));

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
        _ = try loadFontIntoStorage(self.scratch.heap, p, &new_fonts);
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

pub fn render(self: *App) !void {
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

    try frame_renderer.render(self.input_state.selected_object, self.view_state.objectToClipTransform(self.selectedDims()));
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

    const action = try self.input_state.setMouseDown(&self.objects, &fr);
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
    const input_action = self.input_state.setMousePos(new_pos, &self.objects);

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

    const new_idx = try selected_object.data.composition.addObj(selected_object.alloc.heap.general(), id);
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
    try drawing_data.updateBrush(selected_object.alloc.heap.general(), id, self.brushes);
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
    const checkpoint = self.scratch.heap.checkpoint();
    defer self.scratch.heap.restore(checkpoint);

    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const fragment_source = try f.readToEndAllocOptions(self.scratch.heap.allocator(), 1 << 20, null, 4, 0);

    return self.addShaderFromFragmentSource(path, fragment_source);
}

pub fn loadBrush(self: *App, path: [:0]const u8) !BrushId {
    const checkpoint = self.scratch.heap.checkpoint();
    defer self.scratch.heap.restore(checkpoint);

    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const fragment_source = try f.readToEndAllocOptions(self.scratch.heap.allocator(), 1 << 20, null, 4, 0);

    return self.brushes.addShader(path, fragment_source, self.scratch.heap);
}

pub fn loadFont(self: *App, path: [:0]const u8) !FontStorage.FontId {
    return loadFontIntoStorage(self.scratch.heap, path, &self.fonts);
}

fn loadFontIntoStorage(scratch_alloc: *ScratchAlloc, path: []const u8, fonts: *FontStorage) !FontStorage.FontId {
    const checkpoint = scratch_alloc.checkpoint();
    defer scratch_alloc.restore(checkpoint);

    // readToEndAlloc uses an ArrayList under the hood. No go for our arena.
    // Instead read into scratch, then copy out
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const font_alloc = try fonts.alloc.makeSubAlloc(obj_mod.getAllocName(.text));
    errdefer font_alloc.deinit();

    const alloc = font_alloc.arena();

    const scratch_ttf_data = try f.readToEndAlloc(scratch_alloc.allocator(), 1 << 20);
    const ttf_data = try alloc.dupe(u8, scratch_ttf_data);

    const path_duped = try alloc.dupeZ(u8, path);
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
        return sphmath.applyHomogenous(transform.apply(Vec3{ val[0], val[1], 1.0 }));
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

        const tl_obj_win = sphmath.applyHomogenous(transform.apply(tl_obj));
        const br_obj_win = sphmath.applyHomogenous(transform.apply(br_obj));

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

        const tl_obj_win = sphmath.applyHomogenous(transform.apply(tl_obj));
        const br_obj_win = sphmath.applyHomogenous(transform.apply(br_obj));

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
    start_pos: sphmath.Vec2,
    // Which object is being modified
    idx: obj_mod.CompositionIdx,

    fn init(mouse_pos: Vec2, composition_id: ObjectId, comp_idx: obj_mod.CompositionIdx, objects: *Objects) TransformAdjustingInputState {
        const composition_obj = objects.get(composition_id);
        const composition_dims = composition_obj.dims(objects);
        const composition_aspect = sphmath.calcAspect(composition_dims[0], composition_dims[1]);

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
    mouse_pos: sphmath.Vec2 = .{ 0.0, 0.0 },
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
        export_image,
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
    fn setMouseDown(self: *InputState, objects: *obj_mod.Objects, frame_renderer: *Renderer.FrameRenderer) !?InputAction {
        switch (self.data) {
            .composition => |*action| {
                action.* = try self.makeCompositionInputState(objects, frame_renderer, .move);
            },
            .path => |*selected_obj| {
                const path = objects.get(self.selected_object).asPath() orelse return null; // FIXME assert?
                var closest_point: usize = 0;
                var min_dist = std.math.inf(f32);

                for (path.points.items, 0..) |point, idx| {
                    const dist = sphmath.length2(self.mouse_pos - point);
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

    fn setMousePos(self: *InputState, new_pos: Vec2, objects: *Objects) ?InputAction {
        var apply_mouse_pos = true;
        defer if (apply_mouse_pos) {
            self.mouse_pos = new_pos;
        };

        switch (self.data) {
            .composition => |*composition_state| {
                switch (composition_state.*) {
                    .move => |*params| {
                        const movement = new_pos - params.start_pos;

                        const dims = objects.get(self.selected_object).dims(objects);

                        // Initially it seems like a translation on the object
                        // transform makes sense, however due to some strange
                        // coordinate spaces it is not so simple
                        //
                        // Mouse coordinates are in the object space of the composition
                        // A composed object however works in an imaginary NxN
                        // square in the composition that gets aspect corrected
                        // at the end. This simplifies rotation logic that
                        // would otherwise be quite tricky.
                        //
                        // Unfortunately this means that we need to apply our
                        // translation such that after aspect ratio correction
                        // it will move the right amount

                        const aspect = sphmath.calcAspect(dims[0], dims[1]);
                        const scale: Vec2 = if (aspect > 1.0)
                            .{ aspect, 1.0 }
                        else
                            .{ 1.0, 1.0 / aspect };

                        const scaled_movement = movement * scale;

                        return InputAction{
                            .set_composition_transform = .{
                                .idx = params.idx,
                                .transform = params.initial_transform.then(Transform.translate(scaled_movement[0], scaled_movement[1])),
                            },
                        };
                    },
                    .rotation => |*params| {
                        const transformed_start = params.comp_to_object.apply(
                            Vec3{ params.start_pos[0], params.start_pos[1], 1.0 },
                        );
                        const transformed_end = params.comp_to_object.apply(Vec3{ new_pos[0], new_pos[1], 1.0 });

                        const rotate = Transform.rotateAToB(
                            sphmath.applyHomogenous(transformed_start),
                            sphmath.applyHomogenous(transformed_end),
                        );

                        const translation_vec = sphmath.applyHomogenous(params.initial_transform.apply(Vec3{ 0, 0, 1.0 }));
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
                        const scale = sphmath.applyHomogenous(transformed_end) / sphmath.applyHomogenous(transformed_start);
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
    fn setKeyDown(self: *InputState, key: u8, ctrl: bool, objects: *Objects, frame_renderer: *Renderer.FrameRenderer) !?InputAction {
        switch (self.data) {
            .composition => |*c| {
                switch (key) {
                    's' => c.* = try self.makeCompositionInputState(objects, frame_renderer, .scale),
                    'r' => c.* = try self.makeCompositionInputState(objects, frame_renderer, .rotation),
                    else => {},
                }
            },
            else => {},
        }

        if (key == 's' and ctrl) {
            return .save;
        }

        if (key == 'e' and ctrl) {
            return .export_image;
        }

        return null;
    }

    fn makeCompositionInputState(self: InputState, objects: *Objects, frame_renderer: *Renderer.FrameRenderer, comptime purpose: CompositionInputPurpose) !CompositionInputState {
        const idx = try self.findCompositionIdx(objects, frame_renderer) orelse return .none;
        const state = TransformAdjustingInputState.init(self.mouse_pos, self.selected_object, idx, objects);
        return @unionInit(CompositionInputState, @tagName(purpose), state);
    }

    fn findCompositionIdx(self: InputState, objects: *Objects, frame_renderer: *Renderer.FrameRenderer) !?obj_mod.CompositionIdx {
        const obj = objects.get(self.selected_object);

        const tex = try frame_renderer.renderCompositionIdMask(obj.*, 1, self.mouse_pos);

        const composition_idx = try tex.sample(u32, 0, 0);

        if (composition_idx == std.math.maxInt(u32)) {
            return null;
        }

        return .{ .value = composition_idx };
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
                try p.addPoint(selected_object.alloc.heap.general(), obj_loc);
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
                try d.addStroke(selected_object.alloc.heap.general(), self.scratch.heap, self.scratch.gl, pos, &self.objects, self.renderer.distance_field_generator);
            }
        },
        .add_stroke_sample => |pos| {
            const selected_object = self.selectedObject();
            if (selected_object.asDrawing()) |d| {
                try d.addSample(selected_object.alloc.heap.general(), self.scratch.heap, self.scratch.gl, pos, &self.objects, self.renderer.distance_field_generator);
            }
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

test {
    std.testing.refAllDeclsRecursive(@This());
}
