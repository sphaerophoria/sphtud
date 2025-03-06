const std = @import("std");
const sphalloc = @import("sphalloc");
const MemoryTracker = sphalloc.MemoryTracker;
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphmath = @import("sphmath");
const sphimp = @import("sphimp");
const sphwindow = @import("sphwindow");
const App = sphimp.App;
const obj_mod = sphimp.object;
const gui = @import("sphui");
const ui_action = @import("sphimp_ui/ui_action.zig");
const logError = @import("sphimp_ui/util.zig").logError;
const UiAction = ui_action.UiAction;
const root_ui_mod = @import("sphimp_ui/root.zig");

const Args = struct {
    action: Action,
    exe_path: []const u8,
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
                .exe_path = process_name,
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
            .exe_path = process_name,
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

    var app = try App.init(
        try root_render_alloc.makeSubAlloc("App"),
        &allocators.scratch,
        scratch_gl,
        args.exe_path,
    );
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
                const background = try app.addShaderObject("background", background_shader_id);
                _ = try app.addDrawing(background);
            }
        },
    }

    var memory_tracker = blk: {
        const now = try std.time.Instant.now();
        break :blk try MemoryTracker.init(root_arena, now, 1000, &allocators.root);
    };

    var drag_source: ?obj_mod.ObjectId = null;

    var ui = try root_ui_mod.makeGui(
        try root_render_alloc.makeSubAlloc("gui"),
        &app,
        &allocators.scratch,
        scratch_gl,
        &memory_tracker,
        &drag_source,
    );

    var last = try std.time.Instant.now();

    while (!window.closed()) {
        allocators.scratch.reset();
        scratch_gl.reset();
        const width, const height = window.getWindowSize();
        const now = try std.time.Instant.now();
        defer last = now;

        var delta_s: f32 = @floatFromInt(now.since(last));
        delta_s /= std.time.ns_per_s;

        sphrender.gl.glViewport(0, 0, @intCast(width), @intCast(height));
        sphrender.gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const window_size = gui.PixelSize{
            .width = @intCast(width),
            .height = @intCast(height),
        };

        const selected_object = ui.app_widget.selectedObjectPtr();
        var next_object = selected_object.*;

        const step_response = try ui.runner.step(delta_s, window_size, &window.queue);
        if (step_response.action) |action| exec_action: {
            switch (action) {
                .update_selected_object => |id| {
                    next_object = id;
                },
                .create_path => {
                    const new_obj = app.createPath(selected_object.*) catch |e| {
                        logError("failed to create path", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    next_object = new_obj;
                },
                .create_composition => {
                    const new_obj = app.addComposition() catch |e| {
                        logError("failed to create composition", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    next_object = new_obj;
                },
                .create_drawing => {
                    const new_obj = app.addDrawing(selected_object.*) catch |e| {
                        logError("failed to create drawing", e, @errorReturnTrace());
                        break :exec_action;
                    };

                    next_object = new_obj;
                },
                .create_text => {
                    const new_obj = app.addText() catch |e| {
                        logError("failed to create text", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    next_object = new_obj;
                },
                .create_shader => |id| {
                    const new_obj = app.addShaderObject("new shader", id) catch |e| {
                        logError("failed to create shader", e, @errorReturnTrace());
                        break :exec_action;
                    };
                    next_object = new_obj;
                },
                .delete_selected_object => {
                    next_object = app.deleteObject(selected_object.*) catch |e| {
                        logError("failed to delete object", e, @errorReturnTrace());
                        break :exec_action;
                    };
                },
                .edit_selected_object_name => |params| {
                    const name = app.objects.get(selected_object.*).name;
                    var edit_name = std.ArrayListUnmanaged(u8){};

                    // FIXME: Should we crash on failure?
                    try edit_name.appendSlice(allocators.scratch.allocator(), name);
                    try gui.textbox.executeTextEditOnArrayList(allocators.scratch.allocator(), &edit_name, params.pos, params.notifier, params.items);

                    try app.objects.get(selected_object.*).updateName(edit_name.items);
                },
                .update_composition_width => |new_width| {
                    app.updateObjectWidth(selected_object.*, new_width) catch |e| {
                        logError("Failed to update selected object width", e, @errorReturnTrace());
                    };
                },
                .update_composition_height => |new_height| {
                    app.updateObjectHeight(selected_object.*, new_height) catch |e| {
                        logError("Failed to update selected object width", e, @errorReturnTrace());
                    };
                },
                .update_shader_float => |params| {
                    app.setShaderFloat(selected_object.*, params.uniform_idx, params.float_idx, params.val) catch |e| {
                        logError("Failed to update shader float", e, @errorReturnTrace());
                    };
                },
                .update_shader_color => |params| {
                    inline for (&.{ "r", "g", "b" }, 0..) |field, i| {
                        app.setShaderFloat(selected_object.*, params.uniform_idx, i, @field(params.color, field)) catch |e| {
                            logError("Failed to update shader " ++ field, e, @errorReturnTrace());
                        };
                    }
                },
                .update_shader_image => |params| {
                    app.setShaderImage(selected_object.*, params.uniform_idx, params.image) catch |e| {
                        logError("Failed to update shader image", e, @errorReturnTrace());
                    };
                },
                .update_drawing_source => |id| {
                    app.updateDrawingDisplayObj(selected_object.*, id) catch |e| {
                        logError("Failed to update drawing source", e, @errorReturnTrace());
                    };
                },
                .update_brush => |id| {
                    app.setDrawingObjectBrush(selected_object.*, id) catch |e| {
                        logError("Failed to chnage brush", e, @errorReturnTrace());
                    };
                    try ui.sidebar.updateObjectProperties(selected_object);
                },
                .update_path_source => |id| {
                    app.updatePathDisplayObj(selected_object.*, id) catch |e| {
                        logError("Failed to update path source", e, @errorReturnTrace());
                    };
                },
                .update_text_obj_name => |params| text_update: {
                    const text = app.objects.get(selected_object.*).asText() orelse break :text_update;

                    var edit = std.ArrayListUnmanaged(u8){};

                    // FIXME: Should we crash on failure?
                    try edit.appendSlice(allocators.scratch.allocator(), text.current_text);
                    try gui.textbox.executeTextEditOnArrayList(allocators.scratch.allocator(), &edit, params.pos, params.notifier, params.items);

                    app.updateTextObjectContent(selected_object.*, edit.items) catch |e| {
                        logError("Failed to set text content", e, @errorReturnTrace());
                    };
                },
                .update_selected_font => |font_id| {
                    app.updateFontId(selected_object.*, font_id) catch |e| {
                        logError("Failed to set font id", e, @errorReturnTrace());
                    };
                },
                .update_text_size => |size| {
                    app.updateFontSize(selected_object.*, size) catch |e| {
                        logError("Failed to set font size", e, @errorReturnTrace());
                    };
                },
                .add_to_composition => |id| blk: {
                    _ = app.addToComposition(selected_object.*, id) catch |e| {
                        logError("Failed to add object to composition", e, @errorReturnTrace());
                        break :blk;
                    };
                    try ui.sidebar.updateObjectProperties(selected_object);
                },
                .delete_from_composition => |idx| {
                    app.deleteFromComposition(selected_object.*, .{ .value = idx }) catch |e| {
                        logError("Failed to delete object from composition", e, @errorReturnTrace());
                    };
                    try ui.sidebar.updateObjectProperties(selected_object);
                },
                .toggle_composition_debug => {
                    app.toggleCompositionDebug() catch |e| {
                        logError("Failed to set composition debug state", e, @errorReturnTrace());
                    };
                },
                .set_drag_source => |v| {
                    drag_source = v;
                },
                .set_drawing_tool => |t| {
                    app.tool_params.active_drawing_tool = t;
                    try ui.sidebar.updateObjectProperties(selected_object);
                },
                .change_eraser_size => |size| {
                    app.tool_params.eraser_width = @max(size, 0.0);
                    app.renderer.eraser_preview_start = try std.time.Instant.now();
                },
            }
        }

        if (step_response.cursor_style) |style| {
            switch (style) {
                .default => window.enableCursor(),
                .hidden => window.disableCursor(),
            }
        }

        try app.step();
        try memory_tracker.step(now);

        for (ui.runner.input_state.key_tracker.pressed_this_frame.items) |key| {
            if (key.ctrl and key.key == .ascii and key.key.ascii == 'd') {
                ui.state.overlay.set(ui.memory_widget, 0, 0);
            } else if (key.key == .escape) {
                try ui.state.overlay.reset();
            } else if (key.key.eql(.{ .ascii = '`' })) {
                try ui.state.overlay.reset();
                ui.drawer.toggleOpenState();
            }
        }

        if (ui.runner.input_state.mouse_released) {
            drag_source = null;
            ui.state.drag_layer.reset();
        }

        if (selected_object.value != next_object.value) {
            ui.app_widget.app_view.setSelectedObject(next_object);
            try ui.sidebar.updateObjectProperties(selected_object);
            ui.sidebar.notifyObjectChanged();
        }

        window.swapBuffers();
    }
}
