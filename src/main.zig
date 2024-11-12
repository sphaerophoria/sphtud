const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const App = @import("App.zig");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "");
    @cDefine("CIMGUI_USE_GLFW", "");
    @cDefine("CIMGUI_USE_OPENGL3", "");

    @cInclude("cimgui.h");
    @cInclude("cimgui_impl.h");
});
const glfwb = c;

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

const Imgui = struct {
    const null_size = c.ImVec2{ .x = 0, .y = 0 };

    const UpdatedObjectSelection = usize;

    fn init(glfw: *Glfw) !void {
        _ = c.igCreateContext(null);
        errdefer c.igDestroyContext(null);

        if (!c.ImGui_ImplGlfw_InitForOpenGL(glfw.window, true)) {
            return error.InitImGuiGlfw;
        }
        errdefer c.ImGui_ImplGlfw_Shutdown();

        if (!c.ImGui_ImplOpenGL3_Init("#version 130")) {
            return error.InitImGuiOgl;
        }
        errdefer c.ImGui_ImplOpenGL3_Shutdown();
    }

    fn deinit() void {
        c.ImGui_ImplOpenGL3_Shutdown();
        c.ImGui_ImplGlfw_Shutdown();
        c.igDestroyContext(null);
    }

    fn startFrame() void {
        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();
    }

    fn renderObjectList(objects: []App.Object, selected_idx: usize) !?UpdatedObjectSelection {
        _ = c.igBegin("Object list", null, 0);

        var ret: ?UpdatedObjectSelection = null;
        for (objects, 0..) |object, i| {
            var buf: [1024]u8 = undefined;
            const id = try std.fmt.bufPrintZ(&buf, "object_list_{d}", .{i});
            c.igPushID_Str(id);

            const name = try std.fmt.bufPrintZ(&buf, "{s}", .{object.name});
            if (c.igSelectable_Bool(name, selected_idx == i, 0, null_size)) {
                ret = i;
            }
            c.igPopID();
        }

        c.igEnd();
        return ret;
    }

    fn renderObjectProperties(selected_object: *App.Object) !void {
        if (!c.igBegin("Object properties", null, 0)) {
            return;
        }

        switch (selected_object.data) {
            .filesystem => |f| blk: {
                const table_ret = c.igBeginTable("table", 2, 0, null_size, 0);
                if (!table_ret) break :blk;

                c.igTableNextRow(0, 0);
                if (c.igTableNextColumn()) c.igText("Key");

                if (c.igTableNextColumn()) c.igText("Value");

                c.igTableNextRow(0, 0);

                if (c.igTableNextColumn()) c.igText("Source");

                var buf: [1024]u8 = undefined;
                const source = try std.fmt.bufPrintZ(&buf, "{s}", .{f.source});

                _ = c.igTableNextColumn();
                c.igText(source.ptr);

                c.igEndTable();
            },
            .composition => {
                c.igText("Composition");
            },
        }
        c.igEnd();
    }

    fn consumedMouseInput() bool {
        const io = c.igGetIO();
        return io.*.WantCaptureMouse;
    }

    fn renderFrame() void {
        c.igRender();
        c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
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

    try Imgui.init(&glfw);
    defer Imgui.deinit();

    var app = try App.init(alloc, window_width, window_height);
    defer app.deinit();

    switch (args.action) {
        .load => |s| {
            try app.load(s);
        },
        .open_images => |images| {
            try app.objects.append(alloc, .{ .name = try alloc.dupe(u8, "composition"), .data = .{ .composition = App.CompositionObject{} } });
            const composition_idx = app.objects.items.len - 1;
            for (images) |path| {
                const id = app.objects.items.len;
                try app.objects.append(alloc, .{ .name = try alloc.dupe(u8, path), .data = .{ .filesystem = try App.FilesystemObject.load(alloc, path) } });
                try app.objects.items[composition_idx].data.composition.objects.append(alloc, .{
                    .id = id,
                    .transform = App.Transform.scale(0.5, 0.5),
                });
            }
        },
    }

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();
        app.window_width = width;
        app.window_height = height;

        Imgui.startFrame();
        if (try Imgui.renderObjectList(app.objects.items, app.selected_object)) |idx| {
            app.selected_object = idx;
        }
        try Imgui.renderObjectProperties(&app.objects.items[app.selected_object]);

        const glfw_mouse = !Imgui.consumedMouseInput();
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
                .mouse_move => |p| if (glfw_mouse) {
                    app.setMousePos(p.x, p.y);
                },
                .mouse_up => if (glfw_mouse) app.setMouseUp(),
                .mouse_down => if (glfw_mouse) app.setMouseDown(),
            }
        }

        try app.render();
        Imgui.renderFrame();

        glfw.swapBuffers();
    }
}
