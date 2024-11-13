const std = @import("std");
const Allocator = std.mem.Allocator;
const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});
const App = @import("App.zig");
const stbiw = @cImport({
    @cInclude("stb_image_write.h");
});

pub const EglContext = struct {
    display: egl.EGLDisplay,
    context: egl.EGLContext,

    pub fn init() !EglContext {
        const display = egl.eglGetDisplay(egl.EGL_DEFAULT_DISPLAY);
        if (display == egl.EGL_NO_DISPLAY) {
            return error.NoDisplay;
        }

        if (egl.eglInitialize(display, null, null) != egl.EGL_TRUE) {
            return error.EglInit;
        }
        errdefer _ = egl.eglTerminate(display);

        if (egl.eglBindAPI(egl.EGL_OPENGL_API) == egl.EGL_FALSE) {
            return error.BindApi;
        }

        var config: egl.EGLConfig = undefined;
        const attribs = [_]egl.EGLint{ egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT, egl.EGL_NONE };

        var num_configs: c_int = 0;
        if (egl.eglChooseConfig(display, &attribs, &config, 1, &num_configs) != egl.EGL_TRUE) {
            return error.ChooseConfig;
        }

        const context = egl.eglCreateContext(display, config, egl.EGL_NO_CONTEXT, null);
        errdefer _ = egl.eglDestroyContext(display, context);
        if (context == egl.EGL_NO_CONTEXT) {
            return error.CreateContext;
        }

        if (egl.eglMakeCurrent(display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, context) == 0) {
            return error.UpdateContext;
        }
        errdefer _ = egl.eglMakeCurrent(display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);

        return .{
            .display = display,
            .context = context,
        };
    }

    pub fn deinit(self: *EglContext) void {
        _ = egl.eglMakeCurrent(self.display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
        _ = egl.eglDestroyContext(self.display, self.context);
        _ = egl.eglTerminate(self.display);
    }
};

pub fn writeDummyImage(alloc: Allocator, path: [:0]const u8) !void {
    const data = try alloc.alloc(u8, 100 * 100 * 4);
    defer alloc.free(data);
    @memset(data, 0xff);
    const ret = stbiw.stbi_write_png(path, 100, 100, 4, data.ptr, 100 * 4);
    if (ret == 0) {
        return error.WriteImage;
    }
}

const swap_colors_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D u_texture;  // The texture
    \\void main()
    \\{
    \\    vec4 tmp = texture(u_texture, vec2(uv.x, 1.0 - uv.y));
    \\    fragment = vec4(tmp.y, tmp.x, tmp.z, tmp.w);
    \\}
;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() != .ok) {
            std.process.exit(1);
        }
    }

    const alloc = gpa.allocator();

    var egl_context = try EglContext.init();
    defer egl_context.deinit();

    var app = try App.init(alloc, 640, 480);
    defer app.deinit();

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var tmpdir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_path = try tmpdir.dir.realpath(".", &tmpdir_path_buf);

    var dummy_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dummy_path = try std.fmt.bufPrintZ(&dummy_path_buf, "{s}/dummy.png", .{tmpdir_path});
    try writeDummyImage(alloc, dummy_path);

    for (0..2) |_| {
        const composition_idx = app.objects.nextId();
        try app.objects.append(alloc, .{ .name = try alloc.dupe(u8, "composition"), .data = .{ .composition = App.CompositionObject{} } });

        const id = app.objects.nextId();
        try app.objects.append(alloc, .{
            .name = try alloc.dupe(u8, dummy_path),
            .data = .{ .filesystem = try App.FilesystemObject.load(alloc, dummy_path) },
        });

        const swapped_name = try std.fmt.allocPrint(alloc, "{s}_swapped", .{dummy_path});
        errdefer alloc.free(swapped_name);

        const shader_id = app.objects.nextId();
        try app.objects.append(alloc, .{ .name = swapped_name, .data = .{ .shader = try App.ShaderObject.init(alloc, id, swap_colors_frag) } });

        try app.objects.get(composition_idx).data.composition.objects.append(alloc, .{
            .id = id,
            .transform = App.Transform.scale(0.5, 0.5),
        });

        try app.objects.get(composition_idx).data.composition.objects.append(alloc, .{
            .id = shader_id,
            .transform = App.Transform.scale(0.5, 0.5),
        });
    }

    var it = app.objects.idIter();
    while (it.next()) |i| {
        app.selected_object = i;

        app.setMousePos(300, 300);
        app.setMouseDown();

        app.setMousePos(100, 100);
        app.setMouseUp();

        try app.render();
    }

    var save_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/save.json", .{tmpdir_path});

    try app.save(save_path);
    try app.load(save_path);

    it = app.objects.idIter();
    while (it.next()) |i| {
        app.selected_object = i;

        app.setMousePos(300, 300);
        app.setMouseDown();

        app.setMousePos(100, 100);
        app.setMouseUp();

        try app.render();
    }
}
