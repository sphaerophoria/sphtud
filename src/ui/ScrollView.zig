const std = @import("std");
const sphrender = @import("../render.zig");
const gui = @import("../ui.zig");
const Scrollbar = gui.scrollbar.Scrollbar;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Widget = gui.Widget;

inner: *Widget,
scrollbar_present: bool = false,
scroll_offs: i32 = 0,
scrollbar: Scrollbar,
widget: Widget,

const Self = @This();

pub fn init(inner: *Widget, shared: *const gui.scrollbar.Shared) Self {
    return .{
        .inner = inner,
        .scrollbar = .{ .shared = shared },
        .widget = .{
            .focused = false,
            .size = .{},
            .vtable = &.{
                .update = update,
                .render = render,
                .input = input,
                .reset = reset,
            },
        },
    };
}

fn update(widget: *Widget, available_size: PixelSize, delta_s: f32) anyerror!void {
    const self: *Self = @fieldParentPtr("widget", widget);

    // We cannot know if the layout requires a scrollbar without actually
    // executing a layout. Try layout with the current scroll state, and
    // re-layout if the state is wrong.
    const scrollbar_options = [2]bool{
        self.scrollbar_present,
        !self.scrollbar_present,
    };

    for (scrollbar_options) |scrollbar_present| {
        self.scrollbar_present = scrollbar_present;

        const adjusted_window_size: PixelSize = .{
            .width = available_size.width -| self.scrollbarWidth(),
            .height = available_size.height,
        };
        try self.inner.update(adjusted_window_size, delta_s);

        if (scrollbarInWrongState(
            available_size.height,
            self.contentHeight(),
            self.scrollbar_present,
        )) {
            continue;
        }

        break;
    }

    self.widget.size = available_size;
    self.clampScrollOffs();

    self.scrollbar.handle_ratio =
        @as(f32, @floatFromInt(available_size.height)) /
        @as(f32, @floatFromInt(self.contentHeight()));

    const max_scroll = self.contentHeight() -| available_size.height;
    if (max_scroll > 0) {
        self.scrollbar.scroll_ratio =
            @as(f32, @floatFromInt(self.scroll_offs)) /
            @as(f32, @floatFromInt(max_scroll));
    } else {
        self.scrollbar.scroll_ratio = 0;
    }
}

fn input(widget: *Widget, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: *InputState) !void {
    const self: *Self = @fieldParentPtr("widget", widget);

    const child_bounds = self.innerBounds(widget_bounds);
    try self.inner.input(
        child_bounds,
        child_bounds.calcIntersection(input_bounds),
        input_state,
    );

    if (self.scrollbar_present) {
        const new_scroll_ratio = self.scrollbar.handleInput(
            input_state,
            scrollAreaBounds(self.scrollbar, widget_bounds),
        );

        if (new_scroll_ratio) |scroll_loc| {
            const scroll_height: f32 = @floatFromInt(self.contentHeight() - widget_bounds.calcHeight());
            self.scroll_offs = @intFromFloat(scroll_height * scroll_loc);
        }

        if (input_bounds.containsMousePos(input_state.mouse_pos)) {
            self.scroll_offs -= @intFromFloat(input_state.frame_scroll * 15);
            input_state.consumeScroll();
        }

        self.clampScrollOffs();
    }
}

fn render(widget: *Widget, bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *Self = @fieldParentPtr("widget", widget);

    {
        // Child widgets do not attempt to keep themselves in their bounds.
        // For most cases this is fine, however if we have a scroll view as
        // part of a layout, we need to ensure that our child does not poke
        // out the top or bottom.
        const scissor = sphrender.TemporaryScissor.init();
        defer scissor.reset();

        const child_bounds = self.innerBounds(bounds);
        const scissor_bounds = child_bounds.calcIntersection(bounds);
        scissor.set(
            scissor_bounds.left,
            window_bounds.bottom - scissor_bounds.bottom,
            scissor_bounds.calcWidth(),
            scissor_bounds.calcHeight(),
        );
        self.inner.render(child_bounds, window_bounds);
    }

    if (self.scrollbar_present) {
        self.scrollbar.render(
            scrollAreaBounds(self.scrollbar, bounds),
            window_bounds,
        );
    }
}

fn reset(widget: *Widget) void {
    const self: *Self = @fieldParentPtr("widget", widget);
    self.scroll_offs = 0;
    self.inner.reset();
}

fn innerBounds(self: Self, bounds: PixelBBox) PixelBBox {
    const top = bounds.top - self.scroll_offs;
    return .{
        .top = top,
        .left = bounds.left,
        .right = bounds.right - @as(i32, self.scrollbarWidth()),
        .bottom = top + self.inner.size.height,
    };
}

fn contentHeight(self: Self) u31 {
    return self.inner.size.height;
}

fn scrollbarWidth(self: Self) u31 {
    return if (self.scrollbar_present) self.scrollbar.shared.style.width else 0;
}

fn clampScrollOffs(self: *Self) void {
    self.scroll_offs = std.math.clamp(
        self.scroll_offs,
        0,
        self.contentHeight() -| self.widget.size.height,
    );
}

fn scrollbarInWrongState(window_height: u31, content_height: u31, scrollbar_present: bool) bool {
    return (content_height > window_height) != scrollbar_present;
}

fn scrollAreaBounds(scrollbar_state: Scrollbar, bounds: PixelBBox) PixelBBox {
    return .{
        .left = bounds.right - scrollbar_state.shared.style.width,
        .right = bounds.right,
        .top = bounds.top,
        .bottom = bounds.bottom,
    };
}
