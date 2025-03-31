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
    stbiw: *std.Build.Module,

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

        const stbiw_translate = b.addTranslateC(.{
            .root_source_file = b.path("src/stb/stb_image_write.h"),
            .target = target,
            .optimize = opt,
        });
        const stbiw = stbiw_translate.createModule();

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
        sphimp.addImport("stbiw", stbiw);
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
            .stbiw = stbiw,
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
        exe.root_module.addImport("stbiw", self.stbiw);
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

        // https://github.com/ziglang/zig/issues/22682
        //
        // Recursively clone all modules and patch out any c source files. This
        // is "fine" because...
        //
        // 1. Next zig upgrade we can just delete this
        // 2. C source files are only used in linking, which we aren't doing
        var patcher = ModulePatcher{};
        check_exe.root_module = try ModulePatcher.cloneModule(self.b.allocator, exe.root_module);
        try patcher.removeCSourceFiles(self.b.allocator, check_exe.root_module);

        self.check_step.dependOn(&check_exe.step);
        self.b.installArtifact(exe);
    }
};

const ModulePatcher = struct {
    seen_modules: std.StringArrayHashMapUnmanaged(*std.Build.Module) = .empty,

    fn cloneModule(alloc: std.mem.Allocator, old: *std.Build.Module) !*std.Build.Module {
        const new = try alloc.create(std.Build.Module);

        new.* = old.*;
        new.link_objects = try old.link_objects.clone(alloc);
        new.import_table = try old.import_table.clone(alloc);
        return new;
    }

    fn removeCSourceFiles(self: *ModulePatcher, alloc: std.mem.Allocator, m: *std.Build.Module) !void {
        var idx: usize = m.link_objects.items.len;
        while (idx > 0) {
            idx -= 1;

            switch (m.link_objects.items[idx]) {
                .c_source_file, .c_source_files => {
                    _ = m.link_objects.swapRemove(idx);
                },
                else => {},
            }
        }

        var it = m.import_table.iterator();
        while (it.next()) |entry| {
            const gop = try self.seen_modules.getOrPut(alloc, entry.key_ptr.*);
            if (!gop.found_existing) {
                const new = try cloneModule(alloc, entry.value_ptr.*);
                try self.removeCSourceFiles(alloc, new);
                gop.value_ptr.* = new;
            }
            entry.value_ptr.* = gop.value_ptr.*;
        }
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
