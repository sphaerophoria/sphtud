const std = @import("std");

const Builder = struct {
    with_gl: bool,
    with_glfw: bool,
    gl_extensions: []const []const u8,
    sphmath: *std.Build.Module,
    sphrender: *std.Build.Module,
    sphtext: *std.Build.Module,
    sphui: *std.Build.Module,
    sphwindow: *std.Build.Module,
    sphalloc: *std.Build.Module,
    sphutil: *std.Build.Module,
    sphttp: *std.Build.Module,
    sphxml: *std.Build.Module,
    sphimage: *std.Build.Module,
    sphnet: *std.Build.Module,
    options: *std.Build.Step.Options,

    fn init(b: *std.Build) Builder {
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

        options.addOption(bool, "export_sphrender", with_gl);
        options.addOption(bool, "export_sphwindow", with_glfw);

        return .{
            .with_gl = with_gl,
            .with_glfw = with_glfw,
            .gl_extensions = gl_extensions,
            .sphmath = sphmath,
            .sphrender = sphrender,
            .sphtext = sphtext,
            .sphui = sphui,
            .sphwindow = sphwindow,
            .sphalloc = sphalloc,
            .sphutil = sphutil,
            .sphttp = sphttp,
            .sphxml = sphxml,
            .sphimage = sphimage,
            .sphnet = sphnet,
            .options = options,
        };
    }

    fn addImports(self: Builder, mod: *std.Build.Module) void {
        mod.addImport("sphalloc", self.sphalloc);
        mod.addImport("sphutil", self.sphutil);
        mod.addImport("sphmath", self.sphmath);
        mod.addImport("sphttp", self.sphttp);
        mod.addImport("sphxml", self.sphxml);
        mod.addImport("sphimage", self.sphimage);
        mod.addImport("sphnet", self.sphnet);
        mod.addOptions("config", self.options);

        if (self.with_gl) {
            mod.addImport("sphtext", self.sphtext);
            mod.addImport("sphrender", self.sphrender);
            mod.addImport("sphui", self.sphui);
        }

        if (self.with_glfw) {
            mod.addImport("sphwindow", self.sphwindow);
        }
    }
};

pub fn build(b: *std.Build) !void {
    const builder = Builder.init(b);

    const sphtud = b.addModule("sphtud", .{
        .root_source_file = b.path("src/sphtud.zig"),
    });
    builder.addImports(sphtud);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_exe = b.addTest(.{
        .name = "sphtud_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sphtud.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    builder.addImports(test_exe.root_module);

    b.installArtifact(test_exe);

    const io_example = b.addExecutable(.{
        .name = "io_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/io_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    io_example.root_module.addImport("sphtud", sphtud);
    b.installArtifact(io_example);
}
