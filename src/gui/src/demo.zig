const sphalloc = @import("sphalloc");
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphwindow = @import("sphwindow");
const gui = @import("gui.zig");

const GuiAction = union(enum) {};

const AtlasRetriever = struct {
    gui_state: *gui.widget_factory.WidgetState(GuiAction),
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

    const widget_factory = gui_state.factory(gui_alloc);
    const label = try widget_factory.makeLabel("Hello world");
    var runner = try widget_factory.makeRunner(label);

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
