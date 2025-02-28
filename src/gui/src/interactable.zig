const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;
const DragLayer = gui.drag_layer.DragLayer;

pub fn Shared(comptime Action: type) type {
    return struct {
        drag_layer: *DragLayer(Action),
    };
}

pub fn interactable(comptime Action: type, arena: Allocator, inner: gui.Widget(Action), action: Action, drag_start_action: ?Action, shared: *const Shared(Action)) !gui.Widget(Action) {
    const ctx = try arena.create(Interactable(Action));
    ctx.* = .{
        .inner = inner,
        .action = action,
        .drag_start_action = drag_start_action,
        .shared = shared,
    };

    return .{
        .ctx = ctx,
        .name = "clickable",
        .vtable = &Interactable(Action).widget_vtable,
    };
}

pub fn Interactable(comptime Action: type) type {
    return struct {
        inner: Widget(Action),
        action: Action,
        drag_start_action: ?Action,
        shared: *const Shared(Action),
        state: enum {
            idle,
            dragging,
        } = .idle,

        const Self = @This();

        const widget_vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.render(widget_bounds, window_bounds);
        }
        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.getSize();
        }
        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            try self.inner.update(available_size, delta_s);
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (!input_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                return .{};
            }

            switch (self.state) {
                .idle => {
                    const emit_click = if (self.drag_start_action == null) input_state.mouse_pressed else input_state.mouse_released;

                    if (!input_bounds.containsMousePos(input_state.mouse_pos) and self.drag_start_action != null) {
                        self.state = .dragging;
                        const mouse_x: i32 = @intFromFloat(input_state.mouse_down_location.?.x);
                        const mouse_y: i32 = @intFromFloat(input_state.mouse_down_location.?.y);
                        const x_offs = mouse_x - widget_bounds.left;
                        const y_offs = mouse_y - widget_bounds.top;
                        self.shared.drag_layer.set(self.inner, x_offs, y_offs);
                        return .{
                            .action = self.drag_start_action.?,
                        };
                    } else if (emit_click) {
                        return .{
                            .action = self.action,
                        };
                    }
                },
                .dragging => {
                    if (input_state.mouse_released) {
                        self.state = .idle;
                    }
                },
            }

            return .{};
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.setFocused(focused);
        }
        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.reset();
        }
    };
}
