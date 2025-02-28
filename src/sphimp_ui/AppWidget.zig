const std = @import("std");
const Allocator = std.mem.Allocator;
const sphimp = @import("sphimp");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const sphrender = @import("sphrender");
const gui = @import("sphui");
const ui_action = @import("ui_action.zig");
const UiAction = ui_action.UiAction;
const logError = @import("util.zig").logError;
const GlAlloc = sphrender.GlAlloc;

app: *sphimp.App,
size: gui.PixelSize = .{},
drag_source: *?ObjectId,
now: std.time.Instant = undefined,

const AppWidget = @This();

const widget_vtable = gui.Widget(UiAction).VTable{
    .render = AppWidget.render,
    .getSize = AppWidget.getSize,
    .update = AppWidget.update,
    .setInputState = AppWidget.setInputState,
    // AFAICT we don't actually need focus support. It would make sense that if
    // we handle keyboard input, we need to ensure the keyboard isn't focused
    // elsewhere, however it seems unclear when we should request focus. In the
    // following sequence...
    // * Click text box
    // * Type
    // * Click off text box
    // * Hover mouse over app widget
    // * Try to scale by pressing S on the keyboard
    //
    // It doesn't really seem reasonable to have to click the main widget in
    // order for the scale to work. It also doesn't seem reasonable to steal
    // focus from the textbox if we happen to hover our mouse over the main
    // window. It also doesn't seem reasonable to allow duplicate entry in the
    // textbox and the app widget
    //
    // For now we do nothing, because at least doing the wrong thing because we
    // didn't try is better than going out of our way to do something stupid.
    // If this ever becomes a problem we can revisit
    .setFocused = null,
    .reset = null,
};

pub fn init(alloc: Allocator, app: *App, drag_source: *?ObjectId) !gui.Widget(UiAction) {
    const ctx = try alloc.create(AppWidget);
    ctx.* = .{
        .app = app,
        .drag_source = drag_source,
    };
    return .{
        .vtable = &widget_vtable,
        .name = "app_widget",
        .ctx = ctx,
    };
}

fn render(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *AppWidget = @ptrCast(@alignCast(ctx));
    const viewport = sphrender.TemporaryViewport.init();
    defer viewport.reset();
    viewport.setViewportOffset(
        widget_bounds.left,
        window_bounds.calcHeight() - widget_bounds.bottom,
        widget_bounds.calcWidth(),
        widget_bounds.calcHeight(),
    );

    const scissor = sphrender.TemporaryScissor.init();
    defer scissor.reset();
    scissor.set(
        widget_bounds.left,
        window_bounds.calcHeight() - widget_bounds.bottom,
        widget_bounds.calcWidth(),
        widget_bounds.calcHeight(),
    );

    self.app.render(self.now) catch return;
}

fn getSize(ctx: ?*anyopaque) gui.PixelSize {
    const self: *AppWidget = @ptrCast(@alignCast(ctx));
    return self.size;
}

fn update(ctx: ?*anyopaque, available_size: gui.PixelSize, _: f32) anyerror!void {
    const self: *AppWidget = @ptrCast(@alignCast(ctx));
    self.size = available_size;
    self.now = try std.time.Instant.now();
    self.app.view_state.window_width = available_size.width;
    self.app.view_state.window_height = available_size.height;
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: gui.InputState) gui.InputResponse(UiAction) {
    const self: *AppWidget = @ptrCast(@alignCast(ctx));

    const action = self.trySetInputState(widget_bounds, input_bounds, input_state) catch |e| {
        logError("input handling failed", e, @errorReturnTrace());
        return .{};
    };

    if (action) |a| {
        return .{
            .action = a,
        };
    }

    return .{};
}

fn trySetInputState(self: *AppWidget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: gui.InputState) !?UiAction {
    var ret: ?UiAction = null;

    if (input_state.mouse_middle_released) self.app.setMiddleUp();
    if (input_state.mouse_released) {
        if (input_bounds.containsMousePos(input_state.mouse_pos)) {
            if (self.drag_source.*) |id| {
                ret = UiAction{ .add_to_composition = id };
            }
        }
        self.app.setMouseUp();
    }

    try self.app.setMousePos(
        input_state.mouse_pos.x - @as(f32, @floatFromInt(widget_bounds.left)),
        input_state.mouse_pos.y - @as(f32, @floatFromInt(widget_bounds.top)),
    );

    if (!input_bounds.containsMousePos(input_state.mouse_pos)) {
        return ret;
    }

    if (input_state.mouse_right_pressed) try self.app.setRightDown();
    if (input_state.mouse_middle_pressed) self.app.setMiddleDown();
    if (input_state.mouse_pressed) try self.app.setMouseDown();

    for (input_state.key_tracker.pressed_this_frame.items) |key| {
        if (key.key == .ascii) {
            try self.app.setKeyDown(key.key.ascii, key.ctrl);
        }
    }

    self.app.scroll(input_state.frame_scroll);

    return ret;
}
