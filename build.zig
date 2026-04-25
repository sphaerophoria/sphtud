const std = @import("std");

pub fn build(b: *std.Build) !void {
    const with_gl = b.option(bool, "with_gl", "") orelse false;
    const with_glfw = b.option(bool, "with_glfw", "") orelse false;
    const gl_extensions = b.option([]const []const u8, "gl_extensions", "") orelse &.{};

    const options = b.addOptions();

    const sphmath = b.dependency("sphmath", .{}).module("sphmath");
    const sphrender = b.dependency("sphrender", .{
        .gl_extensions = gl_extensions,
    }).module("sphrender");

    const sphtext = b.dependency("sphtext", .{
        .gl_extensions = gl_extensions,
    }).module("sphtext");

    const sphui = b.dependency("sphui", .{
        .gl_extensions = gl_extensions,
    }).module("sphui");

    const sphwindow = b.dependency("sphwindow", .{}).module("sphwindow");
    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphttp = b.dependency("sphttp", .{}).module("sphttp");
    const sphxml = b.dependency("sphxml", .{}).module("sphxml");
    const sphimage = b.dependency("sphimage", .{}).module("sphimage");
    const sphnet = b.dependency("sphnet", .{}).module("sphnet");
    const sphio = b.dependency("sphio", .{}).module("sphio");

    const sphtud = b.addModule("sphtud", .{
        .root_source_file = b.path("src/sphtud.zig"),
    });
    sphtud.addImport("sphalloc", sphalloc);
    sphtud.addImport("sphutil", sphutil);
    sphtud.addImport("sphmath", sphmath);
    sphtud.addImport("sphttp", sphttp);
    sphtud.addImport("sphxml", sphxml);
    sphtud.addImport("sphimage", sphimage);
    sphtud.addImport("sphnet", sphnet);
    sphtud.addImport("sphio", sphio);
    sphtud.addOptions("config", options);

    options.addOption(bool, "export_sphrender", with_gl);
    if (with_gl) {
        sphtud.addImport("sphtext", sphtext);
        sphtud.addImport("sphrender", sphrender);
        sphtud.addImport("sphui", sphui);
    }

    options.addOption(bool, "export_sphwindow", with_glfw);
    if (with_glfw) {
        sphtud.addImport("sphwindow", sphwindow);
    }
}
