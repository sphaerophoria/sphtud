const gui = @import("../ui.zig");
const sphalloc = @import("../alloc.zig");

const Self = @This();

alloc: gui.GuiAlloc,
state: *gui.WidgetState,

pub const LabelOptions = struct {
    color: gui.Color = .white,
};

pub fn allocId(self: *const Self) usize {
    return self.state.id_alloc.allocOne();
}

pub fn makeLabel(self: *const Self, text: []const u8, options: LabelOptions) !*gui.Label {
    const ret = try self.alloc.heap.arena().create(gui.Label);
    ret.* = try .init(
        self.alloc,
        &self.state.label_shared,
        text,
        options.color,
    );
    return ret;
}

pub fn makeButton(self: *const Self, label: *gui.Widget, on_click: usize) !*gui.Button {
    const ret = try self.alloc.heap.arena().create(gui.Button);
    ret.* = try .init(label, on_click, &self.state.button_shared);
    return ret;
}

pub fn makeCheckbox(self: *const Self, checked: bool, on_toggle: usize) !*gui.Checkbox {
    const ret = try self.alloc.heap.arena().create(gui.Checkbox);
    ret.* = .init(checked, on_toggle, &self.state.checkbox_shared);
    return ret;
}

pub fn makeDrag(self: *const Self, label: *gui.Widget, on_drag: usize) !*gui.Drag {
    const ret = try self.alloc.heap.arena().create(gui.Drag);
    ret.* = .init(label, on_drag, &self.state.drag_shared);
    return ret;
}

pub fn makeDragF32(self: *const Self, initial_val: f32, on_change: usize) !gui.DragF32 {
    const label = try self.makeLabel("", .{});
    const drag = try self.makeDrag(&label.widget, on_change);
    return try .init(label, drag, initial_val);
}

pub fn makeDragI32(self: *const Self, initial_val: i32, on_change: usize) !gui.DragI32 {
    const label = try self.makeLabel("", .{});
    const drag = try self.makeDrag(&label.widget, on_change);
    return try .init(label, drag, initial_val);
}

pub fn makeHistogram(self: *const Self, label: *gui.Widget) !*gui.Histogram {
    const ret = try self.alloc.heap.arena().create(gui.Histogram);
    ret.* = try .init(self.alloc, &self.state.histogram_shared, label);
    return ret;
}

pub fn makeBox(self: *const Self, inner: *gui.Widget, size: gui.PixelSize, fill_style: gui.Box.FillStyle) !*gui.Box {
    const ret = try self.alloc.heap.arena().create(gui.Box);
    ret.* = .init(
        inner,
        size,
        fill_style,
    );
    return ret;
}

pub fn makeLayout(self: *const Self) !*gui.Layout {
    const ret = try self.alloc.heap.arena().create(gui.Layout);
    ret.* = try .init(
        self.alloc.heap.arena(),
        self.alloc.heap.expansion(),
        self.state.layout_pad,
    );
    return ret;
}

pub fn makeSelectableList(self: *const Self, on_click: usize) !*gui.SelectableList {
    const ret = try self.alloc.heap.arena().create(gui.SelectableList);
    ret.* = .init(on_click, &self.state.selectable_list_shared);
    return ret;
}

pub fn makeScrollView(self: *const Self, inner: *gui.Widget) !*gui.ScrollView {
    const ret = try self.alloc.heap.arena().create(gui.ScrollView);

    ret.* = .init(
        inner,
        &self.state.scroll_shared,
    );
    return ret;
}

pub fn makeComboBox(self: *const Self, preview: *gui.Widget, content: *gui.Widget) !*gui.ComboBox {
    const ret = try self.alloc.heap.arena().create(gui.ComboBox);
    ret.initPinned(preview, content, &self.state.combo_box_shared);
    return ret;
}

pub fn makeRect(self: *const Self, color: gui.Color) !*gui.Rect {
    const ret = try self.alloc.heap.arena().create(gui.Rect);
    ret.* = .init(color, self.state.corner_radius, &self.state.squircle_renderer);
    return ret;
}

pub fn makeFrame(self: *const Self, inner: *gui.Widget) !*gui.Frame {
    const ret = try self.alloc.heap.arena().create(gui.Frame);
    ret.* = .init(inner, self.state.layout_pad);
    return ret;
}

pub fn makeStack(self: *const Self, items: []const gui.Stack.StackItem) !*gui.Stack {
    const ret = try self.alloc.heap.arena().create(gui.Stack);
    ret.* = .init(items);
    return ret;
}

pub fn makeColorPicker(self: *const Self, initial_color: gui.Color, on_change: usize) !*gui.ColorPicker {
    const ret = try self.alloc.heap.arena().create(gui.ColorPicker);
    try ret.initPinned(self.alloc, initial_color, on_change, &self.state.color_picker_shared);
    return ret;
}

pub fn makeInteractable(self: *const Self, inner: *gui.Widget, on_click: usize) !*gui.Interactable {
    const ret = try self.alloc.heap.arena().create(gui.Interactable);
    ret.* = .init(inner, on_click, &self.state.event_queue);
    return ret;
}

pub fn makeMemoryWidget(self: *const Self, memory_tracker: *const sphalloc.MemoryTracker) !*gui.MemoryWidget {
    return gui.MemoryWidget.init(self.alloc, memory_tracker, &self.state.memory_widget_shared);
}

pub fn makeGrid(self: *const Self, columns: []const gui.Grid.ColumnConfig) !*gui.Grid {
    const ret = try self.alloc.heap.arena().create(gui.Grid);
    ret.* = try .init(
        self.alloc.heap.arena(),
        self.alloc.heap.expansion(),
        columns,
        self.state.layout_pad,
    );
    return ret;
}

pub fn makeTextbox(self: *const Self, on_change: usize) !*gui.Textbox {
    const ret = try self.alloc.heap.arena().create(gui.Textbox);
    ret.* = try .init(self.alloc, self.alloc.heap.general(), on_change, &self.state.textbox_shared);
    return ret;
}

pub fn makeThumbnail(self: *const Self) !*gui.Thumbnail {
    const ret = try self.alloc.heap.arena().create(gui.Thumbnail);
    ret.* = .init(&self.state.thumbnail_shared);
    return ret;
}

pub fn makeColorableFrame(self: *const Self, inner: *gui.Widget) !*gui.ColorableFrame {
    const ret = try self.alloc.heap.arena().create(gui.ColorableFrame);
    ret.* = .init(inner, &self.state.color_frame_shared);
    return ret;
}

pub fn makeOneOf(self: *const Self, options: []*gui.Widget) !*gui.OneOf {
    const ret = try self.alloc.heap.arena().create(gui.OneOf);
    ret.* = try .init(options);
    return ret;
}

pub fn makeRunner(self: *const Self, inner: *gui.Widget) !*gui.Runner {
    const root_stack = try self.makeStack(try self.alloc.heap.arena().dupe(gui.Stack.StackItem, &.{
        .{ .widget = inner },
        .{ .widget = &self.state.popup_layer.widget },
        .{ .widget = &self.state.drag_layer.widget },
    }));

    const ret = try self.alloc.heap.arena().create(gui.Runner);
    ret.* = try gui.Runner.init(self.alloc.heap.general(), &root_stack.widget);
    return ret;
}

pub fn makeCentered(self: *const Self, inner: *gui.Widget) !*gui.Centered {
    const ret = try self.alloc.heap.arena().create(gui.Centered);
    ret.* = gui.Centered.init(inner);
    return ret;
}
