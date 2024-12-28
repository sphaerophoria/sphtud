const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const sphimp = @import("sphimp");
const App = sphimp.App;
const obj_mod = sphimp.object;
const shader_storage = sphimp.shader_storage;
const Renderer = sphimp.Renderer;
const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const FontStorage = sphimp.FontStorage;
const BrushId = shader_storage.BrushId;
const gui = @import("sphui");
const ui_action = @import("sphimp_ui/ui_action.zig");
const AppWidget = @import("sphimp_ui/AppWidget.zig");
const logError = @import("sphimp_ui/util.zig").logError;
const list_io = @import("sphimp_ui/list_io.zig");
const label_adaptors = @import("sphimp_ui/label_adaptors.zig");
const float_adaptors = @import("sphimp_ui/float_adaptors.zig");
const color_adaptors = @import("sphimp_ui/color_adaptors.zig");
const sidebar_mod = @import("sphimp_ui/sidebar.zig");
const UiAction = ui_action.UiAction;
const UiActionType = ui_action.UiActionType;
const WindowAction = gui.WindowAction;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const glfwb = c;
const ObjectId = obj_mod.ObjectId;

fn errorCallbackGlfw(_: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("Error: {s}\n", .{std.mem.span(description)});
}

fn keyCallbackGlfw(window: ?*glfwb.GLFWwindow, key: c_int, _: c_int, action: c_int, modifiers: c_int) callconv(.C) void {
    if (action != glfwb.GLFW_PRESS) {
        return;
    }

    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));

    const key_char: gui.Key = switch (key) {
        glfwb.GLFW_KEY_A...glfwb.GLFW_KEY_Z => .{ .ascii = @intCast(key - glfwb.GLFW_KEY_A + 'a') },
        glfwb.GLFW_KEY_COMMA...glfwb.GLFW_KEY_9 => .{ .ascii = @intCast(key - glfwb.GLFW_KEY_COMMA + ',') },
        glfwb.GLFW_KEY_SPACE => .{ .ascii = ' ' },
        glfwb.GLFW_KEY_LEFT => .left_arrow,
        glfwb.GLFW_KEY_RIGHT => .right_arrow,
        glfwb.GLFW_KEY_BACKSPACE => .backspace,
        glfwb.GLFW_KEY_DELETE => .delete,
        else => return,
    };

    glfw.queue.writeItem(.{
        .key_down = .{
            .key = key_char,
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
        glfwb.glfwWindowHint(glfwb.GLFW_SAMPLES, 4);

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

const Args = struct {
    action: Action,
    it: std.process.ArgIterator,

    const Action = union(enum) {
        load: []const u8,
        new: struct {
            brushes: []const [:0]const u8,
            shaders: []const [:0]const u8,
            images: []const [:0]const u8,
            fonts: []const [:0]const u8,
        },
    };

    const ParseState = enum {
        unknown,
        brushes,
        shaders,
        images,
        fonts,

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

        var fonts = std.ArrayList([:0]const u8).init(alloc);
        defer fonts.deinit();

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
                .fonts => try fonts.append(arg),
            }
        }

        return .{
            .action = .{
                .new = .{
                    .images = try images.toOwnedSlice(),
                    .shaders = try shaders.toOwnedSlice(),
                    .brushes = try brushes.toOwnedSlice(),
                    .fonts = try fonts.toOwnedSlice(),
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
                alloc.free(items.fonts);
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
            \\{s} --images <image.png> <image2.png> --shaders <shader1.glsl> ... --brushes <brush1.glsl> <brush2.glsl>... --fonts <font1.ttf> <font2.ttf>...
            \\
        , .{ process_name, process_name }) catch {};
        std.process.exit(1);
    }
};

const background_fragment_shader =
    \\#version 330
    \\
    \\out vec4 fragment;
    \\uniform vec3 color = vec3(1.0, 1.0, 1.0);
    \\
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit(alloc);

    const window_width = 1024;
    const window_height = 600;

    var glfw = Glfw{};

    try glfw.initPinned(window_width, window_height);
    defer glfw.deinit();

    sphrender.gl.glEnable(sphrender.gl.GL_MULTISAMPLE);
    sphrender.gl.glEnable(sphrender.gl.GL_SCISSOR_TEST);
    sphrender.gl.glBlendFunc(sphrender.gl.GL_SRC_ALPHA, sphrender.gl.GL_ONE_MINUS_SRC_ALPHA);
    sphrender.gl.glEnable(sphrender.gl.GL_BLEND);

    var app = try App.init(alloc, window_width, window_height);
    defer app.deinit();

    const background_shader_id = try app.addShaderFromFragmentSource("constant color", background_fragment_shader);

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

            for (items.fonts) |path| {
                _ = try app.loadFont(path);
            }

            if (items.images.len == 0) {
                _ = try app.addShaderObject("background", background_shader_id);
                const drawing = try app.addDrawing();
                app.setSelectedObject(drawing);
            }
        },
    }

    const widget_factory = try gui.widget_factory.widgetFactory(UiAction, alloc);
    defer widget_factory.deinit();

    const toplevel_layout = try widget_factory.makeLayout();
    toplevel_layout.cursor.direction = .horizontal;
    toplevel_layout.item_pad = 0;

    const sidebar = try sidebar_mod.makeSidebar(&app, widget_factory);
    try toplevel_layout.pushOrDeinitWidget(widget_factory.alloc, sidebar.widget);

    const app_widget = try AppWidget.init(alloc, &app, .{ .width = window_width, .height = window_height });
    try toplevel_layout.pushOrDeinitWidget(widget_factory.alloc, app_widget);

    var gui_runner = try widget_factory.makeRunnerOrDeinit(toplevel_layout.asWidget());
    defer gui_runner.deinit();

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();

        sphrender.gl.glViewport(0, 0, @intCast(width), @intCast(height));
        sphrender.gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const window_size = gui.PixelSize{
            .width = @intCast(width),
            .height = @intCast(height),
        };

        const window_bounds = gui.PixelBBox{
            .left = 0,
            .top = 0,
            .right = window_size.width,
            .bottom = window_size.height,
        };

        const selected_object = app.input_state.selected_object;
        if (try gui_runner.step(window_bounds, window_size, &glfw.queue)) |action| exec_action: {
            switch (action) {
                .update_selected_object => |id| {
                    app.setSelectedObject(id);
                },
                .create_path => {
                    const new_obj = app.createPath() catch |e| {
                        logError("failed to create path", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    app.setSelectedObject(new_obj);
                },
                .create_composition => {
                    const new_obj = app.addComposition() catch |e| {
                        logError("failed to create composition", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    app.setSelectedObject(new_obj);
                },
                .create_drawing => {
                    const new_obj = app.addDrawing() catch |e| {
                        logError("failed to create drawing", e, @errorReturnTrace());
                        break :exec_action;
                    };

                    app.setSelectedObject(new_obj);
                },
                .create_text => {
                    const new_obj = app.addText() catch |e| {
                        logError("failed to create text", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    app.setSelectedObject(new_obj);
                },
                .create_shader => |id| {
                    const new_obj = app.addShaderObject("new shader", id) catch |e| {
                        logError("failed to create shader", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    app.setSelectedObject(new_obj);
                },
                .delete_selected_object => {
                    app.deleteSelectedObject() catch |e| {
                        logError("failed to delete object", e, @errorReturnTrace());
                        break :exec_action;
                    };
                },
                .edit_selected_object_name => |params| {
                    const name = app.objects.get(app.input_state.selected_object).name;
                    var edit_name = std.ArrayListUnmanaged(u8){};
                    defer edit_name.deinit(alloc);

                    // FIXME: Should we crash on failure?
                    try edit_name.appendSlice(alloc, name);
                    try gui.textbox.executeTextEditOnArrayList(alloc, &edit_name, params.pos, params.notifier, params.items);

                    try app.updateSelectedObjectName(edit_name.items);
                },
                .update_composition_width => |new_width| {
                    app.updateSelectedWidth(new_width) catch |e| {
                        logError("Failed to update selected object width", e, @errorReturnTrace());
                    };
                },
                .update_composition_height => |new_height| {
                    app.updateSelectedHeight(new_height) catch |e| {
                        logError("Failed to update selected object width", e, @errorReturnTrace());
                    };
                },
                .update_shader_float => |params| {
                    app.setShaderFloat(params.uniform_idx, params.float_idx, params.val) catch |e| {
                        logError("Failed to update shader float", e, @errorReturnTrace());
                    };
                },
                .update_shader_color => |params| {
                    inline for (&.{ "r", "g", "b" }, 0..) |field, i| {
                        app.setShaderFloat(params.uniform_idx, i, @field(params.color, field)) catch |e| {
                            logError("Failed to update shader " ++ field, e, @errorReturnTrace());
                        };
                    }
                },
                .update_shader_image => |params| {
                    app.setShaderImage(params.uniform_idx, params.image) catch |e| {
                        logError("Failed to update shader image", e, @errorReturnTrace());
                    };
                },
                .update_drawing_source => |id| {
                    app.updateDrawingDisplayObj(id) catch |e| {
                        logError("Failed to update drawing source", e, @errorReturnTrace());
                    };
                },
                .update_brush => |id| {
                    app.setDrawingObjectBrush(id) catch |e| {
                        logError("Failed to chnage brush", e, @errorReturnTrace());
                    };
                    try sidebar.handle.updateObjectProperties();
                },
                .update_path_source => |id| {
                    app.updatePathDisplayObj(id) catch |e| {
                        logError("Failed to update path source", e, @errorReturnTrace());
                    };
                },
                .update_text_obj_name => |params| text_update: {
                    const text = app.selectedObject().asText() orelse break :text_update;
                    var edit = std.ArrayListUnmanaged(u8){};
                    defer edit.deinit(alloc);

                    // FIXME: Should we crash on failure?
                    try edit.appendSlice(alloc, text.current_text);
                    try gui.textbox.executeTextEditOnArrayList(alloc, &edit, params.pos, params.notifier, params.items);

                    app.updateTextObjectContent(edit.items) catch |e| {
                        logError("Failed to set text content", e, @errorReturnTrace());
                    };
                },
                .update_selected_font => |font_id| {
                    app.updateFontId(font_id) catch |e| {
                        logError("Failed to set font id", e, @errorReturnTrace());
                    };
                },
                .update_text_size => |size| {
                    app.updateFontSize(size) catch |e| {
                        logError("Failed to set font size", e, @errorReturnTrace());
                    };
                },
                .add_to_composition => |id| blk: {
                    _ = app.addToComposition(id) catch |e| {
                        logError("Failed to add object to composition", e, @errorReturnTrace());
                        break :blk;
                    };
                    try sidebar.handle.updateObjectProperties();
                },
                .delete_from_composition => |idx| {
                    app.deleteFromComposition(.{ .value = idx }) catch |e| {
                        logError("Failed to delete object from composition", e, @errorReturnTrace());
                    };
                    try sidebar.handle.updateObjectProperties();
                },
            }
        }

        if (selected_object.value != app.input_state.selected_object.value) {
            try sidebar.handle.updateObjectProperties();
            sidebar.handle.notifyObjectChanged();
        }

        glfw.swapBuffers();
    }
}
