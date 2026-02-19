const std = @import("std");
const sphalloc = @import("sphalloc");
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphwindow = @import("sphwindow");
const gui = @import("gui.zig");
const sphutil = @import("sphutil");
const sphmath = @import("sphmath");

const GuiAction = union(enum) {
    text_edit: gui.textbox.TextboxNotifier,

    pub fn makeTextEdit(notifier: gui.textbox.TextboxNotifier) GuiAction {
        return .{
            .text_edit = notifier,
        };
    }
};

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

const HistogramRetriever = struct {
    buf: []const f32,

    pub fn generation(_: HistogramRetriever) u64 {
        return 0;
    }

    pub fn numBuckets(self: HistogramRetriever) usize {
        return self.buf.len;
    }

    pub fn getXLabel(_: HistogramRetriever, alloc: std.mem.Allocator, idx: usize) ![]const u8 {
        return try std.fmt.allocPrint(alloc, "{d}", .{idx});
    }

    pub fn getY(self: HistogramRetriever, idx: usize) f32 {
        return self.buf[idx];
    }
};

const MultiLineGraphRetriever = struct {
    y_scale: f32,
    y_offs: f32,
    color: gui.Color,

    const interval = 10;
    const max_pos = 100;

    pub fn getGeneration(_: MultiLineGraphRetriever) usize {
        // Data never changes, but if it did you should return a new number
        // here to force opengl regeneration
        return 0;
    }

    // Colors are externally chosen here, this allows for an application to
    // choose colors for different purposes, and even change them on the fly if
    // they want
    pub fn getColor(self: MultiLineGraphRetriever) gui.Color {
        return self.color;
    }

    // Sometimes we have more graphs than we want to see at once, this allows
    // us to toggle them on and off
    pub fn getEnable(_: MultiLineGraphRetriever) bool {
        return true;
    }

    // We do not necessarily have an even distribution of points. This tells
    // the graph widget how many points we have
    pub fn len(_: MultiLineGraphRetriever) usize {
        return max_pos / interval;
    }

    // This is the core of the retriever. When generating opengl buffers, the
    // widget will ask for our iterator and iterate the graph points. This
    // allows an arbitrary storage format to be used
    const Iter = struct {
        pos: usize,
        parent: *MultiLineGraphRetriever,

        pub fn next(self: *Iter) ?gui.multi_line_graph.GraphPoint {
            if (self.pos >= max_pos) return null;
            defer self.pos += interval;

            return .{
                .x = @floatFromInt(self.pos),
                .y = self.parent.calcY(@floatFromInt(self.pos)),
            };
        }
    };

    pub fn iter(self: *MultiLineGraphRetriever) Iter {
        return .{
            .pos = 0,
            .parent = self,
        };
    }

    // This is called to set the scale of the graph
    pub fn getBounds(self: MultiLineGraphRetriever) gui.multi_line_graph.GraphPoint {
        // Max positions
        return .{
            .x = max_pos,
            .y = self.calcY(max_pos),
        };
    }

    // On hover, the widget will calculate the mouse position in graph space,
    // but it doesn't know which data point actually belongs to that mouse
    // position. Here we look at the data and tell the widget about what point
    // is closest. We can choose to return null if we don't want to show anything
    pub fn closestPoint(self: MultiLineGraphRetriever, in_pos: f32) ?gui.multi_line_graph.GraphPoint {
        const x = in_pos - @mod(in_pos, interval);
        return .{
            .x = x,
            .y = self.calcY(x),
        };
    }

    fn calcY(self: MultiLineGraphRetriever, x: f32) f32 {
        return x * x * self.y_scale + self.y_offs;
    }
};

const ScrollLabelFactory = struct {
    alloc: gui.GuiAlloc,
    state: *gui.widget_factory.WidgetState(GuiAction),
    arenas: sphutil.AutoHashMap(usize, gui.GuiAlloc),

    pub fn createWidget(self: *ScrollLabelFactory, idx: usize) !gui.Widget(GuiAction) {
        const gop = try self.arenas.getOrPut(idx);
        if (!gop.found_existing) {
            gop.val.* = try self.alloc.makeSubAlloc("list label");
        }

        const text = try std.fmt.allocPrint(gop.val.heap.arena(), "hello, i am widget {d}", .{idx});
        const factory = self.state.factory(gop.val.*);
        return try factory.makeLabel(text, .{});
    }

    pub fn destroyWidget(self: *ScrollLabelFactory, idx: usize, widget: gui.Widget(GuiAction)) void {
        _ = widget;
        const arena = self.arenas.remove(idx) orelse unreachable;
        arena.deinit();
    }

    pub fn numItems(self: *const ScrollLabelFactory) usize {
        _ = self;
        return 10000;
    }
};

pub const CustomWidget = struct {
    render_source: sphrender.xyuvt_program.RenderSource,
    program: sphrender.xyuvt_program.Program(Uniforms),
    hover_state: enum {
        default,
        hovered,
    } = .default,

    const Uniforms = struct {
        transform: sphmath.Mat3x3,
        max_color: sphmath.Vec3,
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
        };
    }

    pub fn render(self: CustomWidget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const max_color: sphmath.Vec3 = switch (self.hover_state) {
            .default => .{ 1.0, 0.0, 0.0 },
            .hovered => .{ 0.0, 1.0, 0.0 },
        };

        const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);
        self.program.render(self.render_source, .{
            .transform = transform.inner,
            .max_color = max_color,
        });
    }

    pub fn getSize(_: CustomWidget) gui.PixelSize {
        return .{ .width = 300, .height = 300 };
    }

    fn setInputState(self: CustomWidget, _: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) gui.InputResponse(GuiAction) {
        if (input_bounds.containsMousePos(input_state.mouse_pos)) {
            self.hover_state = .hovered;
        } else {
            self.hover_state = .default;
        }
    }
};

pub fn main() !void {
    var allocators: sphrender.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphwindow.Window = undefined;
    try window.initPinned("sphui demo", 800, 600);

    try sphrender.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const gui_state = try gui.widget_factory.widgetState(
        GuiAction,
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
        .{},
    );

    var std_dist: [25]f32 = undefined;
    generateStandardDist(&std_dist);
    const histogram_retriever = HistogramRetriever{
        .buf = &std_dist,
    };

    const widget_factory = gui_state.factory(gui_alloc);
    const layout = try widget_factory.makeLayout();

    try layout.pushWidget(try widget_factory.makeLabel("A label", .{}));
    try layout.pushWidget(try widget_factory.makeLabel("A red label", .{
        .color = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 },
    }));

    var input_text_buf: [100]u8 = undefined;

    var input_text = std.ArrayList(u8).initBuffer(&input_text_buf);
    try layout.pushWidget(try widget_factory.makeLabel("A text box", .{}));
    try layout.pushWidget(try widget_factory.makeTextbox(&input_text.items, &GuiAction.makeTextEdit));

    try layout.pushWidget(try widget_factory.makeLabel("A histogram", .{}));
    try layout.pushWidget(try widget_factory.makeBox(
        try widget_factory.makeHistogram(histogram_retriever),
        .{ .width = 300, .height = 200 },
        .fill_none,
    ));

    const multiline_retrievers = try gui_alloc.heap.arena().alloc(MultiLineGraphRetriever, 3);
    multiline_retrievers[0] = .{
        .y_scale = 1,
        .y_offs = 0,
        .color = .{ .r = 1, .g = 0.35, .b = 0.87, .a = 1 },
    };
    multiline_retrievers[1] = .{
        .y_scale = 2,
        .y_offs = 1,
        .color = .{ .r = 0.47, .g = 1, .b = 0.26, .a = 1 },
    };
    multiline_retrievers[2] = .{
        .y_scale = 3,
        .y_offs = 2,
        .color = .{ .r = 1, .g = 0.73, .b = 0.35, .a = 1 },
    };

    try layout.pushWidget(try widget_factory.makeLabel("A multi graph", .{}));
    try layout.pushWidget(try widget_factory.makeBox(
        try widget_factory.makeMultiLineGraph(multiline_retrievers),
        .{ .width = 300, .height = 200 },
        .fill_none,
    ));

    try layout.pushWidget(try widget_factory.makeLabel("A custom widget", .{}));
    var custom_widget = try CustomWidget.init(gui_alloc);
    try layout.pushWidget(try widget_factory.makeBox(
        gui.Widget(GuiAction).fromConcrete(&custom_widget, "custom"),
        .{ .width = 300, .height = 300 },
        .fill_none,
    ));

    var label_factory_alloc = try allocators.root_render.makeSubAlloc("label factory");
    var scroll_labels = ScrollLabelFactory{
        .alloc = label_factory_alloc,
        .state = gui_state,
        .arenas = try .init(
            label_factory_alloc.heap.arena(),
            label_factory_alloc.heap.expansion(),
            10,
            10000,
        ),
    };
    try layout.pushWidget(try widget_factory.makeBox(
        try widget_factory.makeScrollList(&scroll_labels),
        .{ .width = 300, .height = 300 },
        .fill_width,
    ));

    var runner = try widget_factory.makeRunner(try widget_factory.makeScrollView(layout.asWidget()));

    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = gui.widget_factory.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        var response = try runner.step(1.0, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        if (response.action) |*a| switch (a.*) {
            .text_edit => |*notifier| {
                for (notifier.events) |ev| switch (ev.key) {
                    .ascii => |char| {
                        try input_text.insertBounded(notifier.priv.insert_idx, char);
                        try notifier.notify(.insert);
                    },
                    .backspace => {
                        _ = input_text.orderedRemove(notifier.backspaceIdx() orelse continue);
                        try notifier.notify(.backspace);
                    },
                    .delete => {
                        _ = input_text.orderedRemove(notifier.deleteIdx(input_text.items.len) orelse continue);
                        try notifier.notify(.delete);
                    },
                    else => {},
                };
            },
        };

        window.swapBuffers();
    }
}
