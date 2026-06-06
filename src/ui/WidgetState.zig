const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("../render.zig");
const sphtext = @import("../text.zig");
const gui = @import("../ui.zig");
const sphalloc = @import("../alloc.zig");
const ScratchAlloc = sphalloc.ScratchAlloc;
const GlAlloc = sphrender.GlAlloc;

layout_pad: u31,
widget_width: u31,
corner_radius: f32,
text_renderer: sphtext.TextRenderer,
distance_field_renderer: sphrender.DistanceFieldGenerator,
ttf: sphtext.ttf.Ttf,
label_shared: gui.Label.SharedState,
drag_shared: gui.Drag.Shared,
button_shared: gui.Button.Shared,
squircle_renderer: gui.SquircleRenderer,
image_renderer: sphrender.xyuvt_program.ImageRenderer,
scroll_shared: gui.scrollbar.Shared,
checkbox_shared: gui.Checkbox.Shared,
histogram_shared: gui.Histogram.Shared,
selectable_list_shared: gui.SelectableList.Shared,
popup_layer: gui.PopupLayer,
drag_layer: gui.DragLayer,
color_frame_shared: gui.ColorableFrame.Shared,
combo_box_shared: gui.ComboBox.Shared,
color_picker_shared: gui.ColorPicker.Shared,
event_queue: gui.EventQueue,
memory_widget_shared: gui.MemoryWidget.Shared,
thumbnail_shared: gui.Thumbnail.Shared,
textbox_shared: gui.Textbox.Shared,

const WidgetState = @This();

pub const WidgetStateOptions = struct {
    font_size: f32 = 11.0,
};

pub fn init(gui_alloc: gui.GuiAlloc, scratch_alloc: *ScratchAlloc, scratch_gl: *GlAlloc, options: WidgetStateOptions) !*WidgetState {
    const arena = gui_alloc.heap.arena();
    const gpa = gui_alloc.heap.general();

    const ret = try arena.create(WidgetState);

    ret.event_queue = .initBuffer(try arena.alloc(usize, 128));

    ret.text_renderer = try sphtext.TextRenderer.init(gpa, gui_alloc.gl, options.font_size);

    ret.distance_field_renderer = try sphrender.DistanceFieldGenerator.init(gui_alloc.gl);

    const font_data = @embedFile("res/Hack-Regular.ttf");
    ret.ttf = try sphtext.ttf.Ttf.init(gpa, font_data);

    const unit: f32 = @floatFromInt(sphtext.ttf.lineHeightPx(ret.ttf, options.font_size));

    const layout_pad: u31 = @intFromFloat(unit / 3);
    ret.layout_pad = layout_pad;

    const widget_width: u31 = @intFromFloat(unit * 8);
    ret.widget_width = widget_width;
    const typical_widget_height: u31 = @intFromFloat(unit * 1.3);
    const corner_radius: f32 = unit / 5;
    ret.corner_radius = corner_radius;

    ret.drag_shared = gui.Drag.Shared{
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
        .squircle_renderer = &ret.squircle_renderer,
        .event_queue = &ret.event_queue,
    };

    ret.squircle_renderer = try gui.SquircleRenderer.init(gui_alloc.gl);

    ret.image_renderer = try sphrender.xyuvt_program.ImageRenderer.init(gui_alloc.gl, .rgba);

    ret.label_shared = gui.Label.SharedState{
        .scratch_alloc = scratch_alloc,
        .scratch_gl = scratch_gl,
        .ttf = &ret.ttf,
        .text_renderer = &ret.text_renderer,
        .distance_field_generator = &ret.distance_field_renderer,
    };

    ret.button_shared = gui.Button.Shared{
        .style = .{
            .default_color = StyleColors.default_color,
            .hover_color = StyleColors.hover_color,
            .click_color = StyleColors.active_color,
            .width = widget_width,
            .height = typical_widget_height,
            .corner_radius = corner_radius,
        },
        .squircle_renderer = &ret.squircle_renderer,
        .event_queue = &ret.event_queue,
    };

    ret.scroll_shared = gui.scrollbar.Shared{
        .renderer = &ret.squircle_renderer,
        .style = .{
            .default_color = StyleColors.default_color,
            .hover_color = StyleColors.hover_color,
            .active_color = StyleColors.active_color,
            .gutter_color = StyleColors.background_color2,
            .corner_radius = corner_radius,
            .width = @intFromFloat(unit * 0.75),
        },
    };

    ret.checkbox_shared = gui.Checkbox.Shared{
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
        .event_queue = &ret.event_queue,
    };

    ret.histogram_shared = try gui.Histogram.Shared.init(
        gui_alloc.gl,
        scratch_alloc,
        StyleColors.default_color,
        StyleColors.hover_color,
    );

    ret.selectable_list_shared = gui.SelectableList.Shared{
        .squircle_renderer = &ret.squircle_renderer,
        .event_queue = &ret.event_queue,
        .style = .{
            .highlight_color = StyleColors.default_color,
            .hover_color = StyleColors.hover_color,
            .background_color = StyleColors.background_color2,
            .corner_radius = corner_radius,
            .item_pad = layout_pad,
            .min_item_height = @intFromFloat(unit),
        },
    };

    ret.popup_layer = gui.PopupLayer.init();
    ret.drag_layer = gui.DragLayer.init();

    ret.color_frame_shared = .{
        .border_size = layout_pad,
        .inner_border_size = @max(1, layout_pad / 4),
        .squircle_renderer = &ret.squircle_renderer,
    };

    ret.combo_box_shared = try gui.ComboBox.Shared.init(
        gui_alloc.gl,
        &ret.squircle_renderer,
        &ret.popup_layer,
        &ret.scroll_shared,
        .{
            .default_color = StyleColors.default_color,
            .hover_color = StyleColors.hover_color,
            .click_color = StyleColors.active_color,
            .popup_background = StyleColors.background_color2,
            .corner_radius = corner_radius,
            .width = widget_width,
            .height = typical_widget_height,
            .triangle_width = @intFromFloat(unit * 0.5),
            .triangle_height = @intFromFloat(unit * 0.5),
            .triangle_color = .white,
            .layout_pad = layout_pad,
            .popup_max_height = @intFromFloat(unit * 10),
        },
    );

    ret.memory_widget_shared = try gui.MemoryWidget.Shared.init(
        gui_alloc.gl,
        scratch_alloc,
        &ret.label_shared,
        &ret.scroll_shared,
        ret.widget_width,
        layout_pad,
        @intFromFloat(unit * 5.0),
        300,
    );

    ret.thumbnail_shared = .{
        .image_renderer = &ret.image_renderer,
    };

    ret.textbox_shared = .{
        .label_shared = &ret.label_shared,
        .squircle_renderer = &ret.squircle_renderer,
        .event_queue = &ret.event_queue,
        .style = .{
            .background_color = StyleColors.background_color2,
            .width = widget_width,
            .height = typical_widget_height,
            .left_pad = layout_pad,
            .corner_radius = corner_radius,
            .cursor_color = .white,
        },
    };

    ret.color_picker_shared = try gui.ColorPicker.Shared.init(
        gui_alloc.gl,
        &ret.squircle_renderer,
        &ret.popup_layer,
        &ret.event_queue,
        &ret.drag_shared,
        &ret.label_shared,
        .{
            .preview_width = typical_widget_height,
            .preview_height = typical_widget_height,
            .popup_width = widget_width * 2,
            .popup_background = StyleColors.background_color2,
            .corner_radius = corner_radius,
            .item_pad = layout_pad,
            .hex_preview_height = typical_widget_height,
            .slider_height = typical_widget_height,
        },
    );

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
