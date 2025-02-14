const std = @import("std");
const sphalloc = @import("sphalloc");
const MemoryTracker = sphalloc.MemoryTracker;
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const sphimp = @import("sphimp");
const sphwindow = @import("sphwindow");
const App = sphimp.App;
const gui = @import("sphui");
const ui_action = @import("sphimp_ui/ui_action.zig");
const AppWidget = @import("sphimp_ui/AppWidget.zig");
const logError = @import("sphimp_ui/util.zig").logError;
const sidebar_mod = @import("sphimp_ui/sidebar.zig");
const UiAction = ui_action.UiAction;

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

const Allocators = struct {
    page: sphalloc.TinyPageAllocator(100),
    root: sphalloc.Sphalloc,
    scratch: sphalloc.ScratchAlloc,

    fn initPinned(self: *Allocators) !void {
        self.page = .{ .page_allocator = std.heap.page_allocator };
        try self.root.initPinned(self.page.allocator(), "root");

        const scratch_tracker = try self.root.makeSubAlloc("scratch");
        const scratch_buf = try scratch_tracker.arena().alloc(u8, 10 * 1024 * 1024);
        self.scratch = sphalloc.ScratchAlloc.init(scratch_buf);
    }

    fn deinit(self: *Allocators) void {
        self.root.deinit();
    }
};

pub fn main() !void {
    var allocators: Allocators = undefined;
    try allocators.initPinned();
    defer allocators.deinit();

    const root_gpa = allocators.root.general();
    const root_arena = allocators.root.arena();

    const args = try Args.parse(root_gpa);

    const window_width = 1024;
    const window_height = 600;

    var window = sphwindow.Window{};

    try window.initPinned("sphimp", window_width, window_height);
    defer window.deinit();

    sphrender.gl.glEnable(sphrender.gl.GL_MULTISAMPLE);
    sphrender.gl.glEnable(sphrender.gl.GL_SCISSOR_TEST);
    sphrender.gl.glBlendFunc(sphrender.gl.GL_SRC_ALPHA, sphrender.gl.GL_ONE_MINUS_SRC_ALPHA);
    sphrender.gl.glEnable(sphrender.gl.GL_BLEND);

    var root_gl_alloc = try sphrender.GlAlloc.init(&allocators.root);
    defer root_gl_alloc.reset();

    const root_render_alloc = sphrender.RenderAlloc.init(&allocators.root, &root_gl_alloc);

    var scratch_gl = try root_gl_alloc.makeSubAlloc(&allocators.root);

    var app = try App.init(try root_render_alloc.makeSubAlloc("App"), &allocators.scratch, scratch_gl, window_width, window_height);
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

    const gui_alloc = try root_render_alloc.makeSubAlloc("gui");

    const widget_state = try gui.widget_factory.widgetState(UiAction, gui_alloc, &allocators.scratch, scratch_gl);

    const widget_factory = widget_state.factory(gui_alloc);

    const toplevel_layout = try widget_factory.makeLayout();
    toplevel_layout.cursor.direction = .horizontal;
    toplevel_layout.item_pad = 0;

    const sidebar = try sidebar_mod.makeSidebar(gui_alloc, &app, widget_state);
    try toplevel_layout.pushWidget(sidebar.widget);

    var memory_tracker = blk: {
        const now = try std.time.Instant.now();
        break :blk try MemoryTracker.init(root_arena, now, 1000, &allocators.root);
    };

    const memory_widget = try widget_factory.makeMemoryWidget(&memory_tracker);

    const app_widget = try AppWidget.init(root_arena, &app, .{ .width = window_width, .height = window_height });
    try toplevel_layout.pushWidget(app_widget);

    var gui_runner = try widget_factory.makeRunner(toplevel_layout.asWidget());

    while (!window.closed()) {
        allocators.scratch.reset();
        scratch_gl.reset();
        const width, const height = window.getWindowSize();
        const now = try std.time.Instant.now();

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
        if (try gui_runner.step(window_bounds, window_size, &window.queue)) |action| exec_action: {
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

                    // FIXME: Should we crash on failure?
                    try edit_name.appendSlice(allocators.scratch.allocator(), name);
                    try gui.textbox.executeTextEditOnArrayList(allocators.scratch.allocator(), &edit_name, params.pos, params.notifier, params.items);

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

                    // FIXME: Should we crash on failure?
                    try edit.appendSlice(allocators.scratch.allocator(), text.current_text);
                    try gui.textbox.executeTextEditOnArrayList(allocators.scratch.allocator(), &edit, params.pos, params.notifier, params.items);

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
                .toggle_composition_debug => {
                    app.toggleCompositionDebug() catch |e| {
                        logError("Failed to set composition debug state", e, @errorReturnTrace());
                    };
                },
            }
        }

        try app.step();
        try memory_tracker.step(now);

        for (gui_runner.input_state.key_tracker.pressed_this_frame.items) |key| {
            if (key.ctrl and key.key == .ascii and key.key.ascii == 'd') {
                widget_factory.state.overlay.set(memory_widget, 0, 0);
            } else if (key.key == .escape) {
                try widget_factory.state.overlay.reset();
            }
        }

        if (selected_object.value != app.input_state.selected_object.value) {
            try sidebar.handle.updateObjectProperties();
            sidebar.handle.notifyObjectChanged();
        }

        window.swapBuffers();
    }
}
