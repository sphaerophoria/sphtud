const std = @import("std");

const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,

    check_step: *std.Build.Step,

    sphmath: *std.Build.Module,
    sphrender: *std.Build.Module,
    sphtext: *std.Build.Module,
    sphimp: *std.Build.Module,
    sphui: *std.Build.Module,
    sphwindow: *std.Build.Module,
    sphalloc: *std.Build.Module,
    sphutil: *std.Build.Module,

    fn init(b: *std.Build) Builder {
        const target = b.standardTargetOptions(.{});
        const opt = b.standardOptimizeOption(.{});

        const check_step = b.step("check", "");

        const sphmath = b.dependency("sphmath", .{}).module("sphmath");
        const sphrender = b.dependency("sphrender", .{}).module("sphrender");
        const sphtext = b.dependency("sphtext", .{}).module("sphtext");
        const sphui = b.dependency("sphui", .{}).module("sphui");
        const sphwindow = b.dependency("sphwindow", .{}).module("sphwindow");
        const sphalloc = b.dependency("sphalloc", .{}).module("sphalloc");
        const sphutil = b.dependency("sphutil", .{}).module("sphutil");

        const sphimp = b.createModule(.{
            .root_source_file = b.path("src/sphimp/sphimp.zig"),
        });
        sphimp.addImport("sphalloc", sphalloc);
        sphimp.addImport("sphrender", sphrender);
        sphimp.addImport("sphmath", sphmath);
        sphimp.addImport("sphtext", sphtext);
        sphimp.addImport("sphutil", sphutil);
        sphimp.addCSourceFiles(.{
            .root = b.path("src/stb"),
            .files = &.{ "stb_image.c", "stb_image_write.c" },
        });
        sphimp.addIncludePath(b.path("src/stb"));

        return .{
            .b = b,
            .check_step = check_step,
            .target = target,
            .opt = opt,
            .sphmath = sphmath,
            .sphrender = sphrender,
            .sphtext = sphtext,
            .sphimp = sphimp,
            .sphui = sphui,
            .sphwindow = sphwindow,
            .sphalloc = sphalloc,
            .sphutil = sphutil,
        };
    }

    fn addAppDependencies(
        self: *Builder,
        exe: *std.Build.Step.Compile,
    ) void {
        exe.linkSystemLibrary("GL");
        exe.addIncludePath(self.b.path("src/stb"));
        exe.root_module.addImport("sphmath", self.sphmath);
        exe.root_module.addImport("sphrender", self.sphrender);
        exe.root_module.addImport("sphtext", self.sphtext);
        exe.root_module.addImport("sphimp", self.sphimp);
        exe.root_module.addImport("sphalloc", self.sphalloc);
        exe.root_module.addImport("sphutil", self.sphutil);
        exe.linkLibC();
    }

    fn addGuiDependencies(self: *Builder, exe: *std.Build.Step.Compile) void {
        exe.root_module.addImport("sphui", self.sphui);
        exe.root_module.addImport("sphwindow", self.sphwindow);
    }

    fn addExecutable(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addExecutable(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn addTest(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addTest(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn installAndCheck(self: *Builder, exe: *std.Build.Step.Compile) !void {
        const check_exe = try self.b.allocator.create(std.Build.Step.Compile);
        check_exe.* = exe.*;
        self.check_step.dependOn(&check_exe.step);
        self.b.installArtifact(exe);
    }
};

pub fn build(b: *std.Build) !void {
    var builder = Builder.init(b);

    const exe = builder.addExecutable("sphimp", "src/main.zig");
    builder.addAppDependencies(exe);
    builder.addGuiDependencies(exe);
    try builder.installAndCheck(exe);

    const lint_exe = builder.addExecutable(
        "lint",
        "src/lint.zig",
    );
    lint_exe.linkSystemLibrary("EGL");
    builder.addAppDependencies(lint_exe);
    try builder.installAndCheck(lint_exe);

    b.installDirectory(.{
        .source_dir = b.path("share"),
        .install_dir = .prefix,
        .install_subdir = "share",
    });

    b.installDirectory(.{
        .source_dir = b.path("res/shaders"),
        .install_dir = .prefix,
        .install_subdir = "share/sphimp/shaders",
    });

    b.installDirectory(.{
        .source_dir = b.path("res/brushes"),
        .install_dir = .prefix,
        .install_subdir = "share/sphimp/brushes",
    });

    // FIXME: Shipping fonts that we didn't make seems a little bad... maybe we
    // should find system fonts or something
    b.installDirectory(.{
        .source_dir = b.path("res/ttf"),
        .install_dir = .prefix,
        .install_subdir = "share/sphimp/ttf",
    });

    const uts = builder.addTest(
        "test",
        "src/sphimp/App.zig",
    );
    builder.addAppDependencies(uts);

    const test_step = b.step("test", "");
    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);
}
