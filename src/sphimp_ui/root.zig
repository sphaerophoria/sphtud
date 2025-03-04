const gui = @import("sphui");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const sphrender = @import("sphrender");
const GlAlloc = sphrender.GlAlloc;
const RenderAlloc = sphrender.RenderAlloc;
const UiAction = @import("ui_action.zig").UiAction;
const WidgetState = gui.widget_factory.WidgetState;
const sidebar_mod = @import("sidebar.zig");
const ImageDrawer = @import("ImageDrawer.zig");
const ImageDrawerTab = @import("ImageDrawerTab.zig");
const sphimp = @import("sphimp");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const MemoryTracker = sphalloc.MemoryTracker;
const AppWidget = @import("AppWidget.zig");
const MemoryWidget = gui.memory_widget.MemoryWidget;

const Gui = struct {
    sidebar: sidebar_mod.Handle,
    app_widget: *AppWidget,
    memory_widget: gui.Widget(UiAction),
    state: *WidgetState(UiAction),
    runner: gui.runner.Runner(UiAction),
    drawer: *ImageDrawer,
};

const sidebar_width = 300;

pub fn makeGui(alloc: RenderAlloc, app: *App, scratch: *ScratchAlloc, scratch_gl: *GlAlloc, memory_tracker: *MemoryTracker, drag_source: *?ObjectId) !Gui {
    const widget_state = try gui.widget_factory.widgetState(UiAction, alloc, scratch, scratch_gl);

    const widget_factory = widget_state.factory(alloc);

    const app_widget = try AppWidget.init(alloc.heap.arena(), app, .{ .heap = scratch, .gl = scratch_gl }, drag_source);
    const selected_id = app_widget.selectedObjectPtr();

    const image_drawer = try ImageDrawer.init(
        app,
        alloc,
        gui.widget_factory.StyleColors.background_color,
        gui.widget_factory.StyleColors.default_color,
        sidebar_width,
        widget_state,
        selected_id,
    );

    var image_drawer_tab = try ImageDrawerTab.init(
        alloc,
        image_drawer,
        &widget_state.squircle_renderer,
        .{
            .width = 20,
            .height = 50,
        },
        gui.widget_factory.StyleColors.background_color2,
    );

    const drawer_then_remaining = try widget_factory.makeLayout();
    drawer_then_remaining.cursor.direction = .right_to_left;
    drawer_then_remaining.item_pad = 0;
    try drawer_then_remaining.pushWidget(image_drawer.asWidget());

    const non_drawer_stack = try widget_factory.makeStack(2);
    try drawer_then_remaining.pushWidget(non_drawer_stack.asWidget());

    const sidebar_then_main_viewport = try widget_factory.makeLayout();
    sidebar_then_main_viewport.cursor.direction = .left_to_right;
    sidebar_then_main_viewport.item_pad = 0;

    try non_drawer_stack.pushWidget(sidebar_then_main_viewport.asWidget(), .{});

    const sidebar = try sidebar_mod.makeSidebar(alloc, app, selected_id, sidebar_width, widget_state);
    try sidebar_then_main_viewport.pushWidget(sidebar.widget);

    const memory_widget = try widget_factory.makeMemoryWidget(memory_tracker);

    try sidebar_then_main_viewport.pushWidget(app_widget.asWidget());

    try non_drawer_stack.pushWidget(image_drawer_tab.asWidget(), .{
        .horizontal_justify = .right,
        .vertical_justify = .center,
    });

    const gui_runner = try widget_factory.makeRunner(drawer_then_remaining.asWidget());

    return .{
        .sidebar = sidebar.handle,
        .app_widget = app_widget,
        .memory_widget = memory_widget,
        .state = widget_state,
        .runner = gui_runner,
        .drawer = image_drawer,
    };
}
