const std = @import("std");
const sphmath = @import("sphmath");
const Vec2 = sphmath.Vec2;
const Vec3 = sphmath.Vec3;
const Transform = sphmath.Transform;
const obj_mod = @import("object.zig");
const ObjectId = obj_mod.ObjectId;
const Objects = obj_mod.Objects;
const tool = @import("tool.zig");
const ToolParams = tool.ToolParams;
const Renderer = @import("Renderer.zig");

const InputState = @This();

selected_object: ObjectId = .{ .value = 0 },
// object coords
mouse_pos: Vec2 = .{ 0.0, 0.0 },
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

pub const InputAction = union(enum) {
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
    remove_stroke_samples: Vec2,
    set_drawing_tool: tool.DrawingTool,
    export_image,
    save,
    pan: Vec2,
};

pub fn selectObject(self: *InputState, id: ObjectId, objects: *Objects) void {
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
pub fn setMouseDown(self: *InputState, tool_params: ToolParams, objects: *obj_mod.Objects, frame_renderer: *Renderer.FrameRenderer) !?InputAction {
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
            switch (tool_params.active_drawing_tool) {
                .brush => {
                    return .{
                        .add_draw_stroke = self.mouse_pos,
                    };
                },
                .eraser => {
                    return .{
                        .remove_stroke_samples = self.mouse_pos,
                    };
                },
            }
        },
        .none => {},
    }
    return null;
}

pub fn setMouseUp(self: *InputState) void {
    switch (self.data) {
        .composition => |*action| action.* = .none,
        .path => |*selected_path_item| selected_path_item.* = null,
        .drawing => |*d| d.mouse_down = false,
        .none => {},
    }
}

pub fn setMousePos(self: *InputState, tool_params: ToolParams, new_pos: Vec2, objects: *Objects) ?InputAction {
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
                switch (tool_params.active_drawing_tool) {
                    .brush => return InputAction{ .add_stroke_sample = new_pos },
                    .eraser => return InputAction{ .remove_stroke_samples = new_pos },
                }
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

pub fn setRightDown(self: *InputState) ?InputAction {
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

pub fn setMiddleDown(self: *InputState) void {
    self.panning = true;
}

pub fn setMiddleUp(self: *InputState) void {
    self.panning = false;
}

// FIXME: Const objects probably
pub fn setKeyDown(self: *InputState, key: u8, ctrl: bool, objects: *Objects, frame_renderer: *Renderer.FrameRenderer) !?InputAction {
    switch (self.data) {
        .composition => |*c| {
            switch (key) {
                's' => c.* = try self.makeCompositionInputState(objects, frame_renderer, .scale),
                'r' => c.* = try self.makeCompositionInputState(objects, frame_renderer, .rotation),
                else => {},
            }
        },
        .drawing => {
            switch (key) {
                'e' => return .{ .set_drawing_tool = .eraser },
                'w' => return .{ .set_drawing_tool = .brush },
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
