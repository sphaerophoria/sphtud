const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("sphui");
const UiAction = @import("ui_action.zig").UiAction;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;
const sphimp = @import("sphimp");
const sphmath = @import("sphmath");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const sphutil = @import("sphutil");
const sphrender = @import("sphrender");
const App = sphimp.App;
const ObjectId = sphimp.object.ObjectId;
const Objects = sphimp.object.Objects;
const Object = sphimp.object.Object;
const Vec2 = sphmath.Vec2;

const TreeView = @This();

app: *App,
scratch: *ScratchAlloc,
size: PixelSize = .{ .height = 300 },
per_frame: PerFrame,
selection_stack: SelectionStack,
thumbnail_shared: *const gui.thumbnail.Shared,
frame_shared: *const gui.frame.Shared,
widget_state: union(enum) {
    default,
    navigating: NavigationData,
} = .default,

pub fn init(
    alloc: gui.GuiAlloc,
    scratch: *ScratchAlloc,
    app: *App,
    thumbnail_shared: *const gui.thumbnail.Shared,
    root_object: *ObjectId,
    frame_shared: *const gui.frame.Shared,
) !gui.Widget(UiAction) {
    const ctx = try alloc.heap.arena().create(TreeView);
    ctx.* = .{
        .app = app,
        .scratch = scratch,
        .per_frame = .{
            .alloc = try alloc.makeSubAlloc("tree view per frame"),
        },
        .selection_stack = try SelectionStack.init(alloc.heap.arena(), root_object),
        .thumbnail_shared = thumbnail_shared,
        .frame_shared = frame_shared,
    };

    return .{
        .ctx = ctx,
        .name = "tree view",
        .vtable = &widget_vtable,
    };
}

const widget_vtable = gui.Widget(UiAction).VTable{
    .render = TreeView.render,
    .getSize = TreeView.getSize,
    .update = TreeView.update,
    .setInputState = TreeView.setInputState,
    .setFocused = null,
    .reset = TreeView.reset,
};

fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    _ = widget_bounds;

    for (0..self.per_frame.layout.data.len) |i| {
        const widget = self.per_frame.widgets[i];
        const layout = self.per_frame.layout.data[i];
        const bounds = calcBounds(layout.x_center, layout.y_center, widget.getSize());
        widget.render(bounds, window_bounds);
    }
}

fn getSize(ctx: ?*anyopaque) PixelSize {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    return self.size;
}

fn update(ctx: ?*anyopaque, available_size: PixelSize, _: f32) anyerror!void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    self.size.width = available_size.width;

    try self.per_frame.reset();
    try self.updateLayout();
    try self.updateTextureCache();
    try self.regenerateWidgets();
}

fn handleNavigationRequest(self: *TreeView, dir: NavigationDir, num_steps: u31) !void {
    switch (dir) {
        .up => {
            self.selection_stack.focus_depth -|= num_steps;
        },
        .down => {
            const focused_id = self.selection_stack.selectedId(&self.app.objects) orelse unreachable;
            for (0..num_steps) |_| {
                _ = try self.selection_stack.getChildIdx(focused_id, &self.app.objects) orelse break;
                self.selection_stack.focus_depth += 1;
            }
        },
        .left => {
            const selected_id = self.selection_stack.selectedId(&self.app.objects) orelse unreachable;
            const child_idx = try self.selection_stack.getChildIdx(selected_id, &self.app.objects) orelse return;
            child_idx.* -|= 1;
        },
        .right => {
            const selected_id = self.selection_stack.selectedId(&self.app.objects) orelse unreachable;
            const child_idx = try self.selection_stack.getChildIdx(selected_id, &self.app.objects) orelse return;
            const num_children = numDependencies(self.app.objects.get(selected_id).*);
            child_idx.* = @min(child_idx.* + num_steps, num_children - 1);
        },
    }
}

fn updateLayout(self: *TreeView) !void {
    var layout_generator = LayoutGenerator.init(
        self.scratch,
        getSize(self),
        &self.app.objects,
        self.selection_stack,
    );
    self.per_frame.layout = try layout_generator.generate(self.per_frame.alloc.heap.arena());
}

fn updateTextureCache(self: *TreeView) !void {
    var fr = self.app.makeFrameRenderer(self.per_frame.alloc.heap.general(), self.per_frame.alloc.gl);
    for (self.per_frame.layout.data) |item| {
        const id = item.id;
        const gop = try self.per_frame.texture_cache.getOrPut(
            self.per_frame.alloc.heap.general(),
            id,
        );

        if (!gop.found_existing) {
            const obj = self.app.objects.get(id).*;
            const texture = try fr.renderObjectToTexture(obj);
            const dims = obj.dims(&self.app.objects);

            gop.value_ptr.* = .{
                .size = .{
                    .width = @intCast(dims[0]),
                    .height = @intCast(dims[1]),
                },
                .texture = texture,
            };
        }
    }
}

fn regenerateWidgets(self: *TreeView) !void {
    var builder = try sphutil.RuntimeBoundedArray(gui.Widget(UiAction)).init(
        self.per_frame.alloc.heap.arena(),
        self.per_frame.layout.data.len,
    );

    for (self.per_frame.layout.data) |item| {
        const id = item.id;
        const texture_data = self.per_frame.texture_cache.get(id) orelse unreachable;

        const thumbnail = try gui.thumbnail.makeThumbnail(
            UiAction,
            self.per_frame.alloc.heap.arena(),
            texture_data,
            self.thumbnail_shared,
        );

        try thumbnail.update(.{
            .width = self.per_frame.layout.thumbnail_height,
            .height = self.per_frame.layout.thumbnail_height,
        }, 0);

        try builder.append(thumbnail);
    }

    self.per_frame.widgets = builder.items;
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(UiAction) {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    _ = widget_bounds;

    // Setting wants_focus to true forces stack widgets to acknowledge that we
    // handled input. This is critical to ensure that we can exit the
    // navigating state when the hidden cursor has moved outside the bounds of
    // our widget
    var ret: InputResponse(UiAction) = .{};

    switch (self.widget_state) {
        .default => {
            if (input_state.mouse_right_pressed and input_bounds.containsMousePos(input_state.mouse_pos)) {
                self.widget_state = .{
                    .navigating = .{
                        .last_mouse_pos = input_state.mouse_pos,
                    },
                };
                ret.cursor_style = .hidden;
            }
        },
        .navigating => |*navigation_data| blk: {
            ret.wants_focus = true;
            if (input_state.mouse_right_released) {
                self.widget_state = .default;
                ret.cursor_style = .default;
                break :blk;
            }

            const step_size_px = 50;

            const before: Vec2 = .{ navigation_data.last_mouse_pos.x, navigation_data.last_mouse_pos.y };

            const after: Vec2 = .{
                input_state.mouse_pos.x,
                input_state.mouse_pos.y,
            };

            const movement = after - before;
            const primary_movement: enum { x, y } = if (@abs(movement[0]) > @abs(movement[1])) .x else .y;

            var num_steps: u31 = 0;
            var dir: NavigationDir = undefined;

            switch (primary_movement) {
                .x => {
                    num_steps = @intFromFloat(@abs(movement[0]) / step_size_px);
                    if (num_steps > 0) {
                        dir = if (movement[0] > 0) .right else .left;
                        navigation_data.last_mouse_pos = input_state.mouse_pos;
                    }
                },
                .y => {
                    num_steps = @intFromFloat(@abs(movement[1]) / step_size_px);
                    if (num_steps > 0) {
                        dir = if (movement[1] < 0) .up else .down;
                        navigation_data.last_mouse_pos = input_state.mouse_pos;
                    }
                },
            }

            if (num_steps > 0) {
                self.handleNavigationRequest(dir, num_steps) catch |e| {
                    std.log.err("Failed to navigate: {s}", .{@errorName(e)});
                };
                ret.action = .{ .update_property_object = self.selection_stack.selectedId(&self.app.objects).? };
            }
        },
    }

    return ret;
}

fn reset(ctx: ?*anyopaque) void {
    const self: *TreeView = @ptrCast(@alignCast(ctx));
    self.selection_stack.reset();
}

const Layout = struct {
    data: []Elem = &.{},
    thumbnail_height: u31 = 0,

    const Elem = struct {
        id: ObjectId,
        x_center: i32,
        y_center: i32,
    };
};

const LayoutGenerator = struct {
    x_center: i32,
    y_center: i32,
    y_increase: i32,
    thumbnail_height: u31,
    scratch: *ScratchAlloc,
    available: PixelSize,
    objects: *Objects,
    selection_stack: SelectionStack,

    fn init(
        scratch: *ScratchAlloc,
        available: PixelSize,
        objects: *Objects,
        selection_stack: SelectionStack,
    ) LayoutGenerator {
        const thumbnail_height = available.height / 3;
        const y_increase = @min(
            thumbnail_height / 2,
            (available.height - thumbnail_height * 2) / @max(1, selection_stack.focus_depth),
        );
        const x_center = available.width / 2;
        const y_center = thumbnail_height / 2;

        return .{
            .x_center = x_center,
            .y_center = y_center,
            .y_increase = y_increase,
            .thumbnail_height = thumbnail_height,
            .scratch = scratch,
            .available = available,
            .objects = objects,
            .selection_stack = selection_stack,
        };
    }

    fn layoutParentStack(self: *LayoutGenerator, it: *SelectionStack.Iterator, out: *sphutil.RuntimeSegmentedList(Layout.Elem)) !void {
        const root_id = try it.next() orelse return;
        try self.layoutAtCursor(root_id, out);

        while (try it.next()) |id| {
            self.advanceYStacked();
            try self.layoutAtCursor(id, out);
        }
    }

    fn layoutLastElemChildren(self: *LayoutGenerator, it: *SelectionStack.Iterator, out: *sphutil.RuntimeSegmentedList(Layout.Elem)) !void {
        const last_id = it.id;
        const child_idx: u31 = it.selectedChildIdx() orelse return;

        const obj = self.objects.get(last_id);
        self.offsetXFromCenter(child_idx);

        var deps = obj.dependencies();
        while (deps.next()) |dep| {
            try self.layoutAtCursor(dep, out);
            self.advanceX();
        }
    }

    fn generate(self: *LayoutGenerator, arena: Allocator) !Layout {
        const checkpoint = self.scratch.checkpoint();
        defer self.scratch.restore(checkpoint);

        var it = self.selection_stack.iter(self.scratch, self.objects);

        var data = try sphutil.RuntimeSegmentedList(Layout.Elem).init(
            self.scratch.allocator(),
            self.scratch.allocator(),
            100,
            // In reality a tree of 1000 elements is absurd, then 10x it just
            // in case, then 10x it again. Worst case is ~=1.5M, and we'll
            // never hit that. Should be ~14 expansion slots so NBD on init
            100000,
        );

        try self.layoutParentStack(&it, &data);
        self.advanceYFull();

        try self.layoutLastElemChildren(&it, &data);

        return .{
            .data = try data.makeContiguous(arena),
            .thumbnail_height = self.thumbnail_height,
        };
    }

    fn advanceYStacked(self: *LayoutGenerator) void {
        self.y_center += self.y_increase;
    }

    fn advanceYFull(self: *LayoutGenerator) void {
        self.y_center += self.thumbnail_height;
    }

    fn offsetXFromCenter(self: *LayoutGenerator, idx: u31) void {
        self.x_center -= idx * self.thumbnail_height;
    }

    fn advanceX(self: *LayoutGenerator) void {
        self.x_center += self.thumbnail_height;
    }

    fn layoutAtCursor(self: *LayoutGenerator, id: ObjectId, out: *sphutil.RuntimeSegmentedList(Layout.Elem)) !void {
        try out.append(.{
            .id = id,
            .x_center = self.x_center,
            .y_center = self.y_center,
        });
    }
};

fn calcBounds(cx: i32, cy: i32, size: PixelSize) PixelBBox {
    const top = cy - size.height / 2;
    const left = cx - size.width / 2;

    return PixelBBox{
        .top = top,
        .left = left,
        .right = left + size.width,
        .bottom = top + size.height,
    };
}

fn depsArray(alloc: *ScratchAlloc, obj: Object) ![]ObjectId {
    var dependencies = sphutil.RuntimeBoundedArray(ObjectId).fromBuf(alloc.allocMax(ObjectId));

    var it = obj.dependencies();
    while (it.next()) |dep| {
        try dependencies.append(dep);
    }

    alloc.shrinkTo(dependencies.items.ptr + dependencies.items.len);
    return dependencies.items;
}

fn numDependencies(obj: Object) usize {
    var ret: usize = 0;

    var it = obj.dependencies();
    while (it.next()) |_| {
        ret += 1;
    }

    return ret;
}
const SelectionStack = struct {
    // u31 seems like an odd choice here, but we use this in some width related
    // math during layout. Instead of allowing usizes here and then bit casting
    // later, we might as well just limit ourselves on insertion into the map
    //
    // In reality we should have a known cap on number of image dependencies,
    // but whatever
    child_map: std.AutoHashMap(ObjectId, u31),
    focus_depth: usize = 0,
    root_object: *ObjectId,

    fn init(gpa: Allocator, root_object: *ObjectId) !SelectionStack {
        return .{
            .child_map = std.AutoHashMap(ObjectId, u31).init(gpa),
            .root_object = root_object,
        };
    }

    fn selectedId(self: SelectionStack, objects: *Objects) ?ObjectId {
        var id = self.root_object.*;
        for (0..self.focus_depth) |_| {
            const selected_idx = self.child_map.get(id) orelse return null;
            const obj = objects.get(id);
            var it = obj.dependencies();
            var dep: ?ObjectId = null;
            for (0..selected_idx + 1) |_| {
                dep = it.next();
            }

            id = dep orelse unreachable;
        }
        return id;
    }

    fn reset(self: *SelectionStack) void {
        self.child_map.clearAndFree();
        self.focus_depth = 0;
    }

    fn getChildIdx(self: *SelectionStack, id: ObjectId, objects: *Objects) !?*u31 {
        const gop = try self.child_map.getOrPut(id);
        const num_children = numDependencies(objects.get(id).*);
        if (!gop.found_existing) {
            if (num_children > 0) {
                gop.value_ptr.* = 0;
            } else {
                _ = self.child_map.remove(id);
                return null;
            }
        }

        return gop.value_ptr;
    }

    const Iterator = struct {
        parent: *const SelectionStack,
        scratch: *ScratchAlloc,
        objects: *Objects,
        id: ObjectId,
        iterations: usize = 0,
        exit_iterations: usize,

        fn next(self: *Iterator) !?ObjectId {
            if (self.iterations >= self.exit_iterations) return null;
            defer self.iterations += 1;

            const checkpoint = self.scratch.checkpoint();
            defer self.scratch.restore(checkpoint);

            const ret = self.id;

            const obj = self.objects.get(self.id);
            const child_idx = self.parent.child_map.get(self.id) orelse {
                self.iterations = self.exit_iterations;
                return ret;
            };

            // Do not advance iterator if last iteration so that we can
            // retrieve children for the last rendered element
            if (self.iterations < self.exit_iterations - 1) {
                const deps_arr = try depsArray(self.scratch, obj.*);
                self.id = deps_arr[child_idx];
            }

            return ret;
        }

        fn selectedChildIdx(self: *Iterator) ?u31 {
            if (self.parent.child_map.get(self.id)) |c| return c;

            var deps = self.objects.get(self.id).dependencies();
            // Return the first child, unless there are none
            if (deps.next() == null) {
                return null;
            }
            return 0;
        }
    };

    fn iter(self: *const SelectionStack, scratch: *ScratchAlloc, objects: *Objects) Iterator {
        return .{
            .parent = self,
            .scratch = scratch,
            .objects = objects,
            .id = self.root_object.*,
            .exit_iterations = self.focus_depth + 1,
        };
    }
};

const NavigationDir = enum {
    left,
    right,
    up,
    down,
};

const NavigationData = struct {
    last_mouse_pos: gui.MousePos,
};

const TextureData = struct {
    size: PixelSize,
    texture: sphrender.Texture,

    pub fn getSize(self: TextureData) PixelSize {
        return self.size;
    }

    pub fn getTexture(self: TextureData) sphrender.Texture {
        return self.texture;
    }
};

const PerFrame = struct {
    alloc: gui.GuiAlloc,
    layout: Layout = .{},
    texture_cache: std.AutoHashMapUnmanaged(ObjectId, TextureData) = .{},
    widgets: []gui.Widget(UiAction) = &.{},

    fn reset(self: *@This()) !void {
        try self.alloc.reset();
        self.layout = .{};
        self.texture_cache = .{};
        self.widgets = &.{};
    }
};
