const std = @import("std");
const Allocator = std.mem.Allocator;
const glfwb = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const gl = @import("gl.zig");
const App = @import("App.zig");

fn logError(comptime msg: []const u8, e: anyerror, trace: ?*std.builtin.StackTrace) void {
    std.log.err(msg ++ ": {s}", .{@errorName(e)});
    if (trace) |t| std.debug.dumpStackTrace(t.*);
}

fn errorCallbackGlfw(_: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("Error: {s}\n", .{std.mem.span(description)});
}

fn keyCallbackGlfw(window: ?*glfwb.GLFWwindow, key: c_int, _: c_int, action: c_int, modifiers: c_int) callconv(.C) void {
    if (action != glfwb.GLFW_PRESS) {
        return;
    }

    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    glfw.queue.writeItem(.{
        .key_down = .{
            .key = key,
            .ctrl = (modifiers & glfwb.GLFW_MOD_CONTROL) != 0,
        },
    }) catch |e| {
        logError("Failed to write key press", e, @errorReturnTrace());
    };
}

fn cursorPositionCallbackGlfw(window: ?*glfwb.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    glfw.queue.writeItem(.{
        .mouse_move = .{
            .x = @floatCast(xpos),
            .y = @floatCast(ypos),
        },
    }) catch |e| {
        logError("Failed to write mouse movement", e, @errorReturnTrace());
    };
}

fn mouseButtonCallbackGlfw(window: ?*glfwb.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.C) void {
    if (button != glfwb.GLFW_MOUSE_BUTTON_LEFT) {
        return;
    }

    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    const is_down = action == glfwb.GLFW_PRESS;
    const write_obj: WindowAction = if (is_down) .mouse_down else .mouse_up;

    glfw.queue.writeItem(write_obj) catch |e| {
        logError("Failed to write mouse press/release", e, @errorReturnTrace());
    };
}

const WindowAction = union(enum) {
    key_down: struct { key: c_int, ctrl: bool },
    mouse_move: struct { x: f32, y: f32 },
    mouse_down,
    mouse_up,
};

const Glfw = struct {
    window: *glfwb.GLFWwindow = undefined,
    queue: Fifo = undefined,

    const Fifo = std.fifo.LinearFifo(WindowAction, .{ .Static = 1024 });

    fn initPinned(self: *Glfw, window_width: comptime_int, window_height: comptime_int) !void {
        _ = glfwb.glfwSetErrorCallback(errorCallbackGlfw);

        if (glfwb.glfwInit() != glfwb.GLFW_TRUE) {
            return error.GLFWInit;
        }
        errdefer glfwb.glfwTerminate();

        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MINOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_PROFILE, glfwb.GLFW_OPENGL_CORE_PROFILE);

        const window = glfwb.glfwCreateWindow(window_width, window_height, "sphimp", null, null);
        if (window == null) {
            return error.CreateWindow;
        }
        errdefer glfwb.glfwDestroyWindow(window);

        _ = glfwb.glfwSetKeyCallback(window, keyCallbackGlfw);
        _ = glfwb.glfwSetCursorPosCallback(window, cursorPositionCallbackGlfw);
        _ = glfwb.glfwSetMouseButtonCallback(window, mouseButtonCallbackGlfw);

        glfwb.glfwMakeContextCurrent(window);
        glfwb.glfwSwapInterval(1);

        glfwb.glfwSetWindowUserPointer(window, self);

        self.* = .{
            .window = window.?,
            .queue = Fifo.init(),
        };
    }

    fn deinit(self: *Glfw) void {
        glfwb.glfwDestroyWindow(self.window);
        glfwb.glfwTerminate();
    }

    fn closed(self: *Glfw) bool {
        return glfwb.glfwWindowShouldClose(self.window) == glfwb.GLFW_TRUE;
    }

    fn getWindowSize(self: *Glfw) struct { usize, usize } {
        var width: c_int = 0;
        var height: c_int = 0;
        glfwb.glfwGetFramebufferSize(self.window, &width, &height);
        return .{ @intCast(width), @intCast(height) };
    }

    fn swapBuffers(self: *Glfw) void {
        glfwb.glfwSwapBuffers(self.window);
        glfwb.glfwPollEvents();
    }
};

const Args = struct {
    action: Action,
    it: std.process.ArgIterator,

    const Action = union(enum) {
        load: []const u8,
        open_images: [][:0]const u8,
    };

    fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "sphimp";

        const first_arg = it.next() orelse help(process_name);

        if (std.mem.eql(u8, first_arg, "--load")) {
            const save = it.next() orelse {
                std.log.err("No save file provided for --load", .{});
                help(process_name);
            };

            return .{
                .action = .{ .load = save },
                .it = it,
            };
        }

        var images = std.ArrayList([:0]const u8).init(alloc);
        defer images.deinit();

        try images.append(first_arg);

        while (it.next()) |arg| {
            try images.append(arg);
        }

        return .{
            .action = .{ .open_images = try images.toOwnedSlice() },
            .it = it,
        };
    }

    fn deinit(self: *Args, alloc: Allocator) void {
        switch (self.action) {
            .load => {},
            .open_images => |images| {
                alloc.free(images);
            },
        }

        self.it.deinit();
    }

    fn help(process_name: []const u8) noreturn {
        const stderr = std.io.getStdErr().writer();

        stderr.print(
            \\USAGE:
            \\{s} --load <save.json>
            \\OR
            \\{s} <image.png> <image2.png> ...
            \\
        , .{ process_name, process_name }) catch {};
        std.process.exit(1);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit(alloc);

    const window_width = 640;
    const window_height = 480;

    var glfw = Glfw{};

    try glfw.initPinned(window_width, window_height);
    defer glfw.deinit();

    var app = try App.init(alloc, window_width, window_height);
    defer app.deinit();

    switch (args.action) {
        .load => |s| {
            try app.load(s);
        },
        .open_images => |images| {
            for (images) |path| {
                try app.objects.append(alloc, try App.Object.loadFromImagePath(alloc, path));
            }
        },
    }

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();
        app.window_width = width;
        app.window_height = height;

        while (glfw.queue.readItem()) |action| {
            switch (action) {
                .key_down => |key| {
                    switch (key.key) {
                        glfwb.GLFW_KEY_S => {
                            if (key.ctrl) {
                                try app.save("save.json");
                            }
                        },
                        else => {},
                    }
                },
                .mouse_move => |p| {
                    app.setMousePos(p.x, p.y);
                },
                .mouse_up => app.setMouseUp(),
                .mouse_down => app.setMouseDown(),
            }
        }
        app.render();
        glfw.swapBuffers();
    }
}
