const std = @import("std");

pub fn build(b: *std.Build) !void {
    const with_gl = b.option(bool, "with_gl", "") orelse false;
    const with_glfw = b.option(bool, "with_glfw", "") orelse false;

    const options = b.addOptions();

    const sphmath = b.dependency("sphmath", .{}).module("sphmath");
    const sphrender = b.dependency("sphrender", .{}).module("sphrender");
    const sphtext = b.dependency("sphtext", .{}).module("sphtext");
    const sphui = b.dependency("sphui", .{}).module("sphui");
    const sphwindow = b.dependency("sphwindow", .{}).module("sphwindow");
    const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
    const sphutil = b.dependency("sphutil", .{}).module("sphutil");
    const sphevent = b.dependency("sphevent", .{}).module("sphevent");
    const sphttp = b.dependency("sphttp", .{}).module("sphttp");

    const sphtud = b.addModule("sphtud", .{
        .root_source_file = b.path("src/sphtud.zig"),
    });
    sphtud.addImport("sphalloc", sphalloc);
    sphtud.addImport("sphutil", sphutil);
    sphtud.addImport("sphmath", sphmath);
    sphtud.addImport("sphevent", sphevent);
    sphtud.addImport("sphttp", sphttp);
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
