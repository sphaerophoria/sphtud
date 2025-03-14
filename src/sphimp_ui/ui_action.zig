const std = @import("std");
const sphimp = @import("sphimp");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const CompositionIdx = sphimp.object.CompositionIdx;
const ShaderId = sphimp.shader_storage.ShaderId;
const BrushId = sphimp.shader_storage.BrushId;
const FontStorage = sphimp.FontStorage;
const gui = @import("sphui");
const list_io = @import("list_io.zig");
const DrawingTool = sphimp.tool.DrawingTool;

pub const UiActionType = @typeInfo(UiAction).@"union".tag_type.?;

pub const TextEditRequest = struct {
    object: ObjectId,
    notifier: gui.textbox.TextboxNotifier,
    pos: usize,
    items: []const gui.KeyEvent,
};

pub const UiAction = union(enum) {
    update_selected_object: ObjectId,
    update_property_object: ObjectId,
    create_path,
    create_composition,
    create_drawing,
    create_text,
    create_shader: ShaderId,
    delete_object: ObjectId,
    edit_object_name: TextEditRequest,
    update_composition_width: struct {
        object: ObjectId,
        width: f32,
    },
    update_composition_height: struct {
        object: ObjectId,
        height: f32,
    },
    update_shader_float: struct {
        object: ObjectId,
        uniform_idx: usize,
        float_idx: usize,
        val: f32,
    },
    update_shader_color: struct {
        object: ObjectId,
        uniform_idx: usize,
        color: gui.Color,
    },
    update_shader_image: struct {
        object: ObjectId,
        uniform_idx: usize,
        image: ObjectId,
    },
    update_drawing_source: struct {
        drawing: ObjectId,
        source: ObjectId,
    },
    update_brush: struct {
        object: ObjectId,
        brush: BrushId,
    },
    update_path_source: struct {
        object: ObjectId,
        source: ObjectId,
    },
    edit_text_obj_content: TextEditRequest,
    update_selected_font: struct {
        object: ObjectId,
        font: FontStorage.FontId,
    },
    update_text_size: struct {
        object: ObjectId,
        size: f32,
    },
    add_to_composition: struct {
        composition: ObjectId,
        to_add: ObjectId,
    },
    delete_from_composition: struct {
        composition: ObjectId,
        idx: CompositionIdx,
    },
    set_drag_source: ObjectId,
    toggle_composition_debug,
    set_drawing_tool: DrawingTool,
    change_eraser_size: f32,

    pub fn makeChangeEraserSize(val: f32) UiAction {
        return .{ .change_eraser_size = val };
    }
};

pub const ShaderColor = struct {
    object: ObjectId,
    uniform_idx: usize,

    pub fn generate(self: ShaderColor, color: gui.Color) UiAction {
        return .{
            .update_shader_color = .{
                .object = self.object,
                .uniform_idx = self.uniform_idx,
                .color = color,
            },
        };
    }
};

pub const ShaderImage = struct {
    app: *App,
    object: ObjectId,
    uniform_idx: usize,

    pub fn generate(self: ShaderImage, idx: usize) UiAction {
        var it = self.app.objects.idIter();
        const obj_id = list_io.idxToId(ObjectId, idx, &it);

        return .{
            .update_shader_image = .{
                .object = self.object,
                .uniform_idx = self.uniform_idx,
                .image = obj_id,
            },
        };
    }
};

pub fn BundledFloatParam(comptime tag: UiActionType, comptime field: [:0]const u8, comptime OtherParams: type) type {
    return struct {
        other_params: OtherParams,

        pub fn generate(self: @This(), val: f32) UiAction {
            const InitType = std.meta.fieldInfo(UiAction, tag).type;
            var init: InitType = undefined;
            inline for (std.meta.fields(OtherParams)) |f| {
                @field(init, f.name) = @field(self.other_params, f.name);
            }
            @field(init, field) = val;
            return @unionInit(UiAction, @tagName(tag), init);
        }
    };
}

pub fn bundledFloatParam(comptime tag: UiActionType, comptime field: [:0]const u8, other_params: anytype) BundledFloatParam(tag, field, @TypeOf(other_params)) {
    return .{
        .other_params = other_params,
    };
}

pub fn TextEditRequestGenerator(comptime tag: UiActionType) type {
    return struct {
        id: *ObjectId,

        pub fn generate(self: @This(), notifier: gui.textbox.TextboxNotifier, pos: usize, items: []const gui.KeyEvent) UiAction {
            return @unionInit(UiAction, @tagName(tag), .{
                .object = self.id.*,
                .notifier = notifier,
                .pos = pos,
                .items = items,
            });
        }
    };
}

pub const DeleteObjectGenerator = struct {
    id: *ObjectId,

    pub fn generate(self: @This()) UiAction {
        return .{ .delete_object = self.id.* };
    }
};

pub const UpdateTextSizeGenerator = struct {
    id: ObjectId,

    pub fn generate(self: UpdateTextSizeGenerator, size: f32) UiAction {
        return .{
            .update_text_size = .{ .object = self.id, .size = size },
        };
    }
};
