const std = @import("std");
const sphalloc = @import("sphalloc");
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphwindow = @import("sphwindow");
const gui = @import("gui.zig");

const GuiAction = union(enum) {};

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

pub fn main() !void {
    var allocators: sphrender.AppAllocators(100) = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphwindow.Window = undefined;
    try window.initPinned("sphui demo", 800, 600);

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const gui_state = try gui.widget_factory.widgetState(
        GuiAction,
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
    );

    var std_dist: [25]f32 = undefined;
    generateStandardDist(&std_dist);
    const histogram_retriever = HistogramRetriever{
        .buf = &std_dist,
    };

    const widget_factory = gui_state.factory(gui_alloc);
    const layout = try widget_factory.makeLayout();

    try layout.pushWidget(try widget_factory.makeLabel("A histogram"));
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

    try layout.pushWidget(try widget_factory.makeLabel("A multi graph"));
    try layout.pushWidget(try widget_factory.makeBox(
        try widget_factory.makeMultiLineGraph(multiline_retrievers),
        .{ .width = 300, .height = 200 },
        .fill_none,
    ));

    var runner = try widget_factory.makeRunner(layout.asWidget());

    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = gui.widget_factory.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const response = try runner.step(1.0, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);
        _ = response;
        window.swapBuffers();
    }
}
