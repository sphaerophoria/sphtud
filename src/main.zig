const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const App = @import("App.zig");
const obj_mod = @import("object.zig");
const lin = @import("lin.zig");
const shader_storage = @import("shader_storage.zig");
const Renderer = @import("Renderer.zig");
const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const BrushId = shader_storage.BrushId;
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

const MousePos = struct { x: f32, y: f32 };
const WindowAction = union(enum) {
    key_down: struct { key: c_int, ctrl: bool },
    mouse_move: MousePos,
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
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_DEBUG_CONTEXT, 1);

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

    fn renderObjectList(objects: *obj_mod.Objects, selected_idx: obj_mod.ObjectId) !?obj_mod.ObjectId {
        _ = c.igBegin("Object list", null, 0);

        var ret: ?obj_mod.ObjectId = null;
        var it = objects.idIter();
        while (it.next()) |object_id| {
            const object = objects.get(object_id);
            var buf: [1024]u8 = undefined;
            const id = try std.fmt.bufPrintZ(&buf, "object_list_{d}", .{object_id.value});
            c.igPushID_Str(id);

            const name = try std.fmt.bufPrintZ(&buf, "{s}", .{object.name});
            if (c.igSelectable_Bool(name, selected_idx.value == object_id.value, 0, null_size)) {
                ret = object_id;
            }
            c.igPopID();
        }

        c.igEnd();
        return ret;
    }

    const PropertyAction = union(enum) {
        delete_from_composition: obj_mod.CompositionIdx,
        add_to_composition: obj_mod.ObjectId,
        update_path_display_obj: obj_mod.ObjectId,
        set_shader_binding_value: struct {
            // FIXME: strong type?
            idx: usize,
            val: Renderer.UniformValue,
        },
        set_shader_primary_input: usize,
    };

    fn renderObjectProperties(selected_object_id: obj_mod.ObjectId, objects: *obj_mod.Objects, shaders: ShaderStorage(ShaderId)) !?PropertyAction {
        const selected_object = objects.get(selected_object_id);
        if (!c.igBegin("Object properties", null, 0)) {
            return null;
        }

        var ret: ?PropertyAction = null;
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

                c.igTableNextRow(0, 0);
                if (c.igTableNextColumn()) c.igText("Width");
                if (c.igTableNextColumn()) c.igText("%lu", f.width);

                c.igTableNextRow(0, 0);
                if (c.igTableNextColumn()) c.igText("Height");
                if (c.igTableNextColumn()) c.igText("%lu", f.height);

                c.igEndTable();
            },
            .composition => |*comp| blk: {
                c.igText("Composition");
                const table_ret = c.igBeginTable("table", 2, 0, null_size, 0);
                if (!table_ret) break :blk;

                const dims = selected_object.dims(objects);

                c.igTableNextRow(0, 0);
                if (c.igTableNextColumn()) c.igText("Width");
                if (c.igTableNextColumn()) c.igText("%lu", dims[0]);

                c.igTableNextRow(0, 0);
                if (c.igTableNextColumn()) c.igText("Height");
                if (c.igTableNextColumn()) c.igText("%lu", dims[1]);

                c.igEndTable();

                for (comp.objects.items, 0..) |child, idx| {
                    const child_obj = objects.get(child.id);
                    var buf: [1024]u8 = undefined;
                    const delete_s = try std.fmt.bufPrintZ(&buf, "Delete##composition_item_{d}", .{idx});
                    if (c.igButton(delete_s, null_size)) {
                        ret = .{ .delete_from_composition = .{ .value = idx } };
                    }

                    c.igSameLine(0, 0);
                    c.igText(" %.*s", child_obj.name.len, child_obj.name.ptr);
                }

                if (!c.igBeginCombo("Availble objects", "Select to add", 0)) break :blk;
                if (try addComposableObjects(objects, "compose", null, null)) |selected| {
                    ret = .{
                        .add_to_composition = selected,
                    };
                }
                c.igEndCombo();
            },
            .shader => |shader_object| {
                c.igText("Shader");

                const program = shaders.get(shader_object.program).program;
                for (0..program.uniforms.len) |idx| {
                    if (try renderShaderUniform(idx, shader_object.bindings, program, objects, selected_object_id)) |action| {
                        ret = action;
                    }
                }

                var primary_input_idx: c_int = @intCast(shader_object.primary_input_idx);
                if (c.igInputInt("Primary input idx", &primary_input_idx, 1, 1, 0)) {
                    if (primary_input_idx < 0) primary_input_idx = 0;
                    ret = .{
                        .set_shader_primary_input = @intCast(primary_input_idx),
                    };
                }
            },
            .path => |p| {
                c.igText("Path");

                var source_name_buf: [1024]u8 = undefined;
                const source_name = try std.fmt.bufPrintZ(&source_name_buf, "{s}", .{objects.get(p.display_object).name});
                if (c.igBeginCombo("Source object", source_name, 0)) {
                    if (try addComposableObjects(objects, "path_display_object", p.display_object, null)) |new_source| {
                        ret = .{
                            .update_path_display_obj = new_source,
                        };
                    }
                    c.igEndCombo();
                }
            },
            .generated_mask => {
                c.igText("Generated mask");
            },
        }
        c.igEnd();

        return ret;
    }

    const AddObjectAction = union(enum) {
        shader_object: ShaderId,
        create_path,
        create_composition,
    };

    fn renderAddObjectView(shaders: ShaderStorage(ShaderId)) !?AddObjectAction {
        if (!c.igBegin("Create an object", null, 0)) {
            return null;
        }

        var ret: ?AddObjectAction = null;
        if (c.igBeginCombo("Add shader", "Add shader", 0)) {
            var shader_it = shaders.idIter();
            while (shader_it.next()) |id| {
                const name = shaders.get(id).name;
                var name_buf: [1024]u8 = undefined;

                const label = try std.fmt.bufPrintZ(&name_buf, "{s}##add_shader_{d}", .{ name, id.value });

                if (c.igSelectable_Bool(label, false, 0, null_size)) {
                    ret = .{ .shader_object = id };
                }
            }

            c.igEndCombo();
        }

        if (c.igButton("Create path", null_size)) {
            ret = .create_path;
        }

        if (c.igButton("Create composition", null_size)) {
            ret = .create_composition;
        }

        c.igEnd();

        return ret;
    }

    fn addComposableObjects(objects: *obj_mod.Objects, purpose: []const u8, selected: ?obj_mod.ObjectId, rejected_id: ?obj_mod.ObjectId) !?obj_mod.ObjectId {
        var ret: ?obj_mod.ObjectId = null;
        var obj_it = objects.idIter();
        while (obj_it.next()) |obj_id| {
            if (rejected_id != null and obj_id.value == rejected_id.?.value) continue;
            const obj = objects.get(obj_id);
            if (!obj.isComposable()) continue;

            var buf: [1024]u8 = undefined;
            const obj_namez = try std.fmt.bufPrintZ(&buf, "{s}##{s}_{d}", .{ obj.name, purpose, obj_id.value });
            const clicked = c.igSelectable_Bool(
                obj_namez.ptr,
                selected != null and selected.?.value == obj_id.value,
                0,
                null_size,
            );

            if (clicked) {
                ret = obj_id;
            }
        }
        return ret;
    }

    fn renderShaderUniform(idx: usize, bindings: []const Renderer.UniformValue, program: Renderer.PlaneRenderProgram, objects: *obj_mod.Objects, selected_object_id: obj_mod.ObjectId) !?PropertyAction {
        var name_buf: [1024]u8 = undefined;
        const uniform = program.uniforms[idx];
        const name = try std.fmt.bufPrintZ(&name_buf, "{s}", .{uniform.name});

        var ret: ?PropertyAction = null;
        const binding = bindings[idx];
        switch (binding) {
            .image => |bound_object_id| {
                var bound_name_buf: [1024]u8 = undefined;
                const bound_object_name = if (bound_object_id) |id|
                    try std.fmt.bufPrintZ(&bound_name_buf, "{s}", .{objects.get(id).name})
                else
                    "none";

                if (c.igBeginCombo(name, bound_object_name, 0)) {
                    if (try addComposableObjects(objects, "uniform_input", null, selected_object_id)) |uniform_dep| {
                        ret = .{
                            .set_shader_binding_value = .{
                                .idx = idx,
                                .val = .{ .image = uniform_dep },
                            },
                        };
                    }
                    c.igEndCombo();
                }
            },
            .float => |f| {
                var val = f;
                if (c.igDragFloat(name, &val, 0.01, -std.math.inf(f32), std.math.inf(f32), "%.03f", 0)) {
                    ret = .{
                        .set_shader_binding_value = .{
                            .idx = idx,
                            .val = .{ .float = val },
                        },
                    };
                }
            },
            .float2 => |f| {
                var val = f;
                if (c.igDragFloat2(name, &val, 0.01, -std.math.inf(f32), std.math.inf(f32), "%.03f", 0)) {
                    ret = .{
                        .set_shader_binding_value = .{
                            .idx = idx,
                            .val = .{ .float2 = val },
                        },
                    };
                }
            },
            .float3 => |f| {
                var val = f;
                if (c.igColorEdit3(name, &val, c.ImGuiColorEditFlags_Float | c.ImGuiColorEditFlags_HDR)) {
                    ret = .{
                        .set_shader_binding_value = .{
                            .idx = idx,
                            .val = .{ .float3 = val },
                        },
                    };
                }
            },
            .int => |i| {
                var val = i;
                if (c.igDragInt(name, &val, 1, -std.math.maxInt(i32), std.math.maxInt(i32), null, 0)) {
                    ret = .{
                        .set_shader_binding_value = .{
                            .idx = idx,
                            .val = .{ .int = val },
                        },
                    };
                }
            },
        }

        return ret;
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
        new: struct {
            brushes: []const [:0]const u8,
            shaders: []const [:0]const u8,
            images: []const [:0]const u8,
        },
    };

    const ParseState = enum {
        unknown,
        brushes,
        shaders,
        images,

        fn parse(arg: []const u8) ParseState {
            return std.meta.stringToEnum(ParseState, arg[2..]) orelse return .unknown;
        }
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

        var shaders = std.ArrayList([:0]const u8).init(alloc);
        defer shaders.deinit();

        var brushes = std.ArrayList([:0]const u8).init(alloc);
        defer brushes.deinit();

        var parse_state = ParseState.parse(first_arg);
        while (it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) {
                const new_state = ParseState.parse(arg);
                if (new_state == .unknown) {
                    std.log.err("Unknown switch {s}", .{arg});
                    help(process_name);
                }
                parse_state = new_state;
                continue;
            }

            switch (parse_state) {
                .unknown => {
                    std.log.err("Please specify one of --load, --images, --shaders, --brushes", .{});
                    help(process_name);
                },
                .images => try images.append(arg),
                .brushes => try brushes.append(arg),
                .shaders => try shaders.append(arg),
            }
        }

        return .{
            .action = .{
                .new = .{
                    .images = try images.toOwnedSlice(),
                    .shaders = try shaders.toOwnedSlice(),
                    .brushes = try brushes.toOwnedSlice(),
                },
            },
            .it = it,
        };
    }

    fn deinit(self: *Args, alloc: Allocator) void {
        switch (self.action) {
            .load => {},
            .new => |items| {
                alloc.free(items.images);
                alloc.free(items.brushes);
                alloc.free(items.shaders);
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
            \\{s} --images <image.png> <image2.png> --shaders <shader1.glsl> ... --brushes <brush1.glsl> <brush2.glsl>...
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
        .new => |items| {
            for (items.images) |path| {
                _ = try app.loadImage(path);
            }
            for (items.shaders) |path| {
                _ = try app.loadShader(path);
            }
            for (items.brushes) |path| {
                _ = try app.loadBrush(path);
            }
        },
    }

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();
        app.view_state.window_width = width;
        app.view_state.window_height = height;

        Imgui.startFrame();
        if (try Imgui.renderObjectList(&app.objects, app.input_state.selected_object)) |idx| {
            app.setSelectedObject(idx);
        }

        if (try Imgui.renderObjectProperties(app.input_state.selected_object, &app.objects, app.shaders)) |action| {
            switch (action) {
                .delete_from_composition => |id| {
                    app.deleteFromComposition(id) catch |e| {
                        logError("Failed to delete item from composition", e, @errorReturnTrace());
                    };
                },
                .add_to_composition => |id| {
                    _ = app.addToComposition(id) catch |e| {
                        logError("Failed to add item to composition", e, @errorReturnTrace());
                    };
                },
                .update_path_display_obj => |id| {
                    app.updatePathDisplayObj(id) catch |e| {
                        logError("Failed to set path object", e, @errorReturnTrace());
                    };
                },
                .set_shader_binding_value => |params| {
                    app.setShaderDependency(params.idx, params.val) catch |e| {
                        logError("Failed to set shader dependency", e, @errorReturnTrace());
                    };
                },
                .set_shader_primary_input => |idx| {
                    app.setShaderPrimaryInput(idx) catch |e| {
                        logError("Failed to set primary input", e, @errorReturnTrace());
                    };
                },
            }
        }

        if (try Imgui.renderAddObjectView(app.shaders)) |action| {
            switch (action) {
                .shader_object => |id| {
                    // FIXME: Sane size
                    _ = try app.addShaderObject("new shader", id);
                },
                .create_path => {
                    _ = try app.createPath();
                },
                .create_composition => {
                    _ = try app.addComposition();
                },
            }
        }

        const glfw_mouse = !Imgui.consumedMouseInput();
        var last_mouse: ?MousePos = null;
        while (glfw.queue.readItem()) |action| {
            switch (action) {
                .key_down => |key| {
                    if (key.key >= glfwb.GLFW_KEY_0 and key.key <= glfwb.GLFW_KEY_Z) {
                        try app.setKeyDown(@intCast(key.key), key.ctrl);
                    }
                },
                .mouse_move => |p| if (glfw_mouse) {
                    last_mouse = p;
                },
                .mouse_up => if (glfw_mouse) app.setMouseUp(),
                .mouse_down => if (glfw_mouse) app.setMouseDown(),
                .middle_up => if (glfw_mouse) app.setMiddleUp(),
                .middle_down => if (glfw_mouse) app.setMiddleDown(),
                .right_click => if (glfw_mouse) try app.clickRightMouse(),
                .scroll => |amount| if (glfw_mouse) {
                    app.scroll(amount);
                },
            }
        }

        if (last_mouse) |p| {
            try app.setMousePos(p.x, p.y);
        }

        try app.render();
        Imgui.renderFrame();

        glfw.swapBuffers();
    }
}
