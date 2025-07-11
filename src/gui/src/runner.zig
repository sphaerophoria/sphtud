const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const CursorStyle = gui.CursorStyle;

pub fn Runner(comptime Action: type) type {
    return struct {
        root: gui.Widget(Action),
        input_state: gui.InputState,
        last_checked_viewport: gui.PixelSize = .{},

        const Self = @This();

        pub fn init(gpa: Allocator, widget: gui.Widget(Action)) Self {
            const input_state = gui.InputState.init(gpa);

            return .{
                .root = widget,
                .input_state = input_state,
            };
        }

        pub const Response = struct {
            action: ?Action,
            cursor_style: ?CursorStyle,
        };

        pub fn step(self: *Self, delta_s: f32, window_size: gui.PixelSize, input_queue: anytype) !Response {
            self.checkViewportScissor(window_size);
            try self.root.update(window_size, delta_s);

            self.input_state.startFrame();
            while (input_queue.readItem()) |action| {
                try self.input_state.pushInput(action);
            }

            const window_bounds = gui.PixelBBox{
                .top = 0,
                .bottom = window_size.height,
                .left = 0,
                .right = window_size.width,
            };

            const widget_size = self.root.getSize();

            const widget_bounds = gui.PixelBBox{
                .top = 0,
                .bottom = widget_size.height,
                .left = 0,
                .right = widget_size.width,
            };

            const input_response = self.root.setInputState(widget_bounds, widget_bounds, self.input_state);
            self.root.setFocused(input_response.wants_focus);
            self.root.render(widget_bounds, window_bounds);
            return .{
                .action = input_response.action,
                .cursor_style = input_response.cursor_style,
            };
        }

        fn checkViewportScissor(self: *Self, window_size: gui.PixelSize) void {
            if (window_size.width == self.last_checked_viewport.width and window_size.height == self.last_checked_viewport.height) {
                return;
            }
            self.last_checked_viewport = window_size;

            var current_viewport = [1]gl.GLint{0} ** 4;
            gl.glGetIntegerv(gl.GL_VIEWPORT, &current_viewport);

            if (!viewportParamsMatchWindow(current_viewport, window_size)) {
                std.log.warn("Viewport should match provided window", .{});
            }

            var scissor_enabled: c_int = 0;
            gl.glGetIntegerv(gl.GL_SCISSOR_TEST, &scissor_enabled);

            if (scissor_enabled != 0) {
                gl.glGetIntegerv(gl.GL_SCISSOR_BOX, &current_viewport);
                if (!viewportParamsMatchWindow(current_viewport, window_size)) {
                    std.log.warn("Scissor box should match provided window", .{});
                }
            }
        }
    };
}

fn viewportParamsMatchWindow(params: [4]gl.GLint, window_size: gui.PixelSize) bool {
    return params[0] == 0 and params[1] == 0 and params[2] == window_size.width and params[3] == window_size.height;
}
