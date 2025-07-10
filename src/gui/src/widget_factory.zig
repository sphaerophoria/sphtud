const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphtext = @import("sphtext");
const gui = @import("gui.zig");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const GlAlloc = sphrender.GlAlloc;

pub fn widgetState(comptime Action: type, gui_alloc: gui.GuiAlloc, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc) !*WidgetState(Action) {
    const arena = gui_alloc.heap.arena();
    const gpa = gui_alloc.heap.general();
    const ret = try arena.create(WidgetState(Action));

    const font_size = 11.0;
    ret.text_renderer = try sphtext.TextRenderer.init(gpa, gui_alloc.gl, font_size);

    ret.distance_field_renderer = try sphrender.DistanceFieldGenerator.init(gui_alloc.gl);

    const font_data = @embedFile("res/Hack-Regular.ttf");
    ret.ttf = try sphtext.ttf.Ttf.init(gpa, font_data);

    const unit: f32 = @floatFromInt(sphtext.ttf.lineHeightPx(ret.ttf, font_size));

    const layout_pad: u31 = @intFromFloat(unit / 3);
    ret.layout_pad = layout_pad;

    const widget_width: u31 = @intFromFloat(unit * 8);
    ret.widget_width = widget_width;
    const typical_widget_height: u31 = @intFromFloat(unit * 1.3);
    const corner_radius: f32 = unit / 5;
    ret.corner_radius = corner_radius;

    ret.drag_shared = gui.drag_float.Shared{
        .style = .{
            .size = .{
                .width = widget_width,
                .height = typical_widget_height,
            },
            .corner_radius = corner_radius,
            .default_color = StyleColors.default_color,
            .hover_color = StyleColors.hover_color,
            .active_color = StyleColors.active_color,
        },
        .guitext_state = &ret.guitext_state,
        .squircle_renderer = &ret.squircle_renderer,
    };

    ret.squircle_renderer = try gui.SquircleRenderer.init(gui_alloc.gl);

    ret.image_renderer = try sphrender.xyuvt_program.ImageRenderer.init(gui_alloc.gl, .rgba);

    ret.guitext_state = gui.gui_text.SharedState{
        .scratch_alloc = scratch_alloc,
        .scratch_gl = scratch_gl,
        .ttf = &ret.ttf,
        .text_renderer = &ret.text_renderer,
        .distance_field_generator = &ret.distance_field_renderer,
    };

    ret.shared_button_state = gui.button.SharedButtonState{
        .text_shared = &ret.guitext_state,
        .style = .{
            .default_color = StyleColors.default_color,
            .hover_color = StyleColors.hover_color,
            .click_color = StyleColors.active_color,
            .width = widget_width,
            .height = typical_widget_height,
            .corner_radius = corner_radius,
        },
        .squircle_renderer = &ret.squircle_renderer,
    };

    ret.scroll_style = gui.scrollbar.Style{
        .default_color = StyleColors.default_color,
        .hover_color = StyleColors.hover_color,
        .active_color = StyleColors.active_color,
        .gutter_color = StyleColors.background_color2,
        .corner_radius = corner_radius,
        .width = @intFromFloat(unit * 0.75),
    };

    ret.shared_color = try gui.color_picker.SharedColorPickerState.init(
        gui_alloc.gl,
        gui.color_picker.ColorStyle{
            .preview_width = widget_width,
            .preview_height = typical_widget_height,
            .popup_width = widget_width * 3 / 2,
            .popup_background = StyleColors.background_color3,
            .item_pad = layout_pad,
            .corner_radius = corner_radius,
            .grid_content_width = widget_width,
        },
        &ret.drag_shared,
        &ret.guitext_state,
        &ret.squircle_renderer,
        &ret.frame_shared,
    );

    ret.shared_textbox_state = gui.textbox.SharedTextboxState{
        .squircle_renderer = &ret.squircle_renderer,
        .guitext_shared = &ret.guitext_state,
        .style = .{
            .cursor_width = @intFromFloat(unit * 0.1),
            .cursor_height = @intFromFloat(unit * 0.9),
            .corner_radius = corner_radius,
            .cursor_color = gui.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
            .left_edge_pad = layout_pad,
            .background_color = StyleColors.default_color,
            .size = .{
                .width = widget_width,
                .height = typical_widget_height,
            },
        },
    };

    ret.shared_selecatble_list_state = gui.selectable_list.SharedState{
        .gui_text_state = &ret.guitext_state,
        .squircle_renderer = &ret.squircle_renderer,
        .style = .{
            .highlight_color = StyleColors.default_color,
            .hover_color = StyleColors.hover_color,
            .background_color = StyleColors.background_color2,
            .corner_radius = corner_radius,
            .item_pad = layout_pad,
            .min_item_height = @intFromFloat(unit),
        },
    };

    ret.frame_shared = gui.frame.Shared{
        .border_size = layout_pad,
        .inner_border_size = layout_pad / 5,
        .squircle_renderer = &ret.squircle_renderer,
    };

    ret.combo_box_shared = try gui.combo_box.Shared(Action).init(
        .{
            .gl_alloc = gui_alloc.gl,
            .style = .{
                .background = StyleColors.default_color,
                .hover_background = StyleColors.hover_color,
                .click_background = StyleColors.active_color,
                .popup_background = StyleColors.background_color3,
                .corner_radius = corner_radius,
                .box_width = widget_width,
                .triangle_width = typical_widget_height / 3,
                .triangle_height = typical_widget_height / 3,
                .triangle_color = gui.Color{ .r = 1, .g = 1, .b = 1, .a = 1 },
                .box_height = typical_widget_height,
                .popup_width = widget_width * 2,
                .popup_height = @intFromFloat(unit * 20),
                .layout_pad = layout_pad,
            },
            .guitext_state = &ret.guitext_state,
            .scroll_style = &ret.scroll_style,
            .squircle_renderer = &ret.squircle_renderer,
            .selectable = &ret.shared_selecatble_list_state,
            .frame = &ret.frame_shared,
            .popup_layer = &ret.overlay,
        },
    );

    ret.checkbox_shared = gui.checkbox.Shared{
        .style = .{
            .outer_size = typical_widget_height,
            .inner_size = typical_widget_height * 4 / 5,
            .corner_radius = corner_radius,
            .outer_color = StyleColors.background_color2,
            .outer_hover_color = StyleColors.background_color4,
            .inner_color = StyleColors.default_color,
            .inner_hover_color = StyleColors.hover_color,
        },
        .squircle_renderer = &ret.squircle_renderer,
    };

    ret.memory_widget_shared = try gui.memory_widget.Shared.init(
        gui_alloc.gl,
        scratch_alloc,
        widget_width,
        layout_pad,
        &ret.guitext_state,
        &ret.scroll_style,
        &ret.squircle_renderer,
    );

    ret.thumbnail_shared = .{
        .image_renderer = &ret.image_renderer,
    };

    ret.drag_layer = gui.drag_layer.DragLayer(Action){};

    ret.interactable_shared = gui.interactable.Shared(Action){
        .drag_layer = &ret.drag_layer,
    };

    ret.overlay = gui.popup_layer.PopupLayer(Action){
        .alloc = try gui_alloc.makeSubAlloc("overlay"),
    };

    return ret;
}

pub const StyleColors = struct {
    pub const default_color = gui.Color{ .r = 0.40, .g = 0.38, .b = 0.44, .a = 1.0 };
    pub const hover_color = hoverColor(default_color);
    pub const active_color = activeColor(default_color);
    pub const background_color = gui.Color{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 };
    pub const background_color2 = gui.Color{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
    pub const background_color3 = gui.Color{ .r = 0.15, .g = 0.15, .b = 0.15, .a = 1.0 };
    pub const background_color4 = gui.Color{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };

    pub fn hoverColor(default: gui.Color) gui.Color {
        return .{
            .r = default.r * 3.0 / 2.0,
            .g = default.g * 3.0 / 2.0,
            .b = default.b * 3.0 / 2.0,
            .a = default.a,
        };
    }

    pub fn activeColor(default: gui.Color) gui.Color {
        return .{
            .r = default.r * 4.0 / 2.0,
            .g = default.g * 4.0 / 2.0,
            .b = default.b * 4.0 / 2.0,
            .a = default.a,
        };
    }
};

pub fn WidgetState(comptime Action: type) type {
    return struct {
        layout_pad: u31,
        widget_width: u31,
        corner_radius: f32,
        text_renderer: sphtext.TextRenderer,
        distance_field_renderer: sphrender.DistanceFieldGenerator,
        ttf: sphtext.ttf.Ttf,
        guitext_state: gui.gui_text.SharedState,
        drag_shared: gui.drag_float.Shared,
        shared_button_state: gui.button.SharedButtonState,
        squircle_renderer: gui.SquircleRenderer,
        image_renderer: sphrender.xyuvt_program.ImageRenderer,
        scroll_style: gui.scrollbar.Style,
        shared_color: gui.color_picker.SharedColorPickerState,
        shared_textbox_state: gui.textbox.SharedTextboxState,
        shared_selecatble_list_state: gui.selectable_list.SharedState,
        frame_shared: gui.frame.Shared,
        combo_box_shared: gui.combo_box.Shared(Action),
        checkbox_shared: gui.checkbox.Shared,
        memory_widget_shared: gui.memory_widget.Shared,
        thumbnail_shared: gui.thumbnail.Shared,
        drag_layer: gui.drag_layer.DragLayer(Action),
        interactable_shared: gui.interactable.Shared(Action),
        overlay: gui.popup_layer.PopupLayer(Action),

        const Self = @This();

        pub fn factory(self: *Self, alloc: gui.GuiAlloc) WidgetFactory(Action) {
            return .{
                .state = self,
                .alloc = alloc,
            };
        }
    };
}

pub fn WidgetFactory(comptime Action: type) type {
    return struct {
        const Self = @This();

        alloc: gui.GuiAlloc,
        state: *WidgetState(Action),

        pub fn makeLabel(self: *const Self, text_retriever: anytype) !gui.Widget(Action) {
            return gui.label.makeLabel(
                Action,
                self.alloc,
                text_retriever,
                &self.state.guitext_state,
            );
        }

        pub fn makeButton(self: *const Self, text_retriever: anytype, click_action: anytype) !gui.Widget(Action) {
            return gui.button.makeButton(
                Action,
                self.alloc,
                text_retriever,
                &self.state.shared_button_state,
                click_action,
            );
        }

        pub fn makeTextbox(self: *const Self, text_retriever: anytype, action: anytype) !gui.Widget(Action) {
            return gui.textbox.makeTextbox(
                Action,
                self.alloc,
                text_retriever,
                action,
                &self.state.shared_textbox_state,
            );
        }

        pub fn makeSelectableList(self: *const Self, retriever: anytype, action_gen: anytype) !gui.Widget(Action) {
            return gui.selectable_list.selectableList(
                Action,
                self.alloc,
                retriever,
                action_gen,
                &self.state.shared_selecatble_list_state,
            );
        }

        pub fn makeComboBox(self: *const Self, preview: gui.Widget(Action), on_click: anytype) !gui.Widget(Action) {
            return gui.combo_box.makeComboBox(
                Action,
                self.alloc,
                preview,
                on_click,
                &self.state.combo_box_shared,
            );
        }

        pub fn makeColorPicker(self: *const Self, retriever: anytype, action_gen: anytype) !gui.Widget(Action) {
            return gui.color_picker.makeColorPicker(
                Action,
                self.alloc,
                retriever,
                action_gen,
                &self.state.shared_color,
                &self.state.overlay,
            );
        }

        pub fn makeDragFloat(self: *const Self, retriever: anytype, action_gen: anytype, drag_speed: f32) !gui.Widget(Action) {
            return gui.drag_float.dragFloat(
                Action,
                self.alloc,
                retriever,
                action_gen,
                drag_speed,
                &self.state.drag_shared,
            );
        }

        pub fn makeLayout(self: *const Self) !*gui.layout.Layout(Action) {
            return gui.layout.Layout(Action).init(self.alloc.heap.arena(), self.state.layout_pad);
        }

        pub fn makePropertyList(self: *const Self, max_size: usize) !*gui.grid.Grid(Action) {
            return self.makeGrid(
                &.{
                    .{
                        .width = .{ .ratio = 1.0 },
                        .horizontal_justify = .left,
                        .vertical_justify = .center,
                    },
                    .{
                        .width = .{ .fixed = self.state.widget_width },
                        .horizontal_justify = .center,
                        .vertical_justify = .center,
                    },
                },
                max_size,
                max_size,
            );
        }

        pub fn makeBox(self: *const Self, inner: gui.Widget(Action), size: gui.PixelSize, fill_style: gui.box.FillStyle) !gui.Widget(Action) {
            return gui.box.box(Action, self.alloc.heap.arena(), inner, size, fill_style);
        }

        pub fn makeFrame(self: *const Self, inner: gui.Widget(Action)) !gui.Widget(Action) {
            return gui.frame.makeFrame(Action, self.alloc.heap.arena(), .{
                .inner = inner,
                .shared = &self.state.frame_shared,
            });
        }

        pub fn makeColorableFrame(
            self: *const Self,
            inner: gui.Widget(Action),
            retriever: anytype,
        ) !gui.Widget(Action) {
            return gui.frame.makeColorableFrame(
                Action,
                self.alloc.heap.arena(),
                inner,
                retriever,
                &self.state.frame_shared,
            );
        }

        pub fn makeScrollView(self: *const Self, inner: gui.Widget(Action)) !gui.Widget(Action) {
            return gui.scroll_view.ScrollView(Action).init(self.alloc.heap.arena(), inner, &self.state.scroll_style, &self.state.squircle_renderer);
        }

        pub fn makeEvenVertLayout(self: *const Self, max_size: comptime_int) !*gui.even_vert_layout.EvenVertLayout(Action, max_size) {
            return try gui.even_vert_layout.EvenVertLayout(Action, max_size).init(
                self.alloc.heap.arena(),
                &self.state.even_vert_layout_shared,
            );
        }

        pub fn makeStack(self: *const Self, max_elems: comptime_int) !*gui.stack.Stack(Action, max_elems) {
            return gui.stack.Stack(Action, max_elems).init(self.alloc.heap.arena());
        }

        pub fn makeGrid(
            self: *const Self,
            columns: []const gui.grid.ColumnConfig,
            typical_elems: usize,
            max_elems: usize,
        ) !*gui.grid.Grid(Action) {
            return gui.grid.Grid(Action).init(
                self.alloc.heap,
                columns,
                self.state.layout_pad,
                typical_elems,
                max_elems,
            );
        }

        pub fn makeRect(self: *const Self, color: anytype, corner_radius: f32) !gui.Widget(Action) {
            return gui.rect.Rect(Action, @TypeOf(color)).init(self.alloc.heap.arena(), corner_radius, color, &self.state.squircle_renderer);
        }

        pub fn makeCheckbox(self: *const Self, checked: anytype, on_change: Action) !gui.Widget(Action) {
            return try gui.checkbox.makeCheckbox(Action, self.alloc.heap.arena(), checked, on_change, &self.state.checkbox_shared);
        }

        pub fn makeOneOf(self: *const Self, retriever: anytype, options: []const gui.Widget(Action)) !gui.Widget(Action) {
            return try gui.one_of.oneOf(Action, self.alloc.heap.arena(), retriever, options);
        }

        pub fn makeRunner(self: *const Self, inner: gui.Widget(Action)) !gui.runner.Runner(Action) {
            const root_stack = try self.makeStack(3);
            try root_stack.pushWidget(inner, .{});
            try root_stack.pushWidget(self.state.overlay.asWidget(), .{});
            try root_stack.pushWidget(self.state.drag_layer.asWidget(), .{});

            return gui.runner.Runner(Action).init(self.alloc.heap.general(), root_stack.asWidget());
        }

        pub fn makeMemoryWidget(self: *const Self, memory_tracker: *const sphalloc.MemoryTracker) !gui.Widget(Action) {
            return gui.memory_widget.makeMemoryWidget(Action, self.alloc, memory_tracker, &self.state.memory_widget_shared);
        }

        pub fn makeThumbnail(self: *const Self, retriever: anytype) !gui.Widget(Action) {
            return gui.thumbnail.makeThumbnail(
                Action,
                self.alloc.heap.arena(),
                retriever,
                &self.state.thumbnail_shared,
            );
        }

        pub fn makeInteractable(self: *const Self, inner: gui.Widget(Action), click_action: Action, drag_action: ?Action) !gui.Widget(Action) {
            return gui.interactable.interactable(
                Action,
                self.alloc.heap.arena(),
                inner,
                click_action,
                drag_action,
                &self.state.interactable_shared,
            );
        }
    };
}
