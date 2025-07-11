const std = @import("std");

const Dependencies = struct {
    sphmath: *std.Build.Module,
    sphtext: *std.Build.Module,
    sphrender: *std.Build.Module,
    sphalloc: *std.Build.Module,
    sphutil: *std.Build.Module,
    sphwindow_events: *std.Build.Module,

    fn init(b: *std.Build) Dependencies {
        const sphmath = b.dependency("sphmath", .{});
        const sphrender = b.dependency("sphrender", .{});
        const sphtext = b.dependency("sphtext", .{});
        const sphalloc = b.dependency("sphalloc", .{});
        const sphutil = b.dependency("sphutil", .{});
        const sphwindow_events = b.dependency("sphwindow_events", .{});

        return .{
            .sphmath = sphmath.module("sphmath"),
            .sphtext = sphtext.module("sphtext"),
            .sphrender = sphrender.module("sphrender"),
            .sphalloc = sphalloc.module("sphalloc"),
            .sphutil = sphutil.module("sphutil"),
            .sphwindow_events = sphwindow_events.module("sphwindow_events"),
        };
    }

    fn add(self: Dependencies, mod: *std.Build.Module) void {
        mod.addImport("sphmath", self.sphmath);
        mod.addImport("sphrender", self.sphrender);
        mod.addImport("sphtext", self.sphtext);
        mod.addImport("sphalloc", self.sphalloc);
        mod.addImport("sphutil", self.sphutil);
        mod.addImport("sphwindow_events", self.sphwindow_events);
    }
};

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "");

    const deps = Dependencies.init(b);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sphui = b.addModule("sphui", .{
        .root_source_file = b.path("src/gui.zig"),
    });
    deps.add(sphui);

    const demo = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    deps.add(demo.root_module);
    demo.root_module.addImport("sphwindow", b.dependency("sphwindow", .{}).module("sphwindow"));
    b.installArtifact(demo);

    const gui_uts = b.addTest(.{
        .name = "gui_test",
        .root_source_file = b.path("src/gui.zig"),
    });
    deps.add(gui_uts.root_module);

    const run_gui_uts = b.addRunArtifact(gui_uts);
    test_step.dependOn(&run_gui_uts.step);
}
