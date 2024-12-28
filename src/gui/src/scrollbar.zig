const std = @import("std");
const SquirqleRenderer = @import("SquircleRenderer.zig");
const gui = @import("gui.zig");
const util = @import("util.zig");
const Color = gui.Color;
const InputState = gui.InputState;
const PixelBBox = gui.PixelBBox;

pub const Style = struct {
    gutter_color: Color,
    default_color: Color,
    hover_color: Color,
    active_color: Color,
    corner_radius: f32,
    width: u31,
};

pub const Scrollbar = struct {
    // Feel free to modify these
    // How tall the handle is relative to the size of entire scrollbar
    handle_ratio: f32 = 1.0,
    // Where the top of the handle is, relative to the size of the scrollbar
    top_offs_ratio: f32 = 0.0,

    // Internal state
    renderer: *const SquirqleRenderer,
    style: *const Style,
    scroll_input_state: ScrollState = .none,

    const ScrollState = union(enum) {
        dragging: f32, // start offs
        hovered,
        none,
    };

    // Returns desired scroll height as ratio of total scrollable area
    pub fn handleInput(self: *Scrollbar, input_state: InputState, bounds: PixelBBox) ?f32 {
        self.updateDragState(input_state, bounds);

        switch (self.scroll_input_state) {
            .dragging => |start_offs| {
                const scrollbar_height: f32 = @floatFromInt(bounds.calcHeight());

                const mouse_movement_px = input_state.mouse_pos.y - input_state.mouse_down_location.?.y;
                const mouse_movement_ratio = mouse_movement_px / scrollbar_height;
                const ret = std.math.clamp(
                    mouse_movement_ratio + start_offs,
                    0.0,
                    1.0 - self.handle_ratio,
                );
                return ret;
            },
            else => {
                return null;
            },
        }
    }

    pub fn render(self: Scrollbar, bounds: PixelBBox, window: PixelBBox) void {
        const transform = util.widgetToClipTransform(bounds, window);
        self.renderer.render(
            self.style.gutter_color,
            0.0, // Intentional, keeps edges crisp and avoids leaking background
            bounds,
            transform,
        );

        const bar_transform = util.widgetToClipTransform(self.calcHandleBounds(bounds), window);
        const bar_color = switch (self.scroll_input_state) {
            .dragging => self.style.active_color,
            .hovered => self.style.hover_color,
            .none => self.style.default_color,
        };

        self.renderer.render(
            bar_color,
            self.style.corner_radius,
            bounds,
            bar_transform,
        );
    }

    fn calcHandleBounds(self: Scrollbar, scrollbar_bounds: PixelBBox) PixelBBox {
        const scrollbar_height: f32 = @floatFromInt(scrollbar_bounds.calcHeight());
        const handle_height_px = scrollbar_height * self.handle_ratio;
        const offs_px = self.top_offs_ratio * scrollbar_height;
        const top_px = @as(f32, @floatFromInt(scrollbar_bounds.top)) + offs_px;
        return .{
            .left = scrollbar_bounds.left,
            .right = scrollbar_bounds.right,
            .top = @intFromFloat(top_px),
            .bottom = @intFromFloat(top_px + handle_height_px),
        };
    }

    fn updateDragState(self: *Scrollbar, input_state: InputState, bounds: PixelBBox) void {
        const already_dragging = self.scroll_input_state == .dragging and input_state.mouse_down_location != null;

        // If we are already dragging, moving into the drag state again would
        // reset the drag start, so we early return
        if (already_dragging) return;

        if (bounds.containsOptMousePos(input_state.mouse_down_location)) {
            self.scroll_input_state = .{ .dragging = self.top_offs_ratio };
        } else if (bounds.containsMousePos(input_state.mouse_pos)) {
            self.scroll_input_state = .hovered;
        } else {
            self.scroll_input_state = .none;
        }
    }
};
