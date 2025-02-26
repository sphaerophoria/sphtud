const gui = @import("sphui");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const sphrender = @import("sphrender");
const GlAlloc = sphrender.GlAlloc;
const RenderAlloc = sphrender.RenderAlloc;
const UiAction = @import("ui_action.zig").UiAction;
const WidgetState = gui.widget_factory.WidgetState;
const sidebar_mod = @import("sidebar.zig");
const sphimp = @import("sphimp");
const App = sphimp.App;
const MemoryTracker = sphalloc.MemoryTracker;
const AppWidget = @import("AppWidget.zig");
const MemoryWidget = gui.memory_widget.MemoryWidget;

const Gui = struct {
    sidebar: sidebar_mod.Handle,
    memory_widget: gui.Widget(UiAction),
    state: *WidgetState(UiAction),
    runner: gui.runner.Runner(UiAction),
};

const sidebar_width = 300;

pub fn makeGui(alloc: RenderAlloc, app: *App, scratch: *ScratchAlloc, scratch_gl: *GlAlloc, memory_tracker: *MemoryTracker) !Gui {
    const widget_state = try gui.widget_factory.widgetState(UiAction, alloc, scratch, scratch_gl);

    const widget_factory = widget_state.factory(alloc);

    const toplevel_layout = try widget_factory.makeLayout();
    toplevel_layout.cursor.direction = .left_to_right;
    toplevel_layout.item_pad = 0;

    const sidebar = try sidebar_mod.makeSidebar(alloc, app, widget_state);
    try toplevel_layout.pushWidget(sidebar.widget);

    const memory_widget = try widget_factory.makeMemoryWidget(memory_tracker);

    const app_widget = try AppWidget.init(alloc.heap.arena(), app);
    try toplevel_layout.pushWidget(app_widget);

    const gui_runner = try widget_factory.makeRunner(toplevel_layout.asWidget());

    return .{
        .sidebar = sidebar.handle,
        .memory_widget = memory_widget,
        .state = widget_state,
        .runner = gui_runner,
    };
}
