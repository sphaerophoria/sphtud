//! Inputs and outputs to selectable lists

const std = @import("std");
const sphimp = @import("sphimp");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const ShaderId = sphimp.shader_storage.ShaderId;
const BrushId = sphimp.shader_storage.BrushId;
const FontId = sphimp.FontStorage.FontId;
const ui_action = @import("ui_action.zig");
const UiAction = ui_action.UiAction;
const UiActionType = ui_action.UiActionType;

/// Retriever for widgets that want to show an object list. We have many
/// scenarios where we want to show an object list, but which item is selected
/// is different. E.g. the main object list, add to composition, shader image
/// inputs, etc.
///
/// Handle all the object listing in a common place, and take in a context
/// which retrieves the selected object ID.
pub fn ObjectListRetriever(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        app: *App,

        pub fn numItems(self: @This()) usize {
            return self.app.objects.numItems();
        }

        pub fn selectedId(self: @This()) usize {
            const id = self.ctx.selectedObject(self.app) orelse return invalid_list_id;
            var it = self.app.objects.idIter();
            return idxForId(&it, id);
        }

        pub fn getText(self: @This(), idx: usize) []const u8 {
            var it = self.app.objects.idIter();
            const object_id = idxToId(ObjectId, idx, &it);
            return self.app.objects.get(object_id).name;
        }
    };
}

pub fn objectListRetriever(ctx: anytype, app: *App) ObjectListRetriever(@TypeOf(ctx)) {
    return .{
        .ctx = ctx,
        .app = app,
    };
}

pub const ShaderListRetriever = struct {
    app: *App,

    pub fn numItems(self: ShaderListRetriever) usize {
        return self.app.shaders.numItems();
    }

    pub fn selectedId(_: ShaderListRetriever) usize {
        return std.math.maxInt(usize);
    }

    pub fn getText(self: ShaderListRetriever, idx: usize) []const u8 {
        var it = self.app.shaders.idIter();
        const shader_id = idxToId(ShaderId, idx, &it);
        return self.app.shaders.get(shader_id).name;
    }
};

pub const FontRetriever = struct {
    app: *App,

    pub fn numItems(self: FontRetriever) usize {
        return self.app.fonts.numItems();
    }

    pub fn selectedId(self: FontRetriever) usize {
        const text_obj = self.app.selectedObject().asText() orelse return invalid_list_id;
        var it = self.app.fonts.idIter();
        return idxForId(&it, text_obj.font);
    }

    pub fn getText(self: FontRetriever, idx: usize) []const u8 {
        var it = self.app.fonts.idIter();
        const font_id = idxToId(FontId, idx, &it);
        const font = self.app.fonts.get(font_id);
        return font.path;
    }
};

pub const BrushRetriever = struct {
    app: *App,

    pub fn init(app: *App) BrushRetriever {
        return .{ .app = app };
    }

    pub fn numItems(self: BrushRetriever) usize {
        return self.app.brushes.numItems();
    }

    pub fn selectedId(self: BrushRetriever) usize {
        const drawing_obj = self.app.selectedObject().asDrawing() orelse return invalid_list_id;
        var it = self.app.brushes.idIter();
        return idxForId(&it, drawing_obj.brush);
    }

    pub fn getText(self: BrushRetriever, idx: usize) []const u8 {
        var it = self.app.brushes.idIter();
        const brush_id = idxToId(BrushId, idx, &it);
        const brush = self.app.brushes.get(brush_id);
        return brush.name;
    }
};

/// When making a list backed by an iterator (object list, shader list, brush
/// list, etc.), what should we do when an item is clicked? ItListAction
/// abstracts the index -> id lookup. A common scenario is that we have a
/// UiAction of the form
///
///  action_type: Id
///
/// We handle this automatically by making an iterator, advancing it N times,
/// and creating the requested action type
pub fn ItListAction(comptime Ctx: type, comptime MakeIt: type, comptime tag: UiActionType) type {
    return struct {
        ctx: Ctx,
        makeIt: MakeIt,

        pub fn generate(self: @This(), idx: usize) UiAction {
            var it = self.makeIt(self.ctx.*);
            const id = idxToId(@TypeOf(it.next().?), idx, &it);
            return @unionInit(UiAction, @tagName(tag), id);
        }
    };
}

pub fn itListAction(ctx: anytype, makeIt: anytype, comptime tag: UiActionType) ItListAction(@TypeOf(ctx), @TypeOf(makeIt), tag) {
    return .{
        .ctx = ctx,
        .makeIt = makeIt,
    };
}

/// Given an iterator, which element is at index idx
pub fn idxToId(comptime Id: type, idx: usize, it: anytype) Id {
    var id: Id = it.next().?;
    for (0..idx) |_| {
        id = it.next() orelse break;
    }
    return id;
}

pub const invalid_list_id = std.math.maxInt(usize);
/// Given an iterator that returns ids, and a strong typed id with a .value
/// inner param, which index has id id
///
/// This matches the pattern for a bunch of containers in sphimp. Object
/// storage, shader storage, brush storage, etc.
pub fn idxForId(it: anytype, id: anytype) usize {
    var idx: usize = 0;
    while (it.next()) |possible_match| {
        defer idx += 1;
        if (possible_match.value == id.value) {
            return idx;
        }
    }

    return std.math.maxInt(usize);
}
