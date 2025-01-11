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

fn wrapFrameScrollViewOrDeinit(widget_factory: *WidgetFactory, inner: gui.Widget(UiAction)) !gui.Widget(UiAction) {
    const frame = blk: {
        errdefer inner.deinit(widget_factory.alloc);
        break :blk try widget_factory.makeFrame(inner);
    };
    errdefer frame.deinit(widget_factory.alloc);

    return try widget_factory.makeScrollView(frame);
}

fn makeObjList(app: *App, widget_factory: *WidgetFactory) !gui.Widget(UiAction) {
    const layout = blk: {
        const layout = try widget_factory.makeLayout();
        errdefer layout.deinit(widget_factory.alloc);

        const label = try widget_factory.makeLabel("Object list");
        try layout.pushOrDeinitWidget(widget_factory.alloc, label);

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
        try layout.pushOrDeinitWidget(widget_factory.alloc, obj_list);

        break :blk layout;
    };

    return wrapFrameScrollViewOrDeinit(widget_factory, layout.asWidget());
}

fn makeCreateObject(app: *App, widget_factory: *gui.widget_factory.WidgetFactory(UiAction)) !gui.Widget(UiAction) {
    const layout = blk: {
        const layout = try widget_factory.makeLayout();
        errdefer layout.deinit(widget_factory.alloc);

        {
            const label = try widget_factory.makeLabel("Create an item");
            try layout.pushOrDeinitWidget(widget_factory.alloc, label);
        }

        {
            const button = try widget_factory.makeButton("New path", .create_path);
            try layout.pushOrDeinitWidget(widget_factory.alloc, button);
        }
        {
            const button = try widget_factory.makeButton("New composition", .create_composition);
            try layout.pushOrDeinitWidget(widget_factory.alloc, button);
        }
        {
            const button = try widget_factory.makeButton("New drawing", .create_drawing);
            try layout.pushOrDeinitWidget(widget_factory.alloc, button);
        }
        {
            const button = try widget_factory.makeButton("New text", .create_text);
            try layout.pushOrDeinitWidget(widget_factory.alloc, button);
        }

        {
            const label = try widget_factory.makeLabel("Create a shader");
            try layout.pushOrDeinitWidget(widget_factory.alloc, label);

            const shader_list = try widget_factory.makeSelectableList(
                list_io.ShaderListRetriever{ .app = app },
                list_io.itListAction(&app.shaders, &ShaderStorage(ShaderId).idIter, .create_shader),
            );
            try layout.pushOrDeinitWidget(widget_factory.alloc, shader_list);
        }

        break :blk layout;
    };

    return wrapFrameScrollViewOrDeinit(widget_factory, layout.asWidget());
}

fn addShaderParamsToPropertyList(app: *App, property_list: *gui.property_list.PropertyList(UiAction), widget_factory: *gui.widget_factory.WidgetFactory(UiAction), uniforms: sphrender.shader_program.UnknownUniforms) !void {
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
                errdefer uniform_label.deinit(widget_factory.alloc);

                const value_widget = try widget_factory.makeLabel("unimplemented");
                errdefer value_widget.deinit(widget_factory.alloc);

                try property_list.pushWidgets(widget_factory.alloc, uniform_label, value_widget);
            },
        }
    }
}

const ObjectProperties = struct {
    widget: gui.Widget(UiAction),
    specific_properties: *gui.layout.Layout(UiAction),
};

fn makeObjectProperties(app: *App, widget_factory: *gui.widget_factory.WidgetFactory(UiAction)) !ObjectProperties {
    const layout = blk: {
        const layout = try widget_factory.makeLayout();
        errdefer layout.deinit(widget_factory.alloc);

        const layout_name = try widget_factory.makeLabel("Object properties");
        try layout.pushOrDeinitWidget(widget_factory.alloc, layout_name);

        const property_list = try widget_factory.makePropertyList();
        try layout.pushOrDeinitWidget(widget_factory.alloc, property_list.asWidget());

        {
            const name_label = try widget_factory.makeLabel("Name");
            errdefer name_label.deinit(widget_factory.alloc);

            const name_box = try widget_factory.makeTextbox(
                label_adaptors.SelectedObjectName.init(app),
                &UiAction.makeEditName,
            );
            errdefer name_box.deinit(widget_factory.alloc);

            try property_list.pushWidgets(widget_factory.alloc, name_label, name_box);
        }

        {
            const delete_button = try widget_factory.makeButton("Delete", .delete_selected_object);
            errdefer delete_button.deinit(widget_factory.alloc);

            try property_list.pushWidgets(widget_factory.alloc, gui.null_widget.makeNull(UiAction), delete_button);
        }

        {
            const label = try widget_factory.makeLabel("Width");
            errdefer label.deinit(widget_factory.alloc);

            const value = try widget_factory.makeLabel(label_adaptors.SelectedObjectWidth.init(app));
            errdefer value.deinit(widget_factory.alloc);

            try property_list.pushWidgets(widget_factory.alloc, label, value);
        }

        {
            const label = try widget_factory.makeLabel("Height");
            errdefer label.deinit(widget_factory.alloc);

            const value = try widget_factory.makeLabel(label_adaptors.SelectedObjectHeight.init(app));
            errdefer value.deinit(widget_factory.alloc);

            try property_list.pushWidgets(widget_factory.alloc, label, value);
        }

        break :blk layout;
    };

    const specific_layout = blk: {
        errdefer layout.deinit(widget_factory.alloc);

        const specific_layout = try widget_factory.makeLayout();
        try layout.pushOrDeinitWidget(widget_factory.alloc, specific_layout.asWidget());
        break :blk specific_layout;
    };

    const widget = try wrapFrameScrollViewOrDeinit(widget_factory, layout.asWidget());

    return .{
        .widget = widget,
        .specific_properties = specific_layout,
    };
}

pub const Handle = struct {
    // Note that these widgets are owned by the sidebar, not by us
    object_properties: gui.Widget(UiAction),
    specific_object_properties: *gui.layout.Layout(UiAction),

    app: *App,
    widget_factory: *WidgetFactory,

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
        self.specific_object_properties.clear(self.widget_factory.alloc);

        const property_list = try self.widget_factory.makePropertyList();
        try self.specific_object_properties.pushOrDeinitWidget(self.widget_factory.alloc, property_list.asWidget());

        const selected_obj = self.app.objects.get(self.app.input_state.selected_object);

        {
            const type_label_key = try self.widget_factory.makeLabel("Object type");
            errdefer type_label_key.deinit(self.widget_factory.alloc);

            const type_label_value = try self.widget_factory.makeLabel(@tagName(selected_obj.data));
            errdefer type_label_value.deinit(self.widget_factory.alloc);

            try property_list.pushWidgets(self.widget_factory.alloc, type_label_key, type_label_value);
        }

        switch (selected_obj.data) {
            .filesystem => |fs_obj| {
                {
                    const source_key = try self.widget_factory.makeLabel("Source");
                    errdefer source_key.deinit(self.widget_factory.alloc);

                    const source_value = try self.widget_factory.makeLabel(fs_obj.source);
                    errdefer source_value.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, source_key, source_value);
                }
            },
            .generated_mask => {},
            .composition => |comp| {
                {
                    const width_label = try self.widget_factory.makeLabel("Width");
                    errdefer width_label.deinit(self.widget_factory.alloc);

                    const width_dragger = try self.widget_factory.makeDragFloat(
                        float_adaptors.SelectedObjectWidth.init(self.app),
                        &UiAction.makeUpdateCompositionWidth,
                        1.0,
                    );
                    errdefer width_dragger.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, width_label, width_dragger);
                }

                {
                    const height_label = try self.widget_factory.makeLabel("Height");
                    errdefer height_label.deinit(self.widget_factory.alloc);

                    const height_dragger = try self.widget_factory.makeDragFloat(
                        float_adaptors.SelectedObjectHeight.init(self.app),
                        &UiAction.makeUpdateCompositionHeight,
                        1.0,
                    );
                    errdefer height_dragger.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, height_label, height_dragger);
                }

                {
                    const debug_label = try self.widget_factory.makeLabel("Debug");
                    errdefer debug_label.deinit(self.widget_factory.alloc);

                    const CheckedRetriever = struct {
                        app: *App,

                        pub fn checked(r: @This()) bool {
                            const composition = r.app.selectedObject().asComposition() orelse return false;
                            return composition.debug_masks;
                        }
                    };

                    const debug_checkbox = try self.widget_factory.makeCheckbox(CheckedRetriever{ .app = self.app }, UiAction.toggle_composition_debug);
                    errdefer debug_checkbox.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, debug_label, debug_checkbox);
                }

                {
                    const add_label = try self.widget_factory.makeLabel("Add");
                    errdefer add_label.deinit(self.widget_factory.alloc);

                    const RetrieverCtx = struct {
                        pub fn selectedObject(_: @This(), _: *App) ?ObjectId {
                            return null;
                        }
                    };
                    const add_combobox = try self.widget_factory.makeComboBox(
                        list_io.objectListRetriever(RetrieverCtx{}, self.app),
                        list_io.itListAction(&self.app.objects, &sphimp.object.Objects.idIter, .add_to_composition),
                    );
                    errdefer add_combobox.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, add_label, add_combobox);
                }

                for (0..comp.objects.items.len) |comp_idx| {
                    const name_label = try self.widget_factory.makeLabel(label_adaptors.CompositionObjName.init(self.app, comp_idx));
                    errdefer name_label.deinit(self.widget_factory.alloc);

                    const delete_button = try self.widget_factory.makeButton("Delete", .{ .delete_from_composition = comp_idx });
                    errdefer delete_button.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, name_label, delete_button);
                }
            },
            .shader => |s| {
                const shader = self.app.shaders.get(s.program);
                try addShaderParamsToPropertyList(self.app, property_list, self.widget_factory, shader.uniforms);
            },
            .drawing => |d| {
                {
                    const source_label = try self.widget_factory.makeLabel("Source object");
                    errdefer source_label.deinit(self.widget_factory.alloc);

                    const RetrieverCtx = struct {
                        pub fn selectedObject(_: @This(), a: *App) ?ObjectId {
                            var obj = a.selectedObject();
                            const drawing = obj.asDrawing() orelse return null;
                            return drawing.display_object;
                        }
                    };

                    const value_widget = try self.widget_factory.makeComboBox(
                        list_io.objectListRetriever(RetrieverCtx{}, self.app),
                        list_io.itListAction(&self.app.objects, &sphimp.object.Objects.idIter, .update_drawing_source),
                    );
                    errdefer value_widget.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, source_label, value_widget);
                }

                {
                    const source_label = try self.widget_factory.makeLabel("Brush");

                    const value_widget = try self.widget_factory.makeComboBox(
                        list_io.BrushRetriever.init(self.app),
                        list_io.itListAction(&self.app.brushes, &shader_storage.ShaderStorage(BrushId).idIter, .update_brush),
                    );
                    errdefer value_widget.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, source_label, value_widget);
                }

                const brush = self.app.brushes.get(d.brush);
                try addShaderParamsToPropertyList(
                    self.app,
                    property_list,
                    self.widget_factory,
                    brush.uniforms,
                );
            },
            .path => {
                const source_label = try self.widget_factory.makeLabel("Source object");
                errdefer source_label.deinit(self.widget_factory.alloc);

                const RetrieverCtx = struct {
                    pub fn selectedObject(_: @This(), a: *App) ?ObjectId {
                        var obj = a.selectedObject();
                        const path = obj.asPath() orelse return null;
                        return path.display_object;
                    }
                };

                const value_widget = try self.widget_factory.makeComboBox(
                    list_io.objectListRetriever(RetrieverCtx{}, self.app),
                    list_io.itListAction(&self.app.objects, &sphimp.object.Objects.idIter, .update_path_source),
                );

                errdefer value_widget.deinit(self.widget_factory.alloc);

                try property_list.pushWidgets(self.widget_factory.alloc, source_label, value_widget);
            },
            .text => |*t| {
                {
                    const key = try self.widget_factory.makeLabel("Text");
                    errdefer key.deinit(self.widget_factory.alloc);

                    const value_widget = try self.widget_factory.makeTextbox(
                        label_adaptors.TextObjectContent.init(self.app),
                        &UiAction.makeTextObjChange,
                    );
                    errdefer value_widget.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, key, value_widget);
                }

                {
                    const key = try self.widget_factory.makeLabel("Font");
                    errdefer key.deinit(self.widget_factory.alloc);

                    const value_widget = try self.widget_factory.makeComboBox(
                        list_io.FontRetriever{ .app = self.app },
                        list_io.itListAction(&self.app.fonts, &FontStorage.idIter, .update_selected_font),
                    );
                    errdefer value_widget.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, key, value_widget);
                }

                {
                    const key = try self.widget_factory.makeLabel("Font size");
                    errdefer key.deinit(self.widget_factory.alloc);

                    const value_widget = try self.widget_factory.makeDragFloat(
                        &t.renderer.point_size,
                        &UiAction.makeChangeTextSize,
                        0.05,
                    );
                    errdefer value_widget.deinit(self.widget_factory.alloc);

                    try property_list.pushWidgets(self.widget_factory.alloc, key, value_widget);
                }
            },
        }
    }
};

const Sidebar = struct {
    widget: gui.Widget(UiAction),
    handle: Handle,
};

pub fn makeSidebar(app: *App, widget_factory: *gui.widget_factory.WidgetFactory(UiAction)) !Sidebar {
    const sidebar_stack = try widget_factory.makeStack();
    errdefer sidebar_stack.deinit(widget_factory.alloc);

    const sidebar_width = 300;
    const sidebar_box = blk: {
        errdefer sidebar_stack.deinit(widget_factory.alloc);

        break :blk try widget_factory.makeBox(
            sidebar_stack.asWidget(),
            .{ .width = sidebar_width, .height = 0 },
            .fill_height,
        );
    };
    errdefer sidebar_box.deinit(widget_factory.alloc);

    const sidebar_background = try widget_factory.makeRect(
        gui.widget_factory.StyleColors.background_color,
    );

    try sidebar_stack.pushWidgetOrDeinit(
        widget_factory.alloc,
        sidebar_background,
        .{ .offset = .{ .x_offs = 0, .y_offs = 0 } },
    );

    const sidebar_layout = try widget_factory.makeEvenVertLayout();
    try sidebar_stack.pushWidgetOrDeinit(widget_factory.alloc, sidebar_layout.asWidget(), .centered);

    const obj_list = try makeObjList(app, widget_factory);
    try sidebar_layout.pushOrDeinitWidget(widget_factory.alloc, obj_list);

    const create_object = try makeCreateObject(app, widget_factory);
    try sidebar_layout.pushOrDeinitWidget(widget_factory.alloc, create_object);

    const properties = try makeObjectProperties(app, widget_factory);
    try sidebar_layout.pushOrDeinitWidget(widget_factory.alloc, properties.widget);

    var handle = Handle{
        .object_properties = properties.widget,
        .specific_object_properties = properties.specific_properties,

        .app = app,
        .widget_factory = widget_factory,
    };

    try handle.updateObjectProperties();

    return .{
        .widget = sidebar_box,
        .handle = handle,
    };
}
