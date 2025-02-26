const std = @import("std");
const Allocator = std.mem.Allocator;
const sphimp = @import("sphimp");
const ObjectId = sphimp.object.ObjectId;
const App = sphimp.App;
const shader_storage = sphimp.shader_storage;
const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const FontStorage = sphimp.FontStorage;
const BrushId = shader_storage.BrushId;
const Renderer = sphimp.Renderer;
const sphrender = @import("sphrender");
const object_properties = @import("object_properties.zig");
const label_adaptors = @import("label_adaptors.zig");
const float_adaptors = @import("float_adaptors.zig");
const color_adaptors = @import("color_adaptors.zig");
const gui = @import("sphui");
const ui_action = @import("ui_action.zig");
const UiAction = ui_action.UiAction;
const list_io = @import("list_io.zig");
const WidgetFactory = gui.widget_factory.WidgetFactory(UiAction);
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const GlAlloc = sphrender.GlAlloc;

fn wrapFrameScrollView(widget_factory: WidgetFactory, inner: gui.Widget(UiAction)) !gui.Widget(UiAction) {
    const frame = try widget_factory.makeFrame(inner);
    return try widget_factory.makeScrollView(frame);
}

fn makeObjList(app: *App, widget_factory: WidgetFactory) !gui.Widget(UiAction) {
    const layout = blk: {
        const layout = try widget_factory.makeLayout();

        const label = try widget_factory.makeLabel("Object list");
        try layout.pushWidget(label);

        const RetrieverCtx = struct {
            pub fn selectedObject(_: @This(), a: *App) ?ObjectId {
                return a.selectedObjectId();
            }
        };

        const retriever = list_io.objectListRetriever(RetrieverCtx{}, app);
        const obj_list = try widget_factory.makeSelectableList(
            retriever,
            list_io.itListAction(&app.objects, &sphimp.object.Objects.idIter, .update_selected_object),
        );
        try layout.pushWidget(obj_list);

        break :blk layout;
    };

    return wrapFrameScrollView(widget_factory, layout.asWidget());
}

fn makeCreateObject(app: *App, widget_factory: gui.widget_factory.WidgetFactory(UiAction)) !gui.Widget(UiAction) {
    const layout = blk: {
        const layout = try widget_factory.makeLayout();

        {
            const label = try widget_factory.makeLabel("Create an item");
            try layout.pushWidget(label);
        }

        {
            const button = try widget_factory.makeButton("New path", .create_path);
            try layout.pushWidget(button);
        }
        {
            const button = try widget_factory.makeButton("New composition", .create_composition);
            try layout.pushWidget(button);
        }
        {
            const button = try widget_factory.makeButton("New drawing", .create_drawing);
            try layout.pushWidget(button);
        }
        {
            const button = try widget_factory.makeButton("New text", .create_text);
            try layout.pushWidget(button);
        }

        {
            const label = try widget_factory.makeLabel("Create a shader");
            try layout.pushWidget(label);

            const shader_list = try widget_factory.makeSelectableList(
                list_io.ShaderListRetriever{ .app = app },
                list_io.itListAction(&app.shaders, &ShaderStorage(ShaderId).idIter, .create_shader),
            );
            try layout.pushWidget(shader_list);
        }

        break :blk layout;
    };

    return wrapFrameScrollView(widget_factory, layout.asWidget());
}

fn addShaderParamsToPropertyList(app: *App, property_list: anytype, widget_factory: gui.widget_factory.WidgetFactory(UiAction), uniforms: sphrender.shader_program.UnknownUniforms) !void {
    const property_widget_gen = object_properties.PropertyWidgetGenerator{
        .app = app,
        .widget_factory = widget_factory,
        .property_list = property_list,
    };

    for (0..uniforms.items.len) |i| {
        const uniform = uniforms.items[i];

        switch (uniform.default) {
            .image => {
                try property_widget_gen.addImageToPropertyList(i, uniforms.items[i].name);
            },
            .float => {
                try property_widget_gen.addFloatToPropertyList(i, uniforms.items[i].name);
            },
            .float2 => {
                try property_widget_gen.addFloat2ToPropertyList(i, uniforms.items[i].name);
            },
            .float3 => {
                try property_widget_gen.addFloat3ToPropertyList(i, uniforms.items[i].name);
            },
            else => {
                const uniform_label = try widget_factory.makeLabel(uniform.name);
                const value_widget = try widget_factory.makeLabel("unimplemented");
                try property_list.pushWidgets(uniform_label, value_widget);
            },
        }
    }
}

const ObjectProperties = struct {
    widget: gui.Widget(UiAction),
    specific_properties: *gui.layout.Layout(UiAction),
};

fn makeObjectProperties(app: *App, widget_factory: gui.widget_factory.WidgetFactory(UiAction)) !ObjectProperties {
    const layout = blk: {
        const layout = try widget_factory.makeLayout();

        const layout_name = try widget_factory.makeLabel("Object properties");
        try layout.pushWidget(layout_name);

        const property_list = try widget_factory.makePropertyList(4);
        try layout.pushWidget(property_list.asWidget());

        {
            const name_label = try widget_factory.makeLabel("Name");
            const name_box = try widget_factory.makeTextbox(
                label_adaptors.SelectedObjectName.init(app),
                &UiAction.makeEditName,
            );
            try property_list.pushWidgets(name_label, name_box);
        }

        {
            const delete_button = try widget_factory.makeButton("Delete", .delete_selected_object);
            try property_list.pushWidgets(gui.null_widget.makeNull(UiAction), delete_button);
        }

        {
            const label = try widget_factory.makeLabel("Width");
            const value = try widget_factory.makeLabel(label_adaptors.SelectedObjectWidth.init(app));
            try property_list.pushWidgets(label, value);
        }

        {
            const label = try widget_factory.makeLabel("Height");
            const value = try widget_factory.makeLabel(label_adaptors.SelectedObjectHeight.init(app));
            try property_list.pushWidgets(label, value);
        }

        break :blk layout;
    };

    const specific_layout = try widget_factory.makeLayout();
    try layout.pushWidget(specific_layout.asWidget());
    const widget = try wrapFrameScrollView(widget_factory, layout.asWidget());

    return .{
        .widget = widget,
        .specific_properties = specific_layout,
    };
}

pub const Handle = struct {
    removable_content_alloc: gui.GuiAlloc,
    // Note that these widgets are owned by the sidebar, not by us
    object_properties: gui.Widget(UiAction),
    specific_object_properties: *gui.layout.Layout(UiAction),

    app: *App,
    removable_content_widget_factory: WidgetFactory,

    pub fn notifyObjectChanged(self: Handle) void {
        // When objects change, we re-use the same widgets, but users expect
        // widgets to behave as if they were new (textbox cursor position as if
        // new, etc.)
        self.object_properties.reset();
    }

    /// Items in the property list don't use the typical widget update() path
    /// to re-generate the widget list. We need to tell the object list that
    /// the items in the property list may have changed, and we have to
    /// re-generate
    pub fn updateObjectProperties(self: Handle) !void {
        self.specific_object_properties.clear();

        try self.removable_content_alloc.reset();

        const property_list = try self.removable_content_widget_factory.makePropertyList(50);
        try self.specific_object_properties.pushWidget(property_list.asWidget());

        const selected_obj = self.app.objects.get(self.app.input_state.selected_object);

        {
            const type_label_key = try self.removable_content_widget_factory.makeLabel("Object type");
            const type_label_value = try self.removable_content_widget_factory.makeLabel(@tagName(selected_obj.data));
            try property_list.pushWidgets(type_label_key, type_label_value);
        }

        switch (selected_obj.data) {
            .filesystem => |fs_obj| {
                {
                    const source_key = try self.removable_content_widget_factory.makeLabel("Source");
                    const source_value = try self.removable_content_widget_factory.makeLabel(fs_obj.source);
                    try property_list.pushWidgets(source_key, source_value);
                }
            },
            .generated_mask => {},
            .composition => |comp| {
                {
                    const width_label = try self.removable_content_widget_factory.makeLabel("Width");
                    const width_dragger = try self.removable_content_widget_factory.makeDragFloat(
                        float_adaptors.SelectedObjectWidth.init(self.app),
                        &UiAction.makeUpdateCompositionWidth,
                        1.0,
                    );
                    try property_list.pushWidgets(width_label, width_dragger);
                }

                {
                    const height_label = try self.removable_content_widget_factory.makeLabel("Height");
                    const height_dragger = try self.removable_content_widget_factory.makeDragFloat(
                        float_adaptors.SelectedObjectHeight.init(self.app),
                        &UiAction.makeUpdateCompositionHeight,
                        1.0,
                    );
                    try property_list.pushWidgets(height_label, height_dragger);
                }

                {
                    const debug_label = try self.removable_content_widget_factory.makeLabel("Debug");

                    const CheckedRetriever = struct {
                        app: *App,

                        pub fn checked(r: @This()) bool {
                            const composition = r.app.selectedObject().asComposition() orelse return false;
                            return composition.debug_masks;
                        }
                    };

                    const debug_checkbox = try self.removable_content_widget_factory.makeCheckbox(CheckedRetriever{ .app = self.app }, UiAction.toggle_composition_debug);
                    try property_list.pushWidgets(debug_label, debug_checkbox);
                }

                {
                    const add_label = try self.removable_content_widget_factory.makeLabel("Add");
                    const RetrieverCtx = struct {
                        pub fn selectedObject(_: @This(), _: *App) ?ObjectId {
                            return null;
                        }
                    };
                    const add_combobox = try self.removable_content_widget_factory.makeComboBox(
                        list_io.objectListRetriever(RetrieverCtx{}, self.app),
                        list_io.itListAction(&self.app.objects, &sphimp.object.Objects.idIter, .add_to_composition),
                    );
                    try property_list.pushWidgets(add_label, add_combobox);
                }

                for (0..comp.objects.items.len) |comp_idx| {
                    const name_label = try self.removable_content_widget_factory.makeLabel(label_adaptors.CompositionObjName.init(self.app, comp_idx));
                    const delete_button = try self.removable_content_widget_factory.makeButton("Delete", .{ .delete_from_composition = comp_idx });
                    try property_list.pushWidgets(name_label, delete_button);
                }
            },
            .shader => |s| {
                const shader = self.app.shaders.get(s.program);
                try addShaderParamsToPropertyList(self.app, property_list, self.removable_content_widget_factory, shader.uniforms);
            },
            .drawing => |d| {
                {
                    const source_label = try self.removable_content_widget_factory.makeLabel("Source object");
                    const RetrieverCtx = struct {
                        pub fn selectedObject(_: @This(), a: *App) ?ObjectId {
                            var obj = a.selectedObject();
                            const drawing = obj.asDrawing() orelse return null;
                            return drawing.display_object;
                        }
                    };

                    const value_widget = try self.removable_content_widget_factory.makeComboBox(
                        list_io.objectListRetriever(RetrieverCtx{}, self.app),
                        list_io.itListAction(&self.app.objects, &sphimp.object.Objects.idIter, .update_drawing_source),
                    );
                    try property_list.pushWidgets(source_label, value_widget);
                }

                {
                    const source_label = try self.removable_content_widget_factory.makeLabel("Brush");

                    const value_widget = try self.removable_content_widget_factory.makeComboBox(
                        list_io.BrushRetriever.init(self.app),
                        list_io.itListAction(&self.app.brushes, &shader_storage.ShaderStorage(BrushId).idIter, .update_brush),
                    );
                    try property_list.pushWidgets(source_label, value_widget);
                }

                const brush = self.app.brushes.get(d.brush);
                try addShaderParamsToPropertyList(
                    self.app,
                    property_list,
                    self.removable_content_widget_factory,
                    brush.uniforms,
                );
            },
            .path => {
                const source_label = try self.removable_content_widget_factory.makeLabel("Source object");
                const RetrieverCtx = struct {
                    pub fn selectedObject(_: @This(), a: *App) ?ObjectId {
                        var obj = a.selectedObject();
                        const path = obj.asPath() orelse return null;
                        return path.display_object;
                    }
                };

                const value_widget = try self.removable_content_widget_factory.makeComboBox(
                    list_io.objectListRetriever(RetrieverCtx{}, self.app),
                    list_io.itListAction(&self.app.objects, &sphimp.object.Objects.idIter, .update_path_source),
                );

                try property_list.pushWidgets(source_label, value_widget);
            },
            .text => |*t| {
                {
                    const key = try self.removable_content_widget_factory.makeLabel("Text");
                    const value_widget = try self.removable_content_widget_factory.makeTextbox(
                        label_adaptors.TextObjectContent.init(self.app),
                        &UiAction.makeTextObjChange,
                    );
                    try property_list.pushWidgets(key, value_widget);
                }

                {
                    const key = try self.removable_content_widget_factory.makeLabel("Font");
                    const value_widget = try self.removable_content_widget_factory.makeComboBox(
                        list_io.FontRetriever{ .app = self.app },
                        list_io.itListAction(&self.app.fonts, &FontStorage.idIter, .update_selected_font),
                    );
                    try property_list.pushWidgets(key, value_widget);
                }

                {
                    const key = try self.removable_content_widget_factory.makeLabel("Font size");
                    const value_widget = try self.removable_content_widget_factory.makeDragFloat(
                        &t.renderer.point_size,
                        &UiAction.makeChangeTextSize,
                        0.05,
                    );
                    try property_list.pushWidgets(key, value_widget);
                }
            },
        }
    }
};

const Sidebar = struct {
    widget: gui.Widget(UiAction),
    handle: Handle,
};

pub fn makeSidebar(sidebar_alloc: gui.GuiAlloc, app: *App, widget_state: *gui.widget_factory.WidgetState(UiAction)) !Sidebar {
    const removable_content_alloc = try sidebar_alloc.makeSubAlloc("sidebar_content");

    const full_factory = widget_state.factory(sidebar_alloc);
    const removable_factory = widget_state.factory(removable_content_alloc);

    const sidebar_stack = try full_factory.makeStack(2);

    const sidebar_width = 300;
    const sidebar_box = try full_factory.makeBox(
        sidebar_stack.asWidget(),
        .{ .width = sidebar_width, .height = 0 },
        .fill_height,
    );

    const sidebar_background = try full_factory.makeRect(
        gui.widget_factory.StyleColors.background_color,
    );

    try sidebar_stack.pushWidget(
        sidebar_background,
        .{},
    );

    const sidebar_layout = try full_factory.makeEvenVertLayout(3);
    try sidebar_stack.pushWidget(sidebar_layout.asWidget(), gui.stack.Layout.centered());

    const obj_list = try makeObjList(app, full_factory);
    try sidebar_layout.pushWidget(obj_list);

    const create_object = try makeCreateObject(app, full_factory);
    try sidebar_layout.pushWidget(create_object);

    const properties = try makeObjectProperties(app, full_factory);
    try sidebar_layout.pushWidget(properties.widget);

    var handle = Handle{
        .removable_content_alloc = removable_content_alloc,
        .object_properties = properties.widget,
        .specific_object_properties = properties.specific_properties,

        .app = app,
        .removable_content_widget_factory = removable_factory,
    };

    try handle.updateObjectProperties();

    return .{
        .widget = sidebar_box,
        .handle = handle,
    };
}
