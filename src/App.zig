const std = @import("std");
const Allocator = std.mem.Allocator;
const lin = @import("lin.zig");
const gl = @import("gl.zig");
const Renderer = @import("Renderer.zig");
const obj_mod = @import("object.zig");
const StbImage = @import("StbImage.zig");

const Object = obj_mod.Object;
const ObjectId = obj_mod.ObjectId;
const Objects = obj_mod.Objects;

const Vec2 = lin.Vec2;
const Vec3 = lin.Vec3;
const Transform = lin.Transform;

const App = @This();

alloc: Allocator,
objects: Objects = .{},
renderer: Renderer,
window_width: usize,
window_height: usize,
mouse_pos: lin.Vec2 = .{ 0.0, 0.0 },
selected_object: ObjectId = .{ .value = 0 },

pub fn init(alloc: Allocator, window_width: usize, window_height: usize) !App {
    var objects = Objects{};
    errdefer objects.deinit(alloc);

    const renderer = try Renderer.init(alloc);

    return .{
        .alloc = alloc,
        .objects = objects,
        .renderer = renderer,
        .window_width = window_width,
        .window_height = window_height,
    };
}

pub fn deinit(self: *App) void {
    self.objects.deinit(self.alloc);
    self.renderer.deinit(self.alloc);
}

pub fn save(self: *App, path: []const u8) !void {
    const object_saves = try self.objects.save(self.alloc);
    defer self.alloc.free(object_saves);

    const out_f = try std.fs.cwd().createFile(path, .{});
    defer out_f.close();

    try std.json.stringify(
        obj_mod.SaveData{
            .objects = object_saves,
        },
        .{ .whitespace = .indent_2 },
        out_f.writer(),
    );
}

pub fn load(self: *App, path: []const u8) !void {
    const in_f = try std.fs.cwd().openFile(path, .{});
    defer in_f.close();

    var json_reader = std.json.reader(self.alloc, in_f.reader());
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(obj_mod.SaveData, self.alloc, &json_reader, .{});
    defer parsed.deinit();

    var new_objects = try Objects.initCapacity(self.alloc, parsed.value.objects.len);
    // Note that objects gets swapped in and is freed by this defer
    defer new_objects.deinit(self.alloc);

    for (parsed.value.objects) |saved_object| {
        var object = try Object.load(self.alloc, saved_object, self.renderer.path_program.vpos_location);
        errdefer object.deinit(self.alloc);

        try new_objects.append(self.alloc, object);
    }

    // Swap objects so the old ones get deinited
    std.mem.swap(Objects, &new_objects, &self.objects);

    // Loaded masks do not generate textures
    try self.regenerateAllMasks();
}

pub fn render(self: *App) !void {
    try self.renderer.render(self.alloc, &self.objects, self.selected_object, self.window_width, self.window_height);
}

pub fn setMouseDown(self: *App) void {
    switch (self.objects.get(self.selected_object).data) {
        .composition => |*c| c.selectClosestPoint(self.mouse_pos),
        .path => |*p| p.selectClosestPoint(self.mouse_pos),
        else => {},
    }
}

pub fn setMouseUp(self: *App) void {
    switch (self.objects.get(self.selected_object).data) {
        .composition => |*c| c.selected_obj = null,
        .path => |*p| p.selected_point = null,
        else => {},
    }
}

pub fn clickRightMouse(self: *App) !void {
    switch (self.objects.get(self.selected_object).data) {
        .path => |*p| {
            try p.addPoint(self.alloc, self.mouse_pos);
            try self.regeneratePathMasks(self.selected_object);
        },
        else => {},
    }
}

pub fn setMousePos(self: *App, xpos: f32, ypos: f32) !void {
    const new_x = windowToClipX(xpos, self.window_width);
    const new_y = windowToClipY(ypos, self.window_height);
    const new_pos = Vec2{ new_x, new_y };
    defer self.mouse_pos = new_pos;

    switch (self.objects.get(self.selected_object).data) {
        .composition => |*composition_object| {
            composition_object.moveObject(new_pos - self.mouse_pos);
        },
        .path => |*p| {
            p.movePoint(new_pos - self.mouse_pos);
            if (p.selected_point) |_| {
                try self.regeneratePathMasks(self.selected_object);
            }
        },
        else => {},
    }
}

pub fn createPath(self: *App) !void {
    const initial_positions: []const Vec2 = &.{
        Vec2{ -0.5, -0.5 },
        Vec2{ 0.5, 0.5 },
    };

    const path_id = self.objects.nextId();
    const path_obj = try obj_mod.PathObject.init(
        self.alloc,
        initial_positions,
        self.selected_object,
        self.renderer.path_program.vpos_location,
    );
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new path"),
        .data = .{
            .path = path_obj,
        },
    });

    const selected_dims = self.objects.get(self.selected_object).dims(&self.objects);
    const mask_id = self.objects.nextId();
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "new mask"),
        .data = .{
            .generated_mask = try obj_mod.GeneratedMaskObject.generate(self.alloc, path_id, selected_dims[0], selected_dims[1], path_obj.points.items),
        },
    });

    const masked_obj_id = self.objects.nextId();
    try self.objects.append(self.alloc, .{
        .name = try self.alloc.dupe(u8, "masked obj"),
        .data = .{
            .shader = try obj_mod.ShaderObject.init(self.alloc, &.{ self.selected_object, mask_id }, Renderer.mul_fragment_shader, &.{ "u_texture", "u_texture_2" }, selected_dims[0], selected_dims[1]),
        },
    });

    // HACK: Assume composition object is 0
    const composition = &self.objects.get(.{ .value = 0 }).data.composition;
    try composition.objects.append(self.alloc, .{
        .id = masked_obj_id,
        .transform = Transform.scale(0.5, 0.5),
    });
}

const MaskIterator = struct {
    it: Objects.IdIter,
    objects: *Objects,

    fn next(self: *MaskIterator) ?*obj_mod.GeneratedMaskObject {
        while (self.it.next()) |obj_id| {
            const obj = self.objects.get(obj_id);
            switch (obj.data) {
                .generated_mask => |*m| return m,
                else => continue,
            }
        }

        return null;
    }
};

fn regenerateMask(self: *App, mask: *obj_mod.GeneratedMaskObject) !void {
    const path_obj = self.objects.get(mask.source);
    const path = switch (path_obj.data) {
        .path => |*p| p,
        else => return error.InvalidMaskObj,
    };

    const width, const height = path_obj.dims(&self.objects);
    var tmp = try obj_mod.GeneratedMaskObject.generate(self.alloc, mask.source, width, height, path.points.items);
    defer tmp.deinit();

    std.mem.swap(obj_mod.GeneratedMaskObject, mask, &tmp);
}

fn regeneratePathMasks(self: *App, path_id: ObjectId) !void {
    var it = MaskIterator{ .it = self.objects.idIter(), .objects = &self.objects };
    while (it.next()) |mask| {
        if (mask.source.value != path_id.value) continue;
        try self.regenerateMask(mask);
    }
}

fn regenerateAllMasks(self: *App) !void {
    var it = MaskIterator{ .it = self.objects.idIter(), .objects = &self.objects };
    while (it.next()) |mask| {
        try self.regenerateMask(mask);
    }
}

fn getCompositionObj(self: *App) ?*obj_mod.CompositionObject {
    switch (self.objects.get(self.selected_object).data) {
        .composition => |*c| return c,
        else => return null,
    }
}

fn windowToClipX(xpos: f32, width: usize) f32 {
    const window_width_f: f32 = @floatFromInt(width);
    return ((xpos / window_width_f) - 0.5) * 2;
}

fn windowToClipY(ypos: f32, height: usize) f32 {
    const window_height_f: f32 = @floatFromInt(height);
    return (1.0 - (ypos / window_height_f) - 0.5) * 2;
}

pub fn loadImageToTexture(path: [:0]const u8) !gl.GLuint {
    const image = try StbImage.init(path);
    defer image.deinit();

    return Renderer.makeTextureFromRgba(image.data, image.width);
}
