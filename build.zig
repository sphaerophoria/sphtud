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

    fn init(b: *std.Build) Builder {
        const target = b.standardTargetOptions(.{});
        const opt = b.standardOptimizeOption(.{});

        const check_step = b.step("check", "");

        const sphmath = b.dependency("sphmath", .{}).module("sphmath");
        const sphrender = b.dependency("sphrender", .{}).module("sphrender");
        const sphtext = b.dependency("sphtext", .{}).module("sphtext");

        const sphimp = b.createModule(.{
            .root_source_file = b.path("src/sphimp/sphimp.zig"),
        });
        sphimp.addImport("sphrender", sphrender);
        sphimp.addImport("sphmath", sphmath);
        sphimp.addImport("sphtext", sphtext);
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
        exe.linkLibC();
        exe.linkLibCpp();
    }

    fn addGuiDependencies(self: *Builder, exe: *std.Build.Step.Compile) void {
        exe.linkSystemLibrary("glfw");
        exe.addCSourceFiles(.{
            .files = &.{
                "cimgui/cimgui.cpp",
                "cimgui/imgui/imgui.cpp",
                "cimgui/imgui/imgui_draw.cpp",
                "cimgui/imgui/imgui_demo.cpp",
                "cimgui/imgui/imgui_tables.cpp",
                "cimgui/imgui/imgui_widgets.cpp",
                "cimgui/imgui/backends/imgui_impl_glfw.cpp",
                "cimgui/imgui/backends/imgui_impl_opengl3.cpp",
            },
        });
        exe.addIncludePath(self.b.path("cimgui"));
        exe.addIncludePath(self.b.path("cimgui/generator/output"));
        exe.addIncludePath(self.b.path("cimgui/imgui/backends"));
        exe.addIncludePath(self.b.path("cimgui/imgui"));
        exe.defineCMacro("IMGUI_IMPL_API", "extern \"C\"");
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

    const uts = builder.addTest(
        "test",
        "src/sphimp/App.zig",
    );
    builder.addAppDependencies(uts);

    const test_step = b.step("test", "");
    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);
}
