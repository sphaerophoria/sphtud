const std = @import("std");
const Allocator = std.mem.Allocator;
const sphimp = @import("sphimp");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const Renderer = sphimp.Renderer;
const gui = @import("sphui");
const ui_action = @import("ui_action.zig");
const sphrender = @import("sphrender");
const list_io = @import("list_io.zig");
const label_adaptors = @import("label_adaptors.zig");
const float_adaptors = @import("float_adaptors.zig");
const color_adaptors = @import("color_adaptors.zig");
const UiAction = ui_action.UiAction;
const Grid = gui.grid.Grid(UiAction);
const WidgetFactory = gui.widget_factory.WidgetFactory(UiAction);

pub const PropertyWidgetGenerator = struct {
    app: *App,
    widget_factory: WidgetFactory,
    property_list: *Grid,

    const drag_speed = 0.01;

    pub fn addImageToPropertyList(self: PropertyWidgetGenerator, uniform_idx: usize, name: []const u8) !void {
        const uniform_label = try self.widget_factory.makeLabel(name);
        const preview = try self.widget_factory.makeLabel(
            label_adaptors.ShaderImageUniformName{ .app = self.app, .uniform_idx = uniform_idx },
        );

        const value_widget = try self.widget_factory.makeComboBox(
            preview,
            ShaderSelectableListGenerator{
                .widget_state = self.widget_factory.state,
                .uniform_idx = uniform_idx,
                .app = self.app,
            },
        );
        try self.property_list.pushWidget(uniform_label);
        try self.property_list.pushWidget(value_widget);
    }

    pub fn addFloatToPropertyList(self: PropertyWidgetGenerator, uniform_idx: usize, name: []const u8) !void {
        const uniform_label = try self.widget_factory.makeLabel(name);
        const value_widget = try self.widget_factory.makeDragFloat(
            float_adaptors.ShaderUniform{
                .app = self.app,
                .uniform_idx = uniform_idx,
                .float_idx = 0,
            },
            ui_action.ShaderFloat{
                .uniform_idx = uniform_idx,
                .float_idx = 0,
            },
            drag_speed,
        );
        try self.property_list.pushWidget(uniform_label);
        try self.property_list.pushWidget(value_widget);
    }

    pub fn addFloat2ToPropertyList(self: PropertyWidgetGenerator, uniform_idx: usize, name: []const u8) !void {
        const max_label_len = 20;
        const params: [2][]const u8 = .{ "X", "Y" };
        for (params, 0..) |param_name, idx| {
            const uniform_label = try self.widget_factory.makeLabel(
                label_adaptors.stackBuf(
                    "{s} {s}",
                    .{ name, param_name },
                    max_label_len,
                ),
            );
            const value_widget = try self.widget_factory.makeDragFloat(
                float_adaptors.ShaderUniform{
                    .app = self.app,
                    .uniform_idx = uniform_idx,
                    .float_idx = idx,
                },
                ui_action.ShaderFloat{
                    .uniform_idx = uniform_idx,
                    .float_idx = idx,
                },
                drag_speed,
            );

            try self.property_list.pushWidget(uniform_label);
            try self.property_list.pushWidget(value_widget);
        }
    }

    pub fn addFloat3ToPropertyList(self: PropertyWidgetGenerator, uniform_idx: usize, name: []const u8) !void {
        const uniform_label = try self.widget_factory.makeLabel(name);

        const value_widget = try self.widget_factory.makeColorPicker(
            color_adaptors.ShaderUniform{
                .app = self.app,
                .uniform_idx = uniform_idx,
            },
            ui_action.ShaderColor{ .uniform_idx = uniform_idx },
        );

        try self.property_list.pushWidget(uniform_label);
        try self.property_list.pushWidget(value_widget);
    }
};

const ShaderImage = struct {
    uniform_idx: usize,

    pub fn selectedObject(self: @This(), a: *App) ?ObjectId {
        const object = a.selectedObject();

        const bindings = object.shaderBindings() orelse return null;

        switch (bindings[self.uniform_idx]) {
            .image => |id| return id orelse return null,
            else => return null,
        }
    }
};

const ShaderSelectableListGenerator = struct {
    widget_state: *gui.widget_factory.WidgetState(UiAction),
    app: *App,
    uniform_idx: usize,

    pub fn makeWidget(self: ShaderSelectableListGenerator, alloc: gui.GuiAlloc) !gui.Widget(UiAction) {
        const factory = self.widget_state.factory(alloc);
        return try factory.makeSelectableList(
            list_io.objectListRetriever(ShaderImage{ .uniform_idx = self.uniform_idx }, self.app),
            ui_action.ShaderImage{
                .app = self.app,
                .uniform_idx = self.uniform_idx,
            },
        );
    }
};
