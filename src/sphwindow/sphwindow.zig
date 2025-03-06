const std = @import("std");
const glfwb = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const gui = @import("sphui");

pub const Window = struct {
    window: *glfwb.GLFWwindow = undefined,
    queue: Fifo = undefined,

    const Fifo = std.fifo.LinearFifo(gui.WindowAction, .{ .Static = 1024 });

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

        _ = glfwb.glfwSetKeyCallback(window, keyCallbackGlfw);
        _ = glfwb.glfwSetCursorPosCallback(window, cursorPositionCallbackGlfw);
        _ = glfwb.glfwSetMouseButtonCallback(window, mouseButtonCallbackGlfw);
        _ = glfwb.glfwSetScrollCallback(window, scrollCallbackGlfw);

        glfwb.glfwMakeContextCurrent(window);
        glfwb.glfwSwapInterval(1);

        glfwb.glfwSetWindowUserPointer(window, self);

        self.* = .{
            .window = window.?,
            .queue = Fifo.init(),
        };
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
    if (trace) |t| std.debug.dumpStackTrace(t.*);
}

fn errorCallbackGlfw(_: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("Error: {s}\n", .{std.mem.span(description)});
}

fn keyCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, key: c_int, _: c_int, action: c_int, modifiers: c_int) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));

    const key_char: gui.Key = switch (key) {
        glfwb.GLFW_KEY_A...glfwb.GLFW_KEY_Z => blk: {
            const base_char: u8 = if (modifiers & glfwb.GLFW_MOD_SHIFT != 0) 'A' else 'a';
            break :blk .{ .ascii = @intCast(key - glfwb.GLFW_KEY_A + base_char) };
        },
        glfwb.GLFW_KEY_GRAVE_ACCENT => .{ .ascii = @intCast('`') },
        glfwb.GLFW_KEY_COMMA...glfwb.GLFW_KEY_9 => .{ .ascii = @intCast(key - glfwb.GLFW_KEY_COMMA + ',') },
        glfwb.GLFW_KEY_SPACE => .{ .ascii = ' ' },
        glfwb.GLFW_KEY_LEFT => .left_arrow,
        glfwb.GLFW_KEY_RIGHT => .right_arrow,
        glfwb.GLFW_KEY_BACKSPACE => .backspace,
        glfwb.GLFW_KEY_DELETE => .delete,
        glfwb.GLFW_KEY_ESCAPE => .escape,
        else => return,
    };

    if (action == glfwb.GLFW_PRESS) {
        window.queue.writeItem(.{
            .key_down = .{
                .key = key_char,
                .ctrl = (modifiers & glfwb.GLFW_MOD_CONTROL) != 0,
            },
        }) catch |e| {
            logError("Failed to write key press", e, @errorReturnTrace());
        };
    } else if (action == glfwb.GLFW_RELEASE) {
        window.queue.writeItem(.{
            .key_up = key_char,
        }) catch |e| {
            logError("Failed to write key release", e, @errorReturnTrace());
        };
    }
}

fn cursorPositionCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));
    window.queue.writeItem(.{
        .mouse_move = .{
            .x = @floatCast(xpos),
            .y = @floatCast(ypos),
        },
    }) catch |e| {
        logError("Failed to write mouse movement", e, @errorReturnTrace());
    };
}

fn mouseButtonCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));
    const is_down = action == glfwb.GLFW_PRESS;
    var write_obj: ?gui.WindowAction = null;

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
        window.queue.writeItem(w) catch |e| {
            logError("Failed to write mouse press/release", e, @errorReturnTrace());
        };
    }
}

fn scrollCallbackGlfw(glfw_window: ?*glfwb.GLFWwindow, _: f64, y: f64) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(glfw_window)));
    window.queue.writeItem(.{
        .scroll = @floatCast(y),
    }) catch |e| {
        logError("Failed to write scroll", e, @errorReturnTrace());
    };
}
