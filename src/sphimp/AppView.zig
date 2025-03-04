const std = @import("std");
const App = @import("App.zig");
const ViewState = @import("ViewState.zig");
const InputState = @import("InputState.zig");
const sphmath = @import("sphmath");
const Vec2 = sphmath.Vec2;
const obj_mod = @import("object.zig");
const ObjectId = obj_mod.ObjectId;
const Object = obj_mod.Object;
const PixelDims = obj_mod.PixelDims;

const AppView = @This();

app: *App,
view_state: ViewState = .{},
input_state: InputState = .{},

pub fn setKeyDown(self: *AppView, key: u8, ctrl: bool) !void {
    const scratch = &self.app.scratch;

    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    var fr = self.app.makeFrameRenderer(scratch.heap.allocator(), scratch.gl);

    const action = try self.input_state.setKeyDown(key, ctrl, &self.app.objects, &fr);
    try self.handleInputAction(action);
}

pub fn setMouseDown(self: *AppView) !void {
    const scratch = &self.app.scratch;
    var fr = self.app.makeFrameRenderer(scratch.heap.allocator(), scratch.gl);

    const action = try self.input_state.setMouseDown(self.app.tool_params, &self.app.objects, &fr);
    try self.handleInputAction(action);
}

pub fn setMouseUp(self: *AppView) void {
    self.input_state.setMouseUp();
}

pub fn setMiddleDown(self: *AppView) void {
    self.input_state.setMiddleDown();
}

pub fn setMiddleUp(self: *AppView) void {
    self.input_state.setMiddleUp();
}

pub fn setRightDown(self: *AppView) !void {
    const input_action = self.input_state.setRightDown();
    try self.handleInputAction(input_action);
}

pub fn setMousePos(self: *AppView, xpos: f32, ypos: f32) !void {
    const new_x = self.view_state.windowToClipX(xpos);
    const new_y = self.view_state.windowToClipY(ypos);
    const selected_dims = self.selectedDims();
    const new_pos = self.view_state.clipToObject(Vec2{ new_x, new_y }, selected_dims);
    const input_action = self.input_state.setMousePos(self.app.tool_params, new_pos, &self.app.objects);

    try self.handleInputAction(input_action);
}

pub fn handleInputAction(self: *AppView, action: ?InputState.InputAction) !void {
    const scratch = &self.app.scratch;
    switch (action orelse return) {
        .add_path_elem => |obj_loc| {
            try self.app.addPathPoint(self.input_state.selected_object, obj_loc);
        },
        .set_composition_transform => |movement| {
            const selected_object = self.app.objects.get(self.input_state.selected_object);
            if (selected_object.asComposition()) |composition| {
                composition.setTransform(movement.idx, movement.transform);
            }
        },
        .move_path_point => |movement| {
            try self.app.movePathPoint(self.input_state.selected_object, movement.idx, movement.amount);
        },
        .add_draw_stroke => |pos| {
            const selected_object = self.app.objects.get(self.input_state.selected_object);
            if (selected_object.asDrawing()) |d| {
                try d.addStroke(
                    scratch.heap,
                    scratch.gl,
                    pos,
                    &self.app.objects,
                    self.app.renderer.distance_field_generator,
                );
            }
        },
        .add_stroke_sample => |pos| {
            const selected_object = self.app.objects.get(self.input_state.selected_object);
            if (selected_object.asDrawing()) |d| {
                try d.addSample(scratch.heap, scratch.gl, pos, &self.app.objects, self.app.renderer.distance_field_generator);
            }
        },
        .remove_stroke_samples => |pos| {
            // FIXME: Error consistency the whole way down
            const selected_object = self.app.objects.get(self.input_state.selected_object);
            if (selected_object.asDrawing()) |d| {
                try d.removePointsWithinRange(
                    scratch.heap,
                    scratch.gl,
                    pos,
                    self.app.tool_params.eraser_width,
                    &self.app.objects,
                    self.app.renderer.distance_field_generator,
                );
            }
        },
        .set_drawing_tool => |t| {
            self.app.tool_params.active_drawing_tool = t;
        },
        .save => {
            try self.app.save("save.json");
        },
        .export_image => {
            try self.app.exportImage(self.selectedObjectId(), "image.png");
        },
        .pan => |amount| {
            self.view_state.pan(amount);
        },
    }
}

pub fn setSelectedObject(self: *AppView, id: ObjectId) void {
    self.input_state.selectObject(id, &self.app.objects);
    self.view_state.reset();
}

pub fn setWindowSize(self: *AppView, width: usize, height: usize) void {
    self.view_state.window_width = width;
    self.view_state.window_height = height;
}

pub fn render(self: *AppView, now: std.time.Instant) !void {
    const scratch = &self.app.scratch;

    const checkpoint = scratch.checkpoint();
    defer scratch.restore(checkpoint);

    var frame_renderer = self.app.makeFrameRenderer(
        scratch.heap.allocator(),
        scratch.gl,
    );

    const obj = self.app.objects.get(self.input_state.selected_object);
    const transform = self.view_state.objectToClipTransform(obj.dims(&self.app.objects));
    try frame_renderer.render(self.input_state.selected_object, transform);

    const ui_renderer = frame_renderer.makeUiRenderer(self.app.tool_params, self.input_state.mouse_pos, now);
    try ui_renderer.render(self.app.objects.get(self.input_state.selected_object).*, transform);
}

pub fn selectedDims(self: *AppView) PixelDims {
    return self.app.objectDims(self.input_state.selected_object);
}

pub fn selectedObject(self: *AppView) *Object {
    return self.app.objects.get(self.input_state.selected_object);
}

pub fn selectedObjectId(self: *AppView) ObjectId {
    return self.input_state.selected_object;
}
