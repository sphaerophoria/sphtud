const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const Renderer = @import("Renderer.zig");
const lin = @import("lin.zig");
const coords = @import("coords.zig");
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
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    const is_down = action == glfwb.GLFW_PRESS;
    var write_obj: ?WindowAction = null;

    if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and is_down) {
        write_obj = .mouse_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and !is_down) {
        write_obj = .mouse_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and is_down) {
        write_obj = .middle_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and !is_down) {
        write_obj = .middle_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_RIGHT and is_down) {
        write_obj = .right_click;
    }

    if (write_obj) |w| {
        glfw.queue.writeItem(w) catch |e| {
            logError("Failed to write mouse press/release", e, @errorReturnTrace());
        };
    }
}

fn scrollCallbackGlfw(window: ?*glfwb.GLFWwindow, _: f64, y: f64) callconv(.C) void {
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    glfw.queue.writeItem(.{
        .scroll = @floatCast(y),
    }) catch |e| {
        logError("Failed to write scroll", e, @errorReturnTrace());
    };
}

const WindowAction = union(enum) {
    key_down: struct { key: c_int, ctrl: bool },
    mouse_move: struct { x: f32, y: f32 },
    mouse_down,
    mouse_up,
    middle_down,
    middle_up,
    right_click,
    scroll: f32,
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
        _ = glfwb.glfwSetScrollCallback(window, scrollCallbackGlfw);

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

const GuiTransform = union(enum) {
    scale: [2]f32,
    translation: [2]f32,
    rotation: f32,
};

const Imgui = struct {
    const null_size = c.ImVec2{ .x = 0, .y = 0 };

    transforms: std.ArrayList(GuiTransform),

    const UpdatedObjectSelection = usize;

    fn init(alloc: Allocator, glfw: *Glfw) !Imgui {
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

        const imgui_io = c.igGetIO();
        _ = c.ImFontAtlas_AddFontFromFileTTF(imgui_io[0].Fonts, "ttf/Hack-Regular.ttf", 20, null, null);

        return .{
            .transforms = std.ArrayList(GuiTransform).init(alloc),
        };
    }

    fn deinit(self: *Imgui) void {
        c.ImGui_ImplOpenGL3_Shutdown();
        c.ImGui_ImplGlfw_Shutdown();
        c.igDestroyContext(null);
        self.transforms.deinit();
    }

    fn startFrame() void {
        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();
    }

    fn renderUi(self: *Imgui) !void {
        _ = c.igBegin("Transform editor", null, 0);

        var to_remove: ?usize = null;
        var move_up: ?usize = null;
        var move_down: ?usize = null;

        for (self.transforms.items, 0..) |*transform, idx| {
            var buf: [1024]u8 = undefined;
            const delete_name = try std.fmt.bufPrintZ(&buf, "Delete##{d}", .{idx});
            if (c.igButton(delete_name, null_size)) {
                to_remove = idx;
            }
            c.igSameLine(0, c.igGetFontSize());
            const up_name = try std.fmt.bufPrintZ(&buf, "Up##{d}", .{idx});
            if (c.igButton(up_name, null_size)) {
                move_up = idx;
            }
            c.igSameLine(0, c.igGetFontSize());
            const down_name = try std.fmt.bufPrintZ(&buf, "Down##{d}", .{idx});
            if (c.igButton(down_name, null_size)) {
                move_down = idx;
            }
            switch (transform.*) {
                .scale => |*data| {
                    const name = try std.fmt.bufPrintZ(&buf, "Scale##{d}", .{idx});
                    _ = c.igDragFloat2(name, data, 0.01, -std.math.inf(f32), std.math.inf(f32), "%.02f", 0);
                },
                .translation => |*data| {
                    const name = try std.fmt.bufPrintZ(&buf, "Translation##{d}", .{idx});
                    _ = c.igDragFloat2(name, data, 0.01, -std.math.inf(f32), std.math.inf(f32), "%.02f", 0);
                },
                .rotation => |*data| {
                    const name = try std.fmt.bufPrintZ(&buf, "Rotation##{d}", .{idx});
                    _ = c.igDragFloat(name, data, 0.01, -std.math.inf(f32), std.math.inf(f32), "%.02f", 0);
                },
            }
        }

        if (to_remove) |remove_idx| {
            _ = self.transforms.orderedRemove(remove_idx);
        }

        if (move_up) |move_idx| blk: {
            if (move_idx == 0) break :blk;
            std.mem.swap(GuiTransform, &self.transforms.items[move_idx], &self.transforms.items[move_idx - 1]);
        }

        if (move_down) |move_idx| blk: {
            if (move_idx + 1 == self.transforms.items.len) break :blk;
            std.mem.swap(GuiTransform, &self.transforms.items[move_idx], &self.transforms.items[move_idx + 1]);
        }

        if (c.igBeginCombo("##Add transform", "Add transform", 0)) {
            if (c.igSelectable_Bool("Scale", false, 0, null_size)) {
                try self.transforms.append(.{
                    .scale = .{ 1.0, 1.0 },
                });
            }
            if (c.igSelectable_Bool("Translation", false, 0, null_size)) {
                try self.transforms.append(.{
                    .translation = .{ 0.0, 0.0 },
                });
            }
            if (c.igSelectable_Bool("Rotation", false, 0, null_size)) {
                try self.transforms.append(.{
                    .rotation = 0.0,
                });
            }
            c.igEndCombo();
        }

        c.igEnd();
    }

    fn renderTransform(self: *Imgui, transform: lin.Transform) !void {
        _ = self;
        _ = c.igBegin("Transform", null, 0);
        if (c.igBeginTable("transform table", 3, 0, null_size, 1.0)) {
            for (0..3) |y| {
                c.igTableNextRow(0, 0);
                const row_start = y * 3;
                const row_end = row_start + 3;
                const row = transform.inner.data[row_start..row_end];
                if (c.igTableNextColumn()) c.igText("%.03f", row[0]);
                if (c.igTableNextColumn()) c.igText("%.03f", row[1]);
                if (c.igTableNextColumn()) c.igText("%.03f", row[2]);
            }
            c.igEndTable();
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const window_width = 800;
    const window_height = 600;

    var glfw = Glfw{};

    try glfw.initPinned(window_width, window_height);
    defer glfw.deinit();

    var gui = try Imgui.init(alloc, &glfw);
    defer gui.deinit();

    const program = try Renderer.PlaneRenderProgram.init(alloc, Renderer.plane_vertex_shader, Renderer.plane_fragment_shader);
    defer program.deinit(alloc);

    const image_width = 600;
    const image_height = 600;
    const image = try alloc.alloc(u32, image_width * image_height);
    defer alloc.free(image);

    for (0..image_height) |y| {
        const g: u32 = @intCast(y * 255 / image_height);
        for (0..image_width) |x| {
            const r: u32 = @intCast(x * 255 / image_width);
            image[y * image_width + x] = 0xff000000 | r | g << 8;
        }
    }
    const texture = Renderer.makeTextureFromRgba(std.mem.sliceAsBytes(image), image_width);

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
        Imgui.startFrame();

        var transform = lin.Transform.identity;
        for (gui.transforms.items) |tx| {
            switch (tx) {
                .scale => |s| transform = transform.then(lin.Transform.scale(s[0], s[1])),
                .translation => |t| transform = transform.then(lin.Transform.translate(t[0], t[1])),
                .rotation => |t| transform = transform.then(lin.Transform.rotate(t)),
            }
        }
        const aspect_corrected = transform.then(coords.aspectRatioCorrectedFill(image_width, image_height, width, height));

        program.render(&.{.{ .image = texture.inner }}, aspect_corrected, image_width / image_height);

        try gui.renderUi();
        try gui.renderTransform(transform);

        const glfw_mouse = !Imgui.consumedMouseInput();
        _ = glfw_mouse;
        while (glfw.queue.readItem()) |action| {
            _ = action;
        }

        Imgui.renderFrame();

        glfw.swapBuffers();
    }
}
