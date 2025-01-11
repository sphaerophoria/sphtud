const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphtext = @import("sphtext");
const gui = @import("gui.zig");

pub fn widgetFactory(comptime Action: type, alloc: Allocator) !*WidgetFactory(Action) {
    const ret = try alloc.create(WidgetFactory(Action));
    errdefer alloc.destroy(ret);
    ret.alloc = alloc;

    const font_size = 11.0;
    ret.text_renderer = try sphtext.TextRenderer.init(alloc, font_size);
    errdefer ret.text_renderer.deinit(alloc);

    ret.distance_field_renderer = try sphrender.DistanceFieldGenerator.init();
    errdefer ret.distance_field_renderer.deinit();

    const font_data = @embedFile("res/Hack-Regular.ttf");
    ret.ttf = try sphtext.ttf.Ttf.init(alloc, font_data);
    errdefer ret.ttf.deinit(alloc);

    const unit: f32 = @floatFromInt(sphtext.ttf.lineHeightPx(ret.ttf, font_size));

    const layout_pad: u31 = @intFromFloat(unit / 3);
    ret.layout_pad = layout_pad;

    const widget_width: u31 = @intFromFloat(unit * 8);
    const typical_widget_height: u31 = @intFromFloat(unit * 1.3);
    const corner_radius: f32 = unit / 5;

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

    ret.squircle_renderer = try gui.SquircleRenderer.init();
    errdefer ret.squircle_renderer.deinit();

    ret.guitext_state = gui.gui_text.SharedState{
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

    ret.property_list_style = gui.property_list.Style{
        .value_width = widget_width,
        .item_pad = layout_pad,
    };

    ret.shared_color = try gui.color_picker.SharedColorPickerState.init(
        gui.color_picker.ColorStyle{
            .preview_width = widget_width,
            .preview_height = typical_widget_height,
            .popup_width = widget_width * 3 / 2,
            .popup_background = StyleColors.background_color3,
            .item_pad = layout_pad,
            .corner_radius = corner_radius,
        },
        &ret.drag_shared,
        &ret.guitext_state,
        &ret.squircle_renderer,
        &ret.frame_shared,
        &ret.property_list_style,
    );
    errdefer ret.shared_color.deinit();

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
    };

    ret.even_vert_layout_shared = gui.even_vert_layout.Shared{
        .corner_radius = 0,
        .border_size = @intFromFloat(unit / 2),
        .border_color = StyleColors.background_color3,
        .squircle_renderer = &ret.squircle_renderer,
    };

    ret.combo_box_shared = try gui.combo_box.Shared.init(
        .{
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
                .popup_height = @intFromFloat(unit * 10),
                .layout_pad = layout_pad,
            },
            .guitext_state = &ret.guitext_state,
            .scroll_style = &ret.scroll_style,
            .squircle_renderer = &ret.squircle_renderer,
            .selectable = &ret.shared_selecatble_list_state,
            .frame = &ret.frame_shared,
        },
    );
    errdefer ret.combo_box_shared.deinit(alloc);

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

    ret.overlay = gui.popup_layer.PopupLayer(Action){};

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

pub fn WidgetFactory(comptime Action: type) type {
    return struct {
        alloc: Allocator,

        layout_pad: u31,
        text_renderer: sphtext.TextRenderer,
        distance_field_renderer: sphrender.DistanceFieldGenerator,
        ttf: sphtext.ttf.Ttf,
        guitext_state: gui.gui_text.SharedState,
        drag_shared: gui.drag_float.Shared,
        shared_button_state: gui.button.SharedButtonState,
        squircle_renderer: gui.SquircleRenderer,
        scroll_style: gui.scrollbar.Style,
        shared_color: gui.color_picker.SharedColorPickerState,
        shared_textbox_state: gui.textbox.SharedTextboxState,
        shared_selecatble_list_state: gui.selectable_list.SharedState,
        frame_shared: gui.frame.Shared,
        even_vert_layout_shared: gui.even_vert_layout.Shared,
        property_list_style: gui.property_list.Style,
        combo_box_shared: gui.combo_box.Shared,
        checkbox_shared: gui.checkbox.Shared,
        overlay: gui.popup_layer.PopupLayer(Action),

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.text_renderer.deinit(self.alloc);
            self.distance_field_renderer.deinit();
            self.ttf.deinit(self.alloc);
            self.squircle_renderer.deinit();
            self.shared_color.deinit();
            self.overlay.reset();
            self.combo_box_shared.deinit();
            self.alloc.destroy(self);
        }

        pub fn makeLabel(self: *const Self, text_retriever: anytype) !gui.Widget(Action) {
            return gui.label.makeLabel(
                Action,
                self.alloc,
                text_retriever,
                &self.guitext_state,
            );
        }

        pub fn makeButton(self: *const Self, text_retriever: anytype, click_action: anytype) !gui.Widget(Action) {
            return gui.button.makeButton(
                Action,
                self.alloc,
                text_retriever,
                &self.shared_button_state,
                click_action,
            );
        }

        pub fn makeTextbox(self: *const Self, text_retriever: anytype, action: anytype) !gui.Widget(Action) {
            return gui.textbox.makeTextbox(
                Action,
                self.alloc,
                text_retriever,
                action,
                &self.shared_textbox_state,
            );
        }

        pub fn makeSelectableList(self: *const Self, retriever: anytype, action_gen: anytype) !gui.Widget(Action) {
            return gui.selectable_list.selectableList(
                Action,
                self.alloc,
                retriever,
                action_gen,
                &self.shared_selecatble_list_state,
            );
        }

        pub fn makeComboBox(self: *Self, retriever: anytype, on_select: anytype) !gui.Widget(Action) {
            return gui.combo_box.makeComboBox(Action, self.alloc, retriever, on_select, &self.overlay, &self.combo_box_shared);
        }

        pub fn makeColorPicker(self: *Self, retriever: anytype, action_gen: anytype) !gui.Widget(Action) {
            return gui.color_picker.makeColorPicker(
                Action,
                self.alloc,
                retriever,
                action_gen,
                &self.shared_color,
                &self.overlay,
            );
        }

        pub fn makeDragFloat(self: *Self, retriever: anytype, action_gen: anytype, drag_speed: f32) !gui.Widget(Action) {
            return gui.drag_float.dragFloat(
                Action,
                self.alloc,
                retriever,
                action_gen,
                drag_speed,
                &self.drag_shared,
            );
        }

        pub fn makeLayout(self: *Self) !*gui.layout.Layout(Action) {
            return gui.layout.Layout(Action).init(self.alloc, self.layout_pad);
        }

        pub fn makePropertyList(self: *Self) !*gui.property_list.PropertyList(Action) {
            return gui.property_list.PropertyList(Action).init(self.alloc, &self.property_list_style);
        }

        pub fn makeBox(self: *Self, inner: gui.Widget(Action), size: gui.PixelSize, fill_style: gui.box.FillStyle) !gui.Widget(Action) {
            return gui.box.box(Action, self.alloc, inner, size, fill_style);
        }

        pub fn makeFrame(self: *Self, inner: gui.Widget(Action)) !gui.Widget(Action) {
            return gui.frame.makeFrame(Action, self.alloc, .{
                .inner = inner,
                .shared = &self.frame_shared,
            });
        }

        pub fn makeScrollView(self: *Self, inner: gui.Widget(Action)) !gui.Widget(Action) {
            return gui.scroll_view.ScrollView(Action).init(self.alloc, inner, &self.scroll_style, &self.squircle_renderer);
        }

        pub fn makeEvenVertLayout(self: *Self) !*gui.even_vert_layout.EvenVertLayout(Action) {
            return try gui.even_vert_layout.EvenVertLayout(Action).init(
                self.alloc,
                &self.even_vert_layout_shared,
            );
        }

        pub fn makeStack(self: *Self) !*gui.stack.Stack(Action) {
            return gui.stack.Stack(Action).init(self.alloc);
        }

        pub fn makeRect(self: *Self, color: gui.Color) !gui.Widget(Action) {
            return gui.rect.Rect(Action).init(self.alloc, 1.0, color, &self.squircle_renderer);
        }

        pub fn makeCheckbox(self: *Self, checked: anytype, on_change: Action) !gui.Widget(Action) {
            return try gui.checkbox.makeCheckbox(Action, self.alloc, checked, on_change, &self.checkbox_shared);
        }

        pub fn makeRunnerOrDeinit(self: *Self, inner: gui.Widget(Action)) !gui.runner.Runner(Action) {
            const root_stack = blk: {
                errdefer inner.deinit(self.alloc);

                const root_stack = try self.makeStack();
                errdefer root_stack.deinit(self.alloc);

                try root_stack.pushWidgetOrDeinit(self.alloc, inner, .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });
                try root_stack.pushWidgetOrDeinit(self.alloc, self.overlay.asWidget(), .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });
                break :blk root_stack.asWidget();
            };

            return gui.runner.Runner(Action).init(self.alloc, root_stack);
        }
    };
}
