//! Ways to show present app state as text/numbers

const std = @import("std");
const sphimp = @import("sphimp");
const ObjectId = sphimp.object.ObjectId;

pub const SelectedObjectName = struct {
    app: *sphimp.App,
    selected: *ObjectId,

    pub fn init(app: *sphimp.App, selected: *ObjectId) SelectedObjectName {
        return .{ .app = app, .selected = selected };
    }

    pub fn getText(self: *SelectedObjectName) []const u8 {
        return self.app.objects.get(self.selected.*).name;
    }
};

pub const SelectedObjectWidth = struct {
    app: *sphimp.App,
    selected: *ObjectId,
    buf: [10]u8 = undefined,

    pub fn init(app: *sphimp.App, selected: *ObjectId) SelectedObjectWidth {
        return .{ .app = app, .selected = selected };
    }

    pub fn getText(self: *SelectedObjectWidth) []const u8 {
        return std.fmt.bufPrint(&self.buf, "{d}", .{self.app.objectDims(self.selected.*)[0]}) catch "error";
    }
};

pub const SelectedObjectHeight = struct {
    app: *sphimp.App,
    selected: *ObjectId,
    buf: [10]u8 = undefined,

    pub fn init(app: *sphimp.App, selected: *ObjectId) SelectedObjectHeight {
        return .{ .app = app, .selected = selected };
    }

    pub fn getText(self: *SelectedObjectHeight) []const u8 {
        return std.fmt.bufPrint(&self.buf, "{d}", .{self.app.objectDims(self.selected.*)[1]}) catch "error";
    }
};

pub const TextObjectContent = struct {
    app: *sphimp.App,
    id: ObjectId,

    pub fn init(app: *sphimp.App, id: ObjectId) TextObjectContent {
        return .{ .app = app, .id = id };
    }

    pub fn getText(self: TextObjectContent) []const u8 {
        const text_obj = self.app.objects.get(self.id).asText() orelse return "";
        return text_obj.current_text;
    }
};

pub fn StackBuf(comptime size: usize) type {
    return struct {
        buf: [size]u8,
        text_len: usize,

        pub fn getText(self: *const @This()) []const u8 {
            return self.buf[0..self.text_len];
        }
    };
}

pub fn stackBuf(comptime fmt: []const u8, args: anytype, comptime max_len: usize) StackBuf(max_len) {
    var buf: [max_len]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..max_len];
    return .{
        .buf = buf,
        .text_len = slice.len,
    };
}

pub const CompositionObjName = struct {
    app: *sphimp.App,
    id: ObjectId,
    composition_idx: usize,

    pub fn init(app: *sphimp.App, id: ObjectId, composition_idx: usize) CompositionObjName {
        return .{
            .app = app,
            .id = id,
            .composition_idx = composition_idx,
        };
    }

    pub fn getText(self: @This()) []const u8 {
        const comp_data = self.app.objects.get(self.id).asComposition() orelse return "";
        const comp_obj = comp_data.objects.items[self.composition_idx];
        const obj = self.app.objects.get(comp_obj.id);
        return obj.name;
    }
};

pub const ShaderImageUniformName = struct {
    app: *sphimp.App,
    id: ObjectId,
    uniform_idx: usize,

    pub fn getText(self: ShaderImageUniformName) []const u8 {
        const object = self.app.objects.get(self.id);
        const bindings = object.shaderBindings() orelse return "";
        switch (bindings[self.uniform_idx]) {
            .image => |id| {
                return self.app.objects.get(id orelse return "").name;
            },
            else => return "",
        }
    }
};

pub const DrawingDisplayObjectName = struct {
    app: *sphimp.App,
    id: ObjectId,

    pub fn getText(self: DrawingDisplayObjectName) []const u8 {
        const drawing = self.app.objects.get(self.id).asDrawing() orelse return "";
        const id = drawing.display_object;
        return self.app.objects.get(id).name;
    }
};

pub const SelectedBrushName = struct {
    app: *sphimp.App,
    id: ObjectId,

    pub fn getText(self: SelectedBrushName) []const u8 {
        const drawing = self.app.objects.get(self.id).asDrawing() orelse return "";
        const id = drawing.brush;
        return self.app.brushes.get(id).name;
    }
};

pub const PathDisplayObjectName = struct {
    app: *sphimp.App,
    id: ObjectId,

    pub fn getText(self: PathDisplayObjectName) []const u8 {
        const path = self.app.objects.get(self.id).asPath() orelse return "";
        const id = path.display_object;
        return self.app.objects.get(id).name;
    }
};

pub const TextObjectFont = struct {
    app: *sphimp.App,
    id: ObjectId,

    pub fn getText(self: TextObjectFont) []const u8 {
        const text = self.app.objects.get(self.id).asText() orelse return "";
        const id = text.font;
        return self.app.fonts.get(id).path;
    }
};
