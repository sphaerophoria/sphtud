const std = @import("std");
const sphalloc = @import("sphalloc");
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphwindow = @import("sphwindow");
const gui = @import("gui.zig");

const GuiAction = union(enum) {};

const AtlasRetriever = struct {
    gui_state: *gui.widget_factory.WidgetState(GuiAction),
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

    pub fn yVals(self: HistogramRetriever) []const f32 {
        return self.buf;
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
    var total: f32 = 0;
    for (&std_dist) |val| {
        total += val;
    }
    std.debug.print("{d}\n", .{total});
    std.debug.print("{any}\n", .{std_dist});

    const widget_factory = gui_state.factory(gui_alloc);
    const layout = try widget_factory.makeLayout();
    try layout.pushWidget(try widget_factory.makeLabel("Hello world"));

    const histogram_retriever = HistogramRetriever{
        .buf = &std_dist,
    };
    try layout.pushWidget(try widget_factory.makeBox(
        try widget_factory.makeHistogram(histogram_retriever),
        .{ .width = 300, .height = 200 },
        .fill_none,
    ));
    var runner = try widget_factory.makeRunner(layout.asWidget());

    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const response = try runner.step(1.0, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);
        _ = response;
        window.swapBuffers();
    }
}
