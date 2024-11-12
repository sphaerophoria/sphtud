const std = @import("std");

fn addAppDependencies(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.addCSourceFile(.{
        .file = b.path("src/stb_image.c"),
    });
    exe.linkSystemLibrary("GL");
    exe.addIncludePath(b.path("src"));
    exe.linkLibC();
    exe.linkLibCpp();
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sphimp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = opt,
    });

    addAppDependencies(b, exe);
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
    exe.addIncludePath(b.path("cimgui"));
    exe.addIncludePath(b.path("cimgui/generator/output"));
    exe.addIncludePath(b.path("cimgui/imgui/backends"));
    exe.addIncludePath(b.path("cimgui/imgui"));
    exe.defineCMacro("IMGUI_IMPL_API", "extern \"C\"");
    b.installArtifact(exe);

    const lint_exe = b.addExecutable(.{
        .name = "lint",
        .root_source_file = b.path("src/lint.zig"),
        .target = target,
        .optimize = opt,
    });
    lint_exe.linkSystemLibrary("EGL");
    lint_exe.addCSourceFile(.{
        .file = b.path("src/stb_image_write.c"),
    });

    addAppDependencies(b, lint_exe);
    b.installArtifact(lint_exe);
}
