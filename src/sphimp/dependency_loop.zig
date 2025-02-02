const std = @import("std");
const obj_mod = @import("object.zig");

const Allocator = std.mem.Allocator;
const ObjectId = obj_mod.ObjectId;
const Objects = obj_mod.Objects;

pub fn ensureNoDependencyLoops(alloc: Allocator, id: ObjectId, objects: *Objects) !void {
    var loop_checker = DependencyLoopChecker.init(alloc, objects);
    try loop_checker.ensureNoDependencyLoops(id);
}

const DependencyLoopChecker = struct {
    seen_ids: std.AutoHashMap(ObjectId, void),
    objects: *Objects,

    fn init(alloc: Allocator, objects: *Objects) DependencyLoopChecker {
        return .{
            .seen_ids = std.AutoHashMap(ObjectId, void).init(alloc),
            .objects = objects,
        };
    }

    fn ensureNoDependencyLoops(self: *DependencyLoopChecker, id: ObjectId) !void {
        if (self.seen_ids.contains(id)) {
            return error.LoopDetected;
        }

        try self.seen_ids.put(id, {});
        defer _ = self.seen_ids.remove(id);

        const obj = self.objects.get(id);

        var dependency_it = obj.dependencies();
        while (dependency_it.next()) |dep_id| {
            try self.ensureNoDependencyLoops(dep_id);
        }
    }
};
