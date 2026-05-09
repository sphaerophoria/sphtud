const std = @import("std");

const Builder = struct {
    with_gl: bool,
    with_glfw: bool,
    gl_extensions: []const []const u8,
    sphmath: *std.Build.Module,
    sphrender: *std.Build.Module,
    sphalloc: *std.Build.Module,
    sphutil: *std.Build.Module,
    sphxml: *std.Build.Module,
    sphnet: *std.Build.Module,
    options: *std.Build.Step.Options,
    options_all: *std.Build.Step.Options,

    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn init(b: *std.Build) Builder {
        const with_gl = b.option(bool, "with_gl", "") orelse false;
        const with_glfw = b.option(bool, "with_glfw", "") orelse false;
        const gl_extensions = b.option([]const []const u8, "gl_extensions", "") orelse &.{};

        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        const sphmath = b.dependency("sphmath", .{}).module("sphmath");
        const sphrender = b.dependency("sphrender", .{
            .gl_extensions = gl_extensions,
        }).module("sphrender");

        const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
        const sphutil = b.dependency("sphutil", .{}).module("sphutil");
        const sphxml = b.dependency("sphxml", .{}).module("sphxml");
        const sphnet = b.dependency("sphnet", .{}).module("sphnet");

        const options = b.addOptions();
        options.addOption(bool, "export_sphrender", with_gl);
        options.addOption(bool, "export_sphwindow", with_glfw);

        const options_all = b.addOptions();
        options_all.addOption(bool, "export_sphrender", true);
        options_all.addOption(bool, "export_sphwindow", true);

        return .{
            .with_gl = with_gl,
            .with_glfw = with_glfw,
            .gl_extensions = gl_extensions,
            .sphmath = sphmath,
            .sphrender = sphrender,
            .sphalloc = sphalloc,
            .sphutil = sphutil,
            .sphxml = sphxml,
            .sphnet = sphnet,
            .options = options,
            .options_all = options_all,

            .b = b,
            .target = target,
            .optimize = optimize,
        };
    }

    fn addImports(self: Builder, mod: *std.Build.Module) void {
        mod.addImport("sphalloc", self.sphalloc);
        mod.addImport("sphutil", self.sphutil);
        mod.addImport("sphmath", self.sphmath);
        mod.addImport("sphxml", self.sphxml);
        mod.addImport("sphnet", self.sphnet);
        mod.addOptions("config", self.options);

        if (self.with_gl) {
            mod.addImport("sphrender", self.sphrender);
        }

        if (self.with_glfw) {
            mod.linkSystemLibrary("glfw", .{});
            mod.link_libc = true;
        }
    }

    fn addImportsAll(self: Builder, mod: *std.Build.Module) void {
        mod.addImport("sphalloc", self.sphalloc);
        mod.addImport("sphutil", self.sphutil);
        mod.addImport("sphmath", self.sphmath);
        mod.addImport("sphxml", self.sphxml);
        mod.addImport("sphnet", self.sphnet);
        mod.addOptions("config", self.options_all);

        mod.addImport("sphrender", self.sphrender);

        mod.linkSystemLibrary("glfw", .{});
        mod.link_libc = true;
    }

    fn addExample(self: Builder, name: []const u8, path: []const u8, sphtud_all: *std.Build.Module) void {
        const example = self.b.addExecutable(.{
            .name = name,
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path(path),
                .target = self.target,
                .optimize = self.optimize,
            }),
        });
        example.root_module.addImport("sphtud", sphtud_all);
        self.b.installArtifact(example);
    }
};

pub fn build(b: *std.Build) !void {
    const builder = Builder.init(b);

    const sphtud = b.addModule("sphtud", .{
        .root_source_file = b.path("src/sphtud.zig"),
        .target = builder.target,
    });
    builder.addImports(sphtud);

    const sphtud_all = b.addModule("sphtud", .{
        .root_source_file = b.path("src/sphtud.zig"),
        .target = builder.target,
    });
    builder.addImportsAll(sphtud_all);

    const test_exe = b.addTest(.{
        .name = "sphtud_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sphtud.zig"),
            .target = builder.target,
            .optimize = builder.optimize,
        }),
    });
    builder.addImportsAll(test_exe.root_module);

    b.installArtifact(test_exe);

    builder.addExample("io_example", "src/examples/io_example.zig", sphtud_all);
    builder.addExample("gui_example", "src/examples/gui_example.zig", sphtud_all);
    builder.addExample("http_client_example", "src/examples/http_client_example.zig", sphtud_all);
    builder.addExample("http_server_example", "src/examples/http_server_example.zig", sphtud_all);
}
