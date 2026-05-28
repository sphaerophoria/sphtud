const std = @import("std");
const glfwb = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const sphutil = @import("util.zig");
const sphwindow_events = @import("window_events.zig");

pub const Window = struct {
    window: *glfwb.GLFWwindow = undefined,
    queue_buf: [1024]sphwindow_events.WindowAction,
    queue: Fifo = undefined,

    const Fifo = sphutil.CircularBuffer(sphwindow_events.WindowAction);

    pub fn initPinned(self: *Window, name: [:0]const u8, window_width: comptime_int, window_height: comptime_int) !void {
        _ = glfwb.glfwSetErrorCallback(errorCallbackGlfw);

        if (glfwb.glfwInit() != glfwb.GLFW_TRUE) {
            return error.GLFWInit;
        }
        errdefer glfwb.glfwTerminate();

        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MINOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_PROFILE, glfwb.GLFW_OPENGL_CORE_PROFILE);
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_DEBUG_CONTEXT, 1);
        glfwb.glfwWindowHint(glfwb.GLFW_SAMPLES, 4);

        const window = glfwb.glfwCreateWindow(window_width, window_height, name, null, null);
        if (window == null) {
            return error.CreateWindow;
        }
        errdefer glfwb.glfwDestroyWindow(window);

        _ = glfwb.glfwSetCharCallback(window, charCallbackGlfw);
        _ = glfwb.glfwSetKeyCallback(window, keyCallbackGlfw);
        _ = glfwb.glfwSetCursorPosCallback(window, cursorPositionCallbackGlfw);
        _ = glfwb.glfwSetMouseButtonCallback(window, mouseButtonCallbackGlfw);
        _ = glfwb.glfwSetScrollCallback(window, scrollCallbackGlfw);

        glfwb.glfwMakeContextCurrent(window);
        glfwb.glfwSwapInterval(1);

        glfwb.glfwSetWindowUserPointer(window, self);

        self.* = .{
            .window = window.?,
            .queue_buf = undefined,
            .queue = undefined,
        };
        self.queue = .{ .items = &self.queue_buf };
    }

    pub fn glLoader(_: *Window) *const fn ([*c]const u8) callconv(.c) ?*const fn () callconv(.c) void {
        return @ptrCast(&glfwb.glfwGetProcAddress);
    }

    pub fn deinit(self: *Window) void {
        glfwb.glfwDestroyWindow(self.window);
        glfwb.glfwTerminate();
    }

    pub fn closed(self: *Window) bool {
        return glfwb.glfwWindowShouldClose(self.window) == glfwb.GLFW_TRUE;
    }

    pub fn getWindowSize(self: *Window) struct { usize, usize } {
        var width: c_int = 0;
        var height: c_int = 0;
        glfwb.glfwGetFramebufferSize(self.window, &width, &height);
        return .{ @intCast(width), @intCast(height) };
    }

    pub fn swapBuffers(self: *Window) void {
        glfwb.glfwSwapBuffers(self.window);
        glfwb.glfwPollEvents();
    }

    pub fn enableCursor(self: *Window) void {
        glfwb.glfwSetInputMode(self.window, glfwb.GLFW_CURSOR, glfwb.GLFW_CURSOR_NORMAL);
    }

    pub fn disableCursor(self: *Window) void {
        glfwb.glfwSetInputMode(self.window, glfwb.GLFW_CURSOR, glfwb.GLFW_CURSOR_DISABLED);
    }
};

fn logError(comptime msg: []const u8, e: anyerror, trace: ?*std.builtin.StackTrace) void {
    std.log.err(msg ++ ": {s}", .{@errorName(e)});
    if (trace) |t| std.debug.dumpErrorReturnTrace(t);
}

fn errorCallbackGlfw(_: c_int, description: [*c]const u8) callconv(.c) void {
    std.log.err("Error: {s}\n", .{std.mem.span(description)});
}

fn charCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));

    const ascii: u8 = if (codepoint <= 0x7f) @intCast(codepoint) else return;

    window.queue.pushNoClobber(.{
        .key_down = .{
            .key = .{ .ascii = ascii },
            .ctrl = false,
        },
    }) catch |e| {
        logError("Failed to write key press", e, @errorReturnTrace());
    };

    window.queue.pushNoClobber(.{
        .key_up = .{ .ascii = ascii },
    }) catch |e| {
        logError("Failed to write key release", e, @errorReturnTrace());
    };
}

fn keyCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, key: c_int, _: c_int, action: c_int, modifiers: c_int) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));

    const key_char: sphwindow_events.Key = switch (key) {
        glfwb.GLFW_KEY_LEFT => .left_arrow,
        glfwb.GLFW_KEY_RIGHT => .right_arrow,
        glfwb.GLFW_KEY_BACKSPACE => .backspace,
        glfwb.GLFW_KEY_DELETE => .delete,
        glfwb.GLFW_KEY_ESCAPE => .escape,
        else => return,
    };

    if (action == glfwb.GLFW_PRESS) {
        window.queue.pushNoClobber(.{
            .key_down = .{
                .key = key_char,
                .ctrl = (modifiers & glfwb.GLFW_MOD_CONTROL) != 0,
            },
        }) catch |e| {
            logError("Failed to write key press", e, @errorReturnTrace());
        };
    } else if (action == glfwb.GLFW_RELEASE) {
        window.queue.pushNoClobber(.{
            .key_up = key_char,
        }) catch |e| {
            logError("Failed to write key release", e, @errorReturnTrace());
        };
    }
}

fn cursorPositionCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));
    window.queue.pushNoClobber(.{
        .mouse_move = .{
            .x = @floatCast(xpos),
            .y = @floatCast(ypos),
        },
    }) catch |e| {
        logError("Failed to write mouse movement", e, @errorReturnTrace());
    };
}

fn mouseButtonCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));
    const is_down = action == glfwb.GLFW_PRESS;
    var write_obj: ?sphwindow_events.WindowAction = null;

    if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and is_down) {
        write_obj = .mouse_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and !is_down) {
        write_obj = .mouse_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and is_down) {
        write_obj = .middle_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and !is_down) {
        write_obj = .middle_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_RIGHT and is_down) {
        write_obj = .right_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_RIGHT and !is_down) {
        write_obj = .right_up;
    }

    if (write_obj) |w| {
        window.queue.pushNoClobber(w) catch |e| {
            logError("Failed to write mouse press/release", e, @errorReturnTrace());
        };
    }
}

fn scrollCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, _: f64, y: f64) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));
    window.queue.pushNoClobber(.{
        .scroll = @floatCast(y),
    }) catch |e| {
        logError("Failed to write scroll", e, @errorReturnTrace());
    };
}
