const sphimp = @import("sphimp");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const ShaderId = sphimp.shader_storage.ShaderId;
const BrushId = sphimp.shader_storage.BrushId;
const FontStorage = sphimp.FontStorage;
const gui = @import("sphui");
const list_io = @import("list_io.zig");

pub const UiActionType = @typeInfo(UiAction).Union.tag_type.?;

pub const TextEditRequest = struct {
    notifier: gui.textbox.TextboxNotifier,
    pos: usize,
    items: []const gui.KeyEvent,
};

pub const UiAction = union(enum) {
    update_selected_object: ObjectId,
    create_path,
    create_composition,
    create_drawing,
    create_text,
    create_shader: ShaderId,
    delete_selected_object,
    edit_selected_object_name: TextEditRequest,
    update_composition_width: f32,
    update_composition_height: f32,
    update_shader_float: struct {
        uniform_idx: usize,
        float_idx: usize,
        val: f32,
    },
    update_shader_color: struct {
        uniform_idx: usize,
        color: gui.Color,
    },
    update_shader_image: struct {
        uniform_idx: usize,
        image: ObjectId,
    },
    update_drawing_source: ObjectId,
    update_brush: BrushId,
    update_path_source: ObjectId,
    update_text_obj_name: TextEditRequest,
    update_selected_font: FontStorage.FontId,
    update_text_size: f32,
    add_to_composition: ObjectId,
    delete_from_composition: usize,
    toggle_composition_debug,

    pub fn makeChangeTextSize(size: f32) UiAction {
        return .{ .update_text_size = size };
    }

    pub fn makeTextObjChange(notifier: gui.textbox.TextboxNotifier, pos: usize, items: []const gui.KeyEvent) UiAction {
        return .{
            .update_text_obj_name = .{
                .notifier = notifier,
                .pos = pos,
                .items = items,
            },
        };
    }

    pub fn makeEditName(notifier: gui.textbox.TextboxNotifier, pos: usize, items: []const gui.KeyEvent) UiAction {
        return .{
            .edit_selected_object_name = .{
                .notifier = notifier,
                .pos = pos,
                .items = items,
            },
        };
    }

    pub fn makeUpdateCompositionWidth(val: f32) UiAction {
        return .{ .update_composition_width = val };
    }

    pub fn makeUpdateCompositionHeight(val: f32) UiAction {
        return .{ .update_composition_height = val };
    }
};

pub const ShaderFloat = struct {
    uniform_idx: usize,
    float_idx: usize,

    pub fn generate(self: ShaderFloat, val: f32) UiAction {
        return .{
            .update_shader_float = .{
                .uniform_idx = self.uniform_idx,
                .float_idx = self.float_idx,
                .val = val,
            },
        };
    }
};

pub const ShaderColor = struct {
    uniform_idx: usize,

    pub fn generate(self: ShaderColor, color: gui.Color) UiAction {
        return .{
            .update_shader_color = .{
                .uniform_idx = self.uniform_idx,
                .color = color,
            },
        };
    }
};

pub const ShaderImage = struct {
    app: *App,
    uniform_idx: usize,

    pub fn generate(self: ShaderImage, idx: usize) UiAction {
        var it = self.app.objects.idIter();
        const obj_id = list_io.idxToId(ObjectId, idx, &it);

        return .{
            .update_shader_image = .{
                .uniform_idx = self.uniform_idx,
                .image = obj_id,
            },
        };
    }
};
