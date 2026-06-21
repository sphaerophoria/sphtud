const std = @import("std");
const sphtud = @import("sphtud");
const sphtext = sphtud.text;
const sphrender = sphtud.render;
const gui = sphtud.ui;
const RuntimeSegmentedList = sphtud.util.RuntimeSegmentedList;
const TextRenderer = sphtud.text.TextRenderer;
const gl = sphtud.render.gl;
const sphalloc = sphtud.alloc;
const ScratchAlloc = sphalloc.ScratchAlloc;
const GlAlloc = sphtud.render.GlAlloc;
const Layout = gui.Layout2;

fn standardNormalVal(z: f32) f32 {
    return std.math.pow(f32, std.math.e, -z * z / 2) / std.math.sqrt(2 * std.math.pi);
}

fn generateStandardDist(out: []f32) void {
    var center: f32 = @floatFromInt(out.len);
    center /= 2;

    // We want a bell curve with ~ 3 standard deviations filling output buffer
    // Thus standard deviation should be 1/6th of output len

    var stddev: f32 = @floatFromInt(out.len);
    stddev /= 6;

    for (out, 0..) |*val, i| {
        const i_f: f32 = @floatFromInt(i);
        val.* = standardNormalVal((i_f - center) / stddev) / stddev;
    }
}

pub const SelectableListOptions = enum {
    first,
    second,
    third,
    fourth,
};

const grid_columns = [_]gui.Grid.ColumnConfig{
    .{ .width = .{ .fixed = 100 }, .horizontal_justify = .left, .vertical_justify = .center },
    .{ .width = .{ .ratio = 1 }, .horizontal_justify = .right, .vertical_justify = .center },
};

const Ids = struct {
    button_click: usize,
    checkbox_toggle: usize,
    want_checkbox_toggle: usize,
    drag_start: usize,
    on_drag: usize,
    combo_select: usize,
    color_change: usize,
    textbox_change: usize,
    thumbnail_drag_start: usize,

    fn init() Ids {
        var alloc = sphtud.util.IdAlloc.init;
        return .{
            .button_click = alloc.allocOne(),
            .checkbox_toggle = alloc.allocOne(),
            .want_checkbox_toggle = alloc.allocOne(),
            .drag_start = alloc.allocOne(),
            .on_drag = alloc.allocOne(),
            .combo_select = alloc.allocOne(),
            .color_change = alloc.allocOne(),
            .textbox_change = alloc.allocOne(),
            .thumbnail_drag_start = alloc.allocOne(),
        };
    }
};

const ids = Ids.init();

pub const CustomWidget = struct {
    render_source: sphrender.xyuvt_program.RenderSource,
    program: sphrender.xyuvt_program.Program(Uniforms),
    hover_state: enum {
        default,
        hovered,
    } = .default,
    widget: gui.Widget,

    const Uniforms = struct {
        transform: sphtud.math.Mat3x3,
        max_color: sphtud.math.Vec3,
    };

    pub const frag =
        \\#version 330
        \\in vec2 uv;
        \\out vec4 fragment;
        \\uniform vec3 max_color;
        \\void main()
        \\{
        \\    vec3 black = vec3(0.0, 0.0, 0.0);
        \\    fragment = vec4(mix(black, max_color, uv.x), 1.0);
        \\}
    ;

    pub fn init(alloc: sphrender.RenderAlloc) !CustomWidget {
        const program = try sphrender.xyuvt_program.Program(Uniforms).init(alloc.gl, frag);
        var render_source = try sphrender.xyuvt_program.RenderSource.init(alloc.gl);
        render_source.bindData(program.handle(), try sphrender.xyuvt_program.makeFullScreenPlane(alloc.gl));

        return .{
            .program = program,
            .render_source = render_source,
            .widget = .{
                .size = .{
                    .width = 300,
                    .height = 300,
                },
                .focused = false,
                .vtable = &.{
                    .render = render,
                    .input = input,
                    .update = null,
                    .reset = null,
                },
            },
        };
    }

    pub fn render(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const self: *CustomWidget = @fieldParentPtr("widget", widget);

        const max_color: sphtud.math.Vec3 = switch (self.hover_state) {
            .default => .{ 1.0, 0.0, 0.0 },
            .hovered => .{ 0.0, 1.0, 0.0 },
        };

        const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);
        self.program.render(self.render_source, .{
            .transform = transform.inner,
            .max_color = max_color,
        });
    }

    pub fn input(widget: *gui.Widget, _: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) !void {
        const self: *CustomWidget = @fieldParentPtr("widget", widget);

        if (input_bounds.containsMousePos(input_state.mouse_pos)) {
            self.hover_state = .hovered;
        } else {
            self.hover_state = .default;
        }
    }
};
const Gui = struct {
    events: *gui.EventQueue,

    thumbnail: *gui.Thumbnail,
    thumbnail_box: *gui.Box,
    textbox: *gui.Textbox,
    textbox_mirror: *gui.Label,
    button_label: *gui.Label,
    button: *gui.Button,
    drag: *gui.Drag,
    drag_text: *gui.Label,
    checkbox: *gui.Checkbox,
    checkbox_text: *gui.Label,
    checkbox_frame: *gui.ColorableFrame,
    histogram: *gui.Histogram,
    histogram_label: *gui.Label,
    combo_preview: *gui.Label,
    combo_popup_list: *gui.SelectableList,
    color_picker: *gui.ColorPicker,
    color_label: *gui.Label,
    grid: *gui.Grid,
    grid_labels: [3]*gui.Label,
    one_of: *gui.OneOf,
    memory_widget: *gui.MemoryWidget,
    popup_layer: *gui.PopupLayer,
    drag_layer: *gui.DragLayer,
    time_label: *gui.Label,
    runner: *gui.Runner,

    pub fn init(allocators: *sphtud.render.AppAllocators, memory_tracker: *const sphtud.alloc.MemoryTracker) !Gui {
        const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

        var ret: Gui = undefined;

        const gui_state = try gui.WidgetState.init(
            gui_alloc,
            &allocators.scratch,
            &allocators.scratch_gl,
            .{},
        );

        const wf = gui.WidgetFactory{
            .alloc = gui_alloc,
            .state = gui_state,
        };

        var root_layout = try wf.makeLayout();

        try appendText(wf, root_layout, "a thumbnail (drag me)");
        ret.thumbnail = try wf.makeThumbnail();
        ret.thumbnail_box = try wf.makeBox(&ret.thumbnail.widget, .{ .width = 200, .height = 150 }, .fill_none);
        const thumbnail_interactable = try wf.makeInteractable(&ret.thumbnail_box.widget, ids.thumbnail_drag_start);
        try root_layout.append(&thumbnail_interactable.widget);

        {
            const background = try wf.makeRect(.{ .r = 255, .g = 0, .b = 255, .a = 255 });

            const label = try wf.makeLabel("a centered label", .{});
            const centered = try wf.makeCentered(&label.widget);

            const stack_items = try wf.alloc.heap.arena().dupe(
                gui.Stack.StackItem,
                &.{
                    .{ .widget = &background.widget },
                    .{ .widget = &centered.widget },
                },
            );
            const stack = try wf.makeStack(stack_items);

            const box = try wf.makeBox(
                &stack.widget,
                .{ .width = 200, .height = 200 },
                .fill_none,
            );
            try root_layout.append(&box.widget);
        }

        try appendText(wf, root_layout, "a textbox");
        ret.textbox = try wf.makeTextbox(ids.textbox_change);
        try root_layout.append(&ret.textbox.widget);
        ret.textbox_mirror = try wf.makeLabel("", .{});
        try root_layout.append(&ret.textbox_mirror.widget);

        ret.button_label = try wf.makeLabel("a button", .{});
        try root_layout.append(&ret.button_label.widget);

        var button_label = try wf.makeLabel("click me", .{});
        ret.button = try wf.makeButton(&button_label.widget, ids.button_click);
        try root_layout.append(&ret.button.widget);

        var checkbox_layout = try wf.makeLayout();
        checkbox_layout.cursor.direction = .left_to_right;

        try appendText(wf, root_layout, "a checkbox");
        ret.checkbox = try wf.makeCheckbox(false, ids.checkbox_toggle);
        try checkbox_layout.append(&ret.checkbox.widget);

        ret.checkbox_text = try wf.makeLabel("", .{});
        const checkbox_text_interactable = try wf.makeInteractable(&ret.checkbox_text.widget, ids.want_checkbox_toggle);
        try checkbox_layout.append(&checkbox_text_interactable.widget);

        ret.checkbox_frame = try wf.makeColorableFrame(&checkbox_layout.widget);
        try root_layout.append(&ret.checkbox_frame.widget);

        try appendText(wf, root_layout, "i32 drag");
        ret.drag_text = try wf.makeLabel("", .{});
        ret.drag = try wf.makeDrag(&ret.drag_text.widget, ids.drag_start, ids.on_drag);
        try root_layout.append(&ret.drag.widget);

        try appendText(wf, root_layout, "A histogram");

        ret.histogram_label = try wf.makeLabel(" ", .{});
        ret.histogram = try wf.makeHistogram(&ret.histogram_label.widget);

        var hist_box = try wf.makeBox(&ret.histogram.widget, .{
            .width = 300,
            .height = 150,
        }, .fill_none);

        try root_layout.append(&hist_box.widget);

        try appendText(wf, root_layout, "a combo box");

        {
            ret.combo_popup_list = try wf.makeSelectableList(ids.combo_select);
            const selectable_list_fields = std.meta.fields(SelectableListOptions);

            const sl_widgets = try wf.alloc.heap.arena().alloc(*gui.Widget, selectable_list_fields.len);
            inline for (selectable_list_fields, 0..) |item, i| {
                const label = try wf.makeLabel(item.name, .{});
                sl_widgets[i] = &label.widget;
            }
            ret.combo_popup_list.setItems(sl_widgets);

            ret.combo_preview = try wf.makeLabel("select...", .{});
            const combo_box = try wf.makeComboBox(&ret.combo_preview.widget, &ret.combo_popup_list.widget);
            try root_layout.append(&combo_box.widget);
        }

        try appendText(wf, root_layout, "a color picker");
        ret.color_picker = try wf.makeColorPicker(.{ .r = 0.8, .g = 0.3, .b = 0.2, .a = 1.0 }, ids.color_change);
        try root_layout.append(&ret.color_picker.widget);
        ret.color_label = try wf.makeLabel("", .{});
        try root_layout.append(&ret.color_label.widget);

        try appendText(wf, root_layout, "a grid");

        ret.grid = try wf.makeGrid(&grid_columns, 6);
        const grid_keys = [_][]const u8{ "alpha", "beta", "gamma" };
        for (&ret.grid_labels, grid_keys) |*val_label, key| {
            const key_label = try wf.makeLabel(key, .{});
            try ret.grid.append(&key_label.widget);
            val_label.* = try wf.makeLabel("0", .{});
            try ret.grid.append(&val_label.*.widget);
        }
        try root_layout.append(&ret.grid.widget);

        try appendText(wf, root_layout, "memory usage");
        ret.memory_widget = try wf.makeMemoryWidget(memory_tracker);
        try root_layout.append(&ret.memory_widget.widget);

        ret.events = &gui_state.event_queue;
        ret.popup_layer = &gui_state.popup_layer;
        ret.drag_layer = &gui_state.drag_layer;

        {
            const options = try gui_alloc.heap.arena().alloc(*gui.Widget, 4);
            const labels = [_][]const u8{
                "one_of 1",
                "one_of 2",
                "one_of 3",
                "one_of 4",
            };

            for (options, labels) |*o, l| {
                const label = try wf.makeLabel(l, .{});
                o.* = &label.widget;
            }
            ret.one_of = try wf.makeOneOf(options);
            try root_layout.append(&ret.one_of.widget);
        }

        ret.time_label = try wf.makeLabel("", .{});
        try root_layout.append(&ret.time_label.widget);

        const custom = try gui_alloc.heap.arena().create(CustomWidget);
        custom.* = try .init(gui_alloc);
        try root_layout.append(&custom.widget);

        const root_frame = try wf.makeFrame(&root_layout.widget);
        var scroll_view = try wf.makeScrollView(&root_frame.widget);

        const runner = try wf.makeRunner(&scroll_view.widget);
        ret.runner = runner;

        return ret;
    }

    fn appendText(wf: gui.WidgetFactory, layout: *gui.Layout, text: []const u8) !void {
        const label = try wf.makeLabel(text, .{});
        try layout.append(&label.widget);
    }
};

fn makeTz(alloc: std.mem.Allocator, scratch: std.mem.Allocator) !sphtud.datetime.TimeZone {
    const f = try sphtud.io.open("/etc/localtime", .{}, 0);
    defer sphtud.io.close(f);

    var tz_buf: [4096]u8 = undefined;
    var tz_reader = sphtud.io.Reader.init(f, &tz_buf);
    return try sphtud.datetime.TimeZone.init(alloc, scratch, &tz_reader.interface);
}

pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphui demo", 800, 600);

    try sphtud.render.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    var memory_tracker = try sphtud.alloc.MemoryTracker.init(
        allocators.root.general(),
        try sphtud.io.clock_gettime(.BOOTTIME),
        100,
        &allocators.root,
    );

    var widgets = try Gui.init(&allocators, &memory_tracker);

    // Create a simple 8x8 checkerboard test texture for the thumbnail
    const tex_w = 8;
    const tex_h = 8;
    var tex_data: [tex_w * tex_h * 4]u8 = undefined;
    for (0..tex_h) |y| {
        for (0..tex_w) |x| {
            const i = (y * tex_w + x) * 4;
            const checker = (x + y) % 2 == 0;
            tex_data[i + 0] = if (checker) 220 else 60;
            tex_data[i + 1] = if (checker) 80 else 180;
            tex_data[i + 2] = if (checker) 60 else 220;
            tex_data[i + 3] = 255;
        }
    }
    const thumb_texture = try sphrender.makeTextureFromRgba(&allocators.root_gl, &tex_data, tex_w);
    widgets.thumbnail.texture = thumb_texture;
    widgets.thumbnail.image_size = .{ .width = tex_w, .height = tex_h };

    var dragging_thumbnail = false;
    var drag_val: i32 = 10;
    var drag_anchor: i32 = 0;
    var drag_label_buf: [32]u8 = undefined;
    try widgets.drag_text.setText(try std.fmt.bufPrint(&drag_label_buf, "{d:.3}", .{drag_val}));

    var dist_buf: [64]f32 = undefined;
    generateStandardDist(&dist_buf);
    try widgets.histogram.setData(&dist_buf);

    var hist_label_buf: [128]u8 = undefined;
    try widgets.checkbox_text.setText("off");

    var click_count: u32 = 0;
    var button_label_buf: [128]u8 = undefined;
    var grid_val_bufs: [3][32]u8 = undefined;

    const start = try sphtud.io.clock_gettime(.BOOTTIME);

    var selectable_list_elem_buf: [128]u8 = undefined;
    var time_buf: [128]u8 = undefined;

    const tz = try makeTz(allocators.root.arena(), allocators.scratch.allocator());

    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        const now = try sphtud.io.clock_gettime(.BOOTTIME);
        const elapsed_ns = start.durationTo(now).toNanoseconds();
        var elapsed_s: f32 = @floatFromInt(elapsed_ns);
        elapsed_s /= std.time.ns_per_s;

        try memory_tracker.step(now);

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = gui.WidgetState.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        try widgets.runner.step(elapsed_s, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        while (widgets.events.pop()) |ev| switch (ev) {
            ids.button_click => {
                click_count +|= 1;
                try widgets.button_label.setText(try std.fmt.bufPrint(&button_label_buf, "Clicked {d} times", .{click_count}));
            },
            ids.thumbnail_drag_start => dragging_thumbnail = true,
            ids.drag_start => drag_anchor = drag_val,
            ids.on_drag => {
                drag_val = drag_anchor + @as(i32, @intFromFloat(widgets.drag.drag_delta_px * 0.1));
                try widgets.drag_text.setText(try std.fmt.bufPrint(&drag_label_buf, "{d:.3}", .{drag_val}));
            },
            ids.checkbox_toggle => {
                const checked = widgets.checkbox.checked;
                try widgets.checkbox_text.setText(if (checked) "on" else "off");
                widgets.checkbox_frame.color = if (checked)
                    gui.Color{ .r = 0.2, .g = 0.8, .b = 0.3, .a = 1.0 }
                else
                    null;
            },
            ids.want_checkbox_toggle => {
                widgets.checkbox.checked = !widgets.checkbox.checked;
                try widgets.events.appendBounded(ids.checkbox_toggle);
            },
            ids.color_change => {
                const c = widgets.color_picker.color;
                try widgets.color_label.setText(try std.fmt.bufPrint(&hist_label_buf, "r={d:.2} g={d:.2} b={d:.2}", .{ c.r, c.g, c.b }));
            },
            ids.textbox_change => {
                try widgets.textbox_mirror.setText(widgets.textbox.text.items);
            },
            ids.combo_select => {
                const tag: SelectableListOptions = @enumFromInt(widgets.combo_popup_list.selected_idx);
                try widgets.combo_preview.setText(try std.fmt.bufPrint(&selectable_list_elem_buf, "{t}", .{tag}));
                widgets.popup_layer.clear();
            },
            else => {},
        };

        const grid_freqs = [_]f32{ 1.0, 2.0, 0.5 };
        for (&widgets.grid_labels, &grid_val_bufs, grid_freqs) |label, *buf, freq| {
            const v = @sin(elapsed_s * freq);
            try label.setText(try std.fmt.bufPrint(buf, "{d:.3}", .{v}));
        }

        if (widgets.histogram.hoveredIdx()) |idx| {
            try widgets.histogram_label.setText(try std.fmt.bufPrint(&hist_label_buf, "bucket={d} y={d:.4}", .{ idx, dist_buf[idx] }));
        } else {
            try widgets.histogram_label.setText(" ");
        }

        // Show the thumbnail floating under the cursor while it is being
        // dragged; clear when the mouse button is released.
        if (dragging_thumbnail and widgets.runner.input_state.mouse_down_location != null) {
            widgets.drag_layer.set(&widgets.thumbnail_box.widget, 0, 0);
        } else {
            dragging_thumbnail = false;
            widgets.drag_layer.reset();
        }

        widgets.one_of.selected = @intFromFloat(elapsed_s);
        widgets.one_of.selected %= widgets.one_of.options.len;

        const time = try sphtud.io.clock_gettime(.REALTIME);
        var time_w = std.Io.Writer.fixed(&time_buf);
        try time_w.writeAll("Time: ");
        const dt = sphtud.datetime.DateTime.init(try tz.fromUTC(time.toSeconds()));
        try dt.format(&time_w);

        try widgets.time_label.setText(time_w.buffered());

        window.swapBuffers();
    }
}
